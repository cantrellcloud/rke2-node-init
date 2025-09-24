#!/usr/bin/env bash
set -Eeuo pipefail

LOG_DIR="$(dirname "$0")/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/rkeprep_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local host; host="$(hostname)"
  echo "[$level] $msg"
  printf "%s %s rkeprep[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
}

find "$LOG_DIR" -type f -name "rkeprep_*.log" -mtime +60 -exec gzip -q {} \; -exec mv {}.gz "$LOG_DIR" \; || true

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Please run with sudo/root."
  exit 1
fi

RKE2_VERSION=""
REGISTRY="kuberegistry.dev.kube/rke2"
REG_USER="admin"
REG_PASS="ZAQwsx!@#123"
CONFIG_FILE=""
ARCH="amd64"
# Default DNS for server/agent when not specified
DEFAULT_DNS="10.0.1.34,10.231.1.34"

print_help() {
  cat <<EOF
Usage: $0 [flags] <subcommand>
Flags:
  -f <file>   YAML config file (overrides CLI flags)
  -v <ver>    RKE2 version (auto-detect if omitted)
  -r <reg>    Private registry (default: kuberegistry.dev.kube/rke2)
  -u <user>   Registry username (default: admin)
  -p <pass>   Registry password (default provided)
  -h          Help

Subcommands:
  pull   Download RKE2 images/binaries/checksums (+ install script)
  push   Load/tag/push images to the private registry (prefers containerd)
  image  Stage artifacts & registry trust for offline use (disables IPv6)
  server Configure VM as RKE2 server (prompts IP/hostname/search domains/DNS)
  agent  Configure VM as RKE2 agent (prompts IP/hostname/search domains/DNS)
  verify Run checks
EOF
}

while getopts ":f:v:r:u:p:h" opt; do
  case ${opt} in
    f) CONFIG_FILE="$OPTARG";;
    v) RKE2_VERSION="$OPTARG";;
    r) REGISTRY="$OPTARG";;
    u) REG_USER="$OPTARG";;
    p) REG_PASS="$OPTARG";;
    h) print_help; exit 0;;
    \?) echo "Invalid option -$OPTARG"; print_help; exit 1;;
    :) echo "Option -$OPTARG requires an argument"; exit 1;;
  esac
done
shift $((OPTIND-1))
SUBCOMMAND="${1:-}"

