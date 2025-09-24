#!/usr/bin/env bash
set -Eeuo pipefail
LOG_DIR="$(dirname "$0")/logs"; mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/rkeprep_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"
log(){ local l="$1";shift; local m="$*"; local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; local h; h="$(hostname)"; echo "[$l] $m"; printf "%s %s rkeprep[%d]: %s %s\n" "$ts" "$h" "$$" "$l:" "$m" >> "$LOG_FILE"; }
find "$LOG_DIR" -type f -name "rkeprep_*.log" -mtime +60 -exec gzip -q {} \; -exec mv {}.gz "$LOG_DIR" \; || true
[[ $EUID -eq 0 ]] || { echo "ERROR: Please run with sudo/root."; exit 1; }

RKE2_VERSION=""; REGISTRY="kuberegistry.dev.kube/rke2"; REG_USER="admin"; REG_PASS="ZAQwsx!@#123"; CONFIG_FILE=""; ARCH="amd64"; DEFAULT_DNS="10.0.1.34,10.231.1.34"; AUTO_YES=0; PRINT_CONFIG=0

print_help(){ cat <<EOF
Usage: $0 [flags] <subcommand>
Flags:
  -f <file>   Kubernetes-style YAML (one manifest per file, kind must match subcommand)
  -v <ver>    RKE2 version (auto-detect if omitted)
  -r <reg>    Private registry (default: kuberegistry.dev.kube/rke2)
  -u <user>   Registry username (default: admin)
  -p <pass>   Registry password (default provided)
  -y          Assume yes to prompts (auto-reboot on server/agent)
  -P          Print sanitized YAML config and continue
  -h          Help
Subcommands: pull | push | image | server | agent | verify
EOF
}

while getopts ":f:v:r:u:p:yPh" opt; do
  case ${opt} in
    f) CONFIG_FILE="$OPTARG";;
    v) RKE2_VERSION="$OPTARG";;
    r) REGISTRY="$OPTARG";;
    u) REG_USER="$OPTARG";;
    p) REG_PASS="$OPTARG";;
    y) AUTO_YES=1;;
    P) PRINT_CONFIG=1;;
    h) print_help; exit 0;;
    \?) echo "Invalid option -$OPTARG"; print_help; exit 1;;
    :) echo "Option -$OPTARG requires an argument"; exit 1;;
  esac
done
shift $((OPTIND-1)); SUBCOMMAND="${1:-}"

yaml_get_kind(){ grep -E '^[[:space:]]*kind:' "$1" | awk -F: '{print $2}' | xargs; }
yaml_get_apiversion(){ grep -E '^[[:space:]]*apiVersion:' "$1" | awk -F: '{print $2}' | xargs; }
yaml_spec_get(){ awk -v k="$2" 'BEGIN{inSpec=0} /^[[:space:]]*spec:[[:space:]]*$/{inSpec=1;next} inSpec==1{ if ($0 ~ /^[^[:space:]]/) exit; if ($0 ~ "^[[:space:]]+"k"[[:space:]]*:"){sub(/^[[:space:]]+/, "", $0); sub(k"[[:space:]]*:[[:space:]]*", "", $0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print $0; exit}}' "$1"; }
normalize_list_csv(){ local v="$1"; v="${v#[}"; v="${v%]}"; v="${v//\"/}"; v="${v//\'/}"; echo "$v" | sed 's/,/ /g' | xargs | sed 's/ /, /g'; }
sanitize_and_print_yaml(){ local f="$1"; echo "----- Sanitized YAML (secrets masked) -----"; sed -E -e 's/(registryPassword:[[:space:]]*)"[^"]*"/\1"********"/' -e 's/(registryPassword:[[:space:]]*)([^"[:space:]].*)/\1"********"/' -e 's/(token:[[:space:]]*)"[^"]*"/\1"********"/' -e 's/(token:[[:space:]]*)([^"[:space:]].*)/\1"********"/' "$f"; echo "------------------------------------------"; }

