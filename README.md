# rke2nodeinit — RKE2 Air-Gapped Image Prep (Auto-Kind)

**rke2nodeinit** is a single Bash utility, `rke2nodeinit.sh`, to prep Ubuntu **24.04 LTS** VMs as production-ready **RKE2** (Kubernetes) Server/Agent nodes for **internet-limited or air-gapped** environments.

> ### New behavior
> When you pass **`-f file.yaml`**, you **do not need a subcommand**.  
> The script reads the YAML’s `kind:` (`Pull`, `Push`, `Image`, `Server`, `Agent`) and runs the correct workflow automatically.  
> (If you provide a subcommand **and** a YAML file, the two must match or the script exits with an error.)

---

## Highlights (entry-level friendly, best practices)

- **Air-gap ready:** pull artifacts once, push to your registry, stage images for offline server/agent setup.
- **Runtime selection that “just works”:** prefers **containerd + nerdctl**; installs containerd if neither runtime present; uses Docker only if containerd isn’t present but Docker is.
- **Kubernetes-style YAML** (one manifest per file): `apiVersion: rkeprep/v1`, `kind`, `metadata`, `spec` (camelCase).
- **Network config** prompts (or YAML): **IPv4**, **prefix (/mask)**, **single optional gateway**, **multiple DNS servers**, **search domains**.
- **IPv6 disabled** in the `image` stage (policy-driven).
- **Secure & observable:** checksum verification, **RFC 5424** logs to `./logs/` mirrored to console, logs gz-archived after 60 days, secrets masked when printing YAML.
- **QoL flags:** `-y/--yes` (auto-reboot for server/agent), `-P/--print-config` (sanitized YAML echo for troubleshooting).

---

## Requirements

- **OS:** Ubuntu **24.04 LTS**
- **Privileges:** `sudo` (root)
- **Internet:** required for `pull` and typically for `push`. Everything else is offline.
- **CA cert:** place your registry CA at `./certs/kuberegistry-ca.crt` before running `image`.

**Defaults**
- Registry: `kuberegistry.dev.kube/rke2`
- Credentials: `admin` / `ZAQwsx!@#123`
- Default DNS (when node-level DNS not provided): `10.0.1.34,10.231.1.34`
- Default search domains: none (override in `Image` spec with `defaultSearchDomains`)
- Subnet prefix default: `/24`

---

## Usage

### A) YAML-driven (no subcommand needed)
```bash
# Examples:
sudo ./rke2nodeinit.sh -f examples/pull.yaml
sudo ./rke2nodeinit.sh -f examples/push.yaml
sudo ./rke2nodeinit.sh -f examples/image.yaml
sudo ./rke2nodeinit.sh -f examples/server.yaml -y         # auto-reboot
sudo ./rke2nodeinit.sh -f examples/agent.yaml  -y -P      # print sanitized YAML then auto-reboot
```

### B) Classic mode with subcommand (still supported)
```bash
sudo ./rke2nodeinit.sh pull
sudo ./rke2nodeinit.sh push
sudo ./rke2nodeinit.sh image
sudo ./rke2nodeinit.sh server
sudo ./rke2nodeinit.sh agent
sudo ./rke2nodeinit.sh verify
```
> If you pass both `-f file.yaml` **and** a subcommand, they must **match** (e.g., YAML `kind: Server` and CLI `server`).

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
  rke2Version: v1.33.1+rke2r1           # optional; auto-detects latest if omitted
  registry: kuberegistry.dev.kube/rke2  # optional
  registryUsername: admin               # optional
  registryPassword: ZAQwsx!@#123        # optional
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
  defaultDns: ["10.0.1.34", "10.231.1.34"]          # optional; site default for nodes
  defaultSearchDomains: ["corp.local", "dev.kube"]  # optional; site default for nodes
  registry: kuberegistry.dev.kube/rke2              # optional override
  registryUsername: admin                           # optional override
  registryPassword: ZAQwsx!@#123                    # optional override
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
  dns: ["10.0.1.34", "10.231.1.34"]         # or: "10.0.1.34,10.231.1.34"
  searchDomains: ["corp.local", "dev.kube"]  # or: "corp.local,dev.kube"
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
  searchDomains: ["corp.local", "dev.kube"]
  serverURL: https://10.0.0.10:9345
  token: <cluster-join-token>
```

---

## Security & operations best practices

- **Run as root**; review prompts before reboots.
- **Checksums verified** on downloads (detect corruption/tampering).
- **Secrets masked** in `-P/--print-config` output (e.g., tokens).
- **RFC 5424 logs** to `./logs/` and console; archives after 60 days.
- **Netplan applied on reboot** (safer on headless nodes).
- **containerd-first** aligns with RKE2 defaults; limits Docker dependency in air-gaps.
- **Private registry trust**: CA installed system-wide; `registries.yaml` includes TLS CA + basic auth (restricted perms).

---

## Troubleshooting

- **YAML kind mismatch**: If `-f` YAML and a CLI subcommand are both provided, they must match.
- **Missing CA**: Put `kuberegistry-ca.crt` into `./certs/` before `image`.
- **Registry login failed**: Check DNS/route and credentials.
- **Images not found**: Re-run `pull`; check `./downloads/`.
- **Networking not applied**: Reboot after `server`/`agent` (or run with `-y`).

---

## Examples

Ready-to-use manifests are in `./examples/`:
- `pull.yaml`
- `push.yaml`
- `image.yaml`
- `server.yaml`
- `agent.yaml`