yaml_get() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  awk -F':' -v k="$key" '
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {sub(/^[[:space:]]+/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}
    $1 ~ "^[[:space:]]*"k"[[:space:]]*" {sub(/^[[:space:]]+/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}
  ' "$file" | sed -e 's/^"//; s/"$//' -e "s/^'//; s/'$//"
}

if [[ -n "$CONFIG_FILE" ]]; then
  log INFO "Loading configuration from $CONFIG_FILE (overrides CLI flags)"
  RKE2_VERSION="${RKE2_VERSION:-$(yaml_get rke2_version "$CONFIG_FILE" || true)}"
  REGISTRY="$(yaml_get registry "$CONFIG_FILE" || echo "$REGISTRY")"
  REG_USER="$(yaml_get registry_username "$CONFIG_FILE" || echo "$REG_USER")"
  REG_PASS="$(yaml_get registry_password "$CONFIG_FILE" || echo "$REG_PASS")"
  SERVER_IP="$(yaml_get server_ip "$CONFIG_FILE" || true)"
  SERVER_PREFIX="$(yaml_get server_prefix "$CONFIG_FILE" || true)"
  SERVER_HOSTNAME="$(yaml_get server_hostname "$CONFIG_FILE" || true)"
  SERVER_DNS="$(yaml_get server_dns "$CONFIG_FILE" || true)"
  SERVER_SEARCH_DOMAINS="$(yaml_get server_search_domains "$CONFIG_FILE" || true)"
  AGENT_IP="$(yaml_get agent_ip "$CONFIG_FILE" || true)"
  AGENT_PREFIX="$(yaml_get agent_prefix "$CONFIG_FILE" || true)"
  AGENT_HOSTNAME="$(yaml_get agent_hostname "$CONFIG_FILE" || true)"
  AGENT_DNS="$(yaml_get agent_dns "$CONFIG_FILE" || true)"
  AGENT_SEARCH_DOMAINS="$(yaml_get agent_search_domains "$CONFIG_FILE" || true)"
  DEFAULT_SEARCH_DOMAINS="$(yaml_get default_search_domains "$CONFIG_FILE" || true)"
  DEFAULT_DNS="$(yaml_get default_dns "$CONFIG_FILE" || echo "$DEFAULT_DNS")"
  SERVER_URL="$(yaml_get server_url "$CONFIG_FILE" || true)"
  TOKEN="$(yaml_get token "$CONFIG_FILE" || true)"
  log WARN "Config file values will override any conflicting CLI flags."
fi

ensure_installed() {
  local pkg="$1"
  if ! dpkg -s "$pkg" &>/dev/null; then
    log INFO "Installing $pkg"
    apt-get update -y && apt-get install -y "$pkg"
  fi
}

# Validation helpers
valid_ipv4() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1
  done
  return 0
}
valid_prefix() {
  local p="$1"
  [[ -z "$p" ]] && return 0
  [[ "$p" =~ ^[0-9]{1,2}$ ]] && (( p>=0 && p<=32 ))
}
valid_ipv4_or_blank() {
  local ip="$1"
  [[ -z "$ip" ]] && return 0
  valid_ipv4 "$ip"
}
valid_csv_dns() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local s="$(echo "$csv" | sed 's/,/ /g')"
  for x in $s; do
    valid_ipv4 "$x" || return 1
  done
  return 0
}
valid_search_domains_csv() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  local s="$(echo "$csv" | sed 's/,/ /g')"
  for d in $s; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
  done
  return 0
}

# Runtime detection (containerd wins; install if none; docker only if present)
RUNTIME=""
ensure_containerd_stack() {
  ensure_installed containerd
  ensure_installed nerdctl
  systemctl enable --now containerd
  RUNTIME="nerdctl"
}
detect_runtime() {
  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    RUNTIME="nerdctl"
  elif command -v containerd &>/dev/null; then
    ensure_installed nerdctl
    systemctl enable --now containerd
    RUNTIME="nerdctl"
  elif command -v docker &>/dev/null; then
    RUNTIME="docker"
  else
    log WARN "No container runtime detected. Installing containerd + nerdctl."
    ensure_containerd_stack()
  fi
}

ARCH="amd64"
# Default DNS for server/agent when not specified
DEFAULT_DNS="10.0.1.34,10.231.1.34"
IMAGES_TAR="rke2-images.linux-$ARCH.tar.zst"
RKE2_TARBALL="rke2.linux-$ARCH.tar.gz"
SHA256_FILE="sha256sum-$ARCH.txt"

