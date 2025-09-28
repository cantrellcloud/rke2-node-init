#!/usr/bin/env bash
#
# rke2kubeconfig
# -----------------------------------------------------------------------------
# Purpose:
#   Merge multiple single-cluster RKE2 kubeconfig files (found in ./kubeconfigs)
#   into a single multi-context kubeconfig named rke2-kubeconfig.yaml.
#
# What it does (per input file named "<cluster>-kubeconfig"):
#   - Prompts you for the API server IP for that cluster and replaces
#     127.0.0.1 in the `server:` URL with your provided IP (port is preserved).
#   - Renames the common "default" names (cluster/user/context/current-context)
#     to the actual cluster name so contexts are unique.
#   - Extracts and base64-decodes `certificate-authority-data` to
#     ./certs/<cluster>.crt (for your reference/audits).
#   - Appends that cluster’s cluster/user/context entries into the unified file.
#
# Output:
#   - ./rke2-kubeconfig.yaml             (merged kubeconfig)
#   - ./certs/<cluster>.crt              (decoded CA cert per cluster)
#
# Optional config file (to avoid prompts):
#   A simple YAML with kind: rke2kubeconfig (see example below) that can
#   predefine server IPs (and optionally the input dir and output path).
#
# Safety:
#   - Uses a temp working directory, cleans up on exit, strict mode enabled.
#   - Validates file name pattern "<cluster>-kubeconfig".
#   - Light IPv4 validation on user input.
#
# Requirements:
#   - Bash 4+ (associative arrays used)
#   - Standard GNU utilities: awk, sed, base64, mktemp
#   - Optional: yq (https://mikefarah.gitbook.io/yq/) if you want non-interactive
#               IP injection from the YAML config file.
#
# Reference:
#   Kubeconfig structure per Kubernetes docs:
#   https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
#
# Usage:
#   ./rke2kubeconfig
#   ./rke2kubeconfig -d kubeconfigs -o rke2-kubeconfig.yaml
#   ./rke2kubeconfig -f rke2kubeconfig.yaml   # use Kind file to pre-fill IPs
#
# Example:
#   kubeconfigs/
#     dc1manager-kubeconfig
#     dc1domain-kubeconfig
#   -> produces rke2-kubeconfig.yaml with two contexts: dc1manager, dc1domain
#
set -euo pipefail

# ------------------------------- Defaults ------------------------------------
SRC_DIR="kubeconfigs"
OUT_FILE="rke2-kubeconfig.yaml"
CERT_DIR="certs"
KIND_FILE=""          # optional: path to YAML with kind: rke2kubeconfig
NONINTERACTIVE=0      # if 1 and config missing values, will fail instead of prompt

# ------------------------------- Helpers -------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
info() { echo "INFO: $*" >&2; }

