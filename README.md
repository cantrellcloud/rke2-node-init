# rke2nodeinit — RKE2 Air-Gapped Image Prep (Auto-Kind)

**rke2nodeinit** is a single Bash utility, `rke2nodeinit.sh`, to prep Ubuntu **24.04 LTS** VMs as production-ready **RKE2** (Kubernetes) Server/Agent nodes for **internet-limited or air-gapped** environments.

> ### New behavior
> When you pass **`-f file.yaml`**, you **do not need a subcommand**.  
> The script reads the YAML’s `kind:` (`Pull`, `Push`, `Image`, `Server`, `Agent`) and runs the correct workflow automatically.  
> (If you provide a subcommand **and** a YAML file, they must match or the script exits with an error.)

---

## Highlights

- **Air-gap ready:** pull artifacts once, push to your registry, stage images for offline server/agent setup.
- **Runtime selection that “just works”:** prefers **containerd + nerdctl**; installs containerd if neither runtime present; uses Docker only if containerd isn’t present but Docker is.
- **Kubernetes-style YAML** (one manifest per file): `apiVersion: rkeprep/v1`, `kind`, `metadata`, `spec` (camelCase).
- **Network config** prompts (or YAML): **IPv4**, **prefix (/mask)**, **single optional gateway**, **multiple DNS servers**, **search domains**.
- **IPv6 disabled** in the `image` stage (policy-driven).
- **Secure & observable:** checksum verification, **RFC 5424** logs to `./logs/` mirrored to console, logs gz-archived after 60 days, secrets masked when printing YAML.
- **QoL flags:** `-y/--yes` (auto-reboot for server/agent), `-P/--print-config` (sanitized YAML echo for troubleshooting).

---

## Image stage updates (important)

- `image` now ensures the VM is **fully patched** (runs `apt-get update && dist-upgrade -y`, then `autoremove`/`autoclean`) and **reboots automatically** after staging.
- RKE2 artifacts (tarball + `install.sh`) are staged to **`/opt/rke2/stage`** for **offline installs** later; `server`/`agent` automatically use that path (fall back to `./downloads/` if missing).

---

## Requirements

- **OS:** Ubuntu **24.04 LTS**
- **Privileges:** `sudo` (root)
- **Internet:** required for `pull` and typically for `push`. Everything else is offline.
- **CA cert:** place your registry CA at `./certs/kuberegistry-ca.crt` before running `image`.

**Defaults**
- Registry: `kuberegistry.dev.kube/rke2`
- Credentials: `admin` / `ZAQwsx!@#123`
- Default DNS: `10.0.1.34,10.231.1.34`
- Default search domains: none (override in `Image` spec with `defaultSearchDomains`)
- Subnet prefix default: `/24`

---

## Usage

### YAML-driven (no subcommand needed)
```bash
sudo ./rke2nodeinit.sh -f examples/pull.yaml
sudo ./rke2nodeinit.sh -f examples/push.yaml
sudo ./rke2nodeinit.sh -f examples/image.yaml
sudo ./rke2nodeinit.sh -f examples/server.yaml -y
sudo ./rke2nodeinit.sh -f examples/agent.yaml  -y -P
```

### Classic mode (still supported)
```bash
sudo ./rke2nodeinit.sh pull
sudo ./rke2nodeinit.sh push
sudo ./rke2nodeinit.sh image
sudo ./rke2nodeinit.sh server
sudo ./rke2nodeinit.sh agent
sudo ./rke2nodeinit.sh verify
```

---

## YAML format (one manifest per file)

- `apiVersion`: must be `rkeprep/v1`
- `kind`: one of `Pull`, `Push`, `Image`, `Server`, `Agent`
- `metadata.name`: informational
- `spec`: camelCase keys; arrays can be YAML lists or comma-separated strings

### Pull
```yaml
apiVersion: rkeprep/v1
kind: Pull
metadata:
  name: rke2-pull
spec:
  rke2Version: v1.33.1+rke2r1
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### Push
```yaml
apiVersion: rkeprep/v1
kind: Push
metadata:
  name: rke2-push
spec:
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### Image
```yaml
apiVersion: rkeprep/v1
kind: Image
metadata:
  name: offline-prep
spec:
  defaultDns: ["10.0.1.34", "10.231.1.34"]
  defaultSearchDomains: ["dev.kube", "dev.local"]
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### Server
```yaml
apiVersion: rkeprep/v1
kind: Server
metadata:
  name: cluster1-server1
spec:
  ip: 10.0.0.10
  prefix: 24
  hostname: cluster1-server1
  dns: ["10.0.1.34", "10.231.1.34"]
  searchDomains: ["dev.kube", "dev.local"]
```

### Agent
```yaml
apiVersion: rkeprep/v1
kind: Agent
metadata:
  name: cluster1-agent1
spec:
  ip: 10.0.0.11
  prefix: 24
  hostname: cluster1-agent1
  dns: ["10.0.1.34", "10.231.1.34"]
  searchDomains: ["dev.kube", "dev.local"]
  serverURL: https://10.0.0.10:9345
  token: <cluster-join-token>
```

---

## Troubleshooting

- YAML kind mismatch (if both `-f` and subcommand provided) → must match.
- Missing CA → put `kuberegistry-ca.crt` into `./certs/` before `image`.
- Registry login failed → check DNS/route and credentials.
- Images not found → run `pull`; check `./downloads/`.
- Networking not applied → reboot after `server`/`agent` (or use `-y`).

---

## Examples
See `./examples/`: `pull.yaml`, `push.yaml`, `image.yaml`, `server.yaml`, `agent.yaml`.
