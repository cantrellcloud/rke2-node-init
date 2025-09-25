#!/usr/bin/env bash
#
# If not running under bash, re-exec with bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec /usr/bin/env bash "$0" "$@"
fi
#
# rke2nodeinit.sh
# ----------------------------------------------------
# Purpose:
#   Prepare and configure a Linux VM/host (Ubuntu/Debian-based) for an offline/air‑gapped
#   Rancher RKE2 Kubernetes deployment. This script supports six main actions:
#
#     1) pull   - Download RKE2 artifacts (images + tarball + checksums) on an online host
#     2) push   - Tag, authenticate, and push preloaded images into a private registry
#     3) image  - Stage artifacts, registries config, CA certs, and OS prereqs for offline use
#     4) server - Configure network, hostname, and install rke2-server (offline)
#     5) agent  - Configure network, hostname, and install rke2-agent  (offline)
#     6) verify - Check that node prerequisites are in place
#
#   The workflow usually looks like: pull  -> push -> image -> server/agent -> verify
#
# Audience:
#   This file is intentionally verbose and formatted with generous spacing so that
#   entry-level admins can read and understand each step.
#
# Safety:
#   - Exits on first error (set -Eeuo pipefail)
#   - Logs to ./logs/ with timestamps and host info
#   - Validates IPs, prefixes, DNS lists, and search domain lists
#   - Avoids leaking secrets in logs
#
# Supported YAML (apiVersion: rkeprep/v1) kinds determine action when using -f <file>:
#   - kind: Pull   | kind: pull
#   - kind: Push   | kind: push
#   - kind: Image  | kind: image
#   - kind: Server | kind: server
#   - kind: Agent  | kind: agent
#
# Exit codes:
#   0   success
#   1   usage error / invalid options
#   2   missing prerequisites or invalid environment
#   3   data not found (e.g., missing downloads)
#   4   runtime/registry auth issues
#   5   YAML validation/unsupported apiVersion/kind
# -----------------------------------------------------------------------------------------

set -Eeuo pipefail

# ---------- Global error trap (prints the line number that failed) ------------------------
trap 'rc=$?; echo "[ERROR] Unexpected failure (exit $rc) at line $LINENO"; exit $rc' ERR

# ---------- Basic locations ---------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
LOG_DIR="$SCRIPT_DIR/logs"
OUT_DIR="$SCRIPT_DIR/outputs"
DOWNLOADS_DIR="$SCRIPT_DIR/downloads"
STAGE_DIR="/opt/rke2/stage"                           # Where artifacts are staged for offline install
SBOM_DIR="$OUT_DIR/sbom"                              # SBOM or inspect metadata output

mkdir -p "$LOG_DIR" "$OUT_DIR" "$DOWNLOADS_DIR" "$STAGE_DIR" "$SBOM_DIR"

# ---------- Log file setup ----------------------------------------------------------------
LOG_FILE="$LOG_DIR/rke2nodeinit_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"

log() {
  # Usage: log LEVEL message...
  # LEVEL: INFO | WARN | ERROR
  local level="$1"; shift
  local msg="$*"
  local ts host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  host="$(hostname)"
  # Always echo to console for visibility
  echo "[$level] $msg"
  # Append to structured log for auditing
  printf "%s %s rke2nodeinit[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
}

# Rotate/compress logs older than                          60 days
find "$LOG_DIR" -type f -name "rke2nodeinit_*.log" -mtime +60 -exec gzip -q {} \; -exec mv {}.gz "$LOG_DIR" \; || true

# ---------- Root check --------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: please run this script as root (use sudo)."
  exit 1
fi

# ---------- Defaults and tunables ---------------------------------------------------------
RKE2_VERSION=""                                       # If empty, we will auto-detect latest from GitHub
REGISTRY="kuberegistry.dev.kube/rke2"                 # Private registry base (host[/namespace])
REG_USER="admin"                                      # Private registry username
REG_PASS="ZAQwsx!@#123"                               # Private registry password (example; change this)
CONFIG_FILE=""                                        # Optional YAML input (apiVersion: rkeprep/v1)
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64";;
  aarch64) ARCH="arm64";;
  *) ARCH="amd64";;