is_ipv4() {
  # Crude but serviceable IPv4 validation (no CIDR)
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

# Capture a YAML list block by name from a kubeconfig (e.g., clusters/contexts/users)
# Prints the list ITEMS (each beginning with "  - ...") without the top-level key.
extract_yaml_list_items() {
  # $1 file, $2 section (clusters|contexts|users)
  awk -v section="$2" '
    $0 ~ "^"section":" {insec=1; next}
    insec && $0 ~ "^[^[:space:]]" {insec=0}  # hit next top-level key
    insec { print }
  ' "$1"
}

# Extract the base64 CA data value (first occurrence)
extract_ca_b64() {
  # $1 file
  awk '
    $1 == "certificate-authority-data:" {
      print $2; exit
    }
  ' "$1"
}

# Replace 127.0.0.1 (or localhost) in the server URL with provided IP.
# Preserves scheme and port.
# Example: server: https://127.0.0.1:6443 -> server: https://10.0.4.51:6443
rewrite_server_ip_inplace() {
  # $1 file, $2 ip
  local file="$1" ip="$2"
  # Only touch lines that contain server: https://127.0.0.1 or localhost
  sed -E -i \
    -e "s#(server:[[:space:]]*https://)(127\.0\.0\.1|localhost)(:[0-9]+)#\1${ip}\3#g" \
    "$file"
}

# Rename the repeated "default" identifiers to the cluster name, safely:
# - name: default          -> - name: <cluster>
#   cluster: default       ->   cluster: <cluster>
#   user: default          ->   user: <cluster>
# current-context: default -> current-context: <cluster>
rename_default_identifiers_inplace() {
  # $1 file, $2 cluster
  local file="$1" cluster="$2"
  # Anchored, exact "default" to avoid collateral replacements.
  # Note: we intentionally replace "name:" in both cluster/user/context lists.
  sed -E -i \
    -e "s/^([[:space:]]*name:[[:space:]]*)default[[:space:]]*$/\1${cluster}/" \
    -e "s/^([[:space:]]*cluster:[[:space:]]*)default[[:space:]]*$/\1${cluster}/" \
    -e "s/^([[:space:]]*user:[[:space:]]*)default[[:space:]]*$/\1${cluster}/" \
    -e "s/^(current-context:[[:space:]]*)default[[:space:]]*$/\1${cluster}/" \
    "$file"
}

# Decode CA and write a .crt
write_ca_cert() {
  # $1 file, $2 cluster, $3 dest dir
  local file="$1" cluster="$2" dstdir="$3"
  local b64
  b64="$(extract_ca_b64 "$file" || true)"
  if [[ -z "${b64}" || "${b64}" == "null" ]]; then
    warn "No certificate-authority-data found in $(basename "$file"); skipping cert for ${cluster}"
    return 0
  fi
  mkdir -p "$dstdir"
  echo "$b64" | base64 -d > "${dstdir}/${cluster}.crt"
  info "Wrote CA cert: ${dstdir}/${cluster}.crt"
}

# If yq is available and a Kind file provided, load IPs and options.
declare -A CFG_IPS   # cluster -> ip
CFG_DIR=""
CFG_OUT=""
load_kind_file_if_any() {
  [[ -z "$KIND_FILE" ]] && return 0
  [[ -f "$KIND_FILE" ]] || die "Kind file not found: $KIND_FILE"

  # Check kind (quick & dirty)
  grep -qE '^kind:[[:space:]]*rke2kubeconfig[[:space:]]*$' "$KIND_FILE" \
    || die "Kind file must have: kind: rke2kubeconfig"

  if command -v yq >/dev/null 2>&1; then
    # Read top-level defaults
    CFG_DIR="$(yq -r '.spec.kubeconfigDir // ""' "$KIND_FILE")"
    CFG_OUT="$(yq -r '.spec.output // ""' "$KIND_FILE")"
    # Load cluster IPs (and, optionally, file names)
    # Rows like "name|ip|kubeconfig"
    mapfile -t rows < <(yq -r '.spec.clusters[] | "\(.name)|\(.serverIP // "")|\(.kubeconfig // "")"' "$KIND_FILE")
    for row in "${rows[@]}"; do
      IFS='|' read -r nm ip fpath <<<"$row"
      [[ -n "$ip" ]] && CFG_IPS["$nm"]="$ip"
      # If kubeconfig file path given, we allow it to live alongside the name pattern.
      # We’ll prefer explicit path when iterating files. (Handled later.)
    done
  else
    warn "yq not found. The Kind file will NOT be parsed; falling back to interactive prompts."
  fi
}

# Prompt (unless we already have it via Kind file) for the cluster IP.
get_cluster_ip() {
  # $1 cluster
  local cluster="$1" ip=""
  if [[ -n "${CFG_IPS[$cluster]:-}" ]]; then
    echo "${CFG_IPS[$cluster]}"
    return 0
  fi
  if (( NONINTERACTIVE == 1 )); then
    die "Missing IP for cluster '${cluster}' and non-interactive mode set."
  fi
  while :; do
    read -rp "Enter API server IP for cluster '${cluster}': " ip
    if is_ipv4 "$ip"; then
      echo "$ip"
      return 0
    fi
    echo "That doesn't look like an IPv4 address. Try again." >&2
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -d DIR    Source kubeconfig directory (default: kubeconfigs)
  -o FILE   Output merged kubeconfig (default: rke2-kubeconfig.yaml)
  -f FILE   YAML Kind file (kind: rke2kubeconfig) to predefine IPs/paths
  -n        Non-interactive (fail if an IP is missing instead of prompting)
  -h        Help

Notes:
- Input files must be named "<cluster>-kubeconfig".
- For each file, 127.0.0.1 (or localhost) in the server URL is replaced with the provided IP.
- "default" names are renamed to the cluster name to keep entries unique.
EOF
}

# ------------------------------ Arg Parsing ----------------------------------
while getopts ":d:o:f:nh" opt; do
  case "$opt" in
    d) SRC_DIR="$OPTARG" ;;
    o) OUT_FILE="$OPTARG" ;;
    f) KIND_FILE="$OPTARG" ;;
    n) NONINTERACTIVE=1 ;;
    h) usage; exit 0 ;;
    \?) die "Unknown option: -$OPTARG" ;;
    :)  die "Option -$OPTARG requires an argument" ;;
  esac
