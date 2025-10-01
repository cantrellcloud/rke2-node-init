#!/usr/bin/env bash
#
# If not running under bash, re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi

# Fail if not root
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: please run this script as root (use sudo)."
  exit 1
fi

# Fail fast on CRLF (Windows) endings, which can also trigger odd parse errors
case "$(head -c 2 "$0" | od -An -t x1 | tr -d ' ')" in
  *0d0a) echo "ERROR: Windows line endings detected. Run: dos2unix '$0'"; exit 2;;
esac

#
# rke2nodeinit.sh
# ----------------------------------------------------
# Purpose:
#   Prepare and configure a Linux VM/host (Ubuntu/Debian-based) for an offline/air-gapped
#   Rancher RKE2 Kubernetes deployment using **containerd + nerdctl** ONLY.
#
# Actions:
#   1) push   - Tag and push preloaded images into a private registry (nerdctl only)
#   2) image  - Stage artifacts, registries config, CA certs, and OS prereqs for offline use
#   3) server - Configure network/hostname and install rke2-server (offline)
#   4) agent  - Configure network/hostname and install rke2-agent  (offline)
#   5) verify - Check that node prerequisites are in place
#
# Major changes vs previous:
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

# ---------- Defaults & tunables ----------------------------------------------------------------
RKE2_VERSION=""                                       # auto-detect if empty
REGISTRY="rke2registry.dev.local"
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

# Logging
LOG_FILE="$LOG_DIR/rke2nodeinit_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"

# ---------- Help --------------------------------------------------------------------------------
print_help() {
  cat <<'EOF'
NOTE: All YAML inputs must include a metadata.name field (e.g., metadata: { name: my-config }).
Usage:
  sudo ./rke2nodeinit.sh -f file.yaml [options]
  sudo ./rke2nodeinit.sh [options] <push|image|server|add-server|agent|verify>
  sudo ./rke2nodeinit.sh examples/pull.yaml


YAML kinds (apiVersion: rkeprep/v1):
  - kind: Push|Image|Airgap|Server|AddServer|Agent|Verify

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
Image action:
  Does the full prep for an air‑gapped base image:
    - Installs OS prerequisites and disables swap
    - Caches nerdctl FULL bundle (containerd + runc + CNI + BuildKit + nerdctl)
    - Detects & downloads RKE2 artifacts (images, tarball, checksums, installer)
    - Verifies checksums and stages artifacts for offline install
    - (Optional) Installs registry/cluster CA into OS trust and writes registries.yaml
    - Saves DNS/search defaults for later (server/agent)
    - Reboots the machine so you can shut down and clone it


Actions:
  image        Prepare a base image for air‑gapped use (installs ONLY standalone nerdctl; caches FULL bundle)
  airgap       Run 'image' without reboot and power off the machine for templating

Outputs:
  - SBOM:    $OUT_DIR/../sbom/<metadata.name>-sbom.txt with sha256 + sizes of cached artifacts
  - Run dir: $OUT_DIR/<metadata.name>/README.txt summarizing image prep

EOF
}

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

  # Protect wait from set -e
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



# --- YAML helpers (robust under 'spec:' for scalars and lists) ---
yaml_spec_get_any() {
  # Usage: yaml_spec_get_any <file> <key1> [key2] [key3] ...
  local file="$1"; shift || true
  local k
  for k in "$@"; do
    local v
    v="$(yaml_spec_get "$file" "$k" || true)"
    if [[ -n "$v" ]]; then
      echo "$v"
      return 0
    fi
  done
  return 1
}

yaml_spec_has_list() {
  # Return 0 if spec.<key> is a YAML list
  local file="$1"; local key="$2"
  awk -v k="$key" '
    BEGIN { inSpec=0; found=0; }
    /^[[:space:]]*spec:[[:space:]]*$/ { inSpec=1; next }
    inSpec==1 {
      if ($0 ~ /^[^[:space:]]/) { exit } # left spec
      if ($0 ~ "^[[:space:]]+" k "[[:space:]]*:[[:space:]]*$") { found=1; next }
      if (found==1) {
        if ($0 ~ "^[[:space:]]*-[[:space:]]+") { print "YES"; exit }
        else if ($0 ~ "^[[:space:]]*$") { next } # skip blanks
        else { exit } # not a list
      }
    }
  ' "$file" | grep -q YES
}

yaml_spec_list_items() {
  # Print items of a YAML list under spec.<key>, one per line (no quoting)
  local file="$1"; local key="$2"
  awk -v k="$key" '
    BEGIN { inSpec=0; collect=0; }
    /^[[:space:]]*spec:[[:space:]]*$/ { inSpec=1; next }
    inSpec==1 {
      if ($0 ~ /^[^[:space:]]/) { exit } # left spec
      if ($0 ~ "^[[:space:]]+" k "[[:space:]]*:[[:space:]]*$") { collect=1; next }
      if (collect==1) {
        if ($0 ~ "^[[:space:]]*-[[:space:]]+(.*)$") {
          sub(/^[[:space:]]*-[[:space:]]+/, "", $0)
          gsub(/^"|'\''|"$/, "", $0)
          print $0
        } else if ($0 ~ "^[[:space:]]*$") {
          next
        } else {
          exit
        }
      }
    }
  ' "$file"
}