if [[ -z "${RKE2_VERSION:-}" ]]; then
  log INFO "Detecting latest RKE2 version..."
  ensure_installed curl
  LATEST_JSON=$(curl -s https://api.github.com/repos/rancher/rke2/releases/latest || true)
  RKE2_VERSION="$(echo "$LATEST_JSON" | grep -Po '"tag_name": "\K[^"]+' || true)"
  [[ -n "$RKE2_VERSION" ]] || { log ERROR "Failed to detect latest RKE2 version"; exit 1; }
  log INFO "Using RKE2 version: $RKE2_VERSION"
fi

BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
IMAGES_URL="$BASE_URL/$IMAGES_TAR"
TARBALL_URL="$BASE_URL/$RKE2_TARBALL"
SHA256_URL="$BASE_URL/$SHA256_FILE"
INSTALL_SCRIPT_URL="https://get.rke2.io"
WORK_DIR="$(dirname "$0")/downloads"
mkdir -p "$WORK_DIR"

sub_pull() {
  log INFO "Downloading artifacts for $RKE2_VERSION"
  ensure_installed curl
  ensure_installed zstd
  ensure_installed ca-certificates
  pushd "$WORK_DIR" >/dev/null
  curl -Lf "$IMAGES_URL" -o "$IMAGES_TAR"
  curl -Lf "$TARBALL_URL" -o "$RKE2_TARBALL"
  curl -Lf "$SHA256_URL" -o "$SHA256_FILE"
  log INFO "Verifying checksums"
  grep "$IMAGES_TAR" "$SHA256_FILE" | sha256sum -c -
  grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c -
  curl -sfL "$INSTALL_SCRIPT_URL" -o install.sh && chmod +x install.sh
  log INFO "pull: completed (artifacts in $WORK_DIR)"
  popd >/dev/null
}

sub_push() {
  log INFO "Preparing to push images to $REGISTRY"
  detect_runtime
  log INFO "Using runtime: $RUNTIME"
  ensure_installed zstd
  [[ -f "$WORK_DIR/$IMAGES_TAR" ]] || { log ERROR "Images archive not found. Run 'pull' first."; exit 1; }
  local REG_HOST="$REGISTRY"; local REG_NS=""
  if [[ "$REGISTRY" == *"/"* ]]; then
    REG_HOST="${REGISTRY%%/*}"; REG_NS="${REGISTRY#*/}"
  fi
  if [[ "$RUNTIME" == "nerdctl" ]]; then
    nerdctl login "$REG_HOST" -u "$REG_USER" -p "$REG_PASS" >/dev/null 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; }
    zstdcat "$WORK_DIR/$IMAGES_TAR" | nerdctl -n k8s.io load
    mapfile -t imgs < <(nerdctl -n k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true)
    for IMG in "${imgs[@]}"; do
      [[ -z "$IMG" ]] && continue
      [[ -n "$REG_NS" ]] && TARGET="$REG_HOST/$REG_NS/$IMG" || TARGET="$REG_HOST/$IMG"
      log INFO "Pushing $TARGET"
      nerdctl -n k8s.io tag "$IMG" "$TARGET"
      nerdctl -n k8s.io push "$TARGET"
      nerdctl -n k8s.io rmi "$TARGET" || true
    done
    nerdctl logout "$REG_HOST" || true
  else
    ensure_installed docker.io
    systemctl enable --now docker
    echo "$REG_PASS" | docker login "$REG_HOST" --username "$REG_USER" --password-stdin 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; }
    zstdcat "$WORK_DIR/$IMAGES_TAR" | docker load
    mapfile -t imgs < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true)
    for IMG in "${imgs[@]}"; do
      [[ -n "$REG_NS" ]] && TARGET="$REG_HOST/$REG_NS/$IMG" || TARGET="$REG_HOST/$IMG"
      log INFO "Pushing $TARGET"
      docker tag "$IMG" "$TARGET"
      docker push "$TARGET"
      docker rmi "$TARGET" || true
    done
    docker logout "$REG_HOST" || true
  fi
  log INFO "push: completed successfully."
}