done

# ------------------------------ Prep & Checks --------------------------------
[[ -d "$SRC_DIR" ]] || die "Input directory not found: $SRC_DIR"
mkdir -p "$CERT_DIR"

# Load Kind file if provided
load_kind_file_if_any
[[ -n "$CFG_DIR" ]] && SRC_DIR="$CFG_DIR"
[[ -n "$CFG_OUT" ]] && OUT_FILE="$CFG_OUT"

# Working dir for temp copies
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# -------------------------- Gather Input Files --------------------------------
# Collect all files matching "<cluster>-kubeconfig". We keep absolute paths.
shopt -s nullglob
mapfile -t INPUT_FILES < <(find "$SRC_DIR" -maxdepth 1 -type f -name "*-kubeconfig" | sort)
shopt -u nullglob

((${#INPUT_FILES[@]} > 0)) || die "No input files found in ${SRC_DIR} matching '*-kubeconfig'."

# ------------------------------ Process Files ---------------------------------
# We'll build three accumulator files to hold the merged list items.
CLUSTERS_TMP="${WORKDIR}/clusters.yaml"
CONTEXTS_TMP="${WORKDIR}/contexts.yaml"
USERS_TMP="${WORKDIR}/users.yaml"
: > "$CLUSTERS_TMP"
: > "$CONTEXTS_TMP"
: > "$USERS_TMP"

FIRST_CLUSTER=""
for inpath in "${INPUT_FILES[@]}"; do
  base="$(basename "$inpath")"
  cluster="${base%-kubeconfig}"
  [[ -n "$cluster" && "$cluster" != "$base" ]] || die "Input file must be named '<cluster>-kubeconfig': $base"

  [[ -z "$FIRST_CLUSTER" ]] && FIRST_CLUSTER="$cluster"

  # Copy to temp so we can edit safely
  tmp="${WORKDIR}/${cluster}.kubeconfig"
  cp -f -- "$inpath" "$tmp"

  # Get IP (Kind-file or prompt)
  ip="$(get_cluster_ip "$cluster")"
  info "Using API server IP for ${cluster}: ${ip}"

  # Rewrite server IP (preserve port)
  rewrite_server_ip_inplace "$tmp" "$ip"

  # Rename default identifiers to cluster name
  rename_default_identifiers_inplace "$tmp" "$cluster"

  # Decode CA
  write_ca_cert "$tmp" "$cluster" "$CERT_DIR"

  # Extract list items and append into accumulators
  # Note: result items already include leading indentation (two spaces).
  extract_yaml_list_items "$tmp" clusters >> "$CLUSTERS_TMP"
  extract_yaml_list_items "$tmp" contexts >> "$CONTEXTS_TMP"
  extract_yaml_list_items "$tmp" users    >> "$USERS_TMP"
done

# ----------------------------- Write Output -----------------------------------
# Compose a valid kubeconfig with merged lists.
{
  cat <<EOF
apiVersion: v1
kind: Config
preferences: {}
current-context: ${FIRST_CLUSTER}
clusters:
$(sed 's/^/  /' "$CLUSTERS_TMP" | sed 's/^    -/  -/g')
contexts:
$(sed 's/^/  /' "$CONTEXTS_TMP" | sed 's/^    -/  -/g')
users:
$(sed 's/^/  /' "$USERS_TMP" | sed 's/^    -/  -/g')
EOF
} > "$OUT_FILE"

info "Wrote merged kubeconfig: $OUT_FILE"
info "Tip: export KUBECONFIG=\$PWD/${OUT_FILE} and run 'kubectl config get-contexts' to verify."