if [[ -n "$CONFIG_FILE" ]]; then
  [[ -f "$CONFIG_FILE" ]] || { log ERROR "YAML file not found: $CONFIG_FILE"; exit 1; }
  AV="$(yaml_get_apiversion "$CONFIG_FILE" || true)"; KD="$(yaml_get_kind "$CONFIG_FILE" || true)"
  [[ "$AV" == "rkeprep/v1" ]] || { log ERROR "Unsupported apiVersion: ${AV:-<missing>} (expected rkeprep/v1)"; exit 1; }
  [[ -n "$SUBCOMMAND" ]] || { log ERROR "No subcommand provided."; exit 1; }
  case "$(tr '[:lower:]' '[:upper:]' <<< "$SUBCOMMAND")" in PULL) REQ_KIND="Pull";; PUSH) REQ_KIND="Push";; IMAGE) REQ_KIND="Image";; SERVER) REQ_KIND="Server";; AGENT) REQ_KIND="Agent";; VERIFY) REQ_KIND="";; esac
  if [[ -n "$REQ_KIND" && "$KD" != "$REQ_KIND" ]]; then log ERROR "YAML kind '$KD' does not match subcommand '$SUBCOMMAND' (expected $REQ_KIND)"; exit 1; fi
  [[ "$PRINT_CONFIG" -eq 1 ]] && sanitize_and_print_yaml "$CONFIG_FILE"
fi

