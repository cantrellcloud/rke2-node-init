#!/usr/bin/env bash
#
# If not running under bash, re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# Fail fast on CRLF (Windows) endings, which can also trigger odd parse errors
case "$(head -c 2 "$0" | od -An -t x1 | tr -d ' ')" in
  *0d0a) echo "ERROR: Windows line endings detected. Run: dos2unix '$0'"; exit 2;;
esac

#
# rke2nodeinit.sh  (containerd-only edition)
# ----------------------------------------------------
# Purpose:
#   Prepare and configure a Linux VM/host (Ubuntu/Debian-based) for an offline/air-gapped
#   Rancher RKE2 Kubernetes deployment using **containerd + nerdctl** ONLY.
#
# Actions:
#   1) pull   - Download RKE2 artifacts (images + tarball + checksums) on an online host
#   2) push   - Tag and push preloaded images into a private registry (nerdctl only)
#   3) image  - Stage artifacts, registries config, CA certs, and OS prereqs for offline use
#   4) server - Configure network/hostname and install rke2-server (offline)
#   5) agent  - Configure network/hostname and install rke2-agent  (offline)
#   6) verify - Check that node prerequisites are in place
#
# Major changes vs previous:
#   - Docker support removed end-to-end.
#   - If Docker is present, we *ask* to uninstall it before proceeding.
#   - Runtime install uses official "nerdctl-full" bundle (includes containerd, runc, CNI, BuildKit).
#   - Fixed verify() return code logic so success returns 0.
#   - Added progress indicators + extra logging for containerd/nerdctl install.
#   - Hardened Netplan so old IP/GW don’t return after reboot (cloud-init disabled; old YAMLs removed).
#
# Safety:
#   - set -Eeuo pipefail
#   - global ERR trap emits line number
#   - root check
#   - strong input validation for IP/prefix/DNS/search
#
# YAML (apiVersion: rkeprep/v1) kinds determine action when using -f <file>:
#   - kind: Pull|pull, Push|push, Image|image, Server|server, AddServer|add-server|addServer, Agent|agent, ClusterCA|cluster-ca
#
# Exit codes:
#   0 success | 1 usage | 2 missing prerequisites | 3 data missing | 4 registry auth | 5 YAML issues
# -----------------------------------------------------------------------------------------

set -Eeuo pipefail
trap 'rc=$?; echo "[ERROR] Unexpected failure (exit $rc) at line $LINENO"; exit $rc' ERR
umask 022
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ---------- Paths -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
LOG_DIR="$SCRIPT_DIR/logs"
OUT_DIR="$SCRIPT_DIR/outputs"
DOWNLOADS_DIR="$SCRIPT_DIR/downloads"
STAGE_DIR="/opt/rke2/stage"
SBOM_DIR="$OUT_DIR/sbom"

mkdir -p "$LOG_DIR" "$OUT_DIR" "$DOWNLOADS_DIR" "$STAGE_DIR" "$SBOM_DIR"

# ---------- Logging ----------------------------------------------------------------------------
LOG_FILE="$LOG_DIR/rke2nodeinit_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"

# ---------- Functions () --------------------------------------------
log() {
  local level="$1"; shift
  local msg="$*"
  local ts host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  host="$(hostname)"
  echo "[$level] $msg"
  printf "%s %s rke2nodeinit[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
}

# Simple spinner for long-running steps (visible progress indicator)
spinner_run() {
  local label="$1"; shift
  local cmd=( "$@" )
  log INFO "$label..."

  ( "${cmd[@]}" >>"$LOG_FILE" 2>&1 ) &
  local pid=$!

  # Forward signals to the child so Ctrl-C works cleanly
  trap 'kill -TERM "$pid" 2>/dev/null' TERM INT

  local spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r[WORK] %s %s" "${spin:i++%${#spin}:1}" "$label"
    sleep 0.15
  done

  # <-- this is the critical change: protect wait from set -e
  local rc
  if wait "$pid"; then
    rc=0
  else
    rc=$?
  fi

  trap - TERM INT
  printf "\r"
  if (( rc == 0 )); then
    echo "[DONE] $label"
    log INFO "$label...done"
  else
    echo "[FAIL] $label (rc=$rc)"
    log ERROR "$label failed (rc=$rc). See $LOG_FILE"
    exit "$rc"
  fi
}

# Simple progress utilities
download_with_progress() {
  # usage: download_with_progress <url> <out> [label]
  local url="$1" out="$2" label="${3:-Downloading $(basename "$2")}"
  log INFO "$label ($url -> $out)"
  mkdir -p "$(dirname "$out")"
  # Prefer curl progress bar; fall back to wget; else spinner
  if command -v curl >/dev/null 2>&1; then
    # Use curl's progress bar (to stderr), while logging to file
    {
      curl -L --fail --progress-bar "$url" -o "$out" 2> >(stdbuf -oL tr -d '\r' | sed -u 's/^/[DL] /') 
    } >>"$LOG_FILE" 2>>"$LOG_FILE"
    rc=$?
  elif command -v wget >/dev/null 2>&1; then
    {
      wget --progress=bar:force:noscroll -O "$out" "$url" 2>&1 | sed -u 's/^/[DL] /'
    } >>"$LOG_FILE" 2>>"$LOG_FILE"
    rc=$?
  else
    spinner_run "$label" sh -c "python3 - <<'PY'\nimport sys, time\nfor i in range(40):\n print('.', end='', flush=True); time.sleep(0.1)\nprint()\nPY"
    rc=0
  fi
  if (( rc != 0 )); then
    log ERROR "Download failed: $url"
    return $rc
  fi
  echo "[OK] $(basename "$out")"
}

extract_with_progress() {
  # usage: extract_with_progress <tarfile> <destdir> [flags]
  local tarfile="$1" dest="$2" flags="${3:--xzf}"
  local label="Extracting $(basename "$tarfile")"
  local rc=0

  mkdir -p "$dest"

  # Strip 'f' from combined flags; we'll always pass -f explicitly
  local tar_flags="${flags//f/}"

  if command -v pv >/dev/null 2>&1; then
    # Show byte progress if pv is present
    pv "$tarfile" | tar $tar_flags -f - -C "$dest" >>"$LOG_FILE" 2>&1
    rc=$?
  else
    # Use tar checkpoints to emit dots to the console
    spinner_run "$label" tar $tar_flags -f "$tarfile" -C "$dest"
    rc=$?
  fi

  if (( rc != 0 )); then
    log ERROR "Extraction failed: $tarfile"
    return $rc
  fi
  echo "[OK] $(basename "$tarfile") extracted"
}

process_stream_with_progress() {
  # usage: process_stream_with_progress <infile> <command...>
  # Example: process_stream_with_progress rke2-images.tar.zst "zstd -d -c | nerdctl -n k8s.io load"
  local infile="$1"; shift
  local pipeline="$*"
  local label="Processing $(basename "$infile")"
  if command -v pv >/dev/null 2>&1; then
    # pv -> pipeline
    bash -c "pv \"$infile\" | eval \"$pipeline\"" >>"$LOG_FILE" 2>&1 &
    local pid=$!
    spinner_run "$label" bash -c "wait $pid"
  else
    spinner_run "$label" bash -c "eval \"$pipeline\"" 
  fi
}


# Rotate/compress logs older than 60 days
find "$LOG_DIR" -type f -name "rke2nodeinit_*.log" -mtime +60 -exec gzip -q {} \; -exec mv {}.gz "$LOG_DIR" \; || true

# ---------- Root check -------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: please run this script as root (use sudo)."
  exit 1
fi

# ---------- Defaults & tunables ----------------------------------------------------------------
RKE2_VERSION=""                                       # auto-detect if empty
REGISTRY="rke2registry.dev.local/rke2"
REG_USER="admin"
REG_PASS="ZAQwsx!@#123"
CONFIG_FILE=""
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64";;
  aarch64) ARCH="arm64";;
  *) ARCH="amd64";;
esac

DEFAULT_DNS="10.0.1.34,10.231.1.34"
AUTO_YES=0                  # -y auto-confirm reboots *and* Docker removal if detected
PRINT_CONFIG=0              # -P print sanitized YAML
DRY_PUSH=0                  # --dry-push skips actual registry push
RUNTIME="nerdctl"           # fixed; Docker removed

# Artifacts
IMAGES_TAR="rke2-images.linux-$ARCH.tar.zst"
RKE2_TARBALL="rke2.linux-$ARCH.tar.gz"
SHA256_FILE="sha256sum-$ARCH.txt"

