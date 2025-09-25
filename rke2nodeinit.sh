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
#
# Safety:
#   - set -Eeuo pipefail
#   - global ERR trap emits line number
#   - root check
#   - strong input validation for IP/prefix/DNS/search
#
# YAML (apiVersion: rkeprep/v1) kinds determine action when using -f <file>:
#   - kind: Pull|pull, Push|push, Image|image, Server|server, Agent|agent
#
# Exit codes:
#   0 success | 1 usage | 2 missing prerequisites | 3 data missing | 4 registry auth | 5 YAML issues
# -----------------------------------------------------------------------------------------

set -Eeuo pipefail
trap 'rc=$?; echo "[ERROR] Unexpected failure (exit $rc) at line $LINENO"; exit $rc' ERR

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
log() {
  local level="$1"; shift
  local msg="$*"
  local ts host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  host="$(hostname)"
  echo "[$level] $msg"
  printf "%s %s rke2nodeinit[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
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
REGISTRY="kuberegistry.dev.kube/rke2"
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
  sudo ./rke2nodeinit.sh [options] <pull|push|image|server|agent|verify>
  sudo ./rke2nodeinit.sh examples/pull.yaml

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
      if ($0 ~ /^[^[:space:]]/) { exit }   # left margin => new top-level
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
    apt-get update -y
    apt-get install -y "$pkg"
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
    if [[ "$reply" =~ ^[Yy]$ ]]; then
      systemctl stop docker 2>/dev/null || true
      systemctl disable docker 2>/dev/null || true
      export DEBIAN_FRONTEND=noninteractive
      apt-get purge -y docker.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin moby-engine moby-cli 2>>"$LOG_FILE" || true
      apt-get autoremove -y || true
      rm -rf /var/lib/docker /etc/docker 2>>"$LOG_FILE" || true
      log INFO "Docker removed."
    else
      log ERROR "Docker must be removed to proceed (this script is containerd-only)."
      exit 2
    fi
  fi
}

install_containerd_nerdctl_full() {
  # Install containerd + runc + CNI + BuildKit + nerdctl from the official "full" tarball.
  # This follows vendor guidance: extract to /usr/local, enable containerd, create config with SystemdCgroup=true.
  ensure_installed curl
  ensure_installed ca-certificates
  ensure_installed tar

  # Detect latest nerdctl tag (includes the full bundle)
  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local tag ver url tmp
  tag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  [[ -z "$tag" ]] && { log ERROR "Failed to detect latest nerdctl release tag"; exit 2; }
  ver="${tag#v}"

  url="https://github.com/containerd/nerdctl/releases/download/${tag}/nerdctl-full-${ver}-linux-${ARCH}.tar.gz"
  tmp="$(mktemp -d)"

  log INFO "Installing containerd stack via nerdctl FULL bundle: ${tag} (${ARCH})"
  curl -fsSL "$url" -o "$tmp/nerdctl-full.tgz"
  tar -C /usr/local -xzf "$tmp/nerdctl-full.tgz"
  rm -rf "$tmp"

  # Ensure systemd sees the unit files from the bundle (they are placed under /usr/local/lib/systemd/system)
  systemctl daemon-reload

  # Generate containerd config with systemd cgroup driver
  mkdir -p /etc/containerd
  if ! command -v containerd >/dev/null 2>&1; then
    log ERROR "containerd binary not found after install (unexpected)."
    exit 2
  fi
  containerd config default | tee /etc/containerd/config.toml >/dev/null
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  # Start containerd
  systemctl enable --now containerd

  # Confirm nerdctl
  if ! /usr/local/bin/nerdctl --version >/dev/null 2>&1; then
    log ERROR "nerdctl not found after install (unexpected)."
    exit 2
  fi
  log INFO "nerdctl installed: $(/usr/local/bin/nerdctl --version)"
}

