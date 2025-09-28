#!/usr/bin/env bash
#
# rke2nodeinit.with-verify.sh
# -----------------------------------------------------------------------------
# Purpose:
#   Pre-warm, push, and install Rancher RKE2 in online/offline environments
#   with a consistent image resolution strategy and explicit verification.
#
# Key actions:
#   - pull   : Cache RKE2 artifacts (binaries + images) and nerdctl-full bundle.
#   - push   : Retag and push cached images to a target registry.
#   - image  : Stage artifacts to the host's standard offline paths.
#   - server : Offline-safe install path for RKE2 server node.
#   - agent  : Offline-safe install path for RKE2 agent node.
#   - verify : Run pre/post checks to confirm artifacts, images, registry mirrors,
#              and containerd readiness.
#
# Image resolution order (server/agent/image):
#   1) Local preloaded cache (pre-warmed via `pull`/`image`).
#   2) Primary offline registry (CLI/YAML/default).
#   3) Optional fallback registries (YAML/CLI), then default public (only if set).
#
# Offline guarantees:
#   - `pull` caches the `nerdctl-full` bundle so containerd+nerdctl can be
#     installed later when the VM is isolated from the Internet.
#   - `server`/`agent` install from the cached artifacts and preloaded images.
#
# -----------------------------------------------------------------------------
# Safety and bash behavior
set -Eeuo pipefail

# Guard against CRLF (Windows) endings to prevent parse errors
case "$(head -c 2 "$0" | od -An -t x1 | tr -d ' ')" in
  *0d0a) echo "ERROR: Windows line endings detected. Run: dos2unix '$0'"; exit 2;;
esac

# Globals and defaults
SCRIPT_NAME="$(basename "$0")"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
OUT_DIR="${ROOT_DIR}/outputs"
DL_DIR="${ROOT_DIR}/downloads"
STAGE_DIR="/opt/rke2/stage"
PRELOAD_DIR="/var/lib/rancher/rke2/agent/images"
CFG_DIR="/etc/rancher/rke2"
REGISTRIES_FILE="${CFG_DIR}/registries.yaml"
CERTS_DIR="${CFG_DIR}/certs"

mkdir -p "$LOG_DIR" "$OUT_DIR" "$DL_DIR" "$CERTS_DIR" "$PRELOAD_DIR" "$STAGE_DIR"

LOG_FILE="${LOG_DIR}/rke2nodeinit_$(date -u +%Y-%m-%dT%H-%M-%SZ).log"

ARCH_RAW="$(uname -m)"
case "$ARCH_RAW" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH_RAW" >&2; exit 2 ;;
esac

# Defaults (overridable via CLI/YAML)
RKE2_VERSION="${RKE2_VERSION:-}"            # e.g., v1.34.1+rke2r1
PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-}"    # e.g., kuberegistry.dev.kube/rke2
FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-}" # comma-separated list
REG_USER="${REG_USER:-}"
REG_PASS="${REG_PASS:-}"
REG_CA_FILE="${REG_CA_FILE:-}"              # path to PEM bundle for registry CAs
REG_CERT_FILE="${REG_CERT_FILE:-}"          # client cert (optional)
REG_KEY_FILE="${REG_KEY_FILE:-}"            # client key (optional)
ALLOW_DEFAULT_PUBLIC="${ALLOW_DEFAULT_PUBLIC:-false}" # if true, add public registries at end

CONFIG_FILE="${CONFIG_FILE:-}"

# Derived file names based on RKE2 version and arch
images_tar_name() { echo "rke2-images.linux-${ARCH}.tar.zst"; }
rke2_tar_name()   { echo "rke2.linux-${ARCH}.tar.gz"; }
sha_file_name()   { echo "sha256sum-${ARCH}.txt"; }

# Logging helpers
log() {
  # usage: log LEVEL MSG...
  local level="$1"; shift
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "${ts} ${level}: $*" | tee -a "$LOG_FILE" >&2
}
die() {
  log ERROR "$*"
  exit 1
}