# ---------- Help --------------------------------------------------------------------------------
print_help() {
  cat <<'EOF'
Usage:
  sudo ./rke2nodeinit.sh -f file.yaml [options]
  sudo ./rke2nodeinit.sh [options] <pull|push|image|server|add-server|agent|cluster-ca|verify>
  sudo ./rke2nodeinit.sh examples/pull.yaml


YAML kinds (apiVersion: rkeprep/v1):
  - kind: Pull|push|Image|Server|AddServer|Agent|ClusterCA|Verify

Example: ClusterCA
---
apiVersion: rkeprep/v1
kind: ClusterCA
spec:
  # Absolute or relative to the script directory
  rootCrt: certs/enterprise-root.crt
  rootKey: certs/enterprise-root.key        # optional; OR use intermediate* below
  intermediateCrt: certs/issuing-ca.crt     # optional
  intermediateKey: certs/issuing-ca.key     # optional
  installToOSTrust: true                    # default true
---

Options:
  -f FILE     YAML config (apiVersion: rkeprep/v1; kind selects action)
  -v VER      RKE2 version tag (e.g., v1.34.1+rke2r1). If omitted, auto-detect latest
  -r REG      Private registry (host[/namespace]), e.g., reg.example.org/rke2
  -u USER     Registry username
  -p PASS     Registry password
  -y          Auto-confirm prompts (reboots, Docker removal)
  -P          Print sanitized YAML to screen (masks secrets)
  -h          Show this help
  --dry-push  Do not actually push images to registry (simulate only)

Server mode flags (when not using -f kind: Server):
  -t TOKEN              Cluster token
  -T TOKEN_FILE         Path to token file on disk
  -l TLS_SANS           Comma-separated TLS SANs for the API server
  -n NODE_IP            Node internal IP
  -e NODE_EXTERNAL_IP   Node external IP
  -S SERVICE_CIDR       Kubernetes service CIDR
  -C CLUSTER_CIDR       Kubernetes pod/cluster CIDR
  -D CLUSTER_DOMAIN     Cluster DNS domain
  -M MODE               write-kubeconfig-mode (e.g., 0640)
  -R ROOT_CRT           Custom CA root certificate (for custom cluster CA)
  -K ROOT_KEY           Custom CA root private key
  -I INT_CRT            Custom intermediate certificate (optional)
  -J INT_KEY            Custom intermediate private key (optional)
  -X 0|1                Install the provided root into OS trust (default 1)

Agent mode flags (when not using -f kind: Agent):
  -s URL                RKE2 server URL (https://host:9345)
  -t TOKEN              Cluster token
  -T TOKEN_FILE         Path to token file on disk
  -n NODE_IP            Node internal IP
  -e NODE_EXTERNAL_IP   Node external IP
  -l TLS_SANS           Optional TLS SANs
  -C CA_CERT            CA certificate to install into local OS trust

EOF
}

# ---------- Lightweight YAML helpers ------------------------------------------------------------
yaml_get_api()  { grep -E '^[[:space:]]*apiVersion:[[:space:]]*' "$1" | awk -F: '{print $2}' | xargs; }
yaml_get_kind() { grep -E '^[[:space:]]*kind:[[:space:]]*'       "$1" | awk -F: '{print $2}' | xargs; }

yaml_spec_get() {
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { inSpec=0 }
    /^[[:space:]]*spec:[[:space:]]*$/ { inSpec=1; next }
    inSpec==1 {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ "^[[:space:]]+" k "[[:space:]]*:") {
        sub(/^[[:space:]]+/, "", $0)
        sub(k "[[:space:]]*:[[:space:]]*", "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}

sanitize_yaml() {
  sed -E \
    -e 's/(registryPassword:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(registryPassword:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    -e 's/(token:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(token:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    "$1"
}

normalize_list_csv() {
  local v="$1"
  v="${v#[}"; v="${v%]}"
  v="${v//\"/}"; v="${v//\'/}"
  echo "$v" | sed 's/,/ /g' | xargs | sed 's/ /, /g'
}

# ---------- Validators --------------------------------------------------------------------------
valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$1"
  for n in "$a" "$b" "$c" "$d"; do [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1; done
}
valid_prefix() { [[ -z "$1" ]] && return 0; [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( $1>=0 && $1<=32 )); }
valid_ipv4_or_blank() { [[ -z "$1" ]] && return 0; valid_ipv4 "$1"; }
valid_csv_dns() {
  [[ -z "$1" ]] && return 0
  local s; s="$(echo "$1" | sed 's/,/ /g')"
  for x in $s; do valid_ipv4 "$x" || return 1; done
}
valid_search_domains_csv() {
  [[ -z "$1" ]] && return 0
  local s; s="$(echo "$1" | sed 's/,/ /g')"
  for d in $s; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
  done
}

# ---------- APT helper --------------------------------------------------------------------------
ensure_installed() {
  local pkg="$1"
  dpkg -s "$pkg" &>/dev/null || {
    log INFO "Installing package: $pkg"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
  }
}

# ---------- Runtime: enforce containerd + nerdctl (FULL) ----------------------------------------
ask_remove_docker_if_present() {
  if command -v docker >/dev/null 2>&1; then
    log WARN "Docker detected on this host."
    if [[ "$AUTO_YES" -eq 1 ]]; then
      reply="y"
    else
      read -rp "Remove Docker packages and proceed with containerd+nerdctl? [y/N]: " reply
    fi
    case "$reply" in
      [Yy])
      spinner_run "Stopping/Disabling Docker" systemctl stop docker
      systemctl disable docker >>"$LOG_FILE" 2>&1 || true
      export DEBIAN_FRONTEND=noninteractive
      spinner_run "Purging Docker packages" apt-get purge -y docker.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin moby-engine moby-cli
      apt-get autoremove -y >>"$LOG_FILE" 2>&1 || true
      rm -rf /var/lib/docker /etc/docker >>"$LOG_FILE" 2>&1 || true
      log INFO "Docker removed."
      ;;
      *)
        log ERROR "Docker must be removed to proceed (this script is containerd-only)."
        exit 2
      ;;
    esac
  fi
}

install_containerd_nerdctl_from_cache() {
  local tgz="$1"
  [[ -f "$tgz" ]] || { log ERROR "Cached nerdctl FULL bundle not found: $tgz"; return 2; }
  ensure_installed tar
  spinner_run "Extracting nerdctl FULL (cached)" tar -C /usr/local -xzf "$tgz"
  spinner_run "Reloading systemd units" systemctl daemon-reload
  mkdir -p /etc/containerd
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  spinner_run "Enabling and starting containerd" systemctl enable --now containerd
  log INFO "nerdctl installed (cached): $(/usr/local/bin/nerdctl --version 2>/dev/null || echo unknown)"
}

install_containerd_nerdctl_full() {
  # Install containerd + runc + CNI + BuildKit + nerdctl from the official "full" tarball.
  ensure_installed curl
  ensure_installed ca-certificates
  ensure_installed tar

  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local tag ver url tmp
  log INFO "Detecting latest nerdctl FULL release..."
  tag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  [[ -z "$tag" ]] && { log ERROR "Failed to detect latest nerdctl release tag"; exit 2; }
  ver="${tag#v}"
  url="https://github.com/containerd/nerdctl/releases/download/${tag}/nerdctl-full-${ver}-linux-${ARCH}.tar.gz"
  tmp="$(mktemp -d)"

  log INFO "Downloading nerdctl FULL bundle ${tag} for ${ARCH}"
  spinner_run "Downloading nerdctl FULL ${tag}" curl -fL "$url" -o "$tmp/nerdctl-full.tgz"

  spinner_run "Extracting nerdctl FULL bundle" tar -C /usr/local -xzf "$tmp/nerdctl-full.tgz"
  rm -rf "$tmp" >>"$LOG_FILE" 2>&1 || true

  # Ensure systemd sees the unit files from the bundle (/usr/local/lib/systemd/system)
  spinner_run "Reloading systemd units" systemctl daemon-reload

  # Generate containerd config with systemd cgroup driver
  mkdir -p /etc/containerd
  if ! command -v containerd >/dev/null 2>&1; then
    log ERROR "containerd binary not found after install (unexpected)."
    exit 2
  fi
  log INFO "Writing /etc/containerd/config.toml (SystemdCgroup=true)"
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  # Start containerd
  spinner_run "Enabling and starting containerd" systemctl enable --now containerd

  # Confirm nerdctl
  if ! /usr/local/bin/nerdctl --version >/dev/null 2>&1; then
    log ERROR "nerdctl not found after install (unexpected)."
    exit 2
  fi
  log INFO "nerdctl installed: $(/usr/local/bin/nerdctl --version)"

  # Extra: log CNI + runc versions for traceability
  if command -v runc >/dev/null 2>&1; then log INFO "runc: $(runc --version | head -n1)"; fi
  if [[ -d /opt/cni/bin ]]; then log INFO "CNI plugins present: $(/bin/ls -1 /opt/cni/bin | wc -l) files"; fi
}

ensure_containerd_ready() {
  ask_remove_docker_if_present

  if systemctl is-active --quiet containerd && command -v nerdctl >/dev/null 2>&1; then
    log INFO "containerd + nerdctl are present and active."
  else
    # Try offline cache first
    local cached
    cached="$(ls -1 "$DOWNLOADS_DIR"/nerdctl-full-*-linux-"$ARCH".tar.gz 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$cached" ]]; then
      log INFO "Installing containerd+nerdctl from cached bundle: $(basename "$cached")"
      install_containerd_nerdctl_from_cache "$cached"
    else
      log WARN "containerd + nerdctl not ready; installing the official FULL bundle (online)."
      install_containerd_nerdctl_full
    fi
  fi  # Namespace used by Kubernetes

  if ! nerdctl --namespace k8s.io images >/dev/null 2>&1; then
    nerdctl --namespace k8s.io images >/dev/null 2>&1 || true
  fi
}

# ---------- RKE2 version detection --------------------------------------------------------------
detect_latest_rke2_version() {
  if [[ -z "${RKE2_VERSION:-}" ]]; then
    log INFO "Detecting latest RKE2 version from GitHub..."
    ensure_installed curl
    local j
    j="$(curl -fsSL https://api.github.com/repos/rancher/rke2/releases/latest || true)"
    RKE2_VERSION="$(echo "$j" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
    [[ -z "$RKE2_VERSION" ]] && { log ERROR "Failed to detect latest RKE2 version"; exit 2; }
    log INFO "Using RKE2 version: $RKE2_VERSION"
  fi
}

# ---------- Netplan helpers (robust) ------------------------------------------------------------
disable_cloud_init_net() {
  # prevent cloud-init from overwriting netplan on reboot
  mkdir -p /etc/cloud/cloud.cfg.d
  cat >/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg <<'EOF'
# Disable cloud-init network configuration; netplan is managed by rke2nodeinit
network: {config: disabled}
EOF
  log INFO "cloud-init network rendering disabled (/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg)"
}

purge_old_netplan() {
  # back up and remove all existing netplan YAMLs to avoid merged old configs
  local bdir="/etc/netplan/.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$bdir"
  shopt -s nullglob
  local moved=0
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ "$(basename "$f")" == "99-rke-static.yaml" ]] && continue
    mv "$f" "$bdir/" && moved=1
  done
  shopt -u nullglob
  if (( moved )); then
    log WARN "Moved existing netplan files to $bdir"
  else
    log INFO "No prior netplan files to move"
  fi
}

apply_netplan_now() {
  # Apply and verify current state; this makes changes effective immediately and also persists through reboot
  if command -v netplan >/dev/null 2>&1; then
    spinner_run "Generating netplan" netplan generate
    spinner_run "Applying netplan" netplan apply
  else
    log ERROR "netplan not found on this system."
    return 1
  fi
  return 0
}