esac

DEFAULT_DNS="10.0.1.34,10.231.1.34"                   # Default DNS CSV fallback
AUTO_YES=0                                            # If set (-y), auto-accept reboots where prompted
PRINT_CONFIG=0                                        # If set (-P), print sanitized YAML to screen
DRY_PUSH=0                                            # If set (--dry-push), skip actual pushes to registry

# Artifact names based on architecture
IMAGES_TAR="rke2-images.linux-$ARCH.tar.zst"
RKE2_TARBALL="rke2.linux-$ARCH.tar.gz"
SHA256_FILE="sha256sum-$ARCH.txt"

# Runtime chosen later (nerdctl/docker), prefer containerd+nerdctl
RUNTIME=""

# ---------- Usage help --------------------------------------------------------------------
print_help() {
  cat <<'EOF'
Usage:
  sudo ./rke2nodeinit.sh -f file.yaml [options]
  sudo ./rke2nodeinit.sh [options] <pull|push|image|server|agent|verify>
  sudo ./rke2nodeinit.sh examples/pull.yaml

Options:
  -f FILE     YAML config (apiVersion: rkeprep/v1; kind selects action)
  -v VER      RKE2 version tag (e.g., v1.34.1+rke2r1). If omitted, auto-detect latest
  -r REG      Private registry (host[/namespace]), e.g., reg.example.org/rke2
  -u USER     Registry username
  -p PASS     Registry password
  -y          Auto-confirm reboots (non-interactive)
  -P          Print sanitized YAML to screen (masks secrets)
  -h          Show this help
  --dry-push  Do not actually push images to registry (simulate & create manifest only)
EOF
}

# ---------- Lightweight YAML helpers ------------------------------------------------------
# Note: These are simple text extractors for "apiVersion:", "kind:", and keys under "spec:".
# They assume well-formed YAML with those fields present only once at the top level.
yaml_get_api()  { grep -E '^[[:space:]]*apiVersion:[[:space:]]*' "$1" | awk -F: '{print $2}' | xargs; }
yaml_get_kind() { grep -E '^[[:space:]]*kind:[[:space:]]*'       "$1" | awk -F: '{print $2}' | xargs; }

