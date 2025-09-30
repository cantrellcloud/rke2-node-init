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


# -----------------------------------------------------------------------------
# Custom CA staging helpers (no generation during image())
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Custom Cluster CA consumption (server/agent phases)
# - Prefer staged downloads/custom-ca/*
# - Else, generate via downloads/generate-custom-ca-certs.sh (offline)
# - Install CA into OS trust and lay down RKE2 TLS CAs
# -----------------------------------------------------------------------------

ensure_pkix_tools() {
  if ! command -v openssl >/dev/null 2>&1; then
    log INFO "Installing minimal crypto tools (openssl, ca-certificates)"
    if command -v apt-get >/dev/null 2>&1; then
      DEBIAN_FRONTEND=noninteractive apt-get update -y -qq || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssl ca-certificates || {
        log ERROR "Failed to install openssl/ca-certificates"; return 1; }
    else
      log WARN "Non-APT distro; please ensure openssl & ca-certificates are present"
    fi
  fi
  update-ca-certificates >/dev/null 2>&1 || true
}

stage_dir_for_custom_ca() {
  local d="${PROJECT_ROOT:-/rke2-node-init}/downloads/custom-ca"
  mkdir -p "$d"
  echo "$d"
}

# returns 0 if either already present or can be generated; sets ROOT_CERT, ROOT_KEY, and optionally INT_CERT, INT_KEY
obtain_root_ca_material() {
  local d; d="$(stage_dir_for_custom_ca)"
  ROOT_CERT="$d/root.crt"; ROOT_KEY="$d/root.key"
  INT_CERT=""; INT_KEY=""

  if [[ -f "$d/intermediate.crt" && -f "$d/intermediate.key" ]]; then
    INT_CERT="$d/intermediate.crt"; INT_KEY="$d/intermediate.key"
  fi

  if [[ -f "$ROOT_CERT" && -f "$ROOT_KEY" ]]; then
    log INFO "Found staged root CA at $d"
    return 0
  fi

  local helper="${PROJECT_ROOT:-/rke2-node-init}/downloads/generate-custom-ca-certs.sh"
  if [[ -x "$helper" ]]; then
    log INFO "No staged root CA; generating root via helper (server/agent phase)"
    "$helper" --out-dir "$d" --cn "RKE2 Cluster Root CA" || {
      log ERROR "Root CA generation failed"; return 1; }
    log OK "Generated root CA at $d"
    return 0
  fi

  log WARN "No staged CA and no helper present; skipping custom cluster CA"
  return 1
}

# Generates component CA pairs signed by either ROOT or INTERMEDIATE (if provided)
generate_component_cas() {
  local out="${1:?outdir required}"
  mkdir -p "$out" "$out/etcd"

  local signer_cert="$ROOT_CERT"; local signer_key="$ROOT_KEY"
  if [[ -n "${INT_CERT:-}" && -n "${INT_KEY:-}" ]]; then
    signer_cert="$INT_CERT"; signer_key="$INT_KEY"
    log INFO "Using INTERMEDIATE as signer for component CAs"
  fi

  gen_ca() {
    local name="$1"; local cn="$2"
    openssl genrsa -out "${out}/${name}.key" 4096
    openssl req -new -key "${out}/${name}.key" -subj "/CN=${cn}" -out "${out}/${name}.csr"
    cat > "${out}/${name}.cnf" <<EOCNF
basicConstraints=CA:TRUE
keyUsage=keyCertSign, cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
EOCNF
    openssl x509 -req -in "${out}/${name}.csr" -CA "$signer_cert" -CAkey "$signer_key" -CAcreateserial -out "${out}/${name}.crt" -days 3650 -sha256 -extfile "${out}/${name}.cnf"
    rm -f "${out}/${name}.csr" "${out}/${name}.cnf" "${out}/${name}.crt.srl"
  }

  gen_ca "server-ca" "kubernetes-ca"
  gen_ca "client-ca" "kubernetes-client-ca"
  gen_ca "request-header-ca" "kube-aggregator-ca"
  # etcd CA set
  gen_ca "etcd/server-ca" "etcd-server-ca"
  gen_ca "etcd/peer-ca" "etcd-peer-ca"
  gen_ca "etcd/client-ca" "etcd-client-ca"
}