sub_image() {
  log INFO "Staging offline artifacts and registry trust"
  if [[ ! -f "$(dirname "$0")/certs/kuberegistry-ca.crt" ]]; then
    log ERROR "Missing certs/kuberegistry-ca.crt"; exit 1
  fi
  cp "$(dirname "$0")/certs/kuberegistry-ca.crt" /usr/local/share/ca-certificates/kuberegistry-ca.crt
  update-ca-certificates
  mkdir -p /var/lib/rancher/rke2/agent/images/
  [[ -f "$WORK_DIR/$IMAGES_TAR" ]] && cp "$WORK_DIR/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/ && log INFO "Copied images tar into agent images path"
  mkdir -p /etc/rancher/rke2/
  local REG_HOST="${REGISTRY%%/*}"
  printf 'system-default-registry: "%s"\n' "$REG_HOST" > /etc/rancher/rke2/config.yaml
  cat > /etc/rancher/rke2/registries.yaml <<EOF
mirrors:
  "docker.io":
    endpoint:
      - "https://$REG_HOST"
configs:
  "$REG_HOST":
    auth:
      username: "$REG_USER"
      password: "$REG_PASS"
    tls:
      ca_file: "/usr/local/share/ca-certificates/kuberegistry-ca.crt"
EOF
  chmod 600 /etc/rancher/rke2/registries.yaml
  if [[ -f "$WORK_DIR/$RKE2_TARBALL" ]]; then
    tar -xzf "$WORK_DIR/$RKE2_TARBALL" -C /usr/local/bin/ --no-same-owner || true
    [[ -f /usr/local/bin/rke2 ]] && chmod +x /usr/local/bin/rke2
  fi
  # Disable IPv6
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  log INFO "IPv6 disabled via sysctl."
  log INFO "image: offline staging complete."
}

write_netplan() {
  local ip="$1" prefix="$2" gw="$3" dns_csv="$4" search_csv="$5"
  local nic
  nic="$(ip -o -4 route show to default | awk '{print $5}' || true)"
  [[ -z "$nic" ]] && nic="$(ls /sys/class/net | grep -v lo | head -n1)"
  local search_line=""
  if [[ -n "$search_csv" ]]; then
    local csv="$(echo "$search_csv" | sed 's/,/ /g')"
    local arr=($csv)
    local joined="$(printf ', %s' "${arr[@]}")"; joined="${joined:2}"
    search_line="      search: [${joined}]"
  fi
  local dns_line="addresses: [8.8.8.8]"
  if [[ -n "$dns_csv" ]]; then
    local dns_csv_sp="$(echo "$dns_csv" | sed 's/,/ /g')"
    local d_arr=($dns_csv_sp)
    local d_join="$(printf ', %s' "${d_arr[@]}")"; d_join="${d_join:2}"
    dns_line="addresses: [${d_join}]"
  fi
  cat > /etc/netplan/99-rke-static.yaml <<EOF
network:
  version: 2
  ethernets:
    $nic:
      addresses: [$ip/${prefix:-24}]
      $( [[ -n "$gw" ]] && echo "gateway4: $gw" )
      nameservers:
        ${dns_line}
${search_line}
EOF
  log INFO "Netplan written for $nic with IP $ip; DNS: ${dns_csv:-<default>}; search: ${search_csv:-<none>}"
}

