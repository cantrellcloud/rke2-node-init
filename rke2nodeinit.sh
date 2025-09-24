#!/usr/bin/env bash
# =============================================================================
# rke2nodeinit.sh — RKE2 Node Image Init for Air‑Gapped Clusters (Ubuntu 24.04)
# =============================================================================
# Purpose
#   Prepare a single golden VM image that can act as either an RKE2 server or
#   agent across multiple air-gapped data centers. The script supports pulling
#   artifacts online, pushing them to an offline registry, preparing the base
#   image (prereqs + staging + updates), interactive server/agent bring-up, and
#   a verify mode to check prerequisites.
#
# Subcommands
#   pull    : Download RKE2 artifacts (images, tarball, install.sh) and LOAD
#             images into local container runtime cache (containerd preferred).
#   push    : Re-tag and PUSH all cached images to your offline registry and
#             write a manifest + SBOMs (SPDX via syft if available, else inspect).
#   image   : Install RKE2 prerequisites, trust registry CA, stage artifacts,
#             disable IPv6, apply OS updates, then auto‑reboot.
#   server  : Configure this VM as an RKE2 server (static IP, hostname, DNS,
#             optional single gateway, search domains), enable rke2-server.
#   agent   : Configure this VM as an RKE2 agent (same networking), enable rke2-agent,
#             optional cluster join settings (server URL + token).
#   verify  : Validate modules, sysctls, swap state, runtime presence, artifacts,
#             and registry/CA configuration.
#
# Features
#   - containerd+nerdctl preferred; use Docker only if containerd not present.
#   - YAML auto-kind mode: when -f/--file is used, the "kind:" in the YAML
#     decides which subcommand runs (no subcommand needed on CLI).
#   - RFC 5424-style logging to ./logs and to console; rotate after 60d.
#   - Safe prompts and clear messaging for entry‑level admins.
#
# Important
#   - Run this script as root (sudo). It touches /etc, installs packages, etc.
#   - Place your offline registry CA at ./certs/kuberegistry-ca.crt before use.
#
# =============================================================================

set -Eeuo pipefail

# ---------- Paths (absolute) and logging setup --------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
LOG_DIR="$SCRIPT_DIR/logs"
OUT_DIR="$SCRIPT_DIR/outputs"
SBOM_DIR="$OUT_DIR/sbom"
mkdir -p "$LOG_DIR" "$OUT_DIR" "$SBOM_DIR"

# Log file – RFC 5424-ish format, one per run
LOG_FILE="$LOG_DIR/rke2nodeinit_$(date -u +"%Y-%m-%dT%H-%M-%SZ").log"

# log LEVEL MESSAGE...
log() {
  local level="$1"; shift
  local msg="$*"
  local ts; ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  local host; host="$(hostname)"
  # Console (human-friendly)
  echo "[$level] $msg"
  # File (parse-friendly)
  printf "%s %s rke2nodeinit[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
}

# Compress/rotate log files older than 60 days
find "$LOG_DIR" -type f -name "rke2nodeinit_*.log" -mtime +60 -exec gzip -q {} \; -exec mv {}.gz "$LOG_DIR" \; || true

# ---------- Root check --------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this script as root (sudo)."
  exit 1
fi

# ---------- Defaults (changeable via YAML or flags) ---------------------------
RKE2_VERSION=""                         # Auto-detected if omitted
REGISTRY="kuberegistry.dev.kube/rke2"   # Default offline registry
REG_USER="admin"                        # Default registry username
REG_PASS="ZAQwsx!@#123"                 # Default registry password
CONFIG_FILE=""                          # -f path
ARCH="amd64"                            # Architecture (linux-amd64 artifacts)
DEFAULT_DNS="10.0.1.34,10.231.1.34"     # Default DNSs for server/agent prompts
AUTO_YES=0                              # -y: auto-confirm reboots
PRINT_CONFIG=0                          # -P: print sanitized YAML
DRY_PUSH=0                              # --dry-push: report/SBOM only