yaml_spec_list_csv() {
  # Emit a comma-separated list from spec.<key> YAML list (if any)
  local file="$1"; local key="$2"
  local items; items="$(yaml_spec_list_items "$file" "$key" | tr '\n' ',' | sed 's/,$//')"
  [[ -n "$items" ]] && echo "$items"
}

append_spec_config_extras() {
  # Append additional config.yaml keys present in spec that we should honor.
  # Skips keys already present to avoid duplicates.
  local file="$1"
  [[ -z "$file" || ! -f "$file" ]] && return 0
  local cfg="/etc/rancher/rke2/config.yaml"

  # Helper to avoid duplicate keys
  _cfg_has_key() { grep -Eq "^[[:space:]]*$1[[:space:]]*:" "$cfg" 2>/dev/null; }

  # Scalars we pass through as-is if present
  local -a scalars=(
    "cluster-cidr" "service-cidr" "cluster-dns" "cluster-domain"
    "cni" "system-default-registry" "private-registry" "write-kubeconfig-mode"
    "selinux" "protect-kernel-defaults" "kube-apiserver-image" "kube-controller-manager-image"
    "kube-scheduler-image" "etcd-image" "disable-cloud-controller" "disable-kube-proxy"
  )

  local k v
  for k in "${scalars[@]}"; do
    _cfg_has_key "$k" && continue
    v="$(yaml_spec_get_any "$file" "$k" "$(echo "$k" | sed -E 's/-([a-z])/\U\\1/g; s/^([a-z])/\U\\1/; s/-//g')")" || true
    if [[ -n "$v" ]]; then
      # ensure quoting for non-boolean, non-numeric values
      if [[ "$v" =~ ^(true|false|[0-9]+)$ ]]; then
        echo "$k: $v" >> "$cfg"
      else
        # strip surrounding quotes then re-quote
        v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
        echo "$k: \"$v\"" >> "$cfg"
      fi
    fi
  done

  # Lists we support (emit YAML arrays)
  local -a lists=(
    "kube-apiserver-arg" "kube-controller-manager-arg" "kube-scheduler-arg" "kube-proxy-arg"
    "node-taint" "node-label" "tls-san"
  )

  for k in "${lists[@]}"; do
    _cfg_has_key "$k" && continue
    if yaml_spec_has_list "$file" "$k"; then
      echo "$k:" >> "$cfg"
      yaml_spec_list_items "$file" "$k" | sed 's/^/  - /' >> "$cfg"
    fi
  done
}

