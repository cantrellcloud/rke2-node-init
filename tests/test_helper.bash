#!/usr/bin/env bash

_test_repo_root() {
  local dir
  dir="${BATS_TEST_DIRNAME}/.."
  cd "$dir" && pwd -P
}

TEST_REPO_ROOT="$(_test_repo_root)"

assert_file_contains() {
  local file="$1" needle="$2"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "Expected '$file' to contain: $needle" >&2
    return 1
  fi
}

test_setup() {
  ORIG_PATH="$PATH"
  export ORIG_PATH
  PATH="$TEST_REPO_ROOT/tests/stubs:$PATH"

  TEST_ROOT="$(mktemp -d)"
  export TEST_ROOT

  export ETC_DIR="$TEST_ROOT/etc"
  export NETPLAN_DIR="$ETC_DIR/netplan"
  export CLOUD_CFG_DIR="$ETC_DIR/cloud/cloud.cfg.d"
  export HOSTS_FILE="$ETC_DIR/hosts"
  export RKE2_DIR="$ETC_DIR/rancher/rke2"
  export RKE2_CONFIG_FILE="$RKE2_DIR/config.yaml"
  export REGISTRIES_FILE="$RKE2_DIR/registries.yaml"
  export SITE_DEFAULTS_FILE="$ETC_DIR/rke2image.defaults"
  mkdir -p "$NETPLAN_DIR" "$CLOUD_CFG_DIR" "$RKE2_DIR"
  : >"$HOSTS_FILE"

  export LOG_DIR="$TEST_ROOT/logs"
  export OUT_DIR="$TEST_ROOT/outputs"
  export DOWNLOADS_DIR="$TEST_ROOT/downloads"
  export STAGE_DIR="$TEST_ROOT/stage"
  export SBOM_DIR="$TEST_ROOT/sbom"
  export LOG_FILE="$TEST_ROOT/rke2.log"
  mkdir -p "$LOG_DIR" "$OUT_DIR" "$DOWNLOADS_DIR" "$STAGE_DIR" "$SBOM_DIR"

  # shellcheck source=/dev/null
  source "$TEST_REPO_ROOT/rke2nodeinit.sh"

  LOG_DIR="$TEST_ROOT/logs"
  OUT_DIR="$TEST_ROOT/outputs"
  DOWNLOADS_DIR="$TEST_ROOT/downloads"
  STAGE_DIR="$TEST_ROOT/stage"
  SBOM_DIR="$TEST_ROOT/sbom"
  LOG_FILE="$TEST_ROOT/rke2.log"

  PATH="$TEST_REPO_ROOT/tests/stubs:$PATH"

  ensure_staged_artifacts() { return 0; }
  setup_custom_cluster_ca() { return 0; }
  run_rke2_installer() { echo "run_rke2_installer $*" >> "$TEST_ROOT/installer.log"; }
  prompt_reboot() { echo "prompt_reboot" >> "$TEST_ROOT/prompt.log"; }
  spinner_run() {
    local label="$1"; shift
    log INFO "$label..."
    "$@" >>"$LOG_FILE" 2>&1
    log INFO "$label...done"
  }
}

test_teardown() {
  PATH="$ORIG_PATH"
  rm -rf "$TEST_ROOT"
}