# ---------- Netplan writer (static IPv4 + DNS + search domains) --------------------------------
write_netplan() {
  # Usage: write_netplan IP PREFIX GATEWAY DNS_CSV SEARCH_CSV
  local ip="$1"; local prefix="$2"; local gw="${3:-}"; local dns_csv="${4:-}"; local search_csv="${5:-}"

  # Detect primary NIC
  local nic
  nic="$(ip -o -4 route show to default | awk '{print $5}' || true)"
  [[ -z "$nic" ]] && nic="$(ls /sys/class/net | grep -Ev '^(lo|docker|cni|flannel|kube|veth|virbr|br-)' | head -n1)"
  [[ -z "$nic" ]] && { log ERROR "Failed to detect a primary network interface"; exit 2; }

  export NETPLAN_LAST_NIC="$nic"

  disable_cloud_init_net
  purge_old_netplan

  local tmp="/etc/netplan/99-rke-static.yaml"
  : > "$tmp"

  {
    echo "network:"
    echo "  version: 2"
    echo "  renderer: networkd"
    echo "  ethernets:"
    echo "    $nic:"
    echo "      dhcp4: false"
    echo "      addresses:"
    echo "        - $ip/${prefix:-24}"
    if [[ -n "$gw" ]]; then
      echo "      routes:"
      echo "        - to: default"
      echo "          via: $gw"
    fi
    echo "      nameservers:"
    if [[ -n "$dns_csv" ]]; then
      local dns_sp arr joined
      dns_sp="$(echo "$dns_csv" | sed 's/,/ /g')"
      read -r -a arr <<<"$dns_sp"
      joined="$(printf ', %s' "${arr[@]}")"; joined="${joined:2}"
      echo "        addresses: [$joined]"
    else
      echo "        addresses: [8.8.8.8]"
    fi
    if [[ -n "$search_csv" ]]; then
      local sd_sp arr2 joined2
      sd_sp="$(echo "$search_csv" | sed 's/,/ /g')"
      read -r -a arr2 <<<"$sd_sp"
      joined2="$(printf ', %s' "${arr2[@]}")"; joined2="${joined2:2}"
      echo "        search: [$joined2]"
    fi
  } >> "$tmp"

  chmod 600 "$tmp"
  log INFO "Netplan written to $tmp for $nic (IP=$ip/${prefix:-24}, GW=${gw:-<none>}, DNS=${dns_csv:-<default>}, SEARCH=${search_csv:-<none>})"

  # Apply immediately (and persists after reboot because other YAMLs are purged and cloud-init is disabled)
  apply_netplan_now || true

  # Quick verification snapshot
  ip -4 addr show dev "$nic"   | sed 's/^/IFACE: /'  >>"$LOG_FILE" 2>&1 || true
  ip route show default        | sed 's/^/ROUTE: /'  >>"$LOG_FILE" 2>&1 || true
}

# ---------- Site defaults -----------------------------------------------------------------------
load_site_defaults() {
  local STATE="/etc/rke2image.defaults"
  if [[ -f "$STATE" ]]; then
    # shellcheck source=/dev/null
    . "$STATE"
    DEFAULT_DNS="${DEFAULT_DNS:-$DEFAULT_DNS}"
    DEFAULT_SEARCH="${DEFAULT_SEARCH:-}"
  else
    DEFAULT_SEARCH=""
  fi
}

# ---------- OS prereqs --------------------------------------------------------------------------
install_rke2_prereqs() {
  log INFO "Installing RKE2 prereqs (iptables-nft, modules, sysctl, swapoff)"
  export DEBIAN_FRONTEND=noninteractive
  log INFO "Updating APT package cache"
  spinner_run "Updating APT package cache" apt-get update -y # >>"$LOG_FILE" 2>&1
  log INFO "Upgrading APT packages"
  spinner_run "Upgrading APT packages" apt-get upgrade -y # >>"$LOG_FILE" 2>&1
  log INFO "Installing required packages"
  spinner_run "Installing required packages" apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq # >>"$LOG_FILE" 2>&1
  log INFO "Removing unnecessary packages"
  spinner_run "Removing unnecessary packages" apt-get autoremove -y # >>"$LOG_FILE" 2>&1

  if update-alternatives --list iptables >/dev/null 2>&1; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set arptables /usr/sbin/arptables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set ebtables  /usr/sbin/ebtables-nft  >>"$LOG_FILE" 2>&1 || true
  fi

  cat >/etc/modules-load.d/rke2.conf <<EOF
br_netfilter
overlay
EOF
  modprobe br_netfilter || true
  modprobe overlay || true

  cat >/etc/sysctl.d/90-rke2.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true

  sed -i.bak '/\sswap\s/s/^/#/g' /etc/fstab || true
  swapoff -a || true
}

verify_prereqs() {
  local fail=0
  log INFO "Verifying prerequisites and environment..."

  for m in br_netfilter overlay; do
    if lsmod | grep -q "^${m}"; then
      log INFO "Module present: $m"
    else
      log ERROR "Module missing: $m"; fail=1
    fi
  done

  [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 0)" == "1" ]] || { log ERROR "sysctl bridge-nf-call-iptables != 1"; fail=1; }
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1"           ]] || { log ERROR "sysctl ip_forward != 1"; fail=1; }

  if [[ -z "$(swapon --summary)" ]]; then
    log INFO "Swap is disabled"
  else
    log ERROR "Swap is enabled"; fail=1
  fi

  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    log INFO "Runtime OK: containerd + nerdctl"
  else
    log ERROR "containerd + nerdctl not ready"; fail=1
  fi

  [[ -f "$SCRIPT_DIR/downloads/$IMAGES_TAR"     ]] && log INFO "Found images archive"     || log WARN "Images archive missing ($SCRIPT_DIR/downloads)"
  [[ -f "$SCRIPT_DIR/downloads/$RKE2_TARBALL"   ]] && log INFO "Found RKE2 tarball"       || log WARN "RKE2 tarball missing ($SCRIPT_DIR/downloads)"
  [[ -f "$STAGE_DIR/install.sh"                 ]] && log INFO "Staged installer present" || log WARN "Staged installer missing ($STAGE_DIR)"
  [[ -f /etc/rancher/rke2/registries.yaml      ]] && log INFO "registries.yaml present"   || log WARN "registries.yaml missing"
  # Verify the CA file referenced in registries.yaml (if any)
  if [[ -f /etc/rancher/rke2/registries.yaml ]]; then
    CA_FILE_PATH="$(awk -F': *' '/ca_file:/ {gsub(/"/,"",$2); print $2}' /etc/rancher/rke2/registries.yaml | head -n1)"
    if [[ -n "$CA_FILE_PATH" && -f "$CA_FILE_PATH" ]]; then
      log INFO "Registry CA present: $CA_FILE_PATH"
    else
      log WARN "Registry CA file missing or not set in registries.yaml"
    fi
  fi

  # --- Custom Cluster CA sub-check ---
  verify_custom_cluster_ca || fail=1

  return $fail
}

# ---------- SBOM / metadata (optional) ----------------------------------------------------------
sanitize_img() { echo "$1" | sed 's#/#_#g; s#:#_#g'; }

gen_inspect_json() {
  local img="$1"
  nerdctl -n k8s.io inspect "$img" 2>/dev/null || echo "{}"
}

gen_sbom_or_metadata() {
  local img="$1" base
  base="$(sanitize_img "$img")"
  if command -v syft &>/dev/null; then
    syft "$img" -o spdx-json > "$SBOM_DIR/${base}.spdx.json" 2>>"$LOG_FILE" || true
    log INFO "SBOM written: $SBOM_DIR/${base}.spdx.json"
  else
    gen_inspect_json "$img" > "$SBOM_DIR/${base}.inspect.json"
    log INFO "Inspect metadata written: $SBOM_DIR/${base}.inspect.json"
  fi
}

run_rke2_installer() {
  local src="$1"
  local itype="${2:-}"
  set +e
  if [[ -n "$itype" ]]; then
    INSTALL_RKE2_TYPE="$itype" INSTALL_RKE2_ARTIFACT_PATH="$src" "$src/install.sh" >>"$LOG_FILE" 2>&1
  else
    INSTALL_RKE2_ARTIFACT_PATH="$src" "$src/install.sh" >>"$LOG_FILE" 2>&1
  fi
  local rc=$?
  set -e
  if (( rc != 0 )); then
    log ERROR "RKE2 installer failed (exit $rc). See $LOG_FILE"
    return "$rc"
  fi
  return 0
}

setup_custom_cluster_ca() {
  local ROOT_CRT="${CUSTOM_CA_ROOT_CRT:-$SCRIPT_DIR/certs/dev-certa001-ca-dev-local.crt}"
  local ROOT_KEY="${CUSTOM_CA_ROOT_KEY:-$SCRIPT_DIR/certs/dev-certa001-ca-dev-local-key.pem}"
  local INT_CRT="${CUSTOM_CA_INT_CRT:-}"
  local INT_KEY="${CUSTOM_CA_INT_KEY:-}"
  local TLS_DIR="/var/lib/rancher/rke2/server/tls"
  local GEN1="$STAGE_DIR/generate-custom-ca-certs.sh"
  local GEN2="$DOWNLOADS_DIR/generate-custom-ca-certs.sh"

  # Optionally ensure OS trust (clients/servers on the host trust the root CA)
  if [[ -f "$ROOT_CRT" ]]; then
    if [[ "${CUSTOM_CA_INSTALL_TO_OS_TRUST:-1}" -ne 0 ]]; then
      mkdir -p /usr/local/share/ca-certificates
      local _bn="$(basename "$ROOT_CRT")"
      if ! cmp -s "$ROOT_CRT" "/usr/local/share/ca-certificates/$_bn" 2>/dev/null; then
        cp "$ROOT_CRT" "/usr/local/share/ca-certificates/$_bn"
        update-ca-certificates >>"$LOG_FILE" 2>&1 || true
        log INFO "Installed $_bn into OS trust store."
      fi
    fi
  else
    log WARN "Root CA not found; custom cluster CA will not be used."
    return 0
  fi

  # If the cluster CA already exists, don't overwrite
  if [[ -f "$TLS_DIR/server-ca.crt" || -f "$TLS_DIR/client-ca.crt" ]]; then
    log INFO "Cluster CA appears to exist in $TLS_DIR; skipping custom CA generation."
    return 0
  fi

  mkdir -p "$TLS_DIR"

  # Stage inputs for the generator per RKE2 docs
  if [[ -f "$ROOT_KEY" ]]; then
    # Use provided root CA + key
    cp -f "$ROOT_CRT" "$TLS_DIR/root-ca.pem"
    cp -f "$ROOT_KEY" "$TLS_DIR/root-ca.key"
    log INFO "Prepared root CA + key for custom cluster CA generation."
  elif [[ -f "$INT_CRT" && -f "$INT_KEY" ]]; then
    # Use root (public) + intermediate (public+key)
    cp -f "$ROOT_CRT" "$TLS_DIR/root-ca.pem"
    cp -f "$INT_CRT"  "$TLS_DIR/intermediate-ca.pem"
    cp -f "$INT_KEY"  "$TLS_DIR/intermediate-ca.key"
    log INFO "Prepared root + intermediate for custom cluster CA generation."
  else
    log WARN "No CA private key found (expected CUSTOM_CA_ROOT_KEY or CUSTOM_CA_INT_KEY). "\
             "Will continue with RKE2 self-signed cluster CA."
    return 0
  fi

  # Find the generator script (prefer offline copy)
  local GEN=""
  if [[ -x "$GEN1" ]]; then
    GEN="$GEN1"
  elif [[ -x "$GEN2" ]]; then
    GEN="$GEN2"
  fi

  if [[ -n "$GEN" ]]; then
    log INFO "Generating RKE2 custom CA set using offline helper: $GEN"
    PRODUCT=rke2 DATA_DIR=/var/lib/rancher/rke2 bash "$GEN" >>"$LOG_FILE" 2>&1 || {
      log ERROR "Custom CA generation failed via $GEN; leaving defaults in place."
      return 1
    }
  else
    if command -v curl >/dev/null 2>&1; then
      log INFO "Downloading helper to generate custom CA set (one-time)."
      curl -fsSL https://github.com/k3s-io/k3s/raw/master/contrib/util/generate-custom-ca-certs.sh \
        | PRODUCT=rke2 DATA_DIR=/var/lib/rancher/rke2 bash - >>"$LOG_FILE" 2>&1 || {
          log ERROR "Custom CA generation failed via curl; leaving defaults in place."
          return 1
        }
    else
      log ERROR "No offline helper found and curl not available; cannot generate custom cluster CA."
      return 1
    fi
  fi

  # Sanity: ensure the expected files exist
  local need=(server-ca.crt server-ca.key client-ca.crt client-ca.key request-header-ca.crt request-header-ca.key etcd/peer-ca.crt etcd/peer-ca.key etcd/server-ca.crt etcd/server-ca.key service.key)
  local missing=0
  for f in "${need[@]}"; do
    [[ -f "$TLS_DIR/$f" ]] || { log ERROR "Missing CA component after generation: $TLS_DIR/$f"; missing=1; }
  done
  if (( missing == 0 )); then
    log INFO "Custom cluster CA seeded successfully. New clusters will chain to provided root."
  fi

}