yaml_meta_get() {
  # Get a key from the top-level "metadata:" section (e.g., "name")
  # usage: yaml_meta_get <file> <key>
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { inMeta=0 }
    /^[[:space:]]*metadata:[[:space:]]*$/ { inMeta=1; next }
    inMeta==1 {
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

ensure_yaml_has_metadata_name() {
  # Validates that CONFIG_FILE has metadata.name; sets global SPEC_NAME
  local file="${1:-$CONFIG_FILE}"
  [[ -z "$file" || ! -f "$file" ]] && return 0
  local name
  name="$(yaml_meta_get "$file" name || true)"
  if [[ -z "$name" ]]; then
    echo "ERROR: YAML file '$file' is missing required 'metadata.name'." >&2
    echo "Add at least:" >&2
    echo "  metadata:" >&2
    echo "    name: <your-config-name>" >&2
    exit 2
  fi
  SPEC_NAME="$name"
  log INFO "YAML metadata.name: ${SPEC_NAME}"
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

# Build a comma CSV of default SANs from hostname/IP/search domains.
# usage: capture_sans "<HOSTNAME>" "<IP>" "<SEARCH_CSV>"
capture_sans() {
  local hn="$1" ip="$2" search_csv="$3"
  local out="$hn,$ip"
  if [[ -n "$search_csv" ]]; then
    IFS=',' read -r -a _sd <<<"$search_csv"
    for d in "${_sd[@]}"; do
      d="${d// /}"
      [[ -n "$d" ]] && out+=",$hn.$d"
    done
  fi
  printf '%s' "$out"
}

# Emit a tls-san: list given a CSV string (no empty lines)
emit_tls_sans() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  echo "tls-san:"
  IFS=',' read -r -a _sans <<<"$csv"
  for s in "${_sans[@]}"; do
    s="${s//\"/}"; s="${s// /}"
    [[ -n "$s" ]] && echo "  - \"$s\""
  done
}

# ---------- OS prereqs --------------------------------------------------------------------------
install_rke2_prereqs() {
  log INFO "Installing RKE2 prereqs (iptables-nft, modules, sysctl, swapoff)"
  export DEBIAN_FRONTEND=noninteractive
  log INFO "Updating APT package cache"
  spinner_run "Updating APT package cache" apt-get update -y
  log INFO "Upgrading APT packages"
  spinner_run "Upgrading APT packages" apt-get upgrade -y
  log INFO "Installing required packages"
  spinner_run "Installing required packages" apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq
  log INFO "Removing unnecessary packages"
  spinner_run "Removing unnecessary packages" apt-get autoremove -y # >>"$LOG_FILE" 2>&1

  if update-alternatives --list iptables >/dev/null 2>&1; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set arptables /usr/sbin/arptables-nft >>"$LOG_FILE" 2>&1 || true
    update-alternatives --set ebtables  /usr/sbin/ebtables-nft  >>"$LOG_FILE" 2>&1 || true
  fi

  mkdir -p /etc/modules-load.d /etc/sysctl.d
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

  # ------------------ Swap off (now and persistent) ------------------
  if swapon --show | grep -q .; then
    log WARN "Swap is enabled; disabling now."
    swapoff -a || true
  fi
  if grep -qs '^\S\+\s\+\S\+\s\+swap\s' /etc/fstab; then
    log INFO "Commenting swap entries in /etc/fstab for Kubernetes compatibility."
    sed -ri 's/^(\s*[^#\s]+\s+[^#\s]+\s+swap\s+.*)$/# \1/' /etc/fstab
  fi

  # ------------------ NetworkManager: ignore CNI if present ------------------
  if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
    mkdir -p /etc/NetworkManager/conf.d
    cat >/etc/NetworkManager/conf.d/rke2-cni-unmanaged.conf <<'NM'
[keyfile]
unmanaged-devices=interface-name:cni*,interface-name:flannel.*,interface-name:flannel.1
NM
    systemctl restart NetworkManager || true
    log INFO "Configured NetworkManager to ignore cni*/flannel* interfaces."
  fi

  # ------------------ Open ports if UFW is active ------------------
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q 'Status: active'; then
    ufw allow 6443/tcp || true   # Kubernetes API
    ufw allow 9345/tcp || true   # RKE2 supervisor
    ufw allow 10250/tcp || true  # kubelet
    ufw allow 8472/udp || true   # VXLAN for CNI (flannel)
    log INFO "UFW rules added for 6443/tcp, 9345/tcp, 10250/tcp, 8472/udp."
  fi
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
  primary_registry="${primary_registry:-${REGISTRY:-'rke2registry.dev.local'}}"
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

fetch_rke2_ca_generator() { 
  # Prefetch custom-CA helper for offline use
  if command -v curl >/dev/null 2>&1; then
    local GEN_URL="https://raw.githubusercontent.com/k3s-io/k3s/refs/heads/main/contrib/util/generate-custom-ca-certs.sh"
    log INFO "Fetching custom-CA helper script for offline use."
    curl -fsSL -o "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" "$GEN_URL" >>"$LOG_FILE" 2>&1 || true
    chmod +x "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" >>"$LOG_FILE" 2>&1 || true
    log INFO "Staged custom-CA helper script for offline use."
  fi
}

cache_rke2_artifacts() {
  mkdir -p "$DOWNLOADS_DIR"
  pushd "$DOWNLOADS_DIR" >/dev/null

  # Pick version: from config/env or latest online
  if [[ -n "$REQ_VER" ]]; then
    RKE2_VERSION="$REQ_VER"
    log INFO "Using RKE2 version from config/env: $RKE2_VERSION"
  else
    detect_latest_rke2_version   # populates RKE2_VERSION
  fi

  local BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION}"
  local IMAGES_TAR="rke2-images.linux-${ARCH}.tar.zst"
  local RKE2_TARBALL="rke2.linux-${ARCH}.tar.gz"
  local SHA256_FILE="sha256sum-${ARCH}.txt"

  # Download artifacts (idempotent)
  [[ -f "$IMAGES_TAR"  ]] || spinner_run "Downloading $IMAGES_TAR"  curl -Lf "$BASE_URL/$IMAGES_TAR"  -o "$IMAGES_TAR"
  [[ -f "$RKE2_TARBALL" ]] || spinner_run "Downloading $RKE2_TARBALL" curl -Lf "$BASE_URL/$RKE2_TARBALL" -o "$RKE2_TARBALL"
  [[ -f "$SHA256_FILE" ]] || spinner_run "Downloading $SHA256_FILE"  curl -Lf "$BASE_URL/$SHA256_FILE"  -o "$SHA256_FILE"
  [[ -f install.sh ]]    || spinner_run "Downloading install.sh"    curl -sfL "https://get.rke2.io" -o install.sh
  chmod +x install.sh || true

  # Verify checksums when possible
  if command -v sha256sum >/dev/null 2>&1; then
    if grep -q "$IMAGES_TAR" "$SHA256_FILE" 2>/dev/null; then
      grep "$IMAGES_TAR"  "$SHA256_FILE" | sha256sum -c - >>"$LOG_FILE" 2>&1 || true
    fi
    if grep -q "$RKE2_TARBALL" "$SHA256_FILE" 2>/dev/null; then
      grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c - >>"$LOG_FILE" 2>&1 || true
    fi
  fi

  popd >/dev/null

  # --- Stage artifacts for offline install -----------------------------------
  mkdir -p /var/lib/rancher/rke2/agent/images/
  if [[ -f "$DOWNLOADS_DIR/$IMAGES_TAR" ]]; then
    cp -f "$DOWNLOADS_DIR/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/ || true
    log INFO "Staged ${IMAGES_TAR} into /var/lib/rancher/rke2/agent/images/"
  fi

  mkdir -p "$STAGE_DIR"
  for f in "$RKE2_TARBALL" "$SHA256_FILE" "install.sh"; do
    if [[ -f "$DOWNLOADS_DIR/$f" ]]; then
      cp -f "$DOWNLOADS_DIR/$f" "$STAGE_DIR/"
      [[ "$f" == "install.sh" ]] && chmod +x "$STAGE_DIR/install.sh"
      log INFO "Staged $f into $STAGE_DIR"
    fi
  done

  # Stage custom-CA helper if present in downloads
  if [[ -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" ]]; then
    cp -f "$DOWNLOADS_DIR/generate-custom-ca-certs.sh" "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    chmod +x "$STAGE_DIR/generate-custom-ca-certs.sh" || true
    log INFO "Staged custom-CA helper into $STAGE_DIR."
  fi
}

prompt_reboot() {
  echo
  if (( AUTO_YES )); then
    log WARN "Auto-confirm enabled (-y). Rebooting now..."
    sleep 2
    reboot
  else
    read -r -p "Reboot now to ensure kernel modules/sysctls persist? [y/N]: " _ans
    case "${_ans,,}" in
      y|yes)
        log WARN "Rebooting..."
        sleep 2
        reboot
        ;;
      *)
        log INFO "Reboot deferred. Remember to reboot before installing RKE2."
        ;;
    esac
  fi
}

# ================================================================================================
# ACTIONS
# ================================================================================================

# ==================
# Action: PUSH
action_push() {
  # Require metadata.name when a YAML file is provided
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi

  if [[ -n "$CONFIG_FILE" ]]; then
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (push)."
  fi

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
  # Require metadata.name; set per-run directories + log
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi
  if [[ -n "${SPEC_NAME:-}" ]]; then
    mkdir -p "$OUT_DIR/$SPEC_NAME"
    RUN_OUT_DIR="$OUT_DIR/$SPEC_NAME"
    LOG_FILE="$LOG_DIR/${SPEC_NAME}_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"
    export LOG_FILE RUN_OUT_DIR
    log INFO "Using run output directory: $RUN_OUT_DIR"
  fi

  # --- Read YAML (optional) -------------------------------------------------
  local REQ_VER="${RKE2_VERSION:-}"
  local defaultDnsCsv="$DEFAULT_DNS"
  local defaultSearchCsv=""
  local REG_HOST="${REGISTRY%%/*}"
  local CA_ROOT="" CA_KEY="" CA_INTCRT="" CA_INTKEY="" CA_INSTALL="true"
  if [[ -n "$CONFIG_FILE" ]]; then
    REQ_VER="${REQ_VER:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    REG_HOST="${REGISTRY%%/*}"
    local d1 s1
    d1="$(yaml_spec_get "$CONFIG_FILE" defaultDns || true)"
    s1="$(yaml_spec_get "$CONFIG_FILE" defaultSearchDomains || true)"
    [[ -n "$d1" ]] && defaultDnsCsv="$(normalize_list_csv "$d1")"
    [[ -n "$s1" ]] && defaultSearchCsv="$(normalize_list_csv "$s1")"
    # Optional custom CA for registry/cluster
    CA_ROOT="$(yaml_spec_get "$CONFIG_FILE" customCA.rootCrt || true)"
    CA_KEY="$(yaml_spec_get "$CONFIG_FILE" customCA.rootKey || true)"
    CA_INTCRT="$(yaml_spec_get "$CONFIG_FILE" customCA.intermediateCrt || true)"
    CA_INTKEY="$(yaml_spec_get "$CONFIG_FILE" customCA.intermediateKey || true)"
    CA_INSTALL="$(yaml_spec_get "$CONFIG_FILE" customCA.installToOSTrust || echo true)"
  fi

  # Resolve cert paths relative to script dir if not absolute
  [[ -n "$CA_ROOT"   && "${CA_ROOT:0:1}"   != "/" ]] && CA_ROOT="$SCRIPT_DIR/$CA_ROOT"
  [[ -n "$CA_KEY"    && "${CA_KEY:0:1}"    != "/" ]] && CA_KEY="$SCRIPT_DIR/$CA_KEY"
  [[ -n "$CA_INTCRT" && "${CA_INTCRT:0:1}" != "/" ]] && CA_INTCRT="$SCRIPT_DIR/$CA_INTCRT"
  [[ -n "$CA_INTKEY" && "${CA_INTKEY:0:1}" != "/" ]] && CA_INTKEY="$SCRIPT_DIR/$CA_INTKEY"

  # --- OS prereqs ------------------------------------------------------------
  install_rke2_prereqs

  # --- Detect/cache nerdctl: FULL (cache only) + standalone (install) --------
  ensure_installed curl
  ensure_installed ca-certificates
  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local ntag nver full_tgz std_tgz full_url std_url
  ntag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  if [[ -n "$ntag" ]]; then
    nver="${ntag#v}"
    full_tgz="nerdctl-full-${nver}-linux-${ARCH}.tar.gz"
    std_tgz="nerdctl-${nver}-linux-${ARCH}.tar.gz"
    full_url="https://github.com/containerd/nerdctl/releases/download/${ntag}/${full_tgz}"
    std_url="https://github.com/containerd/nerdctl/releases/download/${ntag}/${std_tgz}"
    mkdir -p "$DOWNLOADS_DIR"
    # Cache FULL bundle
    if [[ ! -f "$DOWNLOADS_DIR/$full_tgz" ]]; then
      spinner_run "Caching nerdctl FULL ${ntag}" curl -Lf "$full_url" -o "$DOWNLOADS_DIR/$full_tgz"
      log INFO "Cached $(basename "$DOWNLOADS_DIR/$full_tgz")"
    else
      log INFO "nerdctl FULL already cached: $(basename "$DOWNLOADS_DIR/$full_tgz")"
    fi
    # Cache standalone tarball
    if [[ ! -f "$DOWNLOADS_DIR/$std_tgz" ]]; then
      spinner_run "Caching nerdctl standalone ${ntag}" curl -Lf "$std_url" -o "$DOWNLOADS_DIR/$std_tgz"
      log INFO "Cached $(basename "$DOWNLOADS_DIR/$std_tgz")"
    else
      log INFO "nerdctl standalone already cached: $(basename "$DOWNLOADS_DIR/$std_tgz")"
    fi
    # Install ONLY the standalone nerdctl binary
    if [[ -f "$DOWNLOADS_DIR/$std_tgz" ]]; then
      tmpdir="$(mktemp -d)"
      tar -C "$tmpdir" -xzf "$DOWNLOADS_DIR/$std_tgz"
      # tar contains 'nerdctl'
      if [[ -f "$tmpdir/nerdctl" ]]; then
        install -m 0755 "$tmpdir/nerdctl" /usr/local/bin/nerdctl
        log INFO "Installed standalone nerdctl to /usr/local/bin/nerdctl"
      else
        # Fallback: look for nested path
        found="$(find "$tmpdir" -type f -name nerdctl | head -n1 || true)"
        if [[ -n "$found" ]]; then
          install -m 0755 "$found" /usr/local/bin/nerdctl
          log INFO "Installed standalone nerdctl from archive path to /usr/local/bin/nerdctl"
        else
          log WARN "nerdctl binary not found in $std_tgz; skipping install"
        fi
      fi
      rm -rf "$tmpdir"
    fi
  else
    log WARN "Could not detect nerdctl latest release via GitHub API."
  fi

  fetch_rke2_ca_generator
  cache_rke2_artifacts

  # --- Optional: CA trust + registries mirrors -------------------------------
  local CA_BN=""
  if [[ -n "$CA_ROOT" && -f "$CA_ROOT" ]]; then
    CA_BN="$(basename "$CA_ROOT")"
    if [[ "$CA_INSTALL" =~ ^([Tt]rue|1|yes|Y)$ ]]; then
      mkdir -p /usr/local/share/ca-certificates
      cp -f "$CA_ROOT" "/usr/local/share/ca-certificates/$CA_BN"
      update-ca-certificates >>"$LOG_FILE" 2>&1 || true
      log INFO "Installed $CA_BN into OS trust store."
    fi
    # Persist to site defaults for server phase
    local STATE="/etc/rke2image.defaults"
    {
      echo "CUSTOM_CA_ROOT_CRT=\"$CA_ROOT\""
      [[ -n "$CA_KEY"    ]] && echo "CUSTOM_CA_ROOT_KEY=\"$CA_KEY\""
      [[ -n "$CA_INTCRT" ]] && echo "CUSTOM_CA_INT_CRT=\"$CA_INTCRT\""
      [[ -n "$CA_INTKEY" ]] && echo "CUSTOM_CA_INT_KEY=\"$CA_INTKEY\""
      if [[ "$CA_INSTALL" =~ ^([Tt]rue|1|yes|Y)$ ]]; then
        echo "CUSTOM_CA_INSTALL_TO_OS_TRUST=1"
      else
        echo "CUSTOM_CA_INSTALL_TO_OS_TRUST=0"
      fi
    } >> "$STATE"
    chmod 600 "$STATE"
  fi

  # If a registry is configured, write registries.yaml with mirrors + auth + CA
  mkdir -p /etc/rancher/rke2
  if [[ -n "$REG_HOST" ]]; then
    write_registries_yaml_with_fallbacks "$REG_HOST" "" "" "$REG_USER" "$REG_PASS" "/usr/local/share/ca-certificates/${CA_BN:-}"
  else
    rm -f /etc/rancher/rke2/registries.yaml 2>/dev/null || true
  fi
  : > /etc/rancher/rke2/config.yaml

  # --- Save site defaults (DNS/search) ---------------------------------------
  local STATE="/etc/rke2image.defaults"
  {
    echo "DEFAULT_DNS=\"$defaultDnsCsv\""
    echo "DEFAULT_SEARCH=\"$defaultSearchCsv\""
  } > "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved site defaults: DNS=[$defaultDnsCsv], SEARCH=[$defaultSearchCsv]"

  # --- SBOM and README -------------------------------------------------------
  # SBOM lists filenames, sizes, sha256; write to $SBOM_DIR/<name>-sbom.txt
  mkdir -p "$SBOM_DIR"
  local sbom_name="${SPEC_NAME:-image}"
  local sbom_file="$SBOM_DIR/${sbom_name}-sbom.txt"
  {
    echo "# RKE2 Image Prep SBOM"
    echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "RKE2_VERSION: ${RKE2_VERSION}"
    echo "REGISTRY: ${REGISTRY}"
    echo
    for f in "$DOWNLOADS_DIR/$IMAGES_TAR" "$DOWNLOADS_DIR/$RKE2_TARBALL" "$DOWNLOADS_DIR/$SHA256_FILE" "$DOWNLOADS_DIR/install.sh" "$DOWNLOADS_DIR/$full_tgz" "$DOWNLOADS_DIR/$std_tgz"; do
      [[ -f "$f" ]] || continue
      sha256sum "$f"
      ls -l "$f" | awk '{print "SIZE " $5 "  " $9}'
    done
  } > "$sbom_file"
  log INFO "SBOM written to $sbom_file"

  # README in outputs/<SPEC_NAME>
  if [[ -n "${RUN_OUT_DIR:-}" ]]; then
    {
      echo "# Air‑Gapped Image Prep Summary"
      echo "Name: ${SPEC_NAME}"
      echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      echo "RKE2_VERSION: ${RKE2_VERSION}"
      echo "nerdctl FULL: ${full_tgz:-<not cached>}"
      echo "nerdctl standalone: ${std_tgz:-<not cached>}"
      echo "Registry: ${REGISTRY:-<none>}"
      echo "Custom CA: ${CA_ROOT:-<none>} (installed to OS trust: ${CA_INSTALL})"
      echo "Staged:"
      echo "  - /var/lib/rancher/rke2/agent/images/${IMAGES_TAR}"
      echo "  - $STAGE_DIR/${RKE2_TARBALL}, $STAGE_DIR/${SHA256_FILE}, $STAGE_DIR/install.sh"
      echo "Defaults:"
      echo "  - DNS: ${defaultDnsCsv}"
      echo "  - Search Domains: ${defaultSearchCsv:-<none>}"
      echo
      echo "Next:"
      echo "  - Shut down this VM and clone it for use in the air‑gapped environment."
      echo "  - Then run this script in 'server' or 'agent' mode on the clone(s)."
    } > "$RUN_OUT_DIR/README.txt"
    log INFO "Wrote $RUN_OUT_DIR/README.txt"
  fi

 # Image prep complete
  echo "[READY] Minimal image prep complete. Cached artifacts in: $DOWNLOADS_DIR"
  echo "        - You can now install RKE2 offline using the cached tarballs."
  echo
  prompt_reboot
}

# ==============
# Action: SERVER (bootstrap a brand-new control plane)
# Uses cached artifacts from action_image() and writes /etc/rancher/rke2/config.yaml
action_server() {
  log INFO "Ensure YAML has metadata.name..."
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi

  log INFO "Loading site defaults..."
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local TLS_SANS_IN="" TLS_SANS="" CLUSTER_INIT="true" TOKEN=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    local d sd ts
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d"  ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    ts="$(yaml_spec_get_any "$CONFIG_FILE" tlsSans tls-san || true)"; [[ -z "$ts" ]] && ts="$(yaml_spec_list_csv "$CONFIG_FILE" tls-san || true)"; [[ -n "$ts" ]] && TLS_SANS_IN="$(normalize_list_csv "$ts")"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
    CLUSTER_INIT="$(yaml_spec_get "$CONFIG_FILE" clusterInit || echo true)"
  fi

  # Fill missing basics
  [[ -z "$HOSTNAME" ]] && HOSTNAME="$(hostnamectl --static 2>/dev/null || hostname)"
  [[ -z "$IP"       ]] && read -rp "Enter static IPv4 for this server node: " IP
  [[ -z "$PREFIX"   ]] && read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX
  [[ -z "$GW"       ]] && read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS"
  fi
  [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]] && SEARCH="$DEFAULT_SEARCH"

  log INFO "Validating configuration..."
  # Validate
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domains CSV. Re-enter: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # Auto-derive tls-sans if none provided in YAML
  if [[ -n "$TLS_SANS_IN" ]]; then
    TLS_SANS="$TLS_SANS_IN"
  else
    TLS_SANS="$(capture_sans "$HOSTNAME" "$IP" "$SEARCH")"
    log INFO "Auto-derived TLS SANs: $TLS_SANS"
  fi

  log INFO "Ensuring staged artifacts for offline RKE2 server install..."
  ensure_staged_artifacts

  log INFO "Setting new hostname: $HOSTNAME..."
  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -qE "[[:space:]]$HOSTNAME(\$|[[:space:]])" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi

  setup_custom_cluster_ca || true

  log INFO "Writing file: /etc/rancher/rke2/config.yaml..."
  mkdir -p /etc/rancher/rke2
  : > /etc/rancher/rke2/config.yaml
  {
    echo "cluster-init: ${CLUSTER_INIT:-true}"

    # Optional but recommended: stable join secret for future nodes
    if [[ -n "$TOKEN" ]]; then
      echo "token: $TOKEN"
    fi

    echo "node-ip: \"$IP\""
  #  emit_tls_sans "$TLS_SANS"

    # Kubelet defaults (safe; additive). Merge-friendly if you later append more.
    echo "kubelet-arg:"
  #  # Prefer systemd-resolved if present
  #  if [[ -f /run/systemd/resolve/resolv.conf ]]; then
  #    echo "  - resolv-conf=/run/systemd/resolve/resolv.conf"
  #  fi
    echo "  - container-log-max-size=10Mi"
    echo "  - container-log-max-files=5"
    echo "  - protect-kernel-defaults=true"

    echo "write-kubeconfig-mode: \"0640\""
    # Leave system-default-registry unset to preserve cached naming.
  } >> /etc/rancher/rke2/config.yaml
  
  log INFO "Setting file security: /etc/rancher/rke2/config.yaml..."
  chmod 600 /etc/rancher/rke2/config.yaml
  
  log INFO "Append additional keys from YAML spec (cluster-cidr, domain, cni, etc.)..."
  append_spec_config_extras "$CONFIG_FILE"

 # log INFO "Wrote /etc/rancher/rke2/config.yaml (cluster-init=${CLUSTER_INIT})"
  log INFO "Wrote /etc/rancher/rke2/config.yaml"

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"

  log INFO "Installing rke2-server from cache at $STAGE_DIR"
  run_rke2_installer "$STAGE_DIR" "server"
  systemctl enable rke2-server >>"$LOG_FILE" 2>&1 || true

  echo
  echo "[READY] rke2-server installed. Reboot to initialize the control plane."
  echo "        First server token: /var/lib/rancher/rke2/server/node-token"
  echo

  if (( AUTO_YES )); then
    log WARN "Auto-confirm enabled (-y). Rebooting now..."
    sleep 2; reboot
  else
    read -r -p "Reboot now to bring up the control plane? [y/N]: " _ans
    case "${_ans,,}" in
      y|yes) log WARN "Rebooting..."; sleep 2; reboot;;
      *)     log INFO "Reboot deferred. Start later with: systemctl enable --now rke2-server";;
    esac
  fi
}

# ==================
# Action: AGENT
action_agent() {
  # Per-metadata outputs/logging
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi
  if [[ -n "${SPEC_NAME:-}" ]]; then
    mkdir -p "$OUT_DIR/$SPEC_NAME"
    RUN_OUT_DIR="$OUT_DIR/$SPEC_NAME"
    LOG_FILE="$LOG_DIR/${SPEC_NAME}_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"
    export LOG_FILE RUN_OUT_DIR
    log INFO "Using run output directory: $RUN_OUT_DIR"
  fi
  # Require metadata.name when a YAML file is provided
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi

  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local URL="" TOKEN=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    URL="$(yaml_spec_get_any "$CONFIG_FILE" serverURL server url || true)"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
  fi

  if [[ -z "$IP" ]];      then read -rp "Enter static IPv4 for this agent node: " IP; fi
  if [[ -z "$PREFIX" ]];  then read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX; fi
  if [[ -z "$HOSTNAME" ]];then read -rp "Enter hostname for this agent node: " HOSTNAME; fi
  if [[ -z "$GW" ]];      then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  log INFO "Gateway entered (agent): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    if [[ -z "$DNS" ]]; then DNS="$DEFAULT_DNS"; log INFO "Using default DNS for agent: $DNS"; fi
  fi

  if [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for agent: $SEARCH"
  fi

  if [[ -z "$URL" ]]; then
    read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " URL || true
  fi
  if [[ -n "$URL" && -z "$TOKEN" ]]; then
    read -rp "Enter cluster join token [optional]: " TOKEN || true
  fi

  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  log INFO "Ensuring staged artifacts for offline RKE2 agent install..."
  ensure_staged_artifacts
  local SRC="$STAGE_DIR"

  # Ensure local images and registries fallback chain are in place
  #setup_image_resolution_strategy
  log INFO "Proceeding with offline RKE2 agent install..."
  run_rke2_installer "$SRC" "agent"
    if [[ -n "${RUN_OUT_DIR:-}" ]]; then
    [[ -f /etc/rancher/rke2/config.yaml ]] && cp -f /etc/rancher/rke2/config.yaml "$RUN_OUT_DIR/${SPEC_NAME}-rke2-config.yaml" && log INFO "Saved rke2 config to $RUN_OUT_DIR/${SPEC_NAME}-rke2-config.yaml"
    [[ -f /etc/rancher/rke2/registries.yaml ]] && cp -f /etc/rancher/rke2/registries.yaml "$RUN_OUT_DIR/${SPEC_NAME}-registries.yaml" && log INFO "Saved registries to $RUN_OUT_DIR/${SPEC_NAME}-registries.yaml"
    if [[ -n "${AGENT_CA_CERT:-}" && -f "${AGENT_CA_CERT}" ]]; then cp -f "${AGENT_CA_CERT}" "$RUN_OUT_DIR/${SPEC_NAME}-trusted-ca.crt"; fi
  fi

  systemctl enable rke2-agent >>"$LOG_FILE" 2>&1 || true

  mkdir -p /etc/rancher/rke2
  if [[ -n "$URL" ]];   then echo "server: \"$URL\"" >> /etc/rancher/rke2/config.yaml; fi
  if [[ -n "$TOKEN" ]]; then echo "token: $TOKEN"  >> /etc/rancher/rke2/config.yaml; fi

  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -q "$HOSTNAME" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
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

# ================
# Action: ADD_SERVER
action_add_server() {
  # Require metadata.name when a YAML file is provided
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi

  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local URL="" TOKEN_FILE="" TLS_SANS="" TOKEN=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd ts
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    URL="$(yaml_spec_get_any "$CONFIG_FILE" serverURL server url || true)"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
    TOKEN_FILE="$(yaml_spec_get "$CONFIG_FILE" tokenFile || true)"
    ts="$(yaml_spec_get_any "$CONFIG_FILE" tlsSans tls-san || true)"; [[ -z "$ts" ]] && ts="$(yaml_spec_list_csv "$CONFIG_FILE" tls-san || true)"; [[ -n "$ts" ]] && TLS_SANS_IN="$(normalize_list_csv "$ts")"
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

  # Derive TLS SANs if not provided
  local TLS_SANS_IN TLS_SANS
  TLS_SANS_IN="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"
  if [[ -n "$TLS_SANS_IN" ]]; then
    TLS_SANS="$(normalize_list_csv "$TLS_SANS_IN")"
  else
    TLS_SANS="$(_autosan_csv "$HOSTNAME" "$IP" "$SEARCH")"
    log INFO "Auto-derived TLS SANs: $TLS_SANS"
  fi

  # Write RKE2 config for join
  mkdir -p /etc/rancher/rke2
  # Preserve existing config (system-default-registry) if present; then append join settings
  if [[ ! -f /etc/rancher/rke2/config.yaml ]]; then
    : > /etc/rancher/rke2/config.yaml
  fi
  {
    echo "server: \"$SERVER_URL\""     # required
    echo "token: $TOKEN"           # required
    echo "node-ip: \"$IP\""
    _emit_tls_san_yaml "$TLS_SANS"
    echo "kubelet-arg:"
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
      echo "  - resolv-conf=/run/systemd/resolve/resolv.conf"
    fi
    echo "  - container-log-max-size=10Mi"
    echo "  - container-log-max-files=5"
    echo "  - protect-kernel-defaults=true"
    echo "write-kubeconfig-mode: \"0640\""
  } >> /etc/rancher/rke2/config.yaml
  chmod 600 /etc/rancher/rke2/config.yaml

  # Append additional keys from YAML spec (cluster-cidr, domain, cni, etc.)
  append_spec_config_extras "$CONFIG_FILE"
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

# ==================
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

# ==================
# Action: AIRGAP
# One-liner wrapper: prep the image and power off for templating
action_airgap() {
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi
  NO_REBOOT=1 action_image
  sync
  log WARN "Powering off now so you can template/clone the VM."
  sleep 3
  poweroff
}

# ================================================================================================
# ARGUMENT PARSING
# ================================================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-push) DRY_PUSH=1; shift;;
    -f|-v|-r|-u|-p|-y|-P|-h|push|image|server|add-server|agent|verify) break;;
    *) break;;
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
    Push|push)        ACTION="push"        ;;
    Image|image)      ACTION="image"       ;;
    Airgap|airgap)    ACTION="airgap"      ;;
    Server|server)    ACTION="server"      ;;
    AddServer|add-server|addServer) ACTION="add-server" ;;
    Agent|agent)      ACTION="agent"       ;;
    Verify|verify)    ACTION="verify"      ;;
    *) log ERROR "Unsupported or missing YAML kind: '${YAML_KIND:-<none>}'"; exit 5;;
  esac
fi

case "${ACTION:-}" in
  image)       action_image  ;;
  server)      action_server ;;
  agent)       action_agent  ;;
  verify)      action_verify ;;
  add-server|add_server) action_add_server ;;
  airgap)      action_airgap ;;
  push)        action_push   ;;
  *) print_help; exit 1 ;;
esac