# ---------- Help text ---------------------------------------------------------
print_help() {
cat <<'EOF'
Usage:
  sudo ./rke2nodeinit.sh -f file.yaml [options]        # Auto-kind from YAML
  sudo ./rke2nodeinit.sh [options] <pull|push|image|server|agent|verify>

Options:
  -f <file>   YAML manifest (apiVersion: rkeprep/v1; kind: Pull|Push|Image|Server|Agent)
  -v <ver>    RKE2 version (auto-detect if omitted)
  -r <host>   Offline registry (e.g., kuberegistry.dev.kube/rke2)
  -u <user>   Offline registry username
  -p <pass>   Offline registry password
  -y          Auto-yes reboot on server/agent (no interactive prompt)
  -P          Print sanitized YAML (secrets masked)
  --dry-push  Generate manifest + SBOMs but DO NOT push images
  -h          Help

Notes:
  • If -f/--file is supplied, YAML values override conflicting CLI flags.
  • If -f/--file is supplied, you do NOT need to pass a subcommand.
EOF
}

# ---------- Parse --dry-push before getopts -----------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-push) DRY_PUSH=1; shift;;
    -f|-v|-r|-u|-p|-y|-P|-h|pull|push|image|server|agent|verify) break;;
    *) break;;
  esac
done

# ---------- Parse short flags -------------------------------------------------
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

# ---------- Lightweight YAML helpers -----------------------------------------
# NOTE: We avoid requiring yq; these functions are tailored for our simple schema.
yaml_get_kind(){ grep -E '^[[:space:]]*kind:[[:space:]]*' "$1" | awk -F: '{print $2}' | xargs; }
yaml_get_api(){  grep -E '^[[:space:]]*apiVersion:[[:space:]]*' "$1" | awk -F: '{print $2}' | xargs; }
yaml_spec_get(){
  # Extract a single spec.<key>: <value> line value (scalar or inline list)
  local file="$1" key="$2"
  awk -v k="$key" '
    BEGIN{inSpec=0}
    /^[[:space:]]*spec:[[:space:]]*$/ {inSpec=1; next}
    inSpec==1 {
      if ($0 ~ /^[^[:space:]]/) { exit }           # spec block ended
      if ($0 ~ "^[[:space:]]+"k"[[:space:]]*:") {   # found key
        sub(/^[[:space:]]+/, "", $0)               # trim left
        sub(k"[[:space:]]*:[[:space:]]*", "", $0)  # drop "key:"
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        print $0
        exit
      }
    }
  ' "$file"
}
normalize_list_csv(){
  # Convert inline YAML list like ["a","b"] to CSV "a, b"
  local v="$1"
  v="${v#[}"; v="${v%]}"
  v="${v//\"/}"; v="${v//\'/}"
  echo "$v" | sed 's/,/ /g' | xargs | sed 's/ /, /g'
}
sanitize_yaml(){
  # Mask passwords/tokens when printing (-P)
  sed -E \
    -e 's/(registryPassword:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(registryPassword:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    -e 's/(token:[[:space:]]*)"[^"]*"/\1"********"/' \
    -e 's/(token:[[:space:]]*)([^"[:space:]].*)/\1"********"/' \
    "$1"
}

# ---------- Validate YAML (if provided) --------------------------------------
YAML_KIND=""
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log ERROR "YAML not found: $CONFIG_FILE"
    exit 1
  fi
  API="$(yaml_get_api "$CONFIG_FILE" || true)"
  YAML_KIND="$(yaml_get_kind "$CONFIG_FILE" || true)"
  if [[ "$API" != "rkeprep/v1" ]]; then
    log ERROR "apiVersion must be rkeprep/v1"
    exit 1
  fi
  if [[ "$PRINT_CONFIG" -eq 1 ]]; then
    echo "----- Sanitized YAML -----"
    sanitize_yaml "$CONFIG_FILE"
    echo "--------------------------"
  fi
fi