verify_custom_cluster_ca() {
  local TLS_DIR="/var/lib/rancher/rke2/server/tls"
  local ROOT_CA="${CUSTOM_CA_ROOT_CRT:-$TLS_DIR/root-ca.pem}"
  local ok=0 fail=0

  if [[ ! -d "$TLS_DIR" ]]; then
    log WARN "TLS dir not found ($TLS_DIR); rke2-server may not be initialized yet."
    return 0
  fi

  if [[ ! -f "$ROOT_CA" ]]; then
    # Fallback to OS-installed copy of the configured CA
    if [[ -n "${CUSTOM_CA_ROOT_CRT:-}" ]]; then
      local bn="$(basename "$CUSTOM_CA_ROOT_CRT")"
      if [[ -f "/usr/local/share/ca-certificates/$bn" ]]; then
        ROOT_CA="/usr/local/share/ca-certificates/$bn"
      fi
    fi
  fi

  if [[ ! -f "$ROOT_CA" ]]; then
    log WARN "Root CA file not found for verification; skipping CA chain checks."
    return 0
  fi

  local to_check=(
    "server-ca.crt"
    "client-ca.crt"
    "request-header-ca.crt"
    "etcd/server-ca.crt"
    "etcd/peer-ca.crt"
  )

  for f in "${to_check[@]}"; do
    if [[ -f "$TLS_DIR/$f" ]]; then
      if openssl verify -CAfile "$ROOT_CA" "$TLS_DIR/$f" >/dev/null 2>&1; then
        log INFO "OK  : $(printf '%-22s' "$f") chains to root"
        ((ok++))
      else
        log ERROR "FAIL: $(printf '%-22s' "$f") does NOT chain to root"
        ((fail++))
      fi
    else
      log WARN "Missing: $TLS_DIR/$f"
    fi
  done

  # API server live check (if running)
  if systemctl is-active --quiet rke2-server && ss -ltn | awk '{print $4}' | grep -qE '(^|:)6443$'; then
    if timeout 5 openssl s_client -connect 127.0.0.1:6443 -verify_return_error -CAfile "$ROOT_CA" < /dev/null 2>&1 | grep -q "Verify return code: 0 (ok)"; then
      log INFO "OK  : kube-apiserver handshake verified with provided root CA"
    else
      log ERROR "FAIL: kube-apiserver handshake could not be verified with provided root CA"
      ((fail++))
    fi
  else
    log WARN "kube-apiserver not reachable on 127.0.0.1:6443; skipping live handshake check."
  fi

  if (( fail == 0 )); then
    echo "VERIFY (Cluster CA): PASS ($ok checks)"
  else
    echo "VERIFY (Cluster CA): FAIL ($fail failed, $ok passed)"
  fi
  return $fail
}

ensure_staged_artifacts() {
  local missing=0
  if [[ ! -f "$STAGE_DIR/install.sh" ]]; then
    if [[ -f "$DOWNLOADS_DIR/install.sh" ]]; then
      cp "$DOWNLOADS_DIR/install.sh" "$STAGE_DIR/" && chmod +x "$STAGE_DIR/install.sh"
      log INFO "Staged install.sh"
    else
      log ERROR "Missing install.sh. Run 'pull' first."; missing=1
    fi
  fi
  if [[ ! -f "$STAGE_DIR/$RKE2_TARBALL" ]]; then
    if [[ -f "$DOWNLOADS_DIR/$RKE2_TARBALL" ]]; then
      cp "$DOWNLOADS_DIR/$RKE2_TARBALL" "$STAGE_DIR/"
      log INFO "Staged RKE2 tarball"
    else
      log ERROR "Missing $RKE2_TARBALL. Run 'pull' first."; missing=1
    fi
  fi
  if [[ ! -f "$STAGE_DIR/$SHA256_FILE" ]]; then
    if [[ -f "$DOWNLOADS_DIR/$SHA256_FILE" ]]; then
      cp "$DOWNLOADS_DIR/$SHA256_FILE" "$STAGE_DIR/"
      log INFO "Staged SHA256 file"
    else
      log ERROR "Missing $SHA256_FILE. Run 'pull' first."; missing=1
    fi
  fi
  if (( missing != 0 )); then
    exit 3
  fi
}

setup_image_resolution_strategy() {
  # Read primary and fallback registries from YAML (if present), else derive from existing variables.
  local primary_registry="" fallback_registry="" default_offline_registry="" primary_host="" fallback_host="" default_host=""
  local reg_user="${REG_USER:-}" reg_pass="${REG_PASS:-}" ca_guess=""

  if [[ -n "$CONFIG_FILE" ]]; then
    primary_registry="$(yaml_spec_get "$CONFIG_FILE" registry || echo "${REGISTRY:-}")"
    fallback_registry="$(yaml_spec_get "$CONFIG_FILE" fallbackRegistry || true)"
    default_offline_registry="$(yaml_spec_get "$CONFIG_FILE" defaultOfflineRegistry || true)"
    # Optional pinned IPs for /etc/hosts
    local primary_ip fallback_ip
    primary_ip="$(yaml_spec_get "$CONFIG_FILE" registryIP || true)"
    fallback_ip="$(yaml_spec_get "$CONFIG_FILE" fallbackRegistryIP || true)"
    ensure_hosts_pin "${primary_registry%%/*}" "${primary_ip}"
    ensure_hosts_pin "${fallback_registry%%/*}" "${fallback_ip}"
    # Possible credentials
    reg_user="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "${reg_user}")"
    reg_pass="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "${reg_pass}")"
  fi

  # Fallbacks if still empty
  primary_registry="${primary_registry:-${REGISTRY:-'rke2registry.dev.local/rke2'}}"
  primary_host="${primary_registry%%/*}"
  [[ -n "$fallback_registry" ]]        && fallback_host="${fallback_registry%%/*}"        || fallback_host=""
  [[ -n "$default_offline_registry" ]] && default_host="${default_offline_registry%%/*}"  || default_host=""

  # Try to reuse existing registry CA if present
  if [[ -f /etc/rancher/rke2/registries.yaml ]]; then
    ca_guess="$(awk -F': *' '/ca_file:/ {gsub(/"/,"",$2); print $2; exit}' /etc/rancher/rke2/registries.yaml 2>/dev/null || true)"
  fi
  [[ -z "$ca_guess" && -f /usr/local/share/ca-certificates/rke2ca-cert.crt ]] && ca_guess="/usr/local/share/ca-certificates/rke2ca-cert.crt"

  # 1) Load staged images, 2) Retag locally with the primary host so containerd finds them without network
  load_staged_images
  retag_local_images_with_prefix "$primary_host"

  # 3) Mirror upstreams to offline endpoints, in order (primary → fallback → default)
  write_registries_yaml_with_fallbacks "$primary_host" "$fallback_host" "$default_host" "$reg_user" "$reg_pass" "$ca_guess"

  # 4) Ensure system-default-registry matches the primary host (so RKE2 will try it)
  #mkdir -p /etc/rancher/rke2
  #if ! grep -q '^system-default-registry:' /etc/rancher/rke2/config.yaml 2>/dev/null; then
  #  echo "system-default-registry: \"$primary_host\"" >> /etc/rancher/rke2/config.yaml
  #else
  #  sed -i -E "s|^system-default-registry:.*$|system-default-registry: \"${primary_host}\"|g" /etc/rancher/rke2/config.yaml
  #fi
  #log INFO "Set system-default-registry: ${primary_host}"
  # NOTE: Do not force system-default-registry here.
  # If we set it, we must have already retagged every cached image to ${primary_host}/...
  # Retagging happens above; leaving system-default-registry unset ensures cached upstream names match.
  :
}


# ---------- Image resolution strategy (local → offline registry(s)) ----------------------------
# Ensures that: 1) staged images are loaded, 2) local images are retagged to match the
# system-default-registry prefix so containerd will use them without pulling, and
# 3) registries.yaml mirrors point to your offline registry endpoints in priority order.
image_exists_locally() {
  local ref="$1"
  nerdctl --namespace k8s.io image inspect "$ref" >/dev/null 2>&1
}