spinner_run() {
  # usage: spinner_run "Label text" cmd arg...
  local label="$1"; shift
  local cmd=( "$@" )
  log INFO "$label..."
  ( "${cmd[@]}" >>"$LOG_FILE" 2>&1 ) &
  local pid=$!
  local spin='|/-\' i=0
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r[WORK] %s %s" "${spin:i++%${#spin}:1}" "$label"
    sleep 0.15
  done
  wait "$pid"; local rc=$?
  printf "\r"
  if (( rc == 0 )); then
    echo "[DONE] $label"
    log INFO "$label...done"
    return 0
  else
    echo "[FAIL] $label (rc=$rc)"
    log ERROR "$label failed (rc=$rc). See $LOG_FILE"
    return "$rc"
  fi
}

# Utilities
ensure_installed() {
  # usage: ensure_installed pkg1 [pkg2...]
  local missing=()
  for p in "$@"; do
    if ! dpkg -s "$p" >/dev/null 2>&1; then
      missing+=( "$p" )
    fi
  done
  if ((${#missing[@]})); then
    spinner_run "Installing packages: ${missing[*]}" apt-get update -y
    spinner_run "Installing packages: ${missing[*]}" apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

# Simple YAML reader (top-level 'key: value' only)
yaml_get() {
  # usage: yaml_get FILE KEY
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  awk -v k="^${key}:" '
    $0 ~ k {
      # Join everything after the first colon, trim leading space
      sub(/^[^:]*:[[:space:]]*/, "", $0)
      print $0
      exit
    }' "$file"
}

# Version and URL helpers
rke2_release_base() {
  local v="$1"
  echo "https://github.com/rancher/rke2/releases/download/${v}"
}
rke2_images_url() {
  local v="$1"
  echo "$(rke2_release_base "$v")/$(images_tar_name)"
}
rke2_tar_url() {
  local v="$1"
  echo "$(rke2_release_base "$v")/$(rke2_tar_name)"
}
rke2_sha_url() {
  local v="$1"
  echo "$(rke2_release_base "$v")/$(sha_file_name)"
}
rke2_install_sh_url() {
  echo "https://get.rke2.io"
}

# Containerd + nerdctl installers
install_containerd_nerdctl_from_cache() {
  local tgz="$1"
  [[ -f "$tgz" ]] || die "Cached nerdctl FULL bundle not found: $tgz"
  ensure_installed tar
  spinner_run "Extracting nerdctl FULL (cached)" tar -C /usr/local -xzf "$tgz"
  spinner_run "Reloading systemd units" systemctl daemon-reload
  mkdir -p /etc/containerd
  if ! [[ -f /etc/containerd/config.toml ]]; then
    containerd config default | tee /etc/containerd/config.toml >/dev/null
  fi
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
  spinner_run "Enabling and starting containerd" systemctl enable --now containerd
  log INFO "nerdctl installed (cached): $(/usr/local/bin/nerdctl --version 2>/dev/null || echo unknown)"
}

install_containerd_nerdctl_full_online() {
  ensure_installed curl tar ca-certificates
  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local tag ver url tgz
  tag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  [[ -n "$tag" ]] || die "Failed to detect nerdctl latest release"
  ver="${tag#v}"
  url="https://github.com/containerd/nerdctl/releases/download/${tag}/nerdctl-full-${ver}-linux-${ARCH}.tar.gz"
  tgz="${DL_DIR}/nerdctl-full-${ver}-linux-${ARCH}.tar.gz"
  spinner_run "Downloading nerdctl FULL ${tag}" curl -Lf "$url" -o "$tgz"
  install_containerd_nerdctl_from_cache "$tgz"
}

ask_remove_docker_if_present() {
  if command -v docker >/dev/null 2>&1; then
    log WARN "Docker detected. RKE2 prefers containerd."
    if [[ "${AUTO_REMOVE_DOCKER:-}" == "yes" ]]; then
      spinner_run "Removing Docker" apt-get remove -y docker.io docker-ce docker-ce-cli containerd.io || true
    else
      read -r -p "Remove Docker and install containerd instead? [y/N]: " ans
      if [[ "${ans,,}" == "y" ]]; then
        spinner_run "Removing Docker" apt-get remove -y docker.io docker-ce docker-ce-cli containerd.io || true
      else
        log WARN "Continuing without removing Docker may cause conflicts."
      fi
    fi
  fi
}

ensure_containerd_ready() {
  ask_remove_docker_if_present

  if systemctl is-active --quiet containerd && command -v nerdctl >/dev/null 2>&1; then
    log INFO "containerd + nerdctl are present and active."
    return 0
  fi

  # Try offline cache first
  local cached
  cached="$(ls -1 "${DL_DIR}"/nerdctl-full-*-linux-"$ARCH".tar.gz 2>/dev/null | sort | tail -n1 || true)"
  if [[ -n "$cached" ]]; then
    log INFO "Installing containerd+nerdctl from cached bundle: $(basename "$cached")"
    install_containerd_nerdctl_from_cache "$cached"
  else
    log WARN "containerd + nerdctl not ready; installing the official FULL bundle (online)."
    install_containerd_nerdctl_full_online
  fi

  # Initialize k8s.io namespace once
  nerdctl --namespace k8s.io images >/dev/null 2>&1 || true
}

# Artifact staging
ensure_staged_artifacts() {
  # Ensure required RKE2 artifacts are in STAGE_DIR and PRELOAD_DIR
  [[ -n "${RKE2_VERSION:-}" ]] || die "RKE2_VERSION is not set"
  local img_tar rke2_tar sha
  img_tar="$(images_tar_name)"
  rke2_tar="$(rke2_tar_name)"
  sha="$(sha_file_name)"

  mkdir -p "$STAGE_DIR" "$PRELOAD_DIR"

  # Stage installer
  if [[ -f "${DL_DIR}/install.sh" ]]; then
    cp -f "${DL_DIR}/install.sh" "${STAGE_DIR}/install.sh"
    chmod +x "${STAGE_DIR}/install.sh"
  fi

  # Stage tarballs + sha
  for f in "$rke2_tar" "$sha"; do
    if [[ -f "${DL_DIR}/${f}" ]]; then
      cp -f "${DL_DIR}/${f}" "${STAGE_DIR}/${f}"
    else
      log WARN "Missing ${f} in downloads; server/agent may fail."
    fi
  done

  # Ensure images tar in preload path
  if [[ -f "${DL_DIR}/${img_tar}" ]]; then
    cp -f "${DL_DIR}/${img_tar}" "${PRELOAD_DIR}/${img_tar}"
  else
    log WARN "Missing ${img_tar} in downloads; RKE2 may try to pull from registry."
  fi
}

# Image resolution strategy (registries.yaml + optional CA/auth)
setup_image_resolution_strategy() {
  mkdir -p "$CFG_DIR"
  local endpoints_yaml=""
  local IFS=','

  if [[ -n "${PRIMARY_REGISTRY:-}" ]]; then
    endpoints_yaml="${endpoints_yaml}      - \"https://${PRIMARY_REGISTRY}\"\n"
  fi
  if [[ -n "${FALLBACK_REGISTRIES:-}" ]]; then
    for ep in ${FALLBACK_REGISTRIES}; do
      [[ -n "$ep" ]] && endpoints_yaml="${endpoints_yaml}      - \"https://${ep}\"\n"
    done
  fi
  if [[ "${ALLOW_DEFAULT_PUBLIC}" == "true" ]]; then
    # As a last resort (strongly discouraged offline), add representative publics
    endpoints_yaml="${endpoints_yaml}      - \"https://registry.k8s.io\"\n"
    endpoints_yaml="${endpoints_yaml}      - \"https://docker.io\"\n"
    endpoints_yaml="${endpoints_yaml}      - \"https://ghcr.io\"\n"
    endpoints_yaml="${endpoints_yaml}      - \"https://quay.io\"\n"
  fi

  cat >"$REGISTRIES_FILE" <<EOF
mirrors:
  "*":
    endpoint:
$(printf "%b" "$endpoints_yaml")
configs:
EOF

  # TLS/Basic/MTLS config
  if [[ -n "${REG_CA_FILE:-}" ]]; then
    # copy CA into certs dir for stability
    local ca_dest="${CERTS_DIR}/registry-ca.pem"
    cp -f "$REG_CA_FILE" "$ca_dest"
    echo "  ${PRIMARY_REGISTRY}:" >>"$REGISTRIES_FILE"
    echo "    tls:"               >>"$REGISTRIES_FILE"
    echo "      ca_file: ${ca_dest}" >>"$REGISTRIES_FILE"
  fi
  if [[ -n "${REG_CERT_FILE:-}" && -n "${REG_KEY_FILE:-}" ]]; then
    local cert_dest="${CERTS_DIR}/registry.crt"
    local key_dest="${CERTS_DIR}/registry.key"
    cp -f "$REG_CERT_FILE" "$cert_dest"
    cp -f "$REG_KEY_FILE" "$key_dest"
    echo "  ${PRIMARY_REGISTRY}:" >>"$REGISTRIES_FILE"
    echo "    tls:"               >>"$REGISTRIES_FILE"
    echo "      cert_file: ${cert_dest}" >>"$REGISTRIES_FILE"
    echo "      key_file: ${key_dest}"   >>"$REGISTRIES_FILE"
  fi
  if [[ -n "${REG_USER:-}" && -n "${REG_PASS:-}" ]]; then
    # basic auth block
    echo "  ${PRIMARY_REGISTRY}:" >>"$REGISTRIES_FILE"
    echo "    auth:"              >>"$REGISTRIES_FILE"
    echo "      username: ${REG_USER}" >>"$REGISTRIES_FILE"
    echo "      password: ${REG_PASS}" >>"$REGISTRIES_FILE"
  fi

  # Also set system-default-registry for RKE2
  mkdir -p "$CFG_DIR"
  if [[ -n "${PRIMARY_REGISTRY:-}" ]]; then
    if ! grep -q '^system-default-registry:' "$CFG_DIR/config.yaml" 2>/dev/null; then
      echo "system-default-registry: ${PRIMARY_REGISTRY}" >>"$CFG_DIR/config.yaml"
    fi
  fi

  log INFO "Wrote ${REGISTRIES_FILE} (primary + fallbacks)."
}

# Verify routines
pre_install_verify() {
  # Quick pre-flight checks for server/agent before running install.sh
  local ok=true
  command -v nerdctl >/dev/null 2>&1 || { log ERROR "nerdctl not found"; ok=false; }
  systemctl is-active --quiet containerd || { log ERROR "containerd is not running"; ok=false; }

  if [[ ! -s "$REGISTRIES_FILE" ]]; then
    log WARN "registries.yaml not found; image fallback chain not configured"
  fi

  local img_tar="${PRELOAD_DIR}/$(images_tar_name)"
  if [[ ! -f "$img_tar" ]]; then
    log WARN "Preload images tar not found at ${img_tar}"
  else
    log INFO "Preload images tar present: $(basename "$img_tar")"
  fi

  [[ "$ok" == true ]]
}

action_verify() {
  log INFO "Running verification checks..."

  local failures=0

  # containerd + nerdctl
  if systemctl is-active --quiet containerd; then
    echo "[PASS] containerd active"
  else
    echo "[FAIL] containerd not active"
    ((failures++))
  fi
  if command -v nerdctl >/dev/null 2>&1; then
    echo "[PASS] nerdctl present: $(nerdctl --version 2>/dev/null || true)"
  else
    echo "[FAIL] nerdctl missing"
    ((failures++))
  fi

  # Artifacts
  local img_tar="${PRELOAD_DIR}/$(images_tar_name)"
  [[ -f "${STAGE_DIR}/$(rke2_tar_name)" ]] && echo "[PASS] RKE2 tar staged" || { echo "[FAIL] RKE2 tar missing in ${STAGE_DIR}"; ((failures++)); }
  [[ -f "${STAGE_DIR}/$(sha_file_name)" ]] && echo "[PASS] sha256 list staged" || { echo "[FAIL] sha256 list missing in ${STAGE_DIR}"; ((failures++)); }
  [[ -f "${STAGE_DIR}/install.sh" ]] && echo "[PASS] install.sh staged" || { echo "[FAIL] install.sh missing in ${STAGE_DIR}"; ((failures++)); }
  [[ -f "$img_tar" ]] && echo "[PASS] images tar in preload path" || { echo "[FAIL] images tar missing in ${PRELOAD_DIR}"; ((failures++)); }

  # Registries fallback chain
  if [[ -s "$REGISTRIES_FILE" ]]; then
    echo "[PASS] registries.yaml present"
    grep -q 'mirrors:' "$REGISTRIES_FILE" && grep -q 'endpoint:' "$REGISTRIES_FILE" && echo "[PASS] mirrors endpoints defined" || { echo "[FAIL] mirrors endpoints missing"; ((failures++)); }
  else
    echo "[FAIL] registries.yaml missing"
    ((failures++))
  fi

  # Local cache presence (heuristic): at least one rke2 image present in k8s.io
  if nerdctl --namespace k8s.io images 2>/dev/null | awk 'NR>1 {print $1}' | grep -E -q '(rancher|rke2|kubernetes|pause)'; then
    echo "[PASS] images present in local k8s.io cache"
  else
    echo "[WARN] no obvious rke2 images found in local k8s.io cache"
  fi

  # OS trust for optional registry CA
  if [[ -n "${REG_CA_FILE:-}" ]]; then
    if update-ca-certificates --fresh >>"$LOG_FILE" 2>&1; then
      echo "[PASS] OS trust store updated for custom CA"
    else
      echo "[WARN] could not refresh OS trust store for custom CA"
    fi
  fi

  if ((failures>0)); then
    log ERROR "Verify completed with ${failures} failure(s). See $LOG_FILE"
    return 1
  else
    log INFO "Verify completed successfully."
    return 0
  fi
}

# Pull: cache artifacts and pre-warm images
action_pull() {
  ensure_installed curl ca-certificates coreutils zstd

  if [[ -n "${CONFIG_FILE:-}" && -z "${RKE2_VERSION:-}" ]]; then
    RKE2_VERSION="$(yaml_get "$CONFIG_FILE" rke2Version || true)"
  fi
  [[ -n "${RKE2_VERSION:-}" ]] || die "Provide RKE2 version via -v or CONFIG_FILE (key: rke2Version), e.g., v1.34.1+rke2r1"

  log INFO "Caching RKE2 artifacts for ${RKE2_VERSION} (${ARCH})"

  local img_url tar_url sha_url install_url img_tar rke2_tar sha
  img_tar="$(images_tar_name)"; rke2_tar="$(rke2_tar_name)"; sha="$(sha_file_name)"
  img_url="$(rke2_images_url "$RKE2_VERSION")"
  tar_url="$(rke2_tar_url "$RKE2_VERSION")"
  sha_url="$(rke2_sha_url "$RKE2_VERSION")"
  install_url="$(rke2_install_sh_url)"

  spinner_run "Downloading ${img_tar}" curl -Lf "$img_url" -o "${DL_DIR}/${img_tar}"
  spinner_run "Downloading ${rke2_tar}" curl -Lf "$tar_url" -o "${DL_DIR}/${rke2_tar}"
  spinner_run "Downloading ${sha}"     curl -Lf "$sha_url" -o "${DL_DIR}/${sha}"
  spinner_run "Fetching install.sh"    curl -Lf "$install_url" -o "${DL_DIR}/install.sh"
  chmod +x "${DL_DIR}/install.sh"

  # Verify checksums (only lines we have files for)
  ( cd "$DL_DIR"
    grep "$(images_tar_name)" "$sha" | sha256sum -c - && \
    grep "$(rke2_tar_name)"   "$sha" | sha256sum -c -
  ) && echo "[PASS] sha256 verification" || { echo "[FAIL] sha256 verification"; exit 1; }

  # Cache nerdctl-full for offline use
  log INFO "Detecting latest nerdctl FULL release (to cache offline)..."
  local api="https://api.github.com/repos/containerd/nerdctl/releases/latest"
  local ntag nver nurl ntgz
  ntag="$(curl -fsSL "$api" | grep -Po '"tag_name":\s*"\K[^"]+' || true)"
  if [[ -n "$ntag" ]]; then
    nver="${ntag#v}"
    nurl="https://github.com/containerd/nerdctl/releases/download/${ntag}/nerdctl-full-${nver}-linux-${ARCH}.tar.gz"
    ntgz="${DL_DIR}/nerdctl-full-${nver}-linux-${ARCH}.tar.gz"
    if [[ ! -f "$ntgz" ]]; then
      spinner_run "Caching nerdctl FULL ${ntag}" curl -Lf "$nurl" -o "$ntgz"
      log INFO "Cached nerdctl FULL: $(basename "$ntgz")"
    else
      log INFO "nerdctl FULL already cached: $(basename "$ntgz")"
    fi
  else
    log WARN "Could not detect nerdctl release; skipping offline cache."
  fi

  # Pre-warm local containerd cache (optional but useful)
  ensure_containerd_ready
  if command -v nerdctl >/dev/null 2>&1; then
    local img_path="${DL_DIR}/${img_tar}"
    log INFO "Pre-loading images into containerd (k8s.io) from ${img_path}"
    if command -v zstd >/dev/null 2>&1; then
      zstd -d --stdout "$img_path" | nerdctl --namespace k8s.io load >/dev/null 2>>"$LOG_FILE" || true
    else
      log WARN "zstd not available; skipping pre-load. The images tar will be staged for RKE2 to auto-load."
    fi
  fi

  echo "[OK] pull completed for ${RKE2_VERSION} (${ARCH})"
}

# Push: retag and push to target registry
action_push() {
  ensure_containerd_ready
  ensure_installed jq || true

  # Resolve registry info from CLI or YAML
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-$(yaml_get "$CONFIG_FILE" primaryRegistry || true)}"
    FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-$(yaml_get "$CONFIG_FILE" fallbackRegistries || true)}"
    REG_USER="${REG_USER:-$(yaml_get "$CONFIG_FILE" registryUser || true)}"
    REG_PASS="${REG_PASS:-$(yaml_get "$CONFIG_FILE" registryPass || true)}"
  fi
  [[ -n "${PRIMARY_REGISTRY:-}" ]] || die "Primary registry not set. Use -r or set 'primaryRegistry:' in CONFIG_FILE"

  # Load images tar if needed
  local img_path="${DL_DIR}/$(images_tar_name)"
  if [[ -f "$img_path" ]]; then
    if nerdctl --namespace k8s.io images | awk 'NR>1{print $1":"$2}' | grep -q '.'; then
      log INFO "Images already present in k8s.io; continuing."
    else
      if command -v zstd >/dev/null 2>&1; then
        zstd -d --stdout "$img_path" | nerdctl --namespace k8s.io load >/dev/null 2>>"$LOG_FILE" || true
      else
        die "zstd missing; cannot load images from .zst"
      fi
    fi
  else
    log WARN "Images tar not found; pushing whatever is already in local cache."
  fi

  # Retag & push
  local list
  list="$(nerdctl --namespace k8s.io images --format '{{.Repository}}:{{.Tag}}' | grep -v '^<none>' || true)"
  [[ -n "$list" ]] || die "No images found to push"

  log INFO "Retagging and pushing to ${PRIMARY_REGISTRY}"
  while read -r ref; do
    [[ -z "$ref" ]] && continue
    # Skip if already in target registry
    if [[ "$ref" == ${PRIMARY_REGISTRY}/* ]]; then
      dest="$ref"
    else
      # Keep the original path after the first slash (namespace/image:tag)
      # If image has no slash, keep as-is
      path="${ref}"
      if [[ "$ref" == */* ]]; then
        path="${ref#*/}"
      fi
      dest="${PRIMARY_REGISTRY}/${path}"
    fi
    nerdctl --namespace k8s.io tag "$ref" "$dest" >>"$LOG_FILE" 2>&1 || true
    if [[ -n "${REG_USER:-}" && -n "${REG_PASS:-}" ]]; then
      nerdctl --namespace k8s.io login --username "$REG_USER" --password "$REG_PASS" "${PRIMARY_REGISTRY%%/*}" >>"$LOG_FILE" 2>&1 || true
    fi
    nerdctl --namespace k8s.io push "$dest" >>"$LOG_FILE" 2>&1 || true
    echo "pushed: $dest"
  done <<< "$list"

  echo "[OK] push completed → ${PRIMARY_REGISTRY}"
}

# Image: stage artifacts + write registries.yaml (unified)
action_image() {
  # Allow YAML to set registry settings
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-$(yaml_get "$CONFIG_FILE" primaryRegistry || true)}"
    FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-$(yaml_get "$CONFIG_FILE" fallbackRegistries || true)}"
    REG_USER="${REG_USER:-$(yaml_get "$CONFIG_FILE" registryUser || true)}"
    REG_PASS="${REG_PASS:-$(yaml_get "$CONFIG_FILE" registryPass || true)}"
    REG_CA_FILE="${REG_CA_FILE:-$(yaml_get "$CONFIG_FILE" registryCA || true)}"
    REG_CERT_FILE="${REG_CERT_FILE:-$(yaml_get "$CONFIG_FILE" registryClientCert || true)}"
    REG_KEY_FILE="${REG_KEY_FILE:-$(yaml_get "$CONFIG_FILE" registryClientKey || true)}"
  fi

  ensure_containerd_ready
  ensure_staged_artifacts
  setup_image_resolution_strategy

  echo "[OK] image staging completed"
}

run_rke2_installer() {
  local role="$1" # server|agent
  [[ -n "${RKE2_VERSION:-}" ]] || die "RKE2_VERSION is not set"

  local img_tar="${PRELOAD_DIR}/$(images_tar_name)"
  local rke2_tar="${STAGE_DIR}/$(rke2_tar_name)"
  local sha="${STAGE_DIR}/$(sha_file_name)"
  local inst="${STAGE_DIR}/install.sh"

  [[ -f "$inst" ]] || die "install.sh not found in ${STAGE_DIR}"
  [[ -f "$rke2_tar" ]] || die "RKE2 tar not found in ${STAGE_DIR}"
  [[ -f "$img_tar" ]] || log WARN "Images tar not found; RKE2 may need to pull from registry"

  export INSTALL_RKE2_VERSION="${RKE2_VERSION}"
  export INSTALL_RKE2_SKIP_DOWNLOAD=true
  export INSTALL_RKE2_TARFILE="$rke2_tar"
  export INSTALL_RKE2_IMAGES_TAR="$img_tar"

  spinner_run "Running RKE2 ${role} install (offline)" sh "$inst" "${role}"
}

action_server() {
  # Optional YAML values
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_get "$CONFIG_FILE" rke2Version || true)}"
    PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-$(yaml_get "$CONFIG_FILE" primaryRegistry || true)}"
    FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-$(yaml_get "$CONFIG_FILE" fallbackRegistries || true)}"
    REG_USER="${REG_USER:-$(yaml_get "$CONFIG_FILE" registryUser || true)}"
    REG_PASS="${REG_PASS:-$(yaml_get "$CONFIG_FILE" registryPass || true)}"
    REG_CA_FILE="${REG_CA_FILE:-$(yaml_get "$CONFIG_FILE" registryCA || true)}"
    REG_CERT_FILE="${REG_CERT_FILE:-$(yaml_get "$CONFIG_FILE" registryClientCert || true)}"
    REG_KEY_FILE="${REG_KEY_FILE:-$(yaml_get "$CONFIG_FILE" registryClientKey || true)}"
  fi

  ensure_containerd_ready
  ensure_staged_artifacts
  setup_image_resolution_strategy

  pre_install_verify || die "Pre-install verify failed; fix issues and re-run."

  run_rke2_installer "server"
  echo "[OK] RKE2 server install invoked. Next steps: enable service, verify cluster."
}

