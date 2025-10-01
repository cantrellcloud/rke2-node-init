Nice—here’s a tight patch that auto-derives sensible TLS SANs and drops in safe kubelet defaults for both a fresh Server bootstrap and AddServer joins. It won’t step on your offline flow.

---

# 1) Auto-TLS SANs + kubelet defaults (used by Server & AddServer)

Drop this helper near your other small helpers:

```bash
# Build a comma CSV of default SANs from hostname/IP/search domains.
# usage: _autosan_csv "<HOSTNAME>" "<IP>" "<SEARCH_CSV>"
_autosan_csv() {
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
```

And this tiny writer (keeps `config.yaml` clean):

```bash
# Emit a tls-san: list given a CSV string (no empty lines)
_emit_tls_san_yaml() {
  local csv="$1"
  [[ -z "$csv" ]] && return 0
  echo "tls-san:"
  IFS=',' read -r -a _sans <<<"$csv"
  for s in "${_sans[@]}"; do
    s="${s//\"/}"; s="${s// /}"
    [[ -n "$s" ]] && echo "  - \"$s\""
  done
}
```

---

# 2) Update: `action_server()` (defaults wired in)

Replace your `action_server()` with this version (same behavior you approved, now with auto-SANs and kubelet args):

```bash
# ==============
# Action: SERVER (bootstrap a brand-new control plane)
# Uses cached artifacts from action_image() and writes /etc/rancher/rke2/config.yaml
action_server() {
  if [[ -n "$CONFIG_FILE" ]]; then ensure_yaml_has_metadata_name "$CONFIG_FILE"; fi
  load_site_defaults

  local IP="" PREFIX="" HOSTNAME="" DNS="" SEARCH="" GW=""
  local TLS_SANS_IN="" TLS_SANS="" TOKEN="" CLUSTER_INIT="true"

  if [[ -n "$CONFIG_FILE" ]]; then
    IP="$(yaml_spec_get "$CONFIG_FILE" ip || true)"
    PREFIX="$(yaml_spec_get "$CONFIG_FILE" prefix || true)"
    HOSTNAME="$(yaml_spec_get "$CONFIG_FILE" hostname || true)"
    GW="$(yaml_spec_get "$CONFIG_FILE" gateway || true)"
    local d sd ts
    d="$(yaml_spec_get "$CONFIG_FILE" dns || true)"; [[ -n "$d"  ]] && DNS="$(normalize_list_csv "$d")"
    sd="$(yaml_spec_get "$CONFIG_FILE" searchDomains || true)"; [[ -n "$sd" ]] && SEARCH="$(normalize_list_csv "$sd")"
    ts="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"; [[ -n "$ts" ]] && TLS_SANS_IN="$(normalize_list_csv "$ts")"
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
    TLS_SANS="$(_autosan_csv "$HOSTNAME" "$IP" "$SEARCH")"
    log INFO "Auto-derived TLS SANs: $TLS_SANS"
  fi

  ensure_staged_artifacts
  install_rke2_prereqs

  hostnamectl set-hostname "$HOSTNAME"
  if ! grep -qE "[[:space:]]$HOSTNAME(\$|[[:space:]])" /etc/hosts; then echo "$IP $HOSTNAME" >> /etc/hosts; fi
  write_netplan "$IP" "$PREFIX" "${GW:-}" "${DNS:-}" "${SEARCH:-}"

  mkdir -p /etc/rancher/rke2
  : > /etc/rancher/rke2/config.yaml
  {
    echo "cluster-init: ${CLUSTER_INIT}"
    echo "node-ip: \"$IP\""
    _emit_tls_san_yaml "$TLS_SANS"

    # Kubelet defaults (safe; additive). Merge-friendly if you later append more.
    echo "kubelet-arg:"
    # Prefer systemd-resolved if present
    if [[ -f /run/systemd/resolve/resolv.conf ]]; then
      echo "  - resolv-conf=/run/systemd/resolve/resolv.conf"
    fi
    echo "  - container-log-max-size=10Mi"
    echo "  - container-log-max-files=5"
    echo "  - protect-kernel-defaults=true"

    # Optional but recommended: stable join secret for future nodes
    if [[ -n "$TOKEN" ]]; then
      echo "token: \"$TOKEN\""
    fi

    echo "write-kubeconfig-mode: \"0640\""
    # Leave system-default-registry unset to preserve cached naming.
  } >> /etc/rancher/rke2/config.yaml
  chmod 600 /etc/rancher/rke2/config.yaml
  log INFO "Wrote /etc/rancher/rke2/config.yaml (cluster-init=${CLUSTER_INIT})"

  setup_custom_cluster_ca || true

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
```

---

# 3) Update: `action_add_server()` (defaults wired in too)

Right after you parse the YAML and validate `serverURL` + `token`, inject this block to compute SANs and write kubelet defaults if your function doesn’t already do so:

```bash
  # Derive TLS SANs if not provided
  local TLS_SANS_IN TLS_SANS
  TLS_SANS_IN="$(yaml_spec_get "$CONFIG_FILE" tlsSans || true)"
  if [[ -n "$TLS_SANS_IN" ]]; then
    TLS_SANS="$(normalize_list_csv "$TLS_SANS_IN")"
  else
    TLS_SANS="$(_autosan_csv "$HOSTNAME" "$IP" "$SEARCH")"
    log INFO "Auto-derived TLS SANs: $TLS_SANS"
  fi

  mkdir -p /etc/rancher/rke2
  : > /etc/rancher/rke2/config.yaml
  {
    echo "server: \"$SERVER_URL\""     # required
    echo "token: \"$TOKEN\""           # required
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
```

(Leave your existing install/start logic intact—this only improves the config emitted.)

---

# 4) Dispatcher reminder

If you haven’t already, make sure both `add-server` and `add_server` route to your join function:

```bash
case "${ACTION:-}" in
  image)        action_image   ;;
  server)       action_server  ;;
  agent)        action_agent   ;;
  verify)       action_verify  ;;
  add-server|add_server) action_add_server ;;
  push)         action_push    ;;
  *)            print_help; exit 1 ;;
esac
```

---

### Why these defaults?

* **TLS SANs**: short hostname + IP cover most cases; appending `hostname.searchdomain` prevents the classic x509 mismatch when clients resolve via FQDN.
* **Kubelet args**:

  * `resolv-conf=/run/systemd/resolve/resolv.conf` avoids kubelet reading a stale `/etc/resolv.conf` on Ubuntu 24.04.
  * `container-log-max-*` curbs runaway logs on small nodes.
  * `protect-kernel-defaults=true` keeps kubelet from silently overriding sysctls you hardened in `action_image()`.

If you want me to also merge user-provided `kubelet-arg` entries from YAML (and de-dupe against these defaults), I can wire that too.