load_staged_images() {
  # Load any pre-staged images into containerd so we can retag them.
  shopt -s nullglob
  local loaded=0
  for f in /var/lib/rancher/rke2/agent/images/*.tar*; do
    case "$f" in
      *.zst)  zstdcat "$f" | nerdctl --namespace k8s.io load >/dev/null 2>&1 || true ;;
      *.gz)   gzip -dc "$f" | nerdctl --namespace k8s.io load >/dev/null 2>&1 || true ;;
      *.tar)  nerdctl --namespace k8s.io load -i "$f" >/dev/null 2>&1 || true ;;
    esac
    loaded=1
  done
  shopt -u nullglob
  if (( loaded == 1 )); then
    log INFO "Loaded staged images into containerd namespace k8s.io."
  else
    log INFO "No staged images to load (skip)."
  fi
}

retag_local_images_with_prefix() {
  # Give every locally available image an additional name that includes the private registry host.
  # This guarantees kubelet/containerd can find the content locally when it asks for
  # e.g. <regHost>/rancher/mirrored-pause:3.6.
  local reg_host="$1"
  [[ -z "$reg_host" ]] && return 0

  # Make a best effort and stay quiet on errors
  mapfile -t imgs < <(nerdctl --namespace k8s.io images --format '{{.Repository}}:{{.Tag}}' \
                      | awk '$0 !~ /<none>/' | sort -u)
  local ref
  for ref in "${imgs[@]}"; do
    [[ -z "$ref" ]] && continue
    case "$ref" in
      "$reg_host"/*) : ;; # already retagged with prefix
      *"@sha256:"*)  : ;; # skip digested names
      *"<none>"*)    : ;; # skip invalid
      *:*)           nerdctl --namespace k8s.io tag "$ref" "$reg_host/$ref" >/dev/null 2>&1 || true ;;
      *)             : ;;
    esac
  done
  log INFO "Retagged local images with registry prefix: $reg_host/… (best-effort)."
}

ensure_hosts_pin() {
  # Optionally force-resolve a registry name when DNS is not yet populated.
  local host="$1" ip="$2"
  [[ -z "$host" || -z "$ip" ]] && return 0
  if ! grep -qE "^[[:space:]]*$ip[[:space:]]+$host(\s|$)" /etc/hosts; then
    echo "$ip $host" >> /etc/hosts
    log INFO "Pinned $host → $ip in /etc/hosts"
  fi
}

write_registries_yaml_with_fallbacks() {
  # Build a registries.yaml that points common upstreams to your offline endpoints in priority order.
  # Args: primary_host [fallback_host] [default_offline_host] [username] [password] [ca_file]
  local primary="$1"; shift || true
  local fallback="$1"; shift || true
  local default_offline="$1"; shift || true
  local user="$1"; shift || true
  local pass="$1"; shift || true
  local ca_file="$1"; shift || true

  mkdir -p /etc/rancher/rke2

  # Build endpoint YAML list
  endpoints_primary="      - \"https://${primary}\""
  endpoints_fallback=""
  endpoints_default=""
  [[ -n "$fallback" ]]        && endpoints_fallback=$'\n'"      - \"https://${fallback}\""
  [[ -n "$default_offline" ]] && endpoints_default=$'\n'"      - \"https://${default_offline}\""

  # CA line (optional)
  tls_block_primary=""
  tls_block_fallback=""
  tls_block_default=""
  if [[ -n "$ca_file" && -f "$ca_file" ]]; then
    tls_block_primary=$'\n'"    tls:"$'\n'"      ca_file: \"${ca_file}\""
    tls_block_fallback=$'\n'"    tls:"$'\n'"      ca_file: \"${ca_file}\""
    tls_block_default=$'\n'"    tls:"$'\n'"      ca_file: \"${ca_file}\""
  fi

  # Auth (optional)
  auth_block_primary=""
  auth_block_fallback=""
  auth_block_default=""
  if [[ -n "$user" && -n "$pass" ]]; then
    auth_block_primary=$'\n'"    auth:"$'\n'"      username: \"${user}\""$'\n'"      password: \"${pass}\""
    auth_block_fallback=$'\n'"    auth:"$'\n'"      username: \"${user}\""$'\n'"      password: \"${pass}\""
    auth_block_default=$'\n'"    auth:"$'\n'"      username: \"${user}\""$'\n'"      password: \"${pass}\""
  fi

  # Known upstreams we want to mirror via offline registry
  # Known upstreams we want to mirror via offline registry
  REG_YAML="$(cat <<EOF
mirrors:
  "docker.io":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
  "registry.k8s.io":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
  "k8s.gcr.io":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
  "quay.io":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
  "ghcr.io":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
  "rancher":
    endpoint:
${endpoints_primary}${endpoints_fallback}${endpoints_default}
configs:
  "${primary}":${auth_block_primary}${tls_block_primary}
EOF
)"

  # Optionally add configs for fallback/default
  if [[ -n "$fallback" ]]; then
    REG_YAML+=$'\n'"  \"${fallback}\":${auth_block_fallback}${tls_block_fallback}"
  fi
  if [[ -n "$default_offline" ]]; then
    REG_YAML+=$'\n'"  \"${default_offline}\":${auth_block_default}${tls_block_default}"
  fi

  printf "%s\n" "${REG_YAML}" > /etc/rancher/rke2/registries.yaml
  chmod 600 /etc/rancher/rke2/registries.yaml
  log INFO "Wrote /etc/rancher/rke2/registries.yaml with endpoints (priority): ${primary}${fallback:+, ${fallback}}${default_offline:+, ${default_offline}}"
}

# ================================================================================================
# ACTIONS
# ================================================================================================

# ==================
# Action: CLUSTER-CA
action_cluster_ca() {
  load_site_defaults

  local ROOT_CRT="" ROOT_KEY="" INT_CRT="" INT_KEY=""
  local INSTALL_TRUST="true"

  # Stage helper for offline (same as pull/image path and exit if not found)
  if [[ -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" ]]; then
    cp -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    chmod +x "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    log INFO "Staged custom-CA helper script for offline use."
  else
    log ERROR "custom-CA helper script not found in $DOWNLOADS_DIR. Run 'pull' first."
    exit 3
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    ROOT_CRT="$(yaml_spec_get "$CONFIG_FILE" rootCrt || true)"
    ROOT_KEY="$(yaml_spec_get "$CONFIG_FILE" rootKey || true)"
    INT_CRT="$(yaml_spec_get "$CONFIG_FILE" intermediateCrt || true)"
    INT_KEY="$(yaml_spec_get "$CONFIG_FILE" intermediateKey || true)"
    INSTALL_TRUST="$(yaml_spec_get "$CONFIG_FILE" installToOSTrust || echo true)"
  fi

  # Resolve to absolute paths relative to SCRIPT_DIR if not absolute
  [[ -n "$ROOT_CRT" && "${ROOT_CRT:0:1}" != "/" ]] && ROOT_CRT="$SCRIPT_DIR/$ROOT_CRT"
  [[ -n "$ROOT_KEY" && "${ROOT_KEY:0:1}" != "/" ]] && ROOT_KEY="$SCRIPT_DIR/$ROOT_KEY"
  [[ -n "$INT_CRT"  && "${INT_CRT:0:1}"  != "/" ]] && INT_CRT="$SCRIPT_DIR/$INT_CRT"
  [[ -n "$INT_KEY"  && "${INT_KEY:0:1}"  != "/" ]] && INT_KEY="$SCRIPT_DIR/$INT_KEY"

  # Validate files if set
  [[ -n "$ROOT_CRT" && ! -f "$ROOT_CRT" ]] && { log ERROR "rootCrt not found: $ROOT_CRT"; exit 3; }
  [[ -n "$ROOT_KEY" && ! -f "$ROOT_KEY" ]] && { log ERROR "rootKey not found: $ROOT_KEY"; exit 3; }
  if [[ -z "$ROOT_KEY" && ( -n "$INT_CRT" || -n "$INT_KEY" ) ]]; then
    [[ -n "$INT_CRT" && ! -f "$INT_CRT" ]] && { log ERROR "intermediateCrt not found: $INT_CRT"; exit 3; }
    [[ -n "$INT_KEY" && ! -f "$INT_KEY" ]] && { log ERROR "intermediateKey not found: $INT_KEY"; exit 3; }
  fi

  # Persist into site defaults so server/add-server can use them
  local STATE="/etc/rke2image.defaults"
  {
    [[ -n "$ROOT_CRT" ]] && echo "CUSTOM_CA_ROOT_CRT=\"$ROOT_CRT\""
    [[ -n "$ROOT_KEY" ]] && echo "CUSTOM_CA_ROOT_KEY=\"$ROOT_KEY\""
    [[ -n "$INT_CRT"  ]] && echo "CUSTOM_CA_INT_CRT=\"$INT_CRT\""
    [[ -n "$INT_KEY"  ]] && echo "CUSTOM_CA_INT_KEY=\"$INT_KEY\""
    if [[ "$INSTALL_TRUST" =~ ^([Tt]rue|1|yes|Y)$ ]]; then
      echo "CUSTOM_CA_INSTALL_TO_OS_TRUST=1"
    else
      echo "CUSTOM_CA_INSTALL_TO_OS_TRUST=0"
    fi
  } >> "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved custom CA configuration to $STATE"

  # Optionally install to OS trust store now
  if [[ "${CUSTOM_CA_INSTALL_TO_OS_TRUST:-${INSTALL_TRUST,,}}" =~ ^(1|true|yes)$ ]]; then
    if [[ -n "$ROOT_CRT" ]]; then
      local bn="$(basename "$ROOT_CRT")"
      cp -f "$ROOT_CRT" "/usr/local/share/ca-certificates/$bn"
      update-ca-certificates >>"$LOG_FILE" 2>&1 || true
      log INFO "Installed $bn into OS trust store."
    fi
  fi
}

# =============
# Action: PULL
action_pull() {
  # Prefetch custom-CA helper for offline use
  if command -v curl >/dev/null 2>&1; then
    local GEN_URL="https://raw.githubusercontent.com/k3s-io/k3s/refs/heads/main/contrib/util/generate-custom-ca-certs.sh"
    log INFO "Fetching custom-CA helper script for offline use."
    curl -fsSL -o "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" "$GEN_URL" >>"$LOG_FILE" 2>&1 || true
    chmod +x "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" >>"$LOG_FILE" 2>&1 || true
    log INFO "Staged custom-CA helper script for offline use."
  fi

  if [[ -n "$CONFIG_FILE" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (pull)."
  fi

  ensure_installed curl
  ensure_installed zstd
  ensure_installed yq
  #ensure_installed pv
  ensure_installed ca-certificates

# --- Cache nerdctl FULL bundle for offline use ---
  log INFO "Detecting latest nerdctl FULL release (to cache offline)..."
  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local ntag nver nurl ntgz
  ntag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  if [[ -n "$ntag" ]]; then
    nver="${ntag#v}"
    nurl="https://github.com/containerd/nerdctl/releases/download/${ntag}/nerdctl-full-${nver}-linux-${ARCH}.tar.gz"
    ntgz="$DOWNLOADS_DIR/nerdctl-full-${nver}-linux-${ARCH}.tar.gz"
    if [[ ! -f "$ntgz" ]]; then
      spinner_run "Caching nerdctl FULL ${ntag}" curl -Lf "$nurl" -o "$ntgz"
      log INFO "Cached nerdctl FULL: $(basename "$ntgz")"
    else
      log INFO "nerdctl FULL already cached: $(basename "$ntgz")"
    fi
  else
    log WARN "Could not detect nerdctl release; skipping offline cache."
  fi

  detect_latest_rke2_version
  ensure_containerd_ready

  local BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
  mkdir -p "$DOWNLOADS_DIR"
  pushd "$DOWNLOADS_DIR" >/dev/null

  log INFO "Downloading artifacts (images, tarball, checksums, installer)..."
  spinner_run "Downloading $IMAGES_TAR"  curl -Lf "$BASE_URL/$IMAGES_TAR"   -o "$IMAGES_TAR"
  spinner_run "Downloading $RKE2_TARBALL" curl -Lf "$BASE_URL/$RKE2_TARBALL" -o "$RKE2_TARBALL"
  spinner_run "Downloading $SHA256_FILE"  curl -Lf "$BASE_URL/$SHA256_FILE"  -o "$SHA256_FILE"
  spinner_run "Downloading install.sh"    curl -sfL "https://get.rke2.io"    -o install.sh
  chmod +x install.sh

  log INFO "Verifying checksums..."
  grep "$IMAGES_TAR"  "$SHA256_FILE" | sha256sum -c - >>"$LOG_FILE" 2>&1
  grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c - >>"$LOG_FILE" 2>&1
  echo "[DONE] Checksums verified"

  log INFO "Pre-loading images into containerd via nerdctl..."
  spinner_run "Loading images into containerd" bash -c "zstdcat \"$IMAGES_TAR\" | nerdctl -n k8s.io load"

  popd >/dev/null
  log INFO "pull: completed successfully."
}

# =============
# Action: PUSH
action_push() {
  if [[ -n "$CONFIG_FILE" ]]; then
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (push)."
  fi

  ensure_containerd_ready
  ensure_installed zstd

  local work="$DOWNLOADS_DIR"
  if [[ ! -f "$work/$IMAGES_TAR" ]]; then
    log ERROR "Images archive not found in $work. Run 'pull' first."
    exit 3
  fi

  zstdcat "$work/$IMAGES_TAR" | nerdctl -n k8s.io load >>"$LOG_FILE" 2>&1

  local -a imgs
  mapfile -t imgs < <(nerdctl -n k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)

  local REG_HOST="$REGISTRY" REG_NS=""
  [[ "$REGISTRY" == *"/"* ]] && { REG_HOST="${REGISTRY%%/*}"; REG_NS="${REGISTRY#*/}"; }

  local manifest_json="$OUT_DIR/images-manifest.json"
  local manifest_txt="$OUT_DIR/images-manifest.txt"
  : > "$manifest_txt"
  echo "[" > "$manifest_json"
  local first=1

  for IMG in "${imgs[@]}"; do
    [[ -z "$IMG" ]] && continue
    local TARGET
    if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi

    [[ $first -eq 0 ]] && echo "," >> "$manifest_json"
    printf '  {"source":"%s","target":"%s"}' "$IMG" "$TARGET" >> "$manifest_json"
    first=0
    echo "$IMG  ->  $TARGET" >> "$manifest_txt"

    gen_sbom_or_metadata "$IMG"
  done
  echo ""  >> "$manifest_json"
  echo "]" >> "$manifest_json"
  log INFO "Pre-push manifest written:"
  log INFO "  - $manifest_txt"
  log INFO "  - $manifest_json"

  if [[ "$DRY_PUSH" -eq 1 ]]; then
    log WARN "--dry-push set; skipping actual registry pushes."
    return 0
  fi

  spinner_run "Logging into $REG_HOST" nerdctl login "$REG_HOST" -u "$REG_USER" -p "$REG_PASS"
  for IMG in "${imgs[@]}"; do
    [[ -z "$IMG" ]] && continue
    local TARGET
    if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
    log INFO "Tag & push: $IMG -> $TARGET"
    nerdctl -n k8s.io tag  "$IMG" "$TARGET"  >>"$LOG_FILE" 2>&1
    spinner_run "Pushing $TARGET" nerdctl -n k8s.io push "$TARGET"
  done
  nerdctl logout "$REG_HOST" >>"$LOG_FILE" 2>&1 || true

  log INFO "push: completed successfully."
}