action_agent() {
  if [[ -n "${CONFIG_FILE:-}" ]]; then
    RKE2_VERSION="${RKE2_VERSION:-$(yaml_get "$CONFIG_FILE" rke2Version || true)}"
    PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-$(yaml_get "$CONFIG_FILE" primaryRegistry || true)}"
    FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-$(yaml_get "$CONFIG_FILE" fallbackRegistries || true)}"
    REG_USER="${REG_USER:-$(yaml_get "$CONFIG_FILE" registryUser || true)}"
    REG_PASS="${REG_PASS:-$(yaml_get "$CONFIG_FILE" registryPass || true)}"
    REG_CA_FILE="${REG_CA_FILE:-$(yaml_get "$CONFIG_FILE" registryCA || true)}"
    REG_CERT_FILE="${REG_CERT_FILE:-$(yaml_get "$CONFIG_FILE" registryClientCert || true)}"
    REG_KEY_FILE="${REG_KEY_FILE:-$(yaml_get "$CONFIG_FILE" registryClientKey || true)}"
  fi

  ensure_containerd_ready
  ensure_staged_artifacts
  setup_image_resolution_strategy

  pre_install_verify || die "Pre-install verify failed; fix issues and re-run."

  run_rke2_installer "agent"
  echo "[OK] RKE2 agent install invoked. Configure server URL/token in /etc/rancher/rke2/config.yaml."
}