sub_server() {
  log INFO "Configuring as RKE2 server"
  ensure_installed curl
  [[ -f "$WORK_DIR/install.sh" ]] || { log ERROR "Missing downloads/install.sh. Run 'pull' first."; exit 1; }
  SERVER_IP="${SERVER_IP:-}"; SERVER_PREFIX="${SERVER_PREFIX:-}"; SERVER_HOSTNAME="${SERVER_HOSTNAME:-}"; GATEWAY="${GATEWAY:-}"; SERVER_DNS="${SERVER_DNS:-}"; SERVER_SEARCH_DOMAINS="${SERVER_SEARCH_DOMAINS:-}"
  [[ -z "$SERVER_IP" ]] && read -rp "Enter static IP for this server node: " SERVER_IP
  [[ -z "$SERVER_PREFIX" ]] && read -rp "Enter subnet prefix length for this server node (0-32) [default 24]: " SERVER_PREFIX || true
  [[ -z "$SERVER_HOSTNAME" ]] && read -rp "Enter hostname for this server node: " SERVER_HOSTNAME
  read -rp "Enter default gateway IP [leave blank to skip]: " GATEWAY || true
  if [[ -z "${SERVER_DNS:-}" ]]; then read -rp "Enter DNS server IP(s) (comma-separated) [leave blank for default ${DEFAULT_DNS}]: " SERVER_DNS || true; fi
  if [[ -z "${SERVER_DNS:-}" ]]; then SERVER_DNS="$DEFAULT_DNS"; log INFO "Using default DNS for server: $SERVER_DNS"; fi
  if [[ -z "${SERVER_SEARCH_DOMAINS:-}" && -n "${DEFAULT_SEARCH_DOMAINS:-}" ]]; then SERVER_SEARCH_DOMAINS="$DEFAULT_SEARCH_DOMAINS"; log INFO "Using default search domains: $SERVER_SEARCH_DOMAINS"; fi
  if [[ -z "${SERVER_SEARCH_DOMAINS:-}" ]]; then read -rp "Enter search domain(s) (comma-separated) [optional]: " SERVER_SEARCH_DOMAINS || true; fi
  # Validate
  while ! valid_ipv4 "$SERVER_IP"; do read -rp "Invalid IPv4. Re-enter server IP: " SERVER_IP; done
  while ! valid_prefix "${SERVER_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " SERVER_PREFIX; done
  while ! valid_ipv4_or_blank "${GATEWAY:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GATEWAY; done
  while ! valid_csv_dns "${SERVER_DNS:-}"; do read -rp "Invalid DNS list. Re-enter comma-separated IPv4s: " SERVER_DNS; done
  while ! valid_search_domains_csv "${SERVER_SEARCH_DOMAINS:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SERVER_SEARCH_DOMAINS; done
  [[ -z "${SERVER_PREFIX:-}" ]] && SERVER_PREFIX=24
  pushd "$WORK_DIR" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$WORK_DIR" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null
  systemctl enable rke2-server
  hostnamectl set-hostname "$SERVER_HOSTNAME"
  grep -q "$SERVER_HOSTNAME" /etc/hosts || echo "$SERVER_IP $SERVER_HOSTNAME" >> /etc/hosts
  write_netplan "$SERVER_IP" "$SERVER_PREFIX" "${GATEWAY:-}" "${SERVER_DNS:-}" "${SERVER_SEARCH_DOMAINS:-}"
  echo "A reboot is required to apply network changes."
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot; else log WARN "Reboot deferred. Please reboot before using this node."; fi
}