install_into_rke2_tls() {
  local base="/var/lib/rancher/rke2/server/tls"
  mkdir -p "$base" "$base/etcd"
  install -m 0644 "$ROOT_CERT" "$base/ca.crt" || true  # root chain for reference

  # Move generated CA pairs into their expected locations
  install -m 0600 "$1/server-ca.key"            "$base/server-ca.key"
  install -m 0644 "$1/server-ca.crt"            "$base/server-ca.crt"
  install -m 0600 "$1/client-ca.key"            "$base/client-ca.key"
  install -m 0644 "$1/client-ca.crt"            "$base/client-ca.crt"
  install -m 0600 "$1/request-header-ca.key"    "$base/request-header-ca.key"
  install -m 0644 "$1/request-header-ca.crt"    "$base/request-header-ca.crt"

  install -m 0600 "$1/etcd/server-ca.key"       "$base/etcd/server-ca.key"
  install -m 0644 "$1/etcd/server-ca.crt"       "$base/etcd/server-ca.crt"
  install -m 0600 "$1/etcd/peer-ca.key"         "$base/etcd/peer-ca.key"
  install -m 0644 "$1/etcd/peer-ca.crt"         "$base/etcd/peer-ca.crt"
  install -m 0600 "$1/etcd/client-ca.key"       "$base/etcd/client-ca.key"
  install -m 0644 "$1/etcd/client-ca.crt"       "$base/etcd/client-ca.crt"

  log OK "Installed custom cluster CA set into ${base}"
}

install_root_into_os_trust() {
  local target="/usr/local/share/ca-certificates/rke2-cluster-root.crt"
  install -m 0644 "$ROOT_CERT" "$target"
  update-ca-certificates || true
  log OK "Installed root CA into OS trust"
}

verify_custom_cluster_ca() {
  local base="/var/lib/rancher/rke2/server/tls"
  local ok=1
  for f in server-ca.crt client-ca.crt request-header-ca.crt etcd/server-ca.crt etcd/peer-ca.crt etcd/client-ca.crt; do
    if [[ ! -s "${base}/${f}" ]]; then ok=0; log ERROR "Missing ${base}/${f}"; fi
  done
  if [[ $ok -eq 1 ]]; then
    log OK "Custom cluster CA verification passed"
  else
    log WARN "Custom cluster CA verification failed"
  fi
  return $(( ok==1 ? 0 : 1 ))
}

custom_ca_server_workflow() {
  ensure_pkix_tools || return 0
  if obtain_root_ca_material; then
    local tmpdir; tmpdir="$(mktemp -d)"
    generate_component_cas "$tmpdir"
    install_into_rke2_tls "$tmpdir"
    install_root_into_os_trust
    verify_custom_cluster_ca || true
    rm -rf "$tmpdir"
  else
    log INFO "Continuing without custom cluster CA"
  fi
}

custom_ca_agent_workflow() {
  ensure_pkix_tools || return 0
  local d; d="$(stage_dir_for_custom_ca)"
  ROOT_CERT="$d/root.crt"
  if [[ -f "$ROOT_CERT" ]]; then
    install_root_into_os_trust
  else
    log INFO "No staged root CA for agent; skipping OS trust install"
  fi
}



# Normalize common truthy/falsey inputs to 1/0
bool_to_10() {
  local v="${1:-}"
  case "${v,,}" in
    1|true|yes|y|on) echo 1 ;;
    0|false|no|n|off|"") echo 0 ;;
    *) echo 0 ;;
  esac
}