usage() {
  cat <<EOF
${SCRIPT_NAME} - Pre-warm, push, and install RKE2 (offline-friendly)

USAGE:
  ${SCRIPT_NAME} ACTION [options]

ACTIONS:
  pull      Cache RKE2 artifacts and nerdctl-full bundle locally.
  push      Retag and push images to a target registry.
  image     Stage artifacts and write unified registries.yaml.
  server    Install RKE2 server using cached artifacts (offline-safe).
  agent     Install RKE2 agent using cached artifacts (offline-safe).
  verify    Run verification checks (pre/post).

COMMON OPTIONS:
  -f FILE   YAML config file with keys (any may be omitted):
              rke2Version: v1.34.1+rke2r1
              primaryRegistry: kuberegistry.dev.kube/rke2
              fallbackRegistries: mirror1.dev.kube,mirror2.dev.kube
              registryUser: myuser
              registryPass: mypass
              registryCA: /path/to/ca.pem
              registryClientCert: /path/to/client.crt
              registryClientKey: /path/to/client.key
  -v VER    RKE2 version (e.g., v1.34.1+rke2r1)
  -r REG    Primary registry (e.g., altregistry.dev.kube/rke2)
  -u USER   Registry username
  -p PASS   Registry password
  --allow-public   Append public registries as final fallbacks (not recommended)
  -h         Show this help

EXAMPLES:
  # 1) Online builder VM collects everything:
  ${SCRIPT_NAME} pull -v v1.34.1+rke2r1

  # 2) Push images into your offline registry:
  ${SCRIPT_NAME} push -r kuberegistry.dev.kube/rke2 -u admin -p 'secret'

  # 3) Stage artifacts + write mirrors file:
  ${SCRIPT_NAME} image -f settings.yaml

  # 4) On the offline VM, install server/agent from cache:
  ${SCRIPT_NAME} server -f settings.yaml
  ${SCRIPT_NAME} agent  -f settings.yaml

  # 5) Verify environment and artifacts:
  ${SCRIPT_NAME} verify

LOGS:
  ${LOG_FILE}

EOF
}

