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

#########################
##  F U N C T I O N S  ##

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

log() {
  local level="$1"; shift
  local msg="$*"
  local ts host
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  host="$(hostname)"
  echo "[$level] $msg"
  printf "%s %s rke2nodeinit[%d]: %s %s\n" "$ts" "$host" "$$" "$level:" "$msg" >> "$LOG_FILE"
}

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

# Stage user-provided custom CA artifacts during image() without generating
# Accepts standalone kind: custom_ca YAML or inline spec.customCA under kind: Image
stage_custom_ca() {
  local did_stage=0
  local stage_dir="${PROJECT_ROOT:-/rke2-node-init}/downloads/custom-ca"
  mkdir -p "$stage_dir"

  local kind=""; local inline_root=""; local inline_key=""; local inline_intcrt=""; local inline_intkey=""
  if [[ -n "${CONFIG_FILE:-}" && -f "${CONFIG_FILE:-}" ]]; then
    kind="$(awk -F: '/^[[:space:]]*kind:/ {print $2}' "$CONFIG_FILE" | head -n1 | tr -d "[:space:]")"
    if [[ "$kind" == "custom_ca" ]]; then
      inline_root="$(yaml_spec_get_nested "$CONFIG_FILE" "rootCert" || true)"
      inline_key="$(yaml_spec_get_nested "$CONFIG_FILE" "rootKey" || true)"
      inline_intcrt="$(yaml_spec_get_nested "$CONFIG_FILE" "intermediateCert" || true)"
      inline_intkey="$(yaml_spec_get_nested "$CONFIG_FILE" "intermediateKey" || true)"
    elif [[ "$kind" == "Image" ]]; then
      inline_root="$(yaml_spec_get_nested "$CONFIG_FILE" "customCA.rootCert" || true)"
      inline_key="$(yaml_spec_get_nested "$CONFIG_FILE" "customCA.rootKey" || true)"
      inline_intcrt="$(yaml_spec_get_nested "$CONFIG_FILE" "customCA.intermediateCert" || true)"
      inline_intkey="$(yaml_spec_get_nested "$CONFIG_FILE" "customCA.intermediateKey" || true)"
    fi
  fi

  if [[ -n "$inline_root" && -n "$inline_key" ]]; then
    if [[ -f "$inline_root" && -f "$inline_key" ]]; then
      cp -f "$inline_root" "${stage_dir}/root.crt"
      cp -f "$inline_key"  "${stage_dir}/root.key"
      log OK "[OK] Staged custom CA root into ${stage_dir}"
      did_stage=1
    else
      log WARN "[WARN] customCA paths in YAML not found on disk; skipping stage"
    fi
    if [[ -n "$inline_intcrt" && -n "$inline_intkey" && -f "$inline_intcrt" && -f "$inline_intkey" ]]; then
      cp -f "$inline_intcrt" "${stage_dir}/intermediate.crt"
      cp -f "$inline_intkey" "${stage_dir}/intermediate.key"
      log OK "[OK] Staged custom intermediate CA into ${stage_dir}"
    fi
  else
    # Interactive prompt
    if [[ -t 0 ]]; then
      echo -n "Would you like to stage a custom cluster CA now? [y/N]: "
      read -r ans || true
      if [[ "$(bool_to_10 "$ans")" == "1" ]]; then
        read -rp "Path to ROOT CA cert (.crt): " inline_root || true
        read -rp "Path to ROOT CA key  (.key|.pem): " inline_key || true
        if [[ -f "$inline_root" && -f "$inline_key" ]]; then
          cp -f "$inline_root" "${stage_dir}/root.crt"
          cp -f "$inline_key"  "${stage_dir}/root.key"
          log WARN "[OK] Staged custom CA root into ${stage_dir}"
          did_stage=1
          read -rp "Optional: path to INTERMEDIATE cert (.crt) [enter to skip]: " inline_intcrt || true
          if [[ -n "$inline_intcrt" ]]; then
            read -rp "Optional: path to INTERMEDIATE key (.key|.pem): " inline_intkey || true
            if [[ -f "$inline_intcrt" && -f "$inline_intkey" ]]; then
              cp -f "$inline_intcrt" "${stage_dir}/intermediate.crt"
              cp -f "$inline_intkey" "${stage_dir}/intermediate.key"
              log OK "[OK] Staged custom intermediate CA into ${stage_dir}"
            else
              log WARN "[WARN] Intermediate files not found; skipping intermediate"
            fi
          fi
        else
          log WARN "[WARN] Provided root cert/key not found; skipping custom CA stage"
        fi
      fi
    fi
  fi

  if (( did_stage == 1 )); then
    echo "staged=1" > "${stage_dir}/.manifest"
    log INFO "[INFO] Custom CA artifacts staged for later use (server phase)"
  else
    log INFO "[INFO] No custom CA provided during image(); skipping"
  fi
}