# ---------- Small validators --------------------------------------------------
ensure_installed(){ dpkg -s "$1" &>/dev/null || { log INFO "Installing $1"; apt-get update -y && apt-get install -y "$1"; }; }
valid_ipv4(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS='.' read -r a b c d <<<"$1"; for n in "$a" "$b" "$c" "$d"; do [[ "$n" -ge 0 && "$n" -le 255 ]] || return 1; done; }
valid_prefix(){ [[ -z "$1" ]] && return 0; [[ "$1" =~ ^[0-9]{1,2}$ ]] && (( $1>=0 && $1<=32 )); }
valid_ipv4_or_blank(){ [[ -z "$1" ]] && return 0; valid_ipv4 "$1"; }
valid_csv_dns(){ [[ -z "$1" ]] && return 0; local s="$(echo "$1" | sed 's/,/ /g')"; for x in $s; do valid_ipv4 "$x" || return 1; done; }
valid_search_domains_csv(){ [[ -z "$1" ]] && return 0; local s="$(echo "$1" | sed 's/,/ /g')"; for d in $s; do [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1; done; }

# ---------- Container runtime detection --------------------------------------
RUNTIME=""                               # nerdctl or docker
IMAGES_TAR="rke2-images.linux-$ARCH.tar.zst"
RKE2_TARBALL="rke2.linux-$ARCH.tar.gz"
SHA256_FILE="sha256sum-$ARCH.txt"

ensure_containerd(){
  # Install containerd + nerdctl and enable service
  ensure_installed containerd
  ensure_installed nerdctl
  systemctl enable --now containerd
  RUNTIME="nerdctl"
}
detect_runtime(){
  # containerd+nerdctl preferred; Docker only if containerd not running
  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    RUNTIME="nerdctl"
  elif command -v containerd &>/dev/null; then
    ensure_installed nerdctl
    systemctl enable --now containerd
    RUNTIME="nerdctl"
  elif command -v docker &>/dev/null; then
    RUNTIME="docker"
  else
    log WARN "No container runtime detected; installing containerd+nerdctl ..."
    ensure_containerd()
    {
      ensure_installed containerd
      ensure_installed nerdctl
      systemctl enable --now containerd
      RUNTIME="nerdctl"
    }
    ensure_containerd
  fi
}

# ---------- RKE2 version resolution ------------------------------------------
detect_latest_version(){
  # Auto-detect latest RKE2 tag from GitHub if not provided via YAML/flag
  if [[ -z "${RKE2_VERSION:-}" ]]; then
    log INFO "Detecting latest RKE2 version from GitHub releases ..."
    ensure_installed curl
    LATEST_JSON=$(curl -s https://api.github.com/repos/rancher/rke2/releases/latest || true)
    RKE2_VERSION="$(echo "$LATEST_JSON" | grep -Po '"tag_name": "\K[^"]+' || true)"
    if [[ -z "$RKE2_VERSION" ]]; then
      log ERROR "Failed to detect latest RKE2 version"
      exit 1
    fi
    log INFO "Using RKE2 version: $RKE2_VERSION"
  fi
}

# ---------- Netplan writer (static IP, single gateway, multi-DNS) ------------
write_netplan(){
  local ip="$1" prefix="$2" gw="$3" dns_csv="$4" search_csv="$5"
  # Pick primary NIC (default route) or the first non-lo
  local nic; nic="$(ip -o -4 route show to default | awk '{print $5}' || true)"
  [[ -z "$nic" ]] && nic="$(ls /sys/class/net | grep -v lo | head -n1)"

  # Search domains (optional)
  local search_line=""
  if [[ -n "$search_csv" ]]; then
    local csv="$(echo "$search_csv" | sed 's/,/ /g')"
    local arr=($csv)
    local joined="$(printf ', %s' "${arr[@]}")"; joined="${joined:2}"
    search_line="      search: [${joined}]"
  fi

  # DNS list (multi)
  local dns_line="addresses: [${dns_csv:-8.8.8.8}]"
  if [[ -n "$dns_csv" ]]; then
    local dns_csv_sp="$(echo "$dns_csv" | sed 's/,/ /g')"
    local d_arr=($dns_csv_sp)
    local d_join="$(printf ', %s' "${d_arr[@]}")"; d_join="${d_join:2}"
    dns_line="addresses: [${d_join}]"
  fi

  # Write /etc/netplan/99-rke-static.yaml
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

# ---------- Persist defaults from 'image' step for later prompts -------------
load_site_defaults(){
  local STATE="/etc/rke2image.defaults"
  if [[ -f "$STATE" ]]; then
    # shellcheck disable=SC1090
    . "$STATE"
    [[ -n "${DEFAULT_DNS:-}" ]] && DEFAULT_DNS="$DEFAULT_DNS"
    DEFAULT_SEARCH="${DEFAULT_SEARCH:-}"
  else
    DEFAULT_SEARCH=""
  fi
}

# ---------- RKE2 prerequisites installer -------------------------------------
install_rke2_prereqs(){
  log INFO "Installing RKE2 prerequisites (packages, kernel modules, sysctl, swapoff, iptables-nft)"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq
  # Prefer nftables-backed iptables
  if update-alternatives --list iptables >/dev/null 2>&1; then
    update-alternatives --set iptables /usr/sbin/iptables-nft || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft || true
    update-alternatives --set arptables /usr/sbin/arptables-nft || true
    update-alternatives --set ebtables /usr/sbin/ebtables-nft || true
  fi
  # Required kernel modules
  cat >/etc/modules-load.d/rke2.conf <<EOF
br_netfilter
overlay
EOF
  modprobe br_netfilter || true
  modprobe overlay || true
  # Sysctl requirements
  cat >/etc/sysctl.d/90-rke2.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  # Disable swap
  sed -i.bak '/\sswap\s/s/^/#/g' /etc/fstab || true
  swapoff -a || true
}

# ---------- Verify prerequisites & environment -------------------------------
verify_prereqs(){
  local ok=1
  log INFO "Verifying RKE2 prerequisites and environment ..."
  # Modules
  for m in br_netfilter overlay; do
    if lsmod | grep -q "^${m}"; then log INFO "Module present: $m"; else log ERROR "Module missing: $m"; ok=0; fi
  done
  # Sysctl
  [[ "$(sysctl -n net.bridge.bridge-nf-call-iptables 2>/dev/null || echo 0)" == "1" ]] || { log ERROR "sysctl net.bridge.bridge-nf-call-iptables != 1"; ok=0; }
  [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]] || { log ERROR "sysctl net.ipv4.ip_forward != 1"; ok=0; }
  # Swap
  if [[ -z "$(swapon --summary)" ]]; then log INFO "Swap is disabled"; else log ERROR "Swap is enabled"; ok=0; fi
  # Runtime
  if command -v nerdctl &>/dev/null && systemctl is-active --quiet containerd; then
    log INFO "Runtime OK: containerd+nerdctl"
  else
    if command -v docker &>/dev/null; then
      log WARN "Docker present (acceptable if containerd absent)"
    else
      log ERROR "No supported container runtime detected"
      ok=0
    fi
  fi
  # Artifacts
  [[ -f "$SCRIPT_DIR/downloads/$IMAGES_TAR" ]] && log INFO "Found images tar: downloads/$IMAGES_TAR" || log WARN "Missing images tar in downloads"
  [[ -f "$SCRIPT_DIR/downloads/$RKE2_TARBALL" ]] && log INFO "Found RKE2 tarball" || log WARN "Missing RKE2 tarball in downloads"
  [[ -f "/opt/rke2/stage/install.sh" ]] && log INFO "Staged installer present" || log WARN "Staged installer missing"
  # Registry config & CA trust
  [[ -f /etc/rancher/rke2/registries.yaml ]] && log INFO "registries.yaml present" || log WARN "registries.yaml missing"
  [[ -f /usr/local/share/ca-certificates/kuberegistry-ca.crt ]] && log INFO "CA installed" || log WARN "CA missing (/usr/local/share/ca-certificates/kuberegistry-ca.crt)"
  return $ok
}

# ---------- SBOM helpers -----------------------------------------------------
sanitize_img(){ echo "$1" | sed 's#/#_#g; s#:#_#g'; }
gen_inspect_json(){
  local img="$1" runtime="$2"
  if [[ "$runtime" == "nerdctl" ]]; then
    nerdctl -n k8s.io inspect "$img" 2>/dev/null || echo "{}"
  else
    docker inspect "$img" 2>/dev/null || echo "{}"
  fi
}
gen_sbom_or_metadata(){
  local img="$1" runtime="$2"
  local base="$(sanitize_img "$img")"
  if command -v syft &>/dev/null; then
    syft "$img" -o spdx-json > "$SBOM_DIR/${base}.spdx.json" 2>>"$LOG_FILE" || true
    log INFO "SBOM (SPDX) written: $SBOM_DIR/${base}.spdx.json"
  else
    gen_inspect_json "$img" "$runtime" > "$SBOM_DIR/${base}.inspect.json"
    log INFO "SBOM fallback (inspect) written: $SBOM_DIR/${base}.inspect.json"
  fi
}

# ============================================================================
# SUBCOMMANDS
# ============================================================================

# ----- pull ------------------------------------------------------------------
sub_pull(){
  # Load YAML overrides
  if [[ -n "$CONFIG_FILE" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; conflicting CLI flags are overridden."
  fi

  # Resolve version (auto-detects if empty)
  detect_latest_version

  # Build release URLs (note: + must be encoded)
  local BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
  local WORK_DIR="$SCRIPT_DIR/downloads"; mkdir -p "$WORK_DIR"

  ensure_installed curl; ensure_installed zstd; ensure_installed ca-certificates

  pushd "$WORK_DIR" >/dev/null
  log INFO "Downloading RKE2 images archive ..."
  curl -Lf "$BASE_URL/$IMAGES_TAR" -o "$IMAGES_TAR"
  log INFO "Downloading RKE2 tarball ..."
  curl -Lf "$BASE_URL/$RKE2_TARBALL" -o "$RKE2_TARBALL"
  log INFO "Downloading checksum file ..."
  curl -Lf "$BASE_URL/$SHA256_FILE" -o "$SHA256_FILE"

  log INFO "Verifying checksums ..."
  grep "$IMAGES_TAR" "$SHA256_FILE" | sha256sum -c -
  grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c -

  log INFO "Fetching installer script (install.sh) ..."
  curl -sfL "https://get.rke2.io" -o install.sh && chmod +x install.sh

  # Load images into local runtime cache (so this VM has all images locally)
  detect_runtime; log INFO "Using runtime to pre-load images: $RUNTIME"
  if [[ "$RUNTIME" == "nerdctl" ]]; then
    zstdcat "$IMAGES_TAR" | nerdctl -n k8s.io load
  else
    zstdcat "$IMAGES_TAR" | docker load
  fi

  log INFO "pull: artifacts downloaded and images loaded into local runtime (cached)."
  popd >/dev/null
}

# ----- push ------------------------------------------------------------------
sub_push(){
  # Load YAML overrides
  if [[ -n "$CONFIG_FILE" ]]; then
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; conflicting CLI flags are overridden."
  fi

  detect_runtime; log INFO "Using runtime: $RUNTIME"; ensure_installed zstd

  local WORK_DIR="$SCRIPT_DIR/downloads"
  if [[ ! -f "$WORK_DIR/$IMAGES_TAR" ]]; then
    log ERROR "Images archive not found in downloads. Run 'pull' first."
    exit 1
  fi

  # Split registry into host + optional namespace path
  local REG_HOST="$REGISTRY"
  local REG_NS=""
  if [[ "$REGISTRY" == *"/"* ]]; then
    REG_HOST="${REGISTRY%%/*}"
    REG_NS="${REGISTRY#*/}"
  fi

  # Ensure images are present locally (safe to re-load from archive)
  if [[ "$RUNTIME" == "nerdctl" ]]; then
    zstdcat "$WORK_DIR/$IMAGES_TAR" | nerdctl -n k8s.io load
  else
    zstdcat "$WORK_DIR/$IMAGES_TAR" | docker load
  fi

  # Build a list of images, write manifest, and generate SBOMs
  local -a imgs
  if [[ "$RUNTIME" == "nerdctl" ]]; then
    mapfile -t imgs < <(nerdctl -n k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
  else
    mapfile -t imgs < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
  fi

  local manifest_json="$OUT_DIR/images-manifest.json"
  local manifest_txt="$OUT_DIR/images-manifest.txt"
  : > "$manifest_txt"; echo "[" > "$manifest_json"
  local first=1
  for IMG in "${imgs[@]}"; do
    [[ -z "$IMG" ]] && continue
    if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
    [[ $first -eq 0 ]] && echo "," >> "$manifest_json"
    printf '  {"source":"%s","target":"%s"}' "$IMG" "$TARGET" >> "$manifest_json"
    first=0
    echo "$IMG  ->  $TARGET" >> "$manifest_txt"
    gen_sbom_or_metadata "$IMG" "$RUNTIME"
  done
  echo "" >> "$manifest_json"; echo "]" >> "$manifest_json"
  log INFO "Pre-push manifest written: $manifest_txt and $manifest_json"

  # If dry run, stop here
  [[ "$DRY_PUSH" -eq 1 ]] && { log WARN "--dry-push set; skipping push."; return 0; }

  # Login & push all
  if [[ "$RUNTIME" == "nerdctl" ]]; then
    nerdctl login "$REG_HOST" -u "$REG_USER" -p "$REG_PASS" >/dev/null 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; }
    for IMG in "${imgs[@]}"; do
      [[ -z "$IMG" ]] && continue
      if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
      log INFO "Tag & push: $IMG -> $TARGET"
      nerdctl -n k8s.io tag "$IMG" "$TARGET"
      nerdctl -n k8s.io push "$TARGET"
    done
    nerdctl logout "$REG_HOST" || true
  else
    ensure_installed docker.io; systemctl enable --now docker
    echo "$REG_PASS" | docker login "$REG_HOST" --username "$REG_USER" --password-stdin 2>>"$LOG_FILE" || { log ERROR "Registry login failed"; exit 1; }
    for IMG in "${imgs[@]}"; do
      [[ -z "$IMG" ]] && continue
      if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
      log INFO "Tag & push: $IMG -> $TARGET"
      docker tag "$IMG" "$TARGET"
      docker push "$TARGET"
    done
    docker logout "$REG_HOST" || true
  fi

  log INFO "push: images retagged and pushed to $REGISTRY. Reports in $OUT_DIR; SBOMs in $SBOM_DIR."
}

# ----- image -----------------------------------------------------------------
sub_image(){
  # Collect defaults from YAML, if provided
  local WORK_DIR="$SCRIPT_DIR/downloads"
  local REG_HOST="${REGISTRY%%/*}"
  local defaultDnsCsv="$DEFAULT_DNS"
  local defaultSearchCsv=""
  local STAGE_DIR="/opt/rke2/stage"
  mkdir -p "$STAGE_DIR"

  if [[ -n "$CONFIG_FILE" ]]; then
    local D1; D1="$(yaml_spec_get "$CONFIG_FILE" defaultDns || true)"; [[ -n "$D1" ]] && defaultDnsCsv="$(normalize_list_csv "$D1")"
    local S1; S1="$(yaml_spec_get "$CONFIG_FILE" defaultSearchDomains || true)"; [[ -n "$S1" ]] && defaultSearchCsv="$(normalize_list_csv "$S1")"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    REG_HOST="${REGISTRY%%/*}"
    log WARN "Using YAML values; conflicting CLI flags are overridden."
  fi

  # Install RKE2 prerequisites (packages, kernel modules, sysctl, swapoff)
  install_rke2_prereqs

  # Trust offline registry CA
  if [[ ! -f "$SCRIPT_DIR/certs/kuberegistry-ca.crt" ]]; then
    log ERROR "Missing certs/kuberegistry-ca.crt"
    exit 1
  fi
  cp "$SCRIPT_DIR/certs/kuberegistry-ca.crt" /usr/local/share/ca-certificates/kuberegistry-ca.crt
  update-ca-certificates

  # Stage artifacts for fully offline install later
  mkdir -p /var/lib/rancher/rke2/agent/images/
  if [[ -f "$WORK_DIR/$IMAGES_TAR" ]]; then
    cp "$WORK_DIR/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/
    log INFO "Copied images archive to /var/lib/rancher/rke2/agent/images/"
  else
    log WARN "Images tar not found in $WORK_DIR; run 'pull' first."
  fi
  if [[ -f "$WORK_DIR/$RKE2_TARBALL" ]]; then
    cp "$WORK_DIR/$RKE2_TARBALL" "$STAGE_DIR/"
    log INFO "Staged $RKE2_TARBALL to $STAGE_DIR"
  else
    log WARN "RKE2 tarball not found in $WORK_DIR; run 'pull' first."
  fi
  if [[ -f "$WORK_DIR/install.sh" ]]; then
    cp "$WORK_DIR/install.sh" "$STAGE_DIR/" && chmod +x "$STAGE_DIR/install.sh"
    log INFO "Staged install.sh to $STAGE_DIR"
  else
    log WARN "install.sh not found in $WORK_DIR; run 'pull' first."
  fi

  # RKE2 registry config for air-gap (system-default-registry + auth + CA)
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

  # Disable IPv6 (per requirement)
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  log INFO "IPv6 disabled via sysctl."

  # Persist defaults used by server/agent prompts
  STATE="/etc/rke2image.defaults"
  echo "DEFAULT_DNS=\"$defaultDnsCsv\"" > "$STATE"
  echo "DEFAULT_SEARCH=\"$defaultSearchCsv\"" >> "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved site defaults: DNS=[$defaultDnsCsv] SEARCH=[$defaultSearchCsv]"

  # Apply OS security updates and reboot to finish
  log INFO "Applying all current updates and patches (apt-get update && dist-upgrade) ..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y
  apt-get autoremove -y || true
  apt-get autoclean -y || true
  log WARN "System will reboot automatically to complete updates."
  sleep 2
  reboot
}

# ----- server ----------------------------------------------------------------
sub_server(){
  load_site_defaults
  local S_IP="" S_PREFIX="" S_HOST="" S_DNS="" S_SEARCH="" S_GW=""

  # YAML overrides first
  if [[ -n "$CONFIG_FILE" ]]; then
    S_IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    S_PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    S_HOST="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d; d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && S_DNS="$(normalize_list_csv "$d")"
    local sd; sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && S_SEARCH="$(normalize_list_csv "$sd")"
  fi

  # Prompt for any missing values
  [[ -n "$S_IP" ]]     || read -rp "Enter static IP for this server node: " S_IP
  [[ -n "$S_PREFIX" ]] || read -rp "Enter subnet prefix length (0-32) [default 24]: " S_PREFIX
  [[ -n "$S_HOST" ]]   || read -rp "Enter hostname for this server node: " S_HOST
  read -rp "Enter default gateway IP [leave blank to skip]: " S_GW || true
  if [[ -z "$S_DNS" ]]; then
    read -rp "Enter DNS IP(s) (comma-separated) [blank=default ${DEFAULT_DNS}]: " S_DNS || true
    [[ -z "$S_DNS" ]] && S_DNS="$DEFAULT_DNS" && log INFO "Using default DNS for server: $S_DNS"
  fi
  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$S_SEARCH" ]]; then
    S_SEARCH="$DEFAULT_SEARCH"; log INFO "Using default search domains for server: $S_SEARCH"
  fi

  # Validate inputs
  while ! valid_ipv4 "$S_IP"; do read -rp "Invalid IPv4. Re-enter server IP: " S_IP; done
  while ! valid_prefix "${S_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " S_PREFIX; done
  while ! valid_ipv4_or_blank "${S_GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " S_GW; done
  while ! valid_csv_dns "${S_DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " S_DNS; done
  while ! valid_search_domains_csv "${S_SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " S_SEARCH; done
  [[ -z "${S_PREFIX:-}" ]] && S_PREFIX=24

  # Offline install using staged artifacts (fall back to downloads)
  local WORK_DIR="$SCRIPT_DIR/downloads"; local STAGE_DIR="/opt/rke2/stage"
  local SRC="$STAGE_DIR"; [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$WORK_DIR"
  if [[ ! -f "$SRC/install.sh" ]]; then
    log ERROR "Missing install.sh. Run 'pull' then 'image' first."
    exit 1
  fi
  pushd "$SRC" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$SRC" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null

  systemctl enable rke2-server

  # Hostname and /etc/hosts entry
  hostnamectl set-hostname "$S_HOST"
  grep -q "$S_HOST" /etc/hosts || echo "$S_IP $S_HOST" >> /etc/hosts

  # Netplan
  write_netplan "$S_IP" "$S_PREFIX" "${S_GW:-}" "${S_DNS:-}" "${S_SEARCH:-}"

  # Reboot prompt
  echo "A reboot is required to apply network changes."
  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes enabled: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    log INFO "Rebooting ..."; reboot
  else
    log WARN "Reboot deferred. Please reboot before using this node."
  fi
}

# ----- agent -----------------------------------------------------------------
sub_agent(){
  load_site_defaults
  local A_IP="" A_PREFIX="" A_HOST="" A_DNS="" A_SEARCH="" A_GW="" A_URL="" A_TOKEN=""

  # YAML overrides first
  if [[ -n "$CONFIG_FILE" ]]; then
    A_IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    A_PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    A_HOST="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    local d; d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d" ]] && A_DNS="$(normalize_list_csv "$d")"
    local sd; sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && A_SEARCH="$(normalize_list_csv "$sd")"
    A_URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"
    A_TOKEN="$(yaml_spec_get "$CONFIG_FILE" token || true)"
  fi

  # Prompt for any missing values
  [[ -n "$A_IP" ]]     || read -rp "Enter static IP for this agent node: " A_IP
  [[ -n "$A_PREFIX" ]] || read -rp "Enter subnet prefix length (0-32) [default 24]: " A_PREFIX
  [[ -n "$A_HOST" ]]   || read -rp "Enter hostname for this agent node: " A_HOST
  read -rp "Enter default gateway IP [leave blank to skip]: " A_GW || true
  if [[ -z "$A_DNS" ]]; then
    read -rp "Enter DNS IP(s) (comma-separated) [blank=default ${DEFAULT_DNS}]: " A_DNS || true
    [[ -z "$A_DNS" ]] && A_DNS="$DEFAULT_DNS" && log INFO "Using default DNS for agent: $A_DNS"
  fi
  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$A_SEARCH" ]]; then
    A_SEARCH="$DEFAULT_SEARCH"; log INFO "Using default search domains for agent: $A_SEARCH"
  fi
  if [[ -z "${A_URL:-}" ]]; then
    read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " A_URL || true
  fi
  if [[ -n "$A_URL" && -z "${A_TOKEN:-}" ]]; then
    read -rp "Enter cluster join token [optional]: " A_TOKEN || true
  fi

  # Validate inputs
  while ! valid_ipv4 "$A_IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " A_IP; done
  while ! valid_prefix "${A_PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " A_PREFIX; done
  while ! valid_ipv4_or_blank "${A_GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " A_GW; done
  while ! valid_csv_dns "${A_DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " A_DNS; done
  while ! valid_search_domains_csv "${A_SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " A_SEARCH; done
  [[ -z "${A_PREFIX:-}" ]] && A_PREFIX=24

  # Offline install using staged artifacts (fall back to downloads)
  local WORK_DIR="$SCRIPT_DIR/downloads"; local STAGE_DIR="/opt/rke2/stage"
  local SRC="$STAGE_DIR"; [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$WORK_DIR"
  if [[ ! -f "$SRC/install.sh" ]]; then
    log ERROR "Missing install.sh. Run 'pull' then 'image' first."
    exit 1
  fi
  pushd "$SRC" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$SRC" INSTALL_RKE2_TYPE="agent" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null

  systemctl enable rke2-agent

  # Optional join config
  if [[ -n "${A_URL:-}" ]]; then echo "server: \"$A_URL\"" >> /etc/rancher/rke2/config.yaml; fi
  if [[ -n "${A_TOKEN:-}" ]]; then echo "token: \"$A_TOKEN\"" >> /etc/rancher/rke2/config.yaml; fi

  # Hostname and /etc/hosts entry
  hostnamectl set-hostname "$A_HOST"
  grep -q "$A_HOST" /etc/hosts || echo "$A_IP $A_HOST" >> /etc/hosts

  # Netplan
  write_netplan "$A_IP" "$A_PREFIX" "${A_GW:-}" "${A_DNS:-}" "${A_SEARCH:-}"

  # Reboot prompt
  echo "A reboot is required to apply network changes."
  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes enabled: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    log INFO "Rebooting ..."; reboot
  else
    log WARN "Reboot deferred. Please reboot before using this node."
  fi
}

# ----- verify ----------------------------------------------------------------
sub_verify(){
  if verify_prereqs; then
    log INFO "VERIFY PASSED: Node meets RKE2 prerequisites."
    exit 0
  else
    log ERROR "VERIFY FAILED: See messages above. Fix issues and re-run."
    exit 1
  fi
}

# ============================================================================
# DISPATCHER
# ============================================================================
ACTION="${CLI_SUB:-}"
if [[ -n "$CONFIG_FILE" && -z "$CLI_SUB" ]]; then
  case "$YAML_KIND" in
    Pull|pull)   ACTION="pull";;
    Push|push)   ACTION="push";;
    Image|image) ACTION="image";;
    Server|server) ACTION="server";;
    Agent|agent) ACTION="agent";;
    *) log ERROR "Unsupported or missing YAML kind: '${YAML_KIND:-<none>}'"; exit 1;;
  esac
fi

case "${ACTION:-}" in
  pull)   sub_pull;;
  push)   sub_push;;
  image)  sub_image;;
  server) sub_server;;
  agent)  sub_agent;;
  verify) sub_verify;;
  *) print_help; exit 1;;
esac