# Argument parsing
ACTION="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f) CONFIG_FILE="$2"; shift 2 ;;
    -v) RKE2_VERSION="$2"; shift 2 ;;
    -r) PRIMARY_REGISTRY="$2"; shift 2 ;;
    -u) REG_USER="$2"; shift 2 ;;
    -p) REG_PASS="$2"; shift 2 ;;
    --allow-public) ALLOW_DEFAULT_PUBLIC="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

# Load YAML defaults if provided
if [[ -n "${CONFIG_FILE:-}" ]]; then
  [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
  RKE2_VERSION="${RKE2_VERSION:-$(yaml_get "$CONFIG_FILE" rke2Version || true)}"
  PRIMARY_REGISTRY="${PRIMARY_REGISTRY:-$(yaml_get "$CONFIG_FILE" primaryRegistry || true)}"
  FALLBACK_REGISTRIES="${FALLBACK_REGISTRIES:-$(yaml_get "$CONFIG_FILE" fallbackRegistries || true)}"
  REG_USER="${REG_USER:-$(yaml_get "$CONFIG_FILE" registryUser || true)}"
  REG_PASS="${REG_PASS:-$(yaml_get "$CONFIG_FILE" registryPass || true)}"
  REG_CA_FILE="${REG_CA_FILE:-$(yaml_get "$CONFIG_FILE" registryCA || true)}"
  REG_CERT_FILE="${REG_CERT_FILE:-$(yaml_get "$CONFIG_FILE" registryClientCert || true)}"
  REG_KEY_FILE="${REG_KEY_FILE:-$(yaml_get "$CONFIG_FILE" registryClientKey || true)}"
fi

# Dispatch
case "${ACTION:-}" in
  pull)   action_pull ;;
  push)   action_push ;;
  image)  action_image ;;
  server) action_server ;;
  agent)  action_agent ;;
  verify) action_verify ;;
  *) usage; exit 2 ;;
esac