install_rke2_prereqs() {
  log INFO "Installing RKE2 prereqs (iptables-nft, modules, sysctl, swapoff)"
  export DEBIAN_FRONTEND=noninteractive
  log INFO "Updating APT package cache"
  spinner_run "Updating APT package cache" apt-get update -y # >>"$LOG_FILE" 2>&1
  log INFO "Upgrading APT packages"
  spinner_run "Upgrading APT packages" apt-get upgrade -y # >>"$LOG_FILE" 2>&1
  log INFO "Installing required packages"
  spinner_run "Installing required and optional packages" apt-get install -y \
    curl ca-certificates iptables nftables ethtool socat conntrack iproute2 \
    ebtables openssl tar gzip zstd jq # >>"$LOG_FILE" 2>&1
  log INFO "Removing unnecessary packages"
  spinner_run "Removing unnecessary packages" apt-get autoremove -y # >>"$LOG_FILE" 2>&1

  # ------------------ Kernel modules + sysctls ------------------
  mkdir -p /etc/modules-load.d /etc/sysctl.d
  cat >/etc/modules-load.d/rke2.conf <<'MODS'
overlay
br_netfilter
MODS
  modprobe overlay || true
  modprobe br_netfilter || true

  cat >/etc/sysctl.d/90-rke2.conf <<'SYS'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYS
  sysctl --system >>"$LOG_FILE" 2>&1 || true

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

  # Stage images tar where the RKE2 installer will auto-detect it offline
  mkdir -p /var/lib/rancher/rke2/agent/images/
  if [[ -f "$DOWNLOADS_DIR/$IMAGES_TAR" ]]; then
    cp -f "$DOWNLOADS_DIR/$IMAGES_TAR" /var/lib/rancher/rke2/agent/images/ || true
    log INFO "Staged ${IMAGES_TAR} into /var/lib/rancher/rke2/agent/images/"
  fi
}

ensure_installed() {
  local pkg="$1"
  dpkg -s "$pkg" &>/dev/null || {
    log INFO "Installing package: $pkg"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >>"$LOG_FILE" 2>&1
    apt-get install -y "$pkg" >>"$LOG_FILE" 2>&1
  }
}

install_nerdctl() {
  # Install ONLY the nerdctl CLI (no containerd). It will be useful once RKE2's containerd is running.
  ensure_installed curl
  ensure_installed ca-certificates
  ensure_installed tar

  local tag="${NERDCTL_VERSION:-}"
  if [[ -z "$tag" ]]; then
    log INFO "Detecting latest nerdctl (CLI) release..."
    tag="$(curl -fsSL https://api.github.com/repos/containerd/nerdctl/releases/latest | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
    [[ -z "$tag" ]] && { log ERROR "Failed to detect nerdctl release tag"; return 2; }
  fi
  local ver="${tag#v}"
  local url="https://github.com/containerd/nerdctl/releases/download/${tag}/nerdctl-${ver}-linux-${ARCH}.tar.gz"
  local tmp
  tmp="$(mktemp -d)"
  pushd "$tmp" >/dev/null
  spinner_run "Downloading nerdctl ${tag} (CLI only)" curl -fL "$url" -o nerdctl.tgz
  spinner_run "Extracting nerdctl" tar -xzf nerdctl.tgz
  install -m 0755 nerdctl /usr/local/bin/nerdctl
  popd >/dev/null
  rm -rf "$tmp"
  log INFO "nerdctl installed: $(/usr/local/bin/nerdctl --version 2>/dev/null || echo 'installed')"
}

#####################
##  A C T I O N S  ##

action_image() {
  # Purpose: Prep a *minimal* Ubuntu 24.04 image for air‑gapped RKE2.
  # - Install only required APT packages (curl, ca-certificates).
  # - Configure kernel modules and sysctls for Kubernetes networking.
  # - Ensure swap is off (now and on reboot).
  # - If NetworkManager exists, make it ignore CNI interfaces.
  # - Optionally open required ports if ufw is active.
  # - Cache RKE2 artifacts (tarball, images, checksums, installer) locally.
  # - Install nerdctl CLI *only* (no containerd) for later use with RKE2's containerd.
  # - Stage the images tarball under /var/lib/rancher/rke2/agent/images for offline install.
  # - Prompt the user to reboot at the end.

  load_site_defaults

  # ------------------ Read config (optional) ------------------
  local REQ_VER="${RKE2_VERSION:-}"
  local WANT_NERDCTL="${NERDCTL_INSTALL:-1}"   # default install nerdctl CLI
  local REGISTRY_HOST=""
  if [[ -n "$CONFIG_FILE" ]]; then
    REQ_VER="${REQ_VER:-$(yaml_spec_get "$CONFIG_FILE" rke2Version || true)}"
    REGISTRY_HOST="$(yaml_spec_get "$CONFIG_FILE" registry || true)"
    local yn
    yn="$(yaml_spec_get "$CONFIG_FILE" nerdctlInstall || true)"; [[ -n "$yn" ]] && WANT_NERDCTL="$yn"
  fi

  install_rke2_prereqs
  fetch_rke2_ca_generator
  cache_rke2_artifacts

  # install nerdctl
  if [[ "${WANT_NERDCTL,,}" =~ ^(1|true|yes)$ ]]; then
    install_nerdctl || true
  else
    log INFO "Skipping nerdctl installation (per configuration)."
  fi

 # Image prep complete
  echo "[READY] Minimal image prep complete. Cached artifacts in: $DOWNLOADS_DIR"
  echo "        - You can now install RKE2 offline using the cached tarballs."
  echo
  prompt_reboot
}

############
##  R U N ##

action_image