# ==============
# Action: IMAGE
action_image() {
  # Stage custom-CA helper into $STAGE_DIR for offline cluster init
  if [[ -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" ]]; then
    cp -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    chmod +x "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    log INFO "Staged custom-CA helper into $STAGE_DIR."
  fi

  local REG_HOST="${REGISTRY%%/*}"
  local defaultDnsCsv="$DEFAULT_DNS"
  local defaultSearchCsv=""

  if [[ -n "$CONFIG_FILE" ]]; then
    local d1 s1
    d1="$(yaml_spec_get "$CONFIG_FILE" defaultDns || true)"
    s1="$(yaml_spec_get "$CONFIG_FILE" defaultSearchDomains || true)"
    [[ -n "$d1" ]] && defaultDnsCsv="$(normalize_list_csv "$d1")"
    [[ -n "$s1" ]] && defaultSearchCsv="$(normalize_list_csv "$s1")"

    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    REG_HOST="${REGISTRY%%/*}"

    log WARN "Using YAML values; CLI flags may be overridden (image)."
  fi

  install_rke2_prereqs
  ensure_containerd_ready

  load_site_defaults
  # Determine CA for registry and cluster trust
  local CA_SRC=""
  if [[ -n "${CUSTOM_CA_ROOT_CRT:-}" ]]; then
    CA_SRC="$CUSTOM_CA_ROOT_CRT"
  elif [[ -f "$SCRIPT_DIR/certs/rke2ca-cert.crt" ]]; then
    CA_SRC="$SCRIPT_DIR/certs/rke2ca-cert.crt"
  fi
  if [[ -n "$CA_SRC" ]]; then
    local CA_BN="$(basename "$CA_SRC")"
    cp -f "$CA_SRC" "/usr/local/share/ca-certificates/$CA_BN"
    update-ca-certificates >>"$LOG_FILE" 2>&1 || true
    log INFO "Installed $CA_BN into OS trust store."
  else
    log WARN "No custom CA provided; continuing without installing registry CA."
  fi

  mkdir -p /var/lib/rancher/rke2/agent/images/
  if [[ -f "$DOWNLOADS_DIR/$IMAGES_TAR" ]]; then
    cp "$DOWNLOADS_DIR/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/
    log INFO "Staged images archive"
  else
    log WARN "Images archive not found; run 'pull' first."
  fi
  if [[ -f "$DOWNLOADS_DIR/$RKE2_TARBALL" ]]; then
    cp "$DOWNLOADS_DIR/$RKE2_TARBALL" "$STAGE_DIR/"
    log INFO "Staged RKE2 tarball"
  else
    log WARN "RKE2 tarball not found; run 'pull' first."
  fi
  if [[ -f "$DOWNLOADS_DIR/install.sh" ]]; then
    cp "$DOWNLOADS_DIR/install.sh" "$STAGE_DIR/"
    chmod +x "$STAGE_DIR/install.sh"
    log INFO "Staged install.sh"
  else
    log WARN "install.sh not found; run 'pull' first."
  fi
  if [[ -f "$DOWNLOADS_DIR/$SHA256_FILE" ]]; then
    cp "$DOWNLOADS_DIR/$SHA256_FILE" "$STAGE_DIR/"
    log INFO "Staged SHA256 file"
  else
    log WARN "SHA256 file not found; run 'pull' first."
  fi

  #mkdir -p /etc/rancher/rke2/
  #printf 'system-default-registry: "%s"\n' "$REG_HOST" > /etc/rancher/rke2/config.yaml

  #cat > /etc/rancher/rke2/registries.yaml <<EOF
#mirrors:
#  "docker.io":
#    endpoint:
#      - "https://$REG_HOST"
#configs:
#  "$REG_HOST":
#    auth:
#      username: "$REG_USER"
#      password: "$REG_PASS"
#    tls:
#      ca_file: "/usr/local/share/ca-certificates/${CA_BN:-rke2ca-cert.crt}"
#EOF
#  chmod 600 /etc/rancher/rke2/registries.yaml

  # Do NOT set system-default-registry here. We want the server to bootstrap
  # from the cached upstream image names shipped in the tarball.
  # If a private/offline registry is provided, write a full mirrors file so pulls
  # (only when truly needed) will go to the offline endpoints.
  mkdir -p /etc/rancher/rke2
  : > /etc/rancher/rke2/config.yaml
  if [[ -n "$REG_HOST" ]]; then
    # Use the comprehensive mirrors writer so non-docker.io registries are covered too.
    write_registries_yaml_with_fallbacks "$REG_HOST" "" "" "$REG_USER" "$REG_PASS" "/usr/local/share/ca-certificates/${CA_BN:-rke2ca-cert.crt}"
  else
    # No registry configured → ensure no registries.yaml exists to avoid accidental pulls.
    rm -f /etc/rancher/rke2/registries.yaml
  fi

  cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  log INFO "IPv6 disabled via sysctl (99-disable-ipv6.conf)."

  local STATE="/etc/rke2image.defaults"
  {
    echo "DEFAULT_DNS=\"$defaultDnsCsv\""
    echo "DEFAULT_SEARCH=\"$defaultSearchCsv\""
  } > "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved site defaults: DNS=[$defaultDnsCsv], SEARCH=[$defaultSearchCsv]"

  log INFO "Applying OS updates; the system will reboot automatically..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >>"$LOG_FILE" 2>&1
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y >>"$LOG_FILE" 2>&1
  apt-get autoremove -y >>"$LOG_FILE" 2>&1 || true
  apt-get autoclean  -y >>"$LOG_FILE" 2>&1 || true
  log WARN "Rebooting now to complete updates."
  sleep 10
  reboot

}

# ==============
# Action: SERVER
#   Server flags: -t TOKEN  -T TOKEN_FILE  -l TLS_SANS  -n NODE_IP  -e NODE_EXTERNAL_IP  -S SERVICE_CIDR  -C CLUSTER_CIDR  -D CLUSTER_DOMAIN  -M WRITE_KUBECONFIG_MODE  -R CUSTOM_ROOT_CRT  -K CUSTOM_ROOT_KEY  -I CUSTOM_INT_CRT  -J CUSTOM_INT_KEY  -X INSTALL_TRUST(0/1)
action_server() {
  load_site_defaults

  # -------------------------
  # Inputs (YAML → CLI → Prompt)
  # -------------------------
  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local TOKEN="" TOKEN_FILE="" TLS_SANS="" NODE_IP="" NODE_EXTERNAL_IP=""
  local SERVICE_CIDR="" CLUSTER_CIDR="" CLUSTER_DOMAIN="" WRITE_KUBECONFIG_MODE=""
  # Custom CA inputs (for generating cluster CA if requested)
  local CUSTOM_ROOT_CRT="" CUSTOM_ROOT_KEY="" CUSTOM_INT_CRT="" CUSTOM_INT_KEY="" INSTALL_TRUST="1"

  # Prefer YAML (kind: Server)
  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)";           [[ -n "$d" ]]  && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)";[[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"

    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
    TOKEN_FILE="$(yaml_spec_get "$CONFIG_FILE" tokenFile || true)"
    TLS_SANS="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"
    NODE_IP="$(yaml_spec_get "$CONFIG_FILE" nodeIP || true)"
    NODE_EXTERNAL_IP="$(yaml_spec_get "$CONFIG_FILE" nodeExternalIP || true)"
    SERVICE_CIDR="$(yaml_spec_get "$CONFIG_FILE" serviceCIDR || true)"
    CLUSTER_CIDR="$(yaml_spec_get "$CONFIG_FILE" clusterCIDR || true)"
    CLUSTER_DOMAIN="$(yaml_spec_get "$CONFIG_FILE" clusterDomain || true)"
    WRITE_KUBECONFIG_MODE="$(yaml_spec_get "$CONFIG_FILE" writeKubeconfigMode || true)"

    # Custom CA (optional) — names kept simple under spec: for kind: Server
    CUSTOM_ROOT_CRT="$(yaml_spec_get "$CONFIG_FILE" customCARootCrt || true)"
    CUSTOM_ROOT_KEY="$(yaml_spec_get "$CONFIG_FILE" customCARootKey || true)"
    CUSTOM_INT_CRT="$(yaml_spec_get "$CONFIG_FILE" customCAIntermediateCrt || true)"
    CUSTOM_INT_KEY="$(yaml_spec_get "$CONFIG_FILE" customCAIntermediateKey || true)"
    INSTALL_TRUST="$(yaml_spec_get "$CONFIG_FILE" customCAInstallToOSTrust || echo "true")"
  fi

  # Allow per-action CLI flags when no YAML or to override parts.
  # Flags: -t TOKEN  -T TOKEN_FILE  -l TLS_SANS  -n NODE_IP  -e NODE_EXTERNAL_IP
  #        -S SERVICE_CIDR  -C CLUSTER_CIDR  -D CLUSTER_DOMAIN  -M WRITE_KUBECONFIG_MODE
  #        -R CUSTOM_ROOT_CRT  -K CUSTOM_ROOT_KEY  -I CUSTOM_INT_CRT  -J CUSTOM_INT_KEY
  #        -X INSTALL_TRUST(0/1)
  local OPTIND=1 opt
  while getopts ":t:T:l:n:e:S:C:D:M:R:K:I:J:X:" opt; do
    case ${opt} in
      t) TOKEN="$OPTARG";;
      T) TOKEN_FILE="$OPTARG";;
      l) TLS_SANS="$OPTARG";;
      n) NODE_IP="$OPTARG";;
      e) NODE_EXTERNAL_IP="$OPTARG";;
      S) SERVICE_CIDR="$OPTARG";;
      C) CLUSTER_CIDR="$OPTARG";;
      D) CLUSTER_DOMAIN="$OPTARG";;
      M) WRITE_KUBECONFIG_MODE="$OPTARG";;
      R) CUSTOM_ROOT_CRT="$OPTARG";;
      K) CUSTOM_ROOT_KEY="$OPTARG";;
      I) CUSTOM_INT_CRT="$OPTARG";;
      J) CUSTOM_INT_KEY="$OPTARG";;
      X) INSTALL_TRUST="$OPTARG";;
    esac
  done
  shift $((OPTIND-1))

  # Prompts for any missing basics
  if [[ -z "$IP"       ]]; then read -rp "Enter static IPv4 for this server node: " IP; fi
  if [[ -z "$PREFIX"   ]]; then read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX; fi
  if [[ -z "$HOSTNAME" ]]; then read -rp "Enter hostname for this server node: " HOSTNAME; fi
  if [[ -z "$GW" ]];     then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    if [[ -z "$DNS" ]]; then DNS="$DEFAULT_DNS"; fi
  fi
  if [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then SEARCH="$DEFAULT_SEARCH"; fi

  # Optional server-level prompts if still missing and no YAML/CLI values
  if [[ -z "$TOKEN" && -z "$TOKEN_FILE" ]]; then
    read -rp "Cluster token (leave blank to skip): " TOKEN || true
  fi
  if [[ -z "$TLS_SANS" ]]; then
    read -rp "TLS SANs for API (comma-separated, optional): " TLS_SANS || true
  fi

  # Validate basics
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # -------------------------
  # Prepare offline artifacts + runtime
  # -------------------------
  log INFO "Ensuring staged artifacts for offline RKE2 server install..."
  ensure_staged_artifacts
  local SRC="$STAGE_DIR"

  ensure_containerd_ready

  # If registries provided in YAML globals, wire mirrors; else avoid forcing system-default-registry
  if [[ -f "$CONFIG_FILE" ]] && [[ -n "$(yaml_spec_get "$CONFIG_FILE" registry || true)" ]]; then
    setup_image_resolution_strategy
  else
    sed -i '/^system-default-registry:/d' /etc/rancher/rke2/config.yaml 2>/dev/null || true
    rm -f /etc/rancher/rke2/registries.yaml 2>/dev/null || true
  fi

  # -------------------------
  # Optional: seed custom cluster CA
  # -------------------------
  # If any custom CA inputs are present (from YAML/CLI/prompt), export env vars for setup_custom_cluster_ca()
  if [[ -n "$CUSTOM_ROOT_CRT" || -n "$CUSTOM_ROOT_KEY" || -n "$CUSTOM_INT_CRT" || -n "$CUSTOM_INT_KEY" ]]; then
    export CUSTOM_CA_ROOT_CRT="$CUSTOM_ROOT_CRT"
    export CUSTOM_CA_ROOT_KEY="$CUSTOM_ROOT_KEY"
    export CUSTOM_CA_INT_CRT="$CUSTOM_INT_CRT"
    export CUSTOM_CA_INT_KEY="$CUSTOM_INT_KEY"
    export CUSTOM_CA_INSTALL_TO_OS_TRUST="$INSTALL_TRUST"
    log INFO "Seeding custom cluster CA (requested via inputs)..."
    setup_custom_cluster_ca || true
  fi

  # -------------------------
  # Write /etc/rancher/rke2/config.yaml from inputs
  # -------------------------
  mkdir -p /etc/rancher/rke2
  local cfg="/etc/rancher/rke2/config.yaml"
  if [[ -f "$cfg" ]]; then cp -f "$cfg" "${cfg}.bak.$(date +%s)" || true; fi
  : > "$cfg"

  {
    # Core server options
    [[ -n "$TOKEN_FILE" ]] && echo "token_file: \"$TOKEN_FILE\""
    [[ -z "$TOKEN_FILE" && -n "$TOKEN" ]] && echo "token: \"$TOKEN\""
    [[ -n "$TLS_SANS" ]] && {
      echo "tls-san:"
      IFS=',' read -r -a _sans <<<"$TLS_SANS"
      for s in "${_sans[@]}"; do s="${s//\"/}"; s="${s// /}"; [[ -n "$s" ]] && echo "  - \"$s\""; done
    }
    [[ -n "$NODE_IP" ]] && echo "node-ip: \"$NODE_IP\""
    [[ -n "$NODE_EXTERNAL_IP" ]] && echo "node-external-ip: \"$NODE_EXTERNAL_IP\""
    [[ -n "$SERVICE_CIDR" ]] && echo "service-cidr: \"$SERVICE_CIDR\""
    [[ -n "$CLUSTER_CIDR" ]] && echo "cluster-cidr: \"$CLUSTER_CIDR\""
    [[ -n "$CLUSTER_DOMAIN" ]] && echo "cluster-domain: \"$CLUSTER_DOMAIN\""
    [[ -n "$WRITE_KUBECONFIG_MODE" ]] && echo "write-kubeconfig-mode: \"$WRITE_KUBECONFIG_MODE\""
  } >> "$cfg"
  chmod 600 "$cfg"
  log INFO "Server config written to $cfg"

  # -------------------------
  # Install RKE2 from cached artifacts
  # -------------------------
  log INFO "Proceeding with offline RKE2 server install..."
  run_rke2_installer "$SRC" "server"
  systemctl enable rke2-server >>"$LOG_FILE" 2>&1 || true

  # -------------------------
  # Hostname + network
  # -------------------------
  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -q "$HOSTNAME" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi
  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
  echo "A reboot is recommended to ensure clean state. Network is already applied."

  # -------------------------
  # Reboot prompt (last)
  # -------------------------
  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  case "$confirm" in
    Y|y) log INFO "Rebooting..."; reboot ;;
    *)   log WARN "Reboot deferred. Please reboot before using this node." ;;
  esac
}
# =============
# Action: AGENT
#   Agent flags:  -s URL  -t TOKEN  -T TOKEN_FILE  -n NODE_IP  -e NODE_EXTERNAL_IP  -l TLS_SANS  -C CA_CERT_PATH
action_agent() {
  load_site_defaults

  # -------------------------
  # Inputs (YAML → CLI → Prompt)
  # -------------------------
  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local URL="" TOKEN="" TOKEN_FILE="" NODE_IP="" NODE_EXTERNAL_IP="" TLS_SANS=""
  local AGENT_CA_CERT=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)";           [[ -n "$d" ]]  && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)";[[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"

    URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
    TOKEN_FILE="$(yaml_spec_get "$CONFIG_FILE" tokenFile || true)"
    NODE_IP="$(yaml_spec_get "$CONFIG_FILE" nodeIP || true)"
    NODE_EXTERNAL_IP="$(yaml_spec_get "$CONFIG_FILE" nodeExternalIP || true)"
    TLS_SANS="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"
    # CA to trust locally (server API/root)
    AGENT_CA_CERT="$(yaml_spec_get "$CONFIG_FILE" caCrt || true)"
  fi

  # Per-action CLI flags for Agent
  # -s URL  -t TOKEN  -T TOKEN_FILE  -n NODE_IP  -e NODE_EXTERNAL_IP  -l TLS_SANS  -C AGENT_CA_CERT
  local OPTIND=1 opt
  while getopts ":s:t:T:n:e:l:C:" opt; do
    case ${opt} in
      s) URL="$OPTARG";;
      t) TOKEN="$OPTARG";;
      T) TOKEN_FILE="$OPTARG";;
      n) NODE_IP="$OPTARG";;
      e) NODE_EXTERNAL_IP="$OPTARG";;
      l) TLS_SANS="$OPTARG";;
      C) AGENT_CA_CERT="$OPTARG";;
    esac
  done
  shift $((OPTIND-1))

  # Prompts as needed
  if [[ -z "$IP" ]];       then read -rp "Enter static IPv4 for this agent node: " IP; fi
  if [[ -z "$PREFIX" ]];   then read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX; fi
  if [[ -z "$HOSTNAME" ]]; then read -rp "Enter hostname for this agent node: " HOSTNAME; fi
  if [[ -z "$GW" ]];       then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    if [[ -z "$DNS" ]]; then DNS="$DEFAULT_DNS"; fi
  fi
  if [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then SEARCH="$DEFAULT_SEARCH"; fi
  if [[ -z "$URL" ]]; then read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345): " URL; fi
  if [[ -z "$TOKEN" && -z "$TOKEN_FILE" ]]; then read -rp "Cluster join token (or leave blank if using token_file): " TOKEN || true; fi

  # Validate basics
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # -------------------------
  # Prepare offline artifacts + runtime
  # -------------------------
  log INFO "Ensuring staged artifacts for offline RKE2 agent install..."
  ensure_staged_artifacts
  local SRC="$STAGE_DIR"
  ensure_containerd_ready

  # Trust the server CA if provided
  if [[ -n "$AGENT_CA_CERT" && -f "$AGENT_CA_CERT" ]]; then
    mkdir -p /usr/local/share/ca-certificates
    local CA_BN="$(basename "$AGENT_CA_CERT")"
    cp -f "$AGENT_CA_CERT" "/usr/local/share/ca-certificates/$CA_BN"
    update-ca-certificates >>"$LOG_FILE" 2>&1 || true
    log INFO "Installed $CA_BN into OS trust store."
  fi

  # -------------------------
  # Write /etc/rancher/rke2/config.yaml for agent join
  # -------------------------
  mkdir -p /etc/rancher/rke2
  local cfg="/etc/rancher/rke2/config.yaml"
  if [[ -f "$cfg" ]]; then cp -f "$cfg" "${cfg}.bak.$(date +%s)" || true; fi
  : > "$cfg"

  {
    echo "server: \"$URL\""
    if [[ -n "$TOKEN_FILE" ]]; then
      echo "token_file: \"$TOKEN_FILE\""
    elif [[ -n "$TOKEN" ]]; then
      echo "token: \"$TOKEN\""
    fi
    [[ -n "$NODE_IP" ]] && echo "node-ip: \"$NODE_IP\""
    [[ -n "$NODE_EXTERNAL_IP" ]] && echo "node-external-ip: \"$NODE_EXTERNAL_IP\""
    [[ -n "$TLS_SANS" ]] && {
      echo "tls-san:"
      IFS=',' read -r -a _sans <<<"$TLS_SANS"
      for s in "${_sans[@]}"; do s="${s//\"/}"; s="${s// /}"; [[ -n "$s" ]] && echo "  - \"$s\""; done
    }
  } >> "$cfg"
  chmod 600 "$cfg"
  log INFO "Agent join config written to $cfg"

  # -------------------------
  # Install RKE2 from cached artifacts
  # -------------------------
  log INFO "Proceeding with offline RKE2 agent install..."
  run_rke2_installer "$SRC" "agent"
  systemctl enable rke2-agent >>"$LOG_FILE" 2>&1 || true

  # -------------------------
  # Hostname + network
  # -------------------------
  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -q "$HOSTNAME" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi
  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"

  # -------------------------
  # Reboot prompt (last)
  # -------------------------
  echo "A reboot is recommended to ensure clean state. Network is already applied."
  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  case "$confirm" in
    Y|y) log INFO "Rebooting..."; reboot ;;
    *)   log WARN "Reboot deferred. Please reboot before using this node." ;;
  esac
}
# ===============
# ================
# Action: ADD-SERVER (join existing HA control plane)
action_add_server() {
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local URL="" TOKEN="" TOKEN_FILE="" TLS_SANS=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd ts
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
    TOKEN_FILE="$(yaml_spec_get "$CONFIG_FILE" tokenFile || true)"
    ts="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"; [[ -n "$ts" ]] && TLS_SANS="$(normalize_list_csv "$ts")"
  fi

  [[ -z "$IP"       ]] && read -rp "Enter static IPv4 for this server node: " IP
  [[ -z "$PREFIX"   ]] && read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX
  [[ -z "$HOSTNAME" ]] && read -rp "Enter hostname for this server node: " HOSTNAME
  [[ -z "$GW"       ]] && read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS"
  fi
  if [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then
    SEARCH="$DEFAULT_SEARCH"
  fi

  # Cluster join info
  [[ -z "$URL" ]] && read -rp "Enter EXISTING RKE2 server URL (e.g. https://<vip-or-node>:9345): " URL
  if [[ -z "$TOKEN" && -z "$TOKEN_FILE" ]]; then
    read -rp "Enter cluster join token (leave blank to provide a token file path): " TOKEN || true
    if [[ -z "$TOKEN" ]]; then
      read -rp "Enter path to token file (e.g., /var/lib/rancher/rke2/server/node-token): " TOKEN_FILE || true
    fi
  fi
  [[ -z "$TLS_SANS" ]] && read -rp "Optional TLS SANs (CSV; hostnames/IPs) [blank=skip]: " TLS_SANS || true

  # Validation
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  ensure_staged_artifacts
  ensure_containerd_ready

  # Write RKE2 config for join
  mkdir -p /etc/rancher/rke2
  # Preserve existing config (system-default-registry) if present; then append join settings
  if [[ ! -f /etc/rancher/rke2/config.yaml ]]; then
    : > /etc/rancher/rke2/config.yaml
  fi

  {
    echo "server: \"$URL\""
    if [[ -n "$TOKEN_FILE" ]]; then
      echo "token_file: \"$TOKEN_FILE\""
    else
      echo "token: \"$TOKEN\""
    fi
    if [[ -n "$TLS_SANS" ]]; then
      echo "tls-san:"
      IFS=',' read -r -a _sans <<<"$TLS_SANS"
      for s in "${_sans[@]}"; do
        s="${s//\"/}"
        s="${s// /}"
        [[ -n "$s" ]] && echo "  - \"$s\""
      done
    fi
  } >> /etc/rancher/rke2/config.yaml
  chmod 600 /etc/rancher/rke2/config.yaml

  log INFO "RKE2 join config written to /etc/rancher/rke2/config.yaml"
  log INFO "server: $URL"
  if [[ -n "$TOKEN_FILE" ]]; then log INFO "token_file: $TOKEN_FILE"; else log INFO "token: (redacted)"; fi

  # Install rke2-server using staged artifacts
  local SRC="$STAGE_DIR"
  log INFO "Seeding custom cluster CA (if first server in a cluster; safe to skip on join)..."
  setup_custom_cluster_ca || true
  log INFO "Installing rke2-server (join existing control plane)..."
  run_rke2_installer "$SRC" "server"
  systemctl enable --now rke2-server >>"$LOG_FILE" 2>&1 || true

  # Basic hostname and /etc/hosts
  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -q "$HOSTNAME" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
  echo "A reboot is recommended to ensure clean state. Network is already applied."
}

# Action: VERIFY
action_verify() {
  load_site_defaults
if verify_prereqs; then
    log INFO "VERIFY PASSED: Node meets RKE2 prerequisites."
    exit 0
  else
    log ERROR "VERIFY FAILED: See messages above and fix issues."
    exit 2
  fi
}

# ================================================================================================
# ARGUMENT PARSING
# ================================================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-push) DRY_PUSH=1; shift;;
    -f|-v|-r|-u|-p|-y|-P|-h|pull|push|image|server|agent|verify) break;;
    *) break;;
  esac
