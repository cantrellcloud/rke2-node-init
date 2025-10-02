#!/usr/bin/env bats

load './test_helper'

setup() {
  test_setup
}

teardown() {
  test_teardown
}

@test "write_netplan backs up existing files and writes new netplan" {
  echo "network: { }" >"$NETPLAN_DIR/10-old.yaml"

  set +e
  write_netplan "10.20.30.40" "24" "10.20.30.1" "1.1.1.1,1.0.0.1" "example.com"
  status=$?
  set -e
  [ "$status" -eq 0 ]

  new_file="$NETPLAN_DIR/99-rke-static.yaml"
  [ -f "$new_file" ]
  assert_file_contains "$new_file" "- 10.20.30.40/24"
  assert_file_contains "$new_file" "via: 10.20.30.1"
  assert_file_contains "$new_file" "addresses: [1.1.1.1, 1.0.0.1]"
  assert_file_contains "$new_file" "search: [example.com]"

  backup_dir="$(find "$NETPLAN_DIR" -maxdepth 1 -type d -name '.backup-*' | head -n1)"
  [ -n "$backup_dir" ]
  [ -f "$backup_dir/10-old.yaml" ]

  cfg_disable="$CLOUD_CFG_DIR/99-disable-network-config.cfg"
  [ -f "$cfg_disable" ]
  assert_file_contains "$cfg_disable" "network: {config: disabled}"
}

@test "action_server writes configuration using redirected paths" {
  cat <<YAML >"$TEST_ROOT/server.yaml"
apiVersion: rkeprep/v1
kind: Server
metadata:
  name: unit-test
spec:
  hostname: control.example.test
  ip: 10.50.60.70
  prefix: 24
  gateway: 10.50.60.1
  dns: 9.9.9.9
  searchDomains: example.test
  clusterInit: true
  token: secret-token
YAML

  export CONFIG_FILE="$TEST_ROOT/server.yaml"

  set +e
  action_server
  status=$?
  set -e
  [ "$status" -eq 0 ]

  [ -f "$RKE2_CONFIG_FILE" ]
  assert_file_contains "$RKE2_CONFIG_FILE" 'node-ip: "10.50.60.70"'
  assert_file_contains "$RKE2_CONFIG_FILE" 'token: secret-token'
  assert_file_contains "$RKE2_CONFIG_FILE" 'cluster-init: true'

  assert_file_contains "$HOSTS_FILE" "10.50.60.70 control.example.test"

  new_netplan="$NETPLAN_DIR/99-rke-static.yaml"
  [ -f "$new_netplan" ]
  assert_file_contains "$new_netplan" "- 10.50.60.70/24"
}
