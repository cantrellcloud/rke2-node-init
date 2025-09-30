Yep, makes sense — and I wired it up.

I patched your script so **`action_server()`** and **`action_agent()`** both:

* **Install RKE2 strictly from the cached artifacts** staged by `action_image()` (`ensure_staged_artifacts` + `run_rke2_installer "$STAGE_DIR" ...`).
* **Accept YAML** (kind: `Server` / `Agent`) with fields that track the RKE2 config keys you pointed at (token/tokenFile, tls SANs, node IPs, CIDRs, domain, etc.).
* **Fallback order**: YAML → CLI flags → interactive prompts.
* **Write `/etc/rancher/rke2/config.yaml`** from the inputs.
* **Update the local OS trust store** when a CA cert is provided (agent) or when a custom cluster CA is requested (server).
* **Keep the reboot prompt last**, after everything else.

Download the updated file:

* **[rke2nodeinit.patched.sh](sandbox:/mnt/data/rke2nodeinit.patched.sh)**

### What changed (quick tour)

* **Server**

  * Parses YAML `spec` keys:

    * `token`, `tokenFile`, `tlsSans`, `nodeIP`, `nodeExternalIP`, `serviceCIDR`, `clusterCIDR`, `clusterDomain`, `writeKubeconfigMode`
    * Custom CA (optional): `customCARootCrt`, `customCARootKey`, `customCAIntermediateCrt`, `customCAIntermediateKey`, `customCAInstallToOSTrust`
  * New per-action flags (when not using `-f`):

    * `-t` TOKEN, `-T` TOKEN_FILE, `-l` TLS_SANS (CSV), `-n` NODE_IP, `-e` NODE_EXTERNAL_IP,
      `-S` SERVICE_CIDR, `-C` CLUSTER_CIDR, `-D` CLUSTER_DOMAIN, `-M` WRITE_KUBECONFIG_MODE,
      `-R` ROOT_CRT, `-K` ROOT_KEY, `-I` INT_CRT, `-J` INT_KEY, `-X` INSTALL_TRUST(0|1)
  * If any custom-CA inputs are present, it exports them to `setup_custom_cluster_ca` and (optionally) installs the root into the OS trust store.

* **Agent**

  * Parses YAML `spec` keys:

    * `serverURL`, `token`, `tokenFile`, `nodeIP`, `nodeExternalIP`, `tlsSans`, `caCrt` (trusted CA to install locally)
  * New per-action flags:

    * `-s` URL, `-t` TOKEN, `-T` TOKEN_FILE, `-n` NODE_IP, `-e` NODE_EXTERNAL_IP, `-l` TLS_SANS, `-C` CA_CERT
  * Installs the provided `caCrt` (or `-C`) into `/usr/local/share/ca-certificates` and runs `update-ca-certificates`.

* **Help text**: I added concise flag blocks for Server/Agent in the built-in help so you’ve got usage at your fingertips.

### Example runs

YAML (Server):

```bash
sudo ./rke2nodeinit.patched.sh -f server.yaml
# server.yaml
apiVersion: rkeprep/v1
kind: Server
spec:
  ip: 10.0.4.11
  prefix: 24
  hostname: cp-01
  dns: 10.0.4.2,10.0.4.3
  gateway: 10.0.4.1
  tokenFile: /root/rke2.token
  tlsSans: cp-01,10.0.4.11,api.dev.local
  nodeIP: 10.0.4.11
  serviceCIDR: 10.96.0.0/12
  clusterCIDR: 10.42.0.0/16
  clusterDomain: cluster.local
  writeKubeconfigMode: "0640"
  customCARootCrt: /certs/root.crt
  customCARootKey: /certs/root.key
  customCAInstallToOSTrust: true
```

CLI (Agent) — falls back to prompts for anything not given:

```bash
sudo ./rke2nodeinit.patched.sh agent \
  -s https://10.0.4.11:9345 \
  -T /root/rke2.token \
  -n 10.0.4.21 \
  -C /certs/root.crt
```

### Notes

* If you define a registry in your YAML globals, the functions still call your existing `setup_image_resolution_strategy` to write mirrors and lean on the cached image retags. If no registry is defined, I avoid forcing `system-default-registry` and remove any leftover `registries.yaml` to keep lookups local-first.
* The **cluster CA generation** only triggers in `action_server()` if you actually provide any of the `customCA*` inputs (YAML/CLI). Otherwise we don’t touch CA and proceed offline with the cached artifacts.

If you want me to align the YAML key names 1:1 with the exact fields in the blog/docs you sent (including list types vs CSV), I can extend the tiny YAML reader to handle arrays — but the above works right now with simple CSV strings for lists like `tlsSans`.