ensure_installed(){ dpkg -s "$1" &>/dev/null || { log INFO "Installing $1"; apt-get update -y && apt-get install -y "$1"; }; }
valid_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS='.' read -r a b c d <<<"$1"; for n in "$a" "$b" "$c" "$d"; do [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1; done; }
valid_prefix(){ [[ -z "$1" ]] && return 0; [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( $1>=0 && $1<=32 )); }
valid_ipv4_or_blank(){ [[ -z "$1" ]] && return 0; valid_ipv4 "$1"; }
valid_csv_dns(){ [[ -z "$1" ]] && return 0; local s="$(echo "$1" | sed 's/,/ /g')"; for x in $s; do valid_ipv4 "$x" || return 1; done; }
valid_search_domains_csv(){ [[ -z "$1" ]] && return 0; local s="$(echo "$1" | sed 's/,/ /g')"; for d in $s; do [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1; done; }

RUNTIME=""
ensure_containerd_stack(){ ensure_installed containerd; ensure_installed nerdctl; systemctl enable --now containerd; RUNTIME="nerdctl"; }
detect_runtime(){ if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then RUNTIME="nerdctl"; elif command -v containerd &>/dev/null; then ensure_installed nerdctl; systemctl enable --now containerd; RUNTIME="nerdctl"; elif command -v docker &>/dev/null; then RUNTIME="docker"; else log WARN "No container runtime detected. Installing containerd + nerdctl."; ensure_containerd_stack; fi; }

ARCH="amd64"; IMAGES_TAR="rke2-images.linux-$ARCH.tar.zst"; RKE2_TARBALL="rke2.linux-$ARCH.tar.gz"; SHA256_FILE="sha256sum-$ARCH.txt"

detect_latest_version(){ if [[ -z "${RKE2_VERSION:-}" ]]; then log INFO "Detecting latest RKE2 version..."; ensure_installed curl; LATEST_JSON=$(curl -s https://api.github.com/repos/rancher/rke2/releases/latest || true); RKE2_VERSION="$(echo "$LATEST_JSON" | grep -Po '"tag_name": "\\K[^"]+' || true)"; [[ -n "$RKE2_VERSION" ]] || { log ERROR "Failed to detect latest RKE2 version"; exit 1; }; log INFO "Using RKE2 version: $RKE2_VERSION"; fi; }

sub_pull(){ if [[ -n "$CONFIG_FILE" ]]; then RKE2_VERSION="${RKE2_VERSION:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"; REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"; REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"; REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"; log WARN "Using YAML values; conflicting CLI flags are overridden."; fi; detect_latest_version; local B="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"; local IU="$B/$IMAGES_TAR"; local TU="$B/$RKE2_TARBALL"; local SU="$B/$SHA256_FILE"; local IU2="https://get.rke2.io"; local W="$(dirname "$0")/downloads"; mkdir -p "$W"; log INFO "Downloading artifacts for $RKE2_VERSION"; ensure_installed curl; ensure_installed zstd; ensure_installed ca-certificates; pushd "$W" >/dev/null; curl -Lf "$IU" -o "$IMAGES_TAR"; curl -Lf "$TU" -o "$RKE2_TARBALL"; curl -Lf "$SU" -o "$SHA256_FILE"; log INFO "Verifying checksums"; grep "$IMAGES_TAR" "$SHA256_FILE" | sha256sum -c -; grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c -; curl -sfL "$IU2" -o install.sh && chmod +x install.sh; log INFO "pull: completed (artifacts in $W)"; popd >/dev/null; }

sub_push(){ if [[ -n "$CONFIG_FILE" ]]; then REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"; REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"; REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"; log WARN "Using YAML values; conflicting CLI flags are overridden."; fi; detect_runtime; log INFO "Using runtime: $RUNTIME"; ensure_installed zstd; local W="$(dirname "$0")/downloads"; [[ -f "$W/$IMAGES_TAR" ]] || { log ERROR "Images archive not found. Run 'pull' first."; exit 1; } local HOST="$REGISTRY"; local NS=""; if [[ "$REGISTRY" == *"/"* ]]; then HOST="${REGISTRY%%/*}"; NS="${REGISTRY#*/}"; fi; if [[ "$RUNTIME" == "nerdctl" ]]; then nerdctl login "$HOST" -u "$REG_USER" -p "$REG_PASS" >/dev/null 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; } zstdcat "$W/$IMAGES_TAR" | nerdctl -n k8s.io load; mapfile -t imgs < <(nerdctl -n k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true); for IMG in "${imgs[@]}"; do [[ -z "$IMG" ]] && continue; [[ -n "$NS" ]] && T="$HOST/$NS/$IMG" || T="$HOST/$IMG"; log INFO "Pushing $T"; nerdctl -n k8s.io tag "$IMG" "$T"; nerdctl -n k8s.io push "$T"; nerdctl -n k8s.io rmi "$T" || true; done; nerdctl logout "$HOST" || true; else ensure_installed docker.io; systemctl enable --now docker; echo "$REG_PASS" | docker login "$HOST" --username "$REG_USER" --password-stdin 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; } zstdcat "$W/$IMAGES_TAR" | docker load; mapfile -t imgs < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true); for IMG in "${imgs[@]}"; do [[ -n "$NS" ]] && T="$HOST/$NS/$IMG" || T="$HOST/$IMG"; log INFO "Pushing $T"; docker tag "$IMG" "$T"; docker push "$T"; docker rmi "$T" || true; done; docker logout "$HOST" || true; fi; log INFO "push: completed successfully."; }

sub_image(){ local W="$(dirname "$0")/downloads"; local HOST="${REGISTRY%%/*}"; local defaultDnsCsv="$DEFAULT_DNS"; local defaultSearchCsv=""; if [[ -n "$CONFIG_FILE" ]]; then local D1="$(yaml_spec_get "$CONFIG_FILE" defaultDns || true)"; [[ -n "$D1" ]] && defaultDnsCsv="$(normalize_list_csv "$D1")"; local S1="$(yaml_spec_get "$CONFIG_FILE" defaultSearchDomains || true)"; [[ -n "$S1" ]] && defaultSearchCsv="$(normalize_list_csv "$S1")"; REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"; REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"; REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"; HOST="${REGISTRY%%/*}"; log WARN "Using YAML values; conflicting CLI flags are overridden."; fi; [[ -f "$(dirname "$0")/certs/kuberegistry-ca.crt" ]] || { log ERROR "Missing certs/kuberegistry-ca.crt"; exit 1; } cp "$(dirname "$0")/certs/kuberegistry-ca.crt" /usr/local/share/ca-certificates/kuberegistry-ca.crt; update-ca-certificates; mkdir -p /var/lib/rancher/rke2/agent/images/; [[ -f "$W/$IMAGES_TAR" ]] && cp "$W/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/ && log INFO "Copied images tar into agent images path"; mkdir -p /etc/rancher/rke2/; printf 'system-default-registry: "%s"\n' "$HOST" > /etc/rancher/rke2/config.yaml; cat > /etc/rancher/rke2/registries.yaml <<EOF
mirrors:
  "docker.io":
    endpoint:
      - "https://$HOST"
configs:
  "$HOST":
    auth:
      username: "$REG_USER"
      password: "$REG_PASS"
    tls:
      ca_file: "/usr/local/share/ca-certificates/kuberegistry-ca.crt"
EOF
  chmod 600 /etc/rancher/rke2/registries.yaml
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  STATE="/etc/rke2image.defaults"; echo "DEFAULT_DNS=\"${defaultDnsCsv}\"" > "$STATE"; echo "DEFAULT_SEARCH=\"${defaultSearchCsv}\"" >> "$STATE"; chmod 600 "$STATE"; log INFO "Saved site defaults: DNS=[${defaultDnsCsv}] SEARCH=[${defaultSearchCsv}]"; log INFO "image: offline staging complete."; }

write_netplan(){ local ip="$1" prefix="$2" gw="$3" dns_csv="$4" search_csv="$5"; local nic; nic="$(ip -o -4 route show to default | awk '{print $5}' || true)"; [[ -z "$nic" ]] && nic="$(ls /sys/class/net | grep -v lo | head -n1)"; local search_line=""; if [[ -n "$search_csv" ]]; then local csv="$(echo "$search_csv" | sed 's/,/ /g')"; local arr=($csv); local joined="$(printf ', %s' "${arr[@]}")"; joined="${joined:2}"; search_line="      search: [${joined}]"; fi; local dns_line="addresses: [${dns_csv:-8.8.8.8}]"; if [[ -n "$dns_csv" ]]; then local dns_csv_sp="$(echo "$dns_csv" | sed 's/,/ /g')"; local d_arr=($dns_csv_sp); local d_join="$(printf ', %s' "${d_arr[@]}")"; d_join="${d_join:2}"; dns_line="addresses: [${d_join}]"; fi; cat > /etc/netplan/99-rke-static.yaml <<EOF
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
  log INFO "Netplan written for $nic with IP $ip; DNS: ${dns_csv:-<default>}; search: ${search_csv:-<none>}"; }

load_site_defaults(){ local S="/etc/rke2image.defaults"; if [[ -f "$S" ]]; then . "$S"; [[ -n "${DEFAULT_DNS:-}" ]] && DEFAULT_DNS="$DEFAULT_DNS"; DEFAULT_SEARCH="${DEFAULT_SEARCH:-}"; else DEFAULT_SEARCH=""; fi; }

sub_server(){ load_site_defaults; local S_IP="" S_PREFIX="" S_HOST="" S_DNS="" S_SEARCH="" S_GW=""; if [[ -n "$CONFIG_FILE" ]]; then S_IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"; S_PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"; S_HOST="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"; local d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && S_DNS="$(normalize_list_csv "$d")"; local sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && S_SEARCH="$(normalize_list_csv "$sd")"; fi; [[ -n "$S_IP" ]] || read -rp "Enter static IP for this server node: " S_IP; [[ -n "$S_PREFIX" ]] || read -rp "Enter subnet prefix length for this server node (0-32) [default 24]: " S_PREFIX; [[ -n "$S_HOST" ]] || read -rp "Enter hostname for this server node: " S_HOST; read -rp "Enter default gateway IP [leave blank to skip]: " S_GW || true; if [[ -z "$S_DNS" ]]; then read -rp "Enter DNS server IP(s) (comma-separated) [leave blank for default ${DEFAULT_DNS}]: " S_DNS || true; [[ -z "$S_DNS" ]] && S_DNS="$DEFAULT_DNS" && log INFO "Using default DNS for server: $S_DNS"; fi; if [[ -z "$S_SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then S_SEARCH="$DEFAULT_SEARCH"; log INFO "Using default search domains for server: $S_SEARCH"; fi; while ! valid_ipv4 "$S_IP"; do read -rp "Invalid IPv4. Re-enter server IP: " S_IP; done; while ! valid_prefix "${S_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " S_PREFIX; done; while ! valid_ipv4_or_blank "${S_GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " S_GW; done; while ! valid_csv_dns "${S_DNS:-}"; do read -rp "Invalid DNS list. Re-enter comma-separated IPv4s: " S_DNS; done; while ! valid_search_domains_csv "${S_SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " S_SEARCH; done; [[ -z "${S_PREFIX:-}" ]] && S_PREFIX=24; local W="$(dirname "$0")/downloads"; [[ -f "$W/install.sh" ]] || { log ERROR "Missing downloads/install.sh. Run 'pull' first."; exit 1; } pushd "$W" >/dev/null; INSTALL_RKE2_ARTIFACT_PATH="$W" sh install.sh >/dev/null 2>>"$LOG_FILE"; popd >/dev/null; systemctl enable rke2-server; hostnamectl set-hostname "$S_HOST"; grep -q "$S_HOST" /etc/hosts || echo "$S_IP $S_HOST" >> /etc/hosts; write_netplan "$S_IP" "$S_PREFIX" "${S_GW:-}" "${S_DNS:-}" "${S_SEARCH:-}"; echo "A reboot is required to apply network changes."; if [[ "$AUTO_YES" -eq 1 ]]; then log INFO "Auto-yes enabled: rebooting now."; reboot; fi; read -rp "Reboot now? [y/N]: " confirm; if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot; else log WARN "Reboot deferred. Please reboot before using this node."; fi; }

sub_agent(){ load_site_defaults; local A_IP="" A_PREFIX="" A_HOST="" A_DNS="" A_SEARCH="" A_GW="" A_URL="" A_TOKEN=""; if [[ -n "$CONFIG_FILE" ]]; then A_IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"; A_PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"; A_HOST="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"; local d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && A_DNS="$(normalize_list_csv "$d")"; local sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && A_SEARCH="$(normalize_list_csv "$sd")"; A_URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"; A_TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"; fi; [[ -n "$A_IP" ]] || read -rp "Enter static IP for this agent node: " A_IP; [[ -n "$A_PREFIX" ]] || read -rp "Enter subnet prefix length for this agent node (0-32) [default 24]: " A_PREFIX; [[ -n "$A_HOST" ]] || read -rp "Enter hostname for this agent node: " A_HOST; read -rp "Enter default gateway IP [leave blank to skip]: " A_GW || true; if [[ -z "$A_DNS" ]]; then read -rp "Enter DNS server IP(s) (comma-separated) [leave blank for default ${DEFAULT_DNS}]: " A_DNS || true; [[ -z "$A_DNS" ]] && A_DNS="$DEFAULT_DNS" && log INFO "Using default DNS for agent: $A_DNS"; fi; if [[ -z "$A_SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then A_SEARCH="$DEFAULT_SEARCH"; log INFO "Using default search domains for agent: $A_SEARCH"; fi; while ! valid_ipv4 "$A_IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " A_IP; done; while ! valid_prefix "${A_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " A_PREFIX; done; while ! valid_ipv4_or_blank "${A_GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " A_GW; done; while ! valid_csv_dns "${A_DNS:-}"; do read -rp "Invalid DNS list. Re-enter comma-separated IPv4s: " A_DNS; done; while ! valid_search_domains_csv "${A_SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " A_SEARCH; done; [[ -z "${A_PREFIX:-}" ]] && A_PREFIX=24; if [[ -z "${A_URL:-}" ]]; then read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " A_URL || true; fi; if [[ -n "$A_URL" && -z "${A_TOKEN:-}" ]]; then read -rp "Enter cluster join token [optional]: " A_TOKEN || true; fi; local W="$(dirname "$0")/downloads"; [[ -f "$W/install.sh" ]] || { log ERROR "Missing downloads/install.sh. Run 'pull' first."; exit 1; } pushd "$W" >/dev/null; INSTALL_RKE2_ARTIFACT_PATH="$W" INSTALL_RKE2_TYPE="agent" sh install.sh >/dev/null 2>>"$LOG_FILE"; popd >/dev/null; systemctl enable rke2-agent; [[ -n "${A_URL:-}" ]] && echo "server: \"$A_URL\"" >> /etc/rancher/rke2/config.yaml; [[ -n "${A_TOKEN:-}" ]] && echo "token: \"$A_TOKEN\"" >> /etc/rancher/rke2/config.yaml; hostnamectl set-hostname "$A_HOST"; grep -q "$A_HOST" /etc/hosts || echo "$A_IP $A_HOST" >> /etc/hosts; write_netplan "$A_IP" "$A_PREFIX" "${A_GW:-}" "${A_DNS:-}" "${A_SEARCH:-}"; echo "A reboot is required to apply network changes."; if [[ "$AUTO_YES" -eq 1 ]]; then log INFO "Auto-yes enabled: rebooting now."; reboot; fi; read -rp "Reboot now? [y/N]: " confirm; if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot; else log WARN "Reboot deferred. Please reboot before using this node."; fi; }

sub_verify(){ log INFO "Verifying installation"; . /etc/os-release || true; log INFO "OS: ${PRETTY_NAME:-unknown}"; if command -v rke2 &>/dev/null; then v=$(rke2 --version | grep -oE 'v[0-9].+rke2r[0-9]+' || true); log INFO "rke2 found: ${v:-unknown}"; else log WARN "rke2 binary not found"; fi; if systemctl is-enabled --quiet rke2-server 2>/dev/null; then log INFO "rke2-server enabled"; elif systemctl is-enabled --quiet rke2-agent 2>/dev/null; then log INFO "rke2-agent enabled"; else log WARN "Neither rke2-server nor rke2-agent is enabled"; fi; [[ -f /etc/netplan/99-rke-static.yaml ]] && log INFO "Netplan static config present" || log WARN "Netplan static config missing"; [[ -f /etc/rancher/rke2/config.yaml ]] && log INFO "config.yaml present" || log WARN "/etc/rancher/rke2/config.yaml missing"; [[ -f /etc/rancher/rke2/registries.yaml ]] && log INFO "registries.yaml present" || log WARN "/etc/rancher/rke2/registries.yaml missing"; log INFO "verify: complete"; }

case "${SUBCOMMAND:-}" in pull) sub_pull;; push) sub_push;; image) sub_image;; server) sub_server;; agent) sub_agent;; verify) sub_verify;; *) print_help; exit 1;; esac