done

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
    \?) echo "Invalid option: -$OPTARG"; print_help; exit 1;;
    :)  echo "Option -$OPTARG requires an argument"; exit 1;;
  esac
done
shift $((OPTIND-1))

CLI_SUB="${1:-}"
if [[ -z "$CONFIG_FILE" && -n "$CLI_SUB" && -f "$CLI_SUB" ]]; then
  CONFIG_FILE="$CLI_SUB"; CLI_SUB=""
fi

YAML_KIND=""
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "YAML file not found: $CONFIG_FILE"; exit 5
  fi
  API="$(yaml_get_api "$CONFIG_FILE" || true)"
  YAML_KIND="$(yaml_get_kind "$CONFIG_FILE" || true)"
  if [[ "$API" != "rkeprep/v1" ]]; then
    log ERROR "Unsupported apiVersion: '$API' (expected rkeprep/v1)"; exit 5
  fi
  if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    echo "----- Sanitized YAML -----"
    sanitize_yaml "$CONFIG_FILE"
    echo "--------------------------"
  fi
fi

ACTION="${CLI_SUB:-}"
if [[ -n "$CONFIG_FILE" && -z "$CLI_SUB" ]]; then
  case "$YAML_KIND" in
    Pull|pull)        ACTION="pull"        ;;
    Push|push)        ACTION="push"        ;;
    Image|image)      ACTION="image"       ;;
    Server|server)    ACTION="server"      ;;
    AddServer|add-server|addServer) ACTION="add-server" ;;
    ClusterCA|cluster-ca|CustomCA|custom-ca) ACTION="cluster-ca" ;;
    Agent|agent)      ACTION="agent"       ;;
    *) log ERROR "Unsupported or missing YAML kind: '${YAML_KIND:-<none>}'"; exit 5;;
  esac
fi

case "${ACTION:-}" in
  pull)   action_pull   ;;
  push)   action_push   ;;
  image)  action_image  ;;
  server) action_server ;;
  add-server) action_add_server ;;
  agent)  action_agent  ;;
  cluster-ca) action_cluster_ca ;;
  verify) action_verify ;;
  *) print_help; exit 1 ;;
esac