# Read a nested key under spec.* with simple dotted path (best-effort YAML grep)
# Usage: yaml_spec_get_nested <yaml-file> <dotted.path>
yaml_spec_get_nested() {
  local file="$1"; local path="$2"
  # very lightweight grep-based extractor for simple YAML (no lists)
  # splits dotted path and searches for 'spec: ... key:' style hierarchy
  awk -v path="$path" '
    function trim(s){ sub(/^[[:space:]]+/,"",s); sub(/[[:space:]]+$/,"",s); return s }
    BEGIN {
      n = split(path, parts, /\./)
      level = 0
    }
    /^[[:space:]]*spec:[[:space:]]*$/ { in_spec=1; stacklevel=0; next }
    in_spec {
      if (match($0,/^([[:space:]]*)([^:#]+):[[:space:]]*(.*)$/, m)) {
        indent = length(m[1])
        key    = trim(m[2])
        val    = trim(m[3])
        # adjust stack based on indent (2-space step heuristic)
        while (stack_indents[stacklevel] > indent && stacklevel>0) { delete stack_keys[stacklevel]; delete stack_indents[stacklevel]; stacklevel-- }
        if (stack_indents[stacklevel] != indent) { stacklevel++ ; stack_indents[stacklevel]=indent }
        stack_keys[stacklevel]=key

        # build current path
        cur=""
        for (i=1;i<=stacklevel;i++){ if (cur=="") cur=stack_keys[i]; else cur=cur"."stack_keys[i] }
        if (cur==path) {
          # print the value for leaf
          print val
          exit
        }
      }
    }
  ' "$file" | sed -E 's/^"?(.*)"?$/\1/; s/^'\''?(.*)'\''?$/\1/'
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
  sudo ./rke2nodeinit.sh [options] <image|push|server|add-server|agent|verify>

Actions:
  image        Prepare a *minimal* Ubuntu 24.04 image for air-gapped RKE2.
               - Install only curl and ca-certificates
               - Enable overlay & br_netfilter, set bridge-nf + ip_forward sysctls
               - Disable swap (now and via /etc/fstab comments)
               - Configure NetworkManager (if present) to ignore CNI (cni*, flannel*)
               - (If ufw is active) allow 6443/tcp, 9345/tcp, 10250/tcp, 8472/udp
               - Cache RKE2 artifacts (tarball, images, checksums, install.sh)
               - Stage images to /var/lib/rancher/rke2/agent/images/
               - Install nerdctl CLI *only* (no containerd)
               - Prompt for reboot when complete

  push         (If implemented in your workflow) Push pre-fetched RKE2 images to a private registry.
               Honors --dry-push to simulate.

  server       Finalize the node as an RKE2 server (control-plane). Expects the 'image' action to have run.

  add-server   Add an additional RKE2 server node to an existing cluster (HA control-plane).

  agent        Finalize the node as an RKE2 agent (worker). Expects the 'image' action to have run.

  verify       Run post-install checks (services, kubelet, cluster reachability, etc.).

YAML Spec (rkeprep/v1):
  apiVersion: rkeprep/v1
  kind: Image|Push|Server|AddServer|Agent|Verify
  spec:
    rke2Version: "v1.34.1+rke2r1"   # optional; if omitted the script auto-detects latest
    registry: "reg.example.org/rke2" # optional; used by push
    nerdctlInstall: true              # optional; defaults to true in 'image'

Options:
  -f FILE     YAML config
  -v VER      RKE2 version tag (e.g., v1.34.1+rke2r1). If omitted, auto-detect latest
  -r REG      Private registry (host[/namespace]), e.g., reg.example.org/rke2
  -u USER     Registry username
  -p PASS     Registry password
  -y          Auto-confirm prompts (e.g., reboot)
  -P          Print sanitized YAML to screen (masks secrets)
  -h          Show this help
  --dry-push  Do not actually push images to registry (simulate only)

Examples:
  sudo ./rke2nodeinit.sh -f clusters/image.yaml image
  sudo ./rke2nodeinit.sh -f clusters/server.yaml server
  sudo ./rke2nodeinit.sh -f clusters/agent.yaml agent
  sudo ./rke2nodeinit.sh -f clusters/verify.yaml verify
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

# ---------- OS prereqs --------------------------------------------------------------------------
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

  if command -v nerdctl &>/dev/null; then
    log INFO "Runtime OK: nerdctl"
  else
    log ERROR "nerdctl not ready"; fail=1
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

# ==============
# Action: SERVER
action_server() {
  # Consume staged or generate custom cluster CA before RKE2 start
  custom_ca_server_workflow
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

  if [[ -z "$IP"       ]]; then read -rp "Enter static IPv4 for this server node: " IP; fi
  if [[ -z "$PREFIX"   ]]; then read -rp "Enter subnet prefix length (0-32) [default 24]: " PREFIX; fi
  if [[ -z "$HOSTNAME" ]]; then read -rp "Enter hostname for this server node: " HOSTNAME; fi
  if [[ -z "$GW"       ]]; then read -rp "Enter default gateway IPv4 [leave blank to skip]: " GW || true; fi
  log INFO "Gateway entered (server): ${GW:-<none>}"

  if [[ -z "$DNS" ]]; then
    read -rp "Enter DNS IPv4s (comma-separated) [blank=default ${DEFAULT_DNS}]: " DNS || true
    if [[ -z "$DNS" ]]; then DNS="$DEFAULT_DNS"; log INFO "Using default DNS for server: $DNS"; fi
  fi

  if [[ -z "$SEARCH" && -n "${DEFAULT_SEARCH:-}" ]]; then
    SEARCH="$DEFAULT_SEARCH"
    log INFO "Using default search domains for server: $SEARCH"
  fi

  while ! valid_ipv4 "$IP"; do read -rp "Invalid IPv4. Re-enter server IP: " IP; done
  while ! valid_prefix "${PREFIX:-}"; do read -rp "Invalid prefix (0-32). Re-enter server prefix [default 24]: " PREFIX; done
  while ! valid_ipv4_or_blank "${GW:-}"; do read -rp "Invalid gateway IPv4 (or blank). Re-enter: " GW; done
  while ! valid_csv_dns "${DNS:-}"; do read -rp "Invalid DNS list. Re-enter CSV IPv4s: " DNS; done
  while ! valid_search_domains_csv "${SEARCH:-}"; do read -rp "Invalid search domain list. Re-enter CSV: " SEARCH; done
  [[ -z "${PREFIX:-}" ]] && PREFIX=24

  log INFO "Ensuring staged artifacts for offline RKE2 server install..."
  ensure_staged_artifacts
  local SRC="$STAGE_DIR"

  ensure_containerd_ready
  # Ensure local images and registries fallback chain are in place
  #setup_image_resolution_strategy
  # Ensure local images win first; if a registry is configured, also retag and write mirrors
  if [[ -f "$CONFIG_FILE" ]] && [[ -n "$(yaml_spec_get "$CONFIG_FILE" registry || true)" ]]; then
    setup_image_resolution_strategy
  else
    # No registry configured: make sure system-default-registry is not set, and no registries.yaml
    sed -i '/^system-default-registry:/d' /etc/rancher/rke2/config.yaml 2>/dev/null || true
    rm -f /etc/rancher/rke2/registries.yaml 2>/dev/null || true
  fi

  log INFO "Seeding custom cluster CA (if provided)..."
  setup_custom_cluster_ca || true
  log INFO "Proceeding with offline RKE2 server install..."
  run_rke2_installer "$SRC" "server"

  systemctl enable rke2-server >>"$LOG_FILE" 2>&1 || true

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

# =============
# Action: AGENT
action_agent() {
  # Install root CA into OS trust if staged
  custom_ca_agent_workflow
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
    URL="$(yaml_spec_get "$CONFIG_FILE" serverURL || true)"
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

  ensure_containerd_ready
  # Ensure local images and registries fallback chain are in place
  #setup_image_resolution_strategy
  log INFO "Proceeding with offline RKE2 agent install..."
  run_rke2_installer "$SRC" "agent"

  systemctl enable rke2-agent >>"$LOG_FILE" 2>&1 || true

  mkdir -p /etc/rancher/rke2
  if [[ -n "$URL" ]];   then echo "server: \"$URL\"" >> /etc/rancher/rke2/config.yaml; fi
  if [[ -n "$TOKEN" ]]; then echo "token: \"$TOKEN\""  >> /etc/rancher/rke2/config.yaml; fi

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
  push)   action_push   ;;
  image)  action_image  ;;
  server) action_server ;;
  add-server) action_add_server ;;
  agent)  action_agent  ;;
  verify) action_verify ;;
  *) print_help; exit 1 ;;
esac