sub_agent() {
  log INFO "Configuring as RKE2 agent"
  ensure_installed curl
  [[ -f "$WORK_DIR/install.sh" ]] || { log ERROR "Missing downloads/install.sh. Run 'pull' first."; exit 1; }
  AGENT_IP="${AGENT_IP:-}"; AGENT_PREFIX="${AGENT_PREFIX:-}"; AGENT_HOSTNAME="${AGENT_HOSTNAME:-}"; GATEWAY="${GATEWAY:-}"; AGENT_DNS="${AGENT_DNS:-}"; AGENT_SEARCH_DOMAINS="${AGENT_SEARCH_DOMAINS:-}"
  [[ -z "$AGENT_IP" ]] && read -rp "Enter static IP for this agent node: " AGENT_IP
  [[ -z "$AGENT_PREFIX" ]] && read -rp "Enter subnet prefix length for this agent node (0-32) [default 24]: " AGENT_PREFIX || true
  [[ -z "$AGENT_HOSTNAME" ]] && read -rp "Enter hostname for this agent node: " AGENT_HOSTNAME
  read -rp "Enter default gateway IP [leave blank to skip]: " GATEWAY || true
  if [[ -z "${AGENT_DNS:-}" ]]; then read -rp "Enter DNS server IP(s) (comma-separated) [leave blank for default ${DEFAULT_DNS}]: " AGENT_DNS || true; fi
  if [[ -z "${AGENT_DNS:-}" ]]; then AGENT_DNS="$DEFAULT_DNS"; log INFO "Using default DNS for agent: $AGENT_DNS"; fi
  if [[ -z "${AGENT_SEARCH_DOMAINS:-}" && -n "${DEFAULT_SEARCH_DOMAINS:-}" ]]; then AGENT_SEARCH_DOMAINS="$DEFAULT_SEARCH_DOMAINS"; log INFO "Using default search domains: $AGENT_SEARCH_DOMAINS"; fi
  if [[ -z "${AGENT_SEARCH_DOMAINS:-}" ]]; then read -rp "Enter search domain(s) (comma-separated) [optional]: " AGENT_SEARCH_DOMAINS || true; fi
  # Validate
  while ! valid_ipv4 "$AGENT_IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " AGENT_IP; done
  while ! valid_prefix "${AGENT_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " AGENT_PREFIX; done
  while ! valid_ipv4_or_blank "${GATEWAY:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GATEWAY; done
  while ! valid_csv_dns "${AGENT_DNS:-}"; do read -rp "Invalid DNS list. Re-enter comma-separated IPv4s: " AGENT_DNS; done
  while ! valid_search_domains_csv "${AGENT_SEARCH_DOMAINS:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " AGENT_SEARCH_DOMAINS; done
  [[ -z "${AGENT_PREFIX:-}" ]] && AGENT_PREFIX=24
  if [[ -z "${SERVER_URL:-}" ]]; then read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " SERVER_URL || true; fi
  if [[ -n "$SERVER_URL" && -z "${TOKEN:-}" ]]; then read -rp "Enter cluster join token [optional]: " TOKEN || true; fi
  pushd "$WORK_DIR" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$WORK_DIR" INSTALL_RKE2_TYPE="agent" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null
  systemctl enable rke2-agent
  [[ -n "${SERVER_URL:-}" ]] && echo "server: \"$SERVER_URL\"" >> /etc/rancher/rke2/config.yaml
  [[ -n "${TOKEN:-}" ]] && echo "token: \"$TOKEN\"" >> /etc/rancher/rke2/config.yaml
  hostnamectl set-hostname "$AGENT_HOSTNAME"
  grep -q "$AGENT_HOSTNAME" /etc/hosts || echo "$AGENT_IP $AGENT_HOSTNAME" >> /etc/hosts
  write_netplan "$AGENT_IP" "$AGENT_PREFIX" "${GATEWAY:-}" "${AGENT_DNS:-}" "${AGENT_SEARCH_DOMAINS:-}"
  echo "A reboot is required to apply network changes."
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot; else log WARN "Reboot deferred. Please reboot before using this node."; fi
}

sub_verify() {
  log INFO "Verifying installation"
  . /etc/os-release || true
  log INFO "OS: ${PRETTY_NAME:-unknown}"
  if command -v rke2 &>/dev/null; then
    v=$(rke2 --version | grep -oE 'v[0-9].+rke2r[0-9]+' || true)
    log INFO "rke2 found: ${v:-unknown}"
  else
    log WARN "rke2 binary not found"
  fi
  if systemctl is-enabled --quiet rke2-server 2>/dev/null; then
    log INFO "rke2-server enabled"
  elif systemctl is-enabled --quiet rke2-agent 2>/dev/null; then
    log INFO "rke2-agent enabled"
  else
    log WARN "Neither rke2-server nor rke2-agent is enabled"
  fi
  if [[ -f /etc/netplan/99-rke-static.yaml ]]; then
    log INFO "Netplan static config present"
  else
    log WARN "Netplan static config missing"
  fi
  if [[ -f /etc/rancher/rke2/config.yaml ]]; then
    log INFO "config.yaml present"
  else
    log WARN "/etc/rancher/rke2/config.yaml missing"
  fi
  if [[ -f /etc/rancher/rke2/registries.yaml ]]; then
    log INFO "registries.yaml present"
  else
    log WARN "/etc/rancher/rke2/registries.yaml missing"
  fi
  log INFO "verify: complete"
}

case "${SUBCOMMAND:-}" in
  pull)   sub_pull;;
  push)   sub_push;;
  image)  sub_image;;
  server) sub_server;;
  agent)  sub_agent;;
  verify) sub_verify;;
  *) print_help; exit 1;;
esac
