Short version: your first server isn’t told to **initialize the cluster**, so `rke2-server` comes up waiting for an etcd that never gets created. That’s why you see:

* `failed to test etcd connection ... failed to get etcd status rpc error`
* `503 ... runtime core not ready`

Those are classic “no `cluster-init` on the first server” symptoms. In your script’s `action_server()` block, the line that would set `cluster-init` is commented out, and the TLS SAN emission for the first server is also commented. So you boot a server with no `server:` (correct for the first node) but also no `cluster-init: true` (not correct) — result: no embedded etcd is formed and the core never becomes ready.

### Quick fix on the node (no script changes)

Edit `/etc/rancher/rke2/config.yaml` so the first server has at minimum:

```yaml
cluster-init: true
node-ip: "<THIS_NODE_IP>"
# Optional but recommended so future nodes share a stable secret:
# token: "<your-long-random-token>"
# Optional if you connect via IPs/hostnames not auto-included:
# tls-san:
#   - "<hostname>"
#   - "<ip>"
```

Then:

```bash
sudo systemctl enable --now rke2-server
# watch it come up
sudo journalctl -u rke2-server -f
```

### Patch your script (the real fix)

In `action_server()` where you write the initial config, do both of these:

1. **Write `cluster-init`** (default to true if not provided):

```bash
# earlier: optionally read from YAML: CLUSTER_INIT="$(yaml_spec_get "$CONFIG_FILE" clusterInit || echo true)"
# ...
mkdir -p /etc/rancher/rke2
: > /etc/rancher/rke2/config.yaml
{
  echo "cluster-init: ${CLUSTER_INIT:-true}"
  echo "node-ip: \"$IP\""
  emit_tls_sans "$TLS_SANS"     # <-- un-comment (see next point)
  # kubelet args ...
  [[ -n "$TOKEN" ]] && echo "token: \"$TOKEN\""
  echo "write-kubeconfig-mode: \"0640\""
} >> /etc/rancher/rke2/config.yaml
```

2. **Actually emit TLS SANs** for the first server (yours are provided in the YAML):

```bash
# change from:
#   # emit_tls_sans "$TLS_SANS"
# to:
    emit_tls_sans "$TLS_SANS"
```

That’s it. Leave `server:` and `token:` out on the very first control-plane unless you want to pin a token (recommended). For **additional** servers, your `action_add_server()` logic is already writing:

```yaml
server: "https://<bootstrap-or-vip>:9345"
token: "<same-stable-token>"
```

which is correct.

### Sanity checks after the patch

* `journalctl -u rke2-server -n 200 | grep -E 'etcd|apiserver'` should show etcd starting, then API server, then controller/scheduler.
* If you use a **custom cluster CA**, keep it as you have it; just ensure the SANs include whatever name/IP you use to hit the API (you already list them in your YAML).

If you want, I can drop a minimal diff of the exact lines to change in your script, but the two un-comments/additions above are the heart of the issue.