ensure_containerd_ready() {
  ask_remove_docker_if_present

  # If containerd is running and nerdctl exists, we're good. Otherwise install the FULL bundle.
  if systemctl is-active --quiet containerd && command -v nerdctl >/dev/null 2>&1; then
    log INFO "containerd + nerdctl are present and active."
  else
    log WARN "containerd + nerdctl not ready; installing the official FULL bundle."
    install_containerd_nerdctl_full
  fi

  # Namespace used by Kubernetes
  if ! nerdctl --namespace k8s.io images >/dev/null 2>&1; then
    # First call creates namespace storage if missing; not fatal
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

# ---------- Netplan writer (static IPv4 + DNS + search domains) --------------------------------
write_netplan() {
  # Usage: write_netplan IP PREFIX GATEWAY DNS_CSV SEARCH_CSV
  local ip="$1"; local prefix="$2"; local gw="${3:-}"; local dns_csv="${4:-}"; local search_csv="${5:-}"

  # Detect primary NIC
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

  log INFO "Netplan written for $nic (IP=$ip/${prefix:-24}, GW=${gw:-<none>}, DNS=${dns_csv:-<default>}, SEARCH=${search_csv:-<none>})"
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
  apt-get update -y
  apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq

  if update-alternatives --list iptables >/dev/null 2>&1; then
    update-alternatives --set iptables  /usr/sbin/iptables-nft || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-nft || true
    update-alternatives --set arptables /usr/sbin/arptables-nft || true
    update-alternatives --set ebtables  /usr/sbin/ebtables-nft  || true
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
  # Return 0 on success; 1 if any check fails.
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
  [[ -f /usr/local/share/ca-certificates/kuberegistry-ca.crt ]] && log INFO "CA installed" || log WARN "CA missing (/usr/local/share/ca-certificates/kuberegistry-ca.crt)"

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

# ================================================================================================
# ACTIONS
# ================================================================================================

action_pull() {
  # Download artifacts; preload images into containerd (nerdctl only).
  if [[ -n "$CONFIG_FILE" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY="$(yaml_spec_get "$CONFIG_FILE" registry || echo "$REGISTRY")"
    REG_USER="$(yaml_spec_get "$CONFIG_FILE" registryUsername || echo "$REG_USER")"
    REG_PASS="$(yaml_spec_get "$CONFIG_FILE" registryPassword || echo "$REG_PASS")"
    log WARN "Using YAML values; CLI flags may be overridden (pull)."
  fi

  detect_latest_rke2_version
  ensure_containerd_ready

  local BASE_URL="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
  mkdir -p "$DOWNLOADS_DIR"
  pushd "$DOWNLOADS_DIR" >/dev/null

  ensure_installed curl
  ensure_installed zstd
  ensure_installed ca-certificates

  log INFO "Downloading artifacts (images, tarball, checksums, installer)..."
  curl -Lf "$BASE_URL/$IMAGES_TAR"   -o "$IMAGES_TAR"
  curl -Lf "$BASE_URL/$RKE2_TARBALL" -o "$RKE2_TARBALL"
  curl -Lf "$BASE_URL/$SHA256_FILE"  -o "$SHA256_FILE"
  curl -sfL "https://get.rke2.io"    -o install.sh && chmod +x install.sh

  log INFO "Verifying checksums..."
  grep "$IMAGES_TAR"  "$SHA256_FILE" | sha256sum -c -
  grep "$RKE2_TARBALL" "$SHA256_FILE" | sha256sum -c -

  log INFO "Pre-loading images into containerd via nerdctl..."
  zstdcat "$IMAGES_TAR" | nerdctl -n k8s.io load

  popd >/dev/null
  log INFO "pull: completed successfully."
}

action_push() {
  # Push all loaded images to the private registry using nerdctl (no Docker).
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

  # Ensure images are present inside k8s.io namespace
  zstdcat "$work/$IMAGES_TAR" | nerdctl -n k8s.io load

  # Build image list
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

  # Login and push (nerdctl stores creds in ~/.docker/config.json)
  nerdctl login "$REG_HOST" -u "$REG_USER" -p "$REG_PASS" >/dev/null 2>>"$LOG_FILE" || {
    log ERROR "Registry login failed"
    exit 4
  }
  for IMG in "${imgs[@]}"; do
    [[ -z "$IMG" ]] && continue
    local TARGET
    if [[ -n "$REG_NS" ]]; then TARGET="$REG_HOST/$REG_NS/$IMG"; else TARGET="$REG_HOST/$IMG"; fi
    log INFO "Tag & push: $IMG -> $TARGET"
    nerdctl -n k8s.io tag  "$IMG" "$TARGET"
    nerdctl -n k8s.io push "$TARGET"
  done
  nerdctl logout "$REG_HOST" || true

  log INFO "push: completed successfully."
}

action_image() {
  # Prepare offline image (OS prereqs, CA, registries.yaml, staged artifacts).
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

  # Private registry CA
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

  # Optional IPv6 disable
  cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
  sysctl --system >/dev/null 2>>"$LOG_FILE" || true
  log INFO "IPv6 disabled via sysctl (99-disable-ipv6.conf)."

  # Save site defaults for later prompts
  local STATE="/etc/rke2image.defaults"
  {
    echo "DEFAULT_DNS=\"$defaultDnsCsv\""
    echo "DEFAULT_SEARCH=\"$defaultSearchCsv\""
  } > "$STATE"
  chmod 600 "$STATE"
  log INFO "Saved site defaults: DNS=[$defaultDnsCsv], SEARCH=[$defaultSearchCsv]"

  # OS updates (optional but recommended for golden images)
  log INFO "Applying OS updates; the system will reboot automatically..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y
  apt-get autoremove -y || true
  apt-get autoclean  -y || true
  log WARN "Rebooting now to complete updates."
  sleep 2
  reboot
}

action_server() {
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""

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

  if [[ -z "${GW:-}" ]]; then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  log INFO "Gateway entered (server): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS" && log INFO "Using default DNS for server: $DNS"
  fi
  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$SEARCH" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for server: $SEARCH"
  fi

  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  # Ensure installer staged
  local SRC="$STAGE_DIR"
  [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$DOWNLOADS_DIR"
  [[ -f "$SRC/install.sh" ]] || { log ERROR "Missing install.sh. Run 'pull' then 'image' first."; exit 3; }

  ensure_containerd_ready
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
    log INFO "Auto-yes: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot
  else log WARN "Reboot deferred. Please reboot before using this node."; fi
}

action_agent() {
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

  if [[ -z "${GW:-}" ]]; then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  log INFO "Gateway entered (agent): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    [[ -z "$DNS" ]] && DNS="$DEFAULT_DNS" && log INFO "Using default DNS for agent: $DNS"
  fi
  if [[ -n "${DEFAULT_SEARCH:-}" && -z "$SEARCH" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for agent: $SEARCH"
  fi

  if [[ -z "${URL:-}" ]]; then read -rp "Enter RKE2 server URL (e.g., https://<server-ip>:9345) [optional]: " URL || true; fi
  if [[ -n "$URL" && -z "${TOKEN:-}" ]]; then read -rp "Enter cluster join token [optional]: " TOKEN || true; fi

  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter agent IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter agent prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  local SRC="$STAGE_DIR"
  [[ -f "$STAGE_DIR/install.sh" ]] || SRC="$DOWNLOADS_DIR"
  [[ -f "$SRC/install.sh" ]] || { log ERROR "Missing install.sh. Run 'pull' then 'image' first."; exit 3; }

  ensure_containerd_ready
  log INFO "Proceeding with offline RKE2 agent install..."
  pushd "$SRC" >/dev/null
  INSTALL_RKE2_ARTIFACT_PATH="$SRC" INSTALL_RKE2_TYPE="agent" sh install.sh >/dev/null 2>>"$LOG_FILE"
  popd >/dev/null

  systemctl enable rke2-agent

  mkdir -p /etc/rancher/rke2
  [[ -n "${URL:-}"   ]] && echo "server: \"$URL\"" >> /etc/rancher/rke2/config.yaml
  [[ -n "${TOKEN:-}" ]] && echo "token: \"$TOKEN\"" >> /etc/rancher/rke2/config.yaml

  hostnamectl set-hostname "$HOSTNAME"
  grep -q "$HOSTNAME" /etc/hosts || echo "$IP $HOSTNAME" >> /etc/hosts

  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"
  echo "A reboot is required to apply network changes."

  if [[ "$AUTO_YES" -eq 1 ]]; then
    log INFO "Auto-yes: rebooting now."
    reboot
  fi
  read -rp "Reboot now? [y/N]: " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then log INFO "Rebooting..."; reboot
  else log WARN "Reboot deferred. Please reboot before using this node."; fi
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
    Pull|pull)     ACTION="pull"   ;;
    Push|push)     ACTION="push"   ;;
    Image|image)   ACTION="image"  ;;
    Server|server) ACTION="server" ;;
    Agent|agent)   ACTION="agent"  ;;
    *) log ERROR "Unsupported or missing YAML kind: '${YAML_KIND:-<none>}'"; exit 5;;
  esac
fi

case "${ACTION:-}" in
  pull)   action_pull   ;;
  push)   action_push   ;;
  image)  action_image  ;;
  server) action_server ;;
  agent)  action_agent  ;;
  verify) action_verify ;;
  *) print_help; exit 1 ;;
esac