yaml_spec_get() {
  # Extract a single key under top-level "spec:" block
  # Example: yaml_spec_get file.yaml ip
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN { inSpec=0 }
    /^[[:space:]]*spec:[[:space:]]*$/ { inSpec=1; next }
    inSpec==1 {
      # Next top-level key would end spec:, so bail if we see no indent
      if ($0 ~ /^[^[:space:]]/) { exit }
      # Match "  key: value"
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
  # Mask sensitive values like passwords and tokens
  sed -E \
    -e 's/(registryPassword:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(registryPassword:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    -e 's/(token:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(token:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    "$1"
}

normalize_list_csv() {
  # Accepts various list formats (e.g., ["a","b"], 'a, b', or space separated)
  # Returns a clean, comma+space separated string: "a, b"
  local v="$1"
  v="${v#[}"; v="${v%]}"
  v="${v//\"/}"; v="${v//\'/}"
  echo "$v" | sed 's/,/ /g' | xargs | sed 's/ /, /g'
}

# ---------- Validators --------------------------------------------------------------------
valid_ipv4() {
  # Return 0 (true) if IPv4 looks like A.B.C.D with each 0-255
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$1"
  for n in "$a" "$b" "$c" "$d"; do
    [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1
  done
}

valid_prefix() {
  # Accepts blank (treated elsewhere) or 0..32
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( $1>=0 && $1<=32 ))
}

valid_ipv4_or_blank() { [[ -z "$1" ]] && return 0; valid_ipv4 "$1"; }

valid_csv_dns() {
  # Comma-separated IPv4s
  [[ -z "$1" ]] && return 0
  local s; s="$(echo "$1" | sed 's/,/ /g')"
  for x in $s; do valid_ipv4 "$x" || return 1; done
}

valid_search_domains_csv() {
  # Comma-separated FQDNs (simple check)
  [[ -z "$1" ]] && return 0
  local s; s="$(echo "$1" | sed 's/,/ /g')"
  for d in $s; do
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
  done
}

# ---------- Package helpers ---------------------------------------------------------------
ensure_installed() {
  # Install a single apt package if missing
  local pkg="$1"
  dpkg -s "$pkg" &>/dev/null || {
    log INFO "Installing package: $pkg"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y "$pkg"
  }
}

# ---------- Container runtime helpers -----------------------------------------------------
install_containerd_pkg() {
  ensure_installed curl
  ensure_installed ca-certificates
  ensure_installed containerd
  systemctl enable --now containerd
}

install_nerdctl_latest() {
  # Install nerdctl directly from GitHub releases (no extra deps beyond tar)
  ensure_installed curl
  ensure_installed ca-certificates
  ensure_installed tar

  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local tag ver url tmp

  tag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  if [[ -z "$tag" ]]; then
    log ERROR "Failed to detect latest nerdctl release tag"
    exit 2
  fi

  ver="${tag#v}"
  url="https://github.com/containerd/nerdctl/releases/download/${tag}/nerdctl-${ver}-linux-${ARCH}.tar.gz"
  tmp="$(mktemp -d)"

  log INFO "Installing nerdctl ${tag}"
  curl -fsSL "$url" -o "$tmp/nerdctl.tgz"
  tar -xzf "$tmp/nerdctl.tgz" -C "$tmp"
  install -m 0755 "$tmp/nerdctl" /usr/local/bin/nerdctl
  rm -rf "$tmp"

  log INFO "nerdctl version: $(/usr/local/bin/nerdctl --version || true)"
}

ensure_containerd_and_nerdctl() {
  # Preference order:
  #   1) Active containerd and nerdctl present
  #   2) containerd present -> ensure active, then install nerdctl
  #   3) Install both
  if systemctl is-active --quiet containerd; then
    if command -v nerdctl >/dev/null 2>&1; then
      RUNTIME="nerdctl"
      return
    fi
    install_nerdctl_latest
    RUNTIME="nerdctl"
    return
  fi

  if command -v containerd >/dev/null 2>&1; then
    systemctl enable --now containerd
    if ! command -v nerdctl >/dev/null 2>&1; then
      install_nerdctl_latest
    fi
    RUNTIME="nerdctl"
    return
  fi

  install_containerd_pkg
  install_nerdctl_latest
  RUNTIME="nerdctl"
}

detect_runtime() {
  # Select a runtime. Prefer containerd+nerdctl; fall back to Docker if present.
  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    RUNTIME="nerdctl"
  elif command -v containerd &>/dev/null; then
    systemctl enable --now containerd
    if ! command -v nerdctl &>/dev/null; then
      install_nerdctl_latest
    fi
    RUNTIME="nerdctl"
  elif command -v docker &>/dev/null; then
    RUNTIME="docker"
  else
    log WARN "No supported container runtime detected; installing containerd + nerdctl..."
    ensure_containerd_and_nerdctl
  fi
}

# ---------- RKE2 version detection --------------------------------------------------------
detect_latest_rke2_version() {
  # If RKE2_VERSION is empty, query GitHub for latest release tag
  if [[ -z "${RKE2_VERSION:-}" ]]; then
    log INFO "Detecting latest RKE2 version from GitHub..."
    ensure_installed curl
    local j
    j="$(curl -fsSL https://api.github.com/repos/rancher/rke2/releases/latest || true)"
    RKE2_VERSION="$(echo "$j" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
    if [[ -z "$RKE2_VERSION" ]]; then
      log ERROR "Failed to detect latest RKE2 version"
      exit 2
    fi
    log INFO "Using RKE2 version: $RKE2_VERSION"
  fi
}

# ---------- Netplan writer (static IPv4 + DNS + search domains) ---------------------------
write_netplan() {
  # Usage: write_netplan IP PREFIX GATEWAY DNS_CSV SEARCH_CSV
  local ip="$1"
  local prefix="$2"
  local gw="${3:-}"
  local dns_csv="${4:-}"
  local search_csv="${5:-}"

  # Try to detect the primary NIC
  local nic
  nic="$(ip -o -4 route show to default | awk '{print $5}' || true)"
  [[ -z "$nic" ]] && nic="$(ls /sys/class/net | grep -v lo | head -n1)"

  local tmp="/etc/netplan/99-rke-static.yaml"
  : > "$tmp"

  {
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $nic:"
    echo "      addresses: [$ip/${prefix:-24}]"
    [[ -n "$gw" ]] && echo "      gateway4: $gw"
    echo "      nameservers:"

    # DNS servers (defaults to public 8.8.8.8 if none provided)
    if [[ -n "$dns_csv" ]]; then
      local dns_sp arr joined
      dns_sp="$(echo "$dns_csv" | sed 's/,/ /g')"
      read -r -a arr <<<"$dns_sp"
      joined="$(printf ', %s' "${arr[@]}")"
      joined="${joined:2}"
      echo "        addresses: [$joined]"
    else
      echo "        addresses: [8.8.8.8]"
    fi

    # Search domains (optional)
    if [[ -n "$search_csv" ]]; then
      local sd_sp arr2 joined2
      sd_sp="$(echo "$search_csv" | sed 's/,/ /g')"
      read -r -a arr2 <<<"$sd_sp"
      joined2="$(printf ', %s' "${arr2[@]}")"
      joined2="${joined2:2}"
      echo "        search: [$joined2]"
    fi
  } >> "$tmp"

  log INFO "Netplan written for $nic (IP=$ip/${prefix:-24}, GW=${gw:-<none>}, DNS=${dns_csv:-<default>}, SEARCH=${search_csv:-<none>})"
}

# ---------- Site defaults (saved by `image` step) -----------------------------------------
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

# ---------- OS prereqs for RKE2 -----------------------------------------------------------
install_rke2_prereqs() {
  log INFO "Installing RKE2 prerequisites (packages, modules, sysctl, swapoff, iptables-nft)"
  export DEBIAN_FRONTEND=noninteractive

  apt-get update -y
  apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq

  # Ensure iptables alternatives are the nft variants if available
  if update-alternatives --list iptables >/dev/null 2>&1; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft || true
    update-alternatives --set arptables /usr/sbin/arptables-nft || true
    update-alternatives --set ebtables  /usr/sbin/ebtables-nft  || true
  fi

  # Load required kernel modules
  cat >/etc/modules-load.d/rke2.conf <<EOF
br_netfilter
overlay
EOF
  modprobe br_netfilter || true
  modprobe overlay || true

  # Kubernetes sysctls
  cat >/etc/sysctl.d/90-rke2.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true

  # Disable swap (recommended by Kubernetes)
  sed -i.bak '/\sswap\s/s/^/#/g' /etc/fstab || true
  swapoff -a || true
}

verify_prereqs() {
  # Perform a series of checks. Returns 0 if all green, 1 otherwise.
  local ok=1
  log INFO "Verifying prerequisites and environment..."

  for m in br_netfilter overlay; do
    if lsmod | grep -q "^${m}"; then
      log INFO "Module present: $m"
    else
      log ERROR "Module missing: $m"
      ok=0
    fi
  done

  [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 0)" == "1" ]] || { log ERROR "sysctl bridge-nf-call-iptables != 1"; ok=0; }
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]]           || { log ERROR "sysctl ip_forward != 1"; ok=0; }

  [[ -z "$(swapon --summary)" ]] && log INFO "Swap is disabled" || { log ERROR "Swap is enabled"; ok=0; }

  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    log INFO "Runtime OK: containerd + nerdctl"
  elif command -v docker &>/dev/null; then
    log WARN "Docker present (fallback)"
  else
    log ERROR "No supported container runtime detected"
    ok=0
  fi

  [[ -f "$SCRIPT_DIR/downloads/$IMAGES_TAR" ]] && log INFO "Found images archive" || log WARN "Images archive missing ($SCRIPT_DIR/downloads)"
  [[ -f "$SCRIPT_DIR/downloads/$RKE2_TARBALL" ]] && log INFO "Found RKE2 tarball" || log WARN "RKE2 tarball missing ($SCRIPT_DIR/downloads)"
  [[ -f "$STAGE_DIR/install.sh" ]] && log INFO "Staged installer present" || log WARN "Staged installer missing ($STAGE_DIR)"
  [[ -f /etc/rancher/rke2/registries.yaml ]] && log INFO "registries.yaml present" || log WARN "registries.yaml missing"
  [[ -f /usr/local/share/ca-certificates/kuberegistry-ca.crt ]] && log INFO "CA installed" || log WARN "CA missing (/usr/local/share/ca-certificates/kuberegistry-ca.crt)"

  return $ok
}

# ---------- Optional SBOM / metadata capture ----------------------------------------------
sanitize_img() { echo "$1" | sed 's#/#_#g; s#:#_#g'; }

gen_inspect_json() {
  # Fallback metadata if syft is not installed
  local img="$1" runtime="$2"
  if [[ "$runtime" == "nerdctl" ]]; then
    nerdctl -n k8s.io inspect "$img" 2>/dev/null || echo "{}"
  else
    docker inspect "$img" 2>/dev/null || echo "{}"
  fi
}

gen_sbom_or_metadata() {
  # If syft exists, create SPDX SBOM. Otherwise save inspect JSON.
  local img="$1" runtime="$2" base
  base="$(sanitize_img "$img")"

  if command -v syft &>/dev/null; then
    syft "$img" -o spdx-json > "$SBOM_DIR/${base}.spdx.json" 2>>"$LOG_FILE" || true
    log INFO "SBOM written: $SBOM_DIR/${base}.spdx.json"
  else
    gen_inspect_json "$img" "$runtime" > "$SBOM_DIR/${base}.inspect.json"
    log INFO "Inspect metadata written: $SBOM_DIR/${base}.inspect.json"
  fi
}

# =========================================================================================
# ACTIONS
# =========================================================================================

action_pull() {
  # Download artifacts from GitHub and preload images into container runtime.
  # YAML (if provided) may define:
  #   spec.rke2Version, spec.registry, spec.registryUsername, spec.registryPassword
  if [[ -n "$CONFIG_FILE" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (pull)."
  fi

  detect_latest_rke2_version

  local BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"

  mkdir -p "$DOWNLOADS_DIR"
  pushd "$DOWNLOADS_DIR" >/dev/null

  ensure_installed curl
  ensure_installed zstd
  ensure_installed ca-certificates

  log INFO "Downloading artifacts (images, tarball, checksums, installer)..."
  curl -Lf "$BASE_URL/$IMAGES_TAR"  -o "$IMAGES_TAR"
  curl -Lf "$BASE_URL/$RKE2_TARBALL" -o "$RKE2_TARBALL"
  curl -Lf "$BASE_URL/$SHA256_FILE"  -o "$SHA256_FILE"
  curl -sfL "https://get.rke2.io"    -o install.sh && chmod +x install.sh

  log INFO "Verifying checksums..."
  grep "$IMAGES_TAR"  "$SHA256_FILE" | sha256sum -c -
  grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c -

  detect_runtime

  if [[ "$RUNTIME" == "docker" ]]; then
    log WARN "Docker runtime detected (containerd not active). Loading via Docker..."
    zstdcat "$IMAGES_TAR" | docker load
  else
    ensure_containerd_and_nerdctl
    log INFO "Pre-loading images into containerd via nerdctl..."
    zstdcat "$IMAGES_TAR" | nerdctl -n k8s.io load
  fi

  popd >/dev/null
  log INFO "pull: completed successfully."
}

action_push() {
  # Tag and push all loaded images to the private registry.
  # Uses REGISTRY/REG_USER/REG_PASS. Requires images to be preloaded (via pull).
  if [[ -n "$CONFIG_FILE" ]]; then
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (push)."
  fi

  detect_runtime
  ensure_installed zstd
  [[ "$RUNTIME" != "docker" ]] && ensure_containerd_and_nerdctl

  local work="$DOWNLOADS_DIR"
  if [[ ! -f "$work/$IMAGES_TAR" ]]; then
    log ERROR "Images archive not found in $work. Run 'pull' first."
    exit 3
  fi

  if [[ "$RUNTIME" == "docker" ]]; then
    zstdcat "$work/$IMAGES_TAR" | docker load
  else
    zstdcat "$work/$IMAGES_TAR" | nerdctl -n k8s.io load
  fi

  # List unique images
  local -a imgs
  if [[ "$RUNTIME" == "docker" ]]; then
    mapfile -t imgs < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
  else
    mapfile -t imgs < <(nerdctl -n k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
  fi

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
    if [[ -n "$REG_NS" ]]; then
      TARGET="$REG_HOST/$REG_NS/$IMG"
    else
      TARGET="$REG_HOST/$IMG"
    fi

    [[ $first -eq 0 ]] && echo "," >> "$manifest_json"
    printf '  {"source":"%s","target":"%s"}' "$IMG" "$TARGET" >> "$manifest_json"
    first=0
    echo "$IMG  ->  $TARGET" >> "$manifest_txt"

    gen_sbom_or_metadata "$IMG" "$RUNTIME"
  done

  echo ""  >> "$manifest_json"
  echo "]" >> "$manifest_json"
  log INFO "Pre-push manifest written to:"
  log INFO "  - $manifest_txt"
  log INFO "  - $manifest_json"

  if [[ "$DRY_PUSH" -eq 1 ]]; then
    log WARN "--dry-push set; skipping actual registry pushes."
    return 0
  fi

  # Authenticate and push
  if [[ "$RUNTIME" == "docker" ]]; then
    ensure_installed docker.io
    systemctl enable --now docker
    echo "$REG_PASS" | docker login "$REG_HOST" --username "$REG_USER" --password-stdin 2>>"$LOG_FILE" || {
      log ERROR "Registry login failed"
      exit 4
    }
    for IMG in "${imgs[@]}"; do
      [[ -z "$IMG" ]] && continue
      local TARGET
      if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
      log INFO "Tag & push: $IMG -> $TARGET"
      docker tag "$IMG" "$TARGET"
      docker push "$TARGET"
    done
    docker logout "$REG_HOST" || true
  else
    nerdctl login "$REG_HOST" -u "$REG_USER" -p "$REG_PASS" >/dev/null 2>>"$LOG_FILE" || {
      log ERROR "Registry login failed"
      exit 4
    }
    for IMG in "${imgs[@]}"; do
      [[ -z "$IMG" ]] && continue
      local TARGET
      if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
      log INFO "Tag & push: $IMG -> $TARGET"
      nerdctl -n k8s.io tag "$IMG" "$TARGET"
      nerdctl -n k8s.io push "$TARGET"
    done
    nerdctl logout "$REG_HOST" || true
  fi

  log INFO "push: completed successfully."
}

action_image() {
  # Prepare the offline image (OS prereqs, CA, registries.yaml, artifacts staged).
  # YAML (if provided) may define defaults for DNS/search and registry credentials.
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
  install_containerd_pkg
  install_nerdctl_latest

  # CA certificate required for private registry TLS
  if [[ ! -f "$SCRIPT_DIR/certs/kuberegistry-ca.crt" ]]; then
    log ERROR "Missing $SCRIPT_DIR/certs/kuberegistry-ca.crt"
    exit 3
  fi
  cp "$SCRIPT_DIR/certs/kuberegistry-ca.crt" /usr/local/share/ca-certificates/kuberegistry-ca.crt
  update-ca-certificates

  # Stage artifacts if present
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

  # rke2 config and registries
  mkdir -p /etc/rancher/rke2/
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

  # Optional: disable IPv6 if desired by your environment
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  log INFO "IPv6 disabled via sysctl (99-disable-ipv6.conf)."

  # Save site defaults for later (server/agent prompts)
  local STATE="/etc/rke2image.defaults"
  {
    echo "DEFAULT_DNS=\"$defaultDnsCsv\""
    echo "DEFAULT_SEARCH=\"$defaultSearchCsv\""
  } > "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved site defaults: DNS=[$defaultDnsCsv], SEARCH=[$defaultSearchCsv]"

  # Optional: bring OS current and reboot (good idea for golden images)
  log INFO "Applying OS updates; the system will reboot automatically..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y
  apt-get autoremove -y || true
  apt-get autoclean -y  || true
  log WARN "Rebooting now to complete updates."
  sleep 2
  reboot
}

action_server() {
  # Configure a node as an RKE2 server (control-plane)
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""

  # Pull values from YAML if present, else prompt
  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
  fi

  [[ -n "$IP"      ]] || read -rp "Enter static IPv4 for this server node: " IP
  [[ -n "$PREFIX"  ]] || read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX
  [[ -n "$HOSTNAME"]] || read -rp "Enter hostname for this server node: " HOSTNAME

  if [[ -z "${GW:-}" ]]; then
    read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true
  fi
  log INFO "Gateway entered (server): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS" && log INFO "Using default DNS for server: $DNS"
  fi

  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$SEARCH" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for server: $SEARCH"
  fi

  # Validation loops
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # Ensure installer is staged (prefer /opt/rke2/stage, fall back to ./downloads)
  local SRC="$STAGE_DIR"
  [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$DOWNLOADS_DIR"
  [[ -f "$SRC/install.sh" ]] || { log ERROR "Missing install.sh. Run 'pull' then 'image' first."; exit 3; }

  log INFO "Proceeding with offline RKE2 server install..."
  pushd "$SRC" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$SRC" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null

  systemctl enable rke2-server

  hostnamectl set-hostname "$HOSTNAME"
  grep -q "$HOSTNAME" /etc/hosts || echo "$IP $HOSTNAME" >> /etc/hosts

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
  echo "A reboot is required to apply network changes."

  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes enabled: rebooting now."
    reboot
  fi

  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    log INFO "Rebooting..."
    reboot
  else
    log WARN "Reboot deferred. Please reboot before using this node."
  fi
}

action_agent() {
  # Configure a node as an RKE2 agent (worker)
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW="" URL="" TOKEN=""

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d sd
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"
    TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
  fi

  [[ -n "$IP"      ]] || read -rp "Enter static IPv4 for this agent node: " IP
  [[ -n "$PREFIX"  ]] || read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX
  [[ -n "$HOSTNAME"]] || read -rp "Enter hostname for this agent node: " HOSTNAME

  if [[ -z "${GW:-}" ]]; then
    read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true
  fi
  log INFO "Gateway entered (agent): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS" && log INFO "Using default DNS for agent: $DNS"
  fi

  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$SEARCH" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for agent: $SEARCH"
  fi

  if [[ -z "${URL:-}" ]]; then
    read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " URL || true
  fi
  if [[ -n "$URL" && -z "${TOKEN:-}" ]]; then
    read -rp "Enter cluster join token [optional]: " TOKEN || true
  fi

  # Validation loops
  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # Ensure installer is staged
  local SRC="$STAGE_DIR"
  [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$DOWNLOADS_DIR"
  [[ -f "$SRC/install.sh" ]] || { log ERROR "Missing install.sh. Run 'pull' then 'image' first."; exit 3; }

  log INFO "Proceeding with offline RKE2 agent install..."
  pushd "$SRC" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$SRC" INSTALL_RKE2_TYPE="agent" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null

  systemctl enable rke2-agent

  # Append server URL/token to RKE2 config if provided
  mkdir -p /etc/rancher/rke2
  if [[ -n "${URL:-}" ]]; then echo "server: \"$URL\"" >> /etc/rancher/rke2/config.yaml; fi
  if [[ -n "${TOKEN:-}" ]]; then echo "token: \"$TOKEN\""   >> /etc/rancher/rke2/config.yaml; fi

  hostnamectl set-hostname "$HOSTNAME"
  grep -q "$HOSTNAME" /etc/hosts || echo "$IP $HOSTNAME" >> /etc/hosts

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
  echo "A reboot is required to apply network changes."

  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes enabled: rebooting now."
    reboot
  fi

  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    log INFO "Rebooting..."
    reboot
  else
    log WARN "Reboot deferred. Please reboot before using this node."
  fi
}

action_verify() {
  if verify_prereqs; then
    log INFO "VERIFY PASSED: Node meets RKE2 prerequisites."
    exit 0
  else
    log ERROR "VERIFY FAILED: See messages above and fix issues."
    exit 2
  fi
}

# =========================================================================================
# ARGUMENT PARSING
# =========================================================================================

# Pre-scan to catch the lone --dry-push flag early (so getopts doesn't choke)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-push) DRY_PUSH=1; shift;;
    -f|-v|-r|-u|-p|-y|-P|-h|pull|push|image|server|agent|verify) break;;
    *) break;;
  esac
done

# getopts for short flags
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

# If the remaining argument is a file, treat it as -f FILE
CLI_SUB="${1:-}"
if [[ -z "$CONFIG_FILE" && -n "$CLI_SUB" && -f "$CLI_SUB" ]]; then
  CONFIG_FILE="$CLI_SUB"
  CLI_SUB=""
fi

# If a YAML file is provided, validate and optionally print a sanitized view
YAML_KIND=""
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "YAML file not found: $CONFIG_FILE"
    exit 5
  fi
  API="$(yaml_get_api "$CONFIG_FILE" || true)"
  YAML_KIND="$(yaml_get_kind "$CONFIG_FILE" || true)"

  if [[ "$API" != "rkeprep/v1" ]]; then
    log ERROR "Unsupported apiVersion: '$API' (expected rkeprep/v1)"
    exit 5
  fi

  if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    echo "----- Sanitized YAML -----"
    sanitize_yaml "$CONFIG_FILE"
    echo "--------------------------"
  fi
fi

# =========================================================================================
# ROUTER
# =========================================================================================

ACTION="${CLI_SUB:-}"

# If a YAML was provided without a CLI action, infer from kind:
if [[ -n "$CONFIG_FILE" && -z "$CLI_SUB" ]]; then
  case "$YAML_KIND" in
    Pull|pull)   ACTION="pull"   ;;
    Push|push)   ACTION="push"   ;;
    Image|image) ACTION="image"  ;;
    Server|server) ACTION="server";;
    Agent|agent) ACTION="agent"  ;;
    *) log ERROR "Unsupported or missing YAML kind: '${YAML_KIND:-<none>}'"; exit 5;;
  esac
fi

# Dispatch
case "${ACTION:-}" in
  pull)   action_pull   ;;
  push)   action_push   ;;
  image)  action_image  ;;
  server) action_server ;;
  agent)  action_agent  ;;
  verify) action_verify ;;
  *) print_help; exit 1 ;;
esac
