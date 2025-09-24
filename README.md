# rke2nodeinit — Air‑Gapped RKE2 Node Image Prep (Ubuntu 24.04 LTS)

**Version:** v6  
**Supports:** RKE2 (Server/Agent), containerd-first runtime, optional Docker fallback  
**Audience:** Entry‑level admins and SREs preparing air‑gapped Kubernetes (RKE2) clusters across multiple datacenters.

---

## What this project does

This repo builds and maintains a **single golden VM image** that can be turned into either an **RKE2 Server** or **RKE2 Agent** in **internet-limited / air‑gapped** networks. It:

- **Pulls** official RKE2 artifacts (images, tarballs, installer) online and **loads images** into the local runtime cache.
- **Pushes** all locally cached images into your **private offline registry**, including a **pre‑push manifest** and **SBOMs** (SPDX via `syft` if present; otherwise metadata via runtime `inspect`).
- **Preps a base image** for a future offline install:
  - Installs **RKE2 prerequisites** (kernel modules, sysctls, nftables iptables, swapoff, etc.).
  - Installs and trusts your **registry CA**.
  - Stages RKE2 **artifacts** for **offline** installation.
  - **Disables IPv6** (per your policy).
  - Applies **all OS updates** and **auto‑reboots** (with a clear notice).
- Configures a node as a **Server** or **Agent** with:
  - Static IPv4 + **single gateway** (intentional), **multiple DNS servers**, **search domains**.
  - Air‑gap registry settings (`registries.yaml`), optional **join token** and **server URL** for agents.
  - Reboot prompt to apply network changes (or auto‑yes via `-y`).

> **Default offline registry:** `kuberegistry.dev.kube/rke2`  
> **Default credentials:** `admin / ZAQwsx!@#123`  
> **Default DNS list (server/agent):** `10.0.1.34,10.231.1.34`

---

## Repository layout

```
rke2nodeinit_release_repo_v6/
├─ rke2nodeinit.sh          # Main script (heavily commented and cleanly formatted)
├─ README.md                # This document
├─ certs/
│  └─ kuberegistry-ca.crt   # <-- place your registry CA here (required for image/push)
├─ examples/
│  ├─ pull.yaml             # kind: Pull
│  ├─ push.yaml             # kind: Push
│  ├─ image.yaml            # kind: Image (site defaults)
│  ├─ server.yaml           # kind: Server (per-node)
│  └─ agent.yaml            # kind: Agent  (per-node)
└─ outputs/
   ├─ images-manifest.txt   # Written by push (source -> target)
   ├─ images-manifest.json  # Written by push (machine-readable)
   └─ sbom/                 # Image SBOMs (SPDX via syft, else inspect)
```

> The script also writes logs to `./logs/rke2nodeinit_<UTC>.log` in an RFC 5424‑like format and compresses logs older than 60 days.

---

## Quick start

1. **Prepare a connected build VM (Ubuntu 24.04):**
   ```bash
   sudo apt-get update
   sudo apt-get install -y curl ca-certificates
   ```

2. **Pull artifacts (online):**  
   Downloads the RKE2 image archive, tarball, checksums, installer, verifies them, and **loads** images into the local runtime cache.
   ```bash
   cd rke2nodeinit_release_repo_v6
   sudo ./rke2nodeinit.sh -f examples/pull.yaml
   ```

3. **Push to your offline registry (still online):**
   ```bash
   sudo ./rke2nodeinit.sh -f examples/push.yaml
   # Preview only (no push), generate manifest & SBOMs:
   sudo ./rke2nodeinit.sh push --dry-push
   ```

4. **Prep the golden image (can be online or offline if artifacts staged):**  
   Installs prereqs, trusts CA, stages artifacts, **disables IPv6**, patches OS, **auto‑reboots**.
   ```bash
   sudo ./rke2nodeinit.sh -f examples/image.yaml
   ```

5. **Convert a cloned VM into a Server or Agent (offline OK):**
   ```bash
   # Server
   sudo ./rke2nodeinit.sh -f examples/server.yaml -y
   # Agent
   sudo ./rke2nodeinit.sh -f examples/agent.yaml -y
   ```

6. **Verify node readiness at any time:**
   ```bash
   sudo ./rke2nodeinit.sh verify
   ```

---

## Input format (Kubernetes‑style YAML)

- **One object per file**.
- `apiVersion: rkeprep/v1`
- `kind: Pull | Push | Image | Server | Agent`
- `metadata.name`: any string
- `spec`: fields in **camelCase**

### kind: Pull
Downloads and loads images into the local runtime cache.

```yaml
apiVersion: rkeprep/v1
kind: Pull
metadata:
  name: rke2-artifacts
spec:
  # optional; if omitted the script auto-detects the latest
  rke2Version: v1.33.1+rke2r1

  # used for future steps (push/image); not required to pull
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### kind: Push
Tags and pushes all locally cached images to your air‑gapped registry and writes a manifest + SBOMs.

```yaml
apiVersion: rkeprep/v1
kind: Push
metadata:
  name: mirror-to-offline-registry
spec:
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### kind: Image
Preps the golden base image to be usable offline later.

```yaml
apiVersion: rkeprep/v1
kind: Image
metadata:
  name: site-defaults
spec:
  defaultDns: ["10.0.1.34", "10.231.1.34"]
  defaultSearchDomains: ["corp.local", "dev.kube"]

  # Registry where images will be pulled from in offline mode:
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### kind: Server
Configures a node as an RKE2 server.

```yaml
apiVersion: rkeprep/v1
kind: Server
metadata:
  name: c1-s1
spec:
  ip: 10.0.0.10
  prefix: 24
  gateway: 10.0.4.1                  # single gateway supported (optional)
  hostname: c1-s1
  dns: ["10.0.1.34", "10.231.1.34"]
  searchDomains: ["corp.local", "dev.kube"]
```

### kind: Agent
Configures a node as an RKE2 agent; can join a server when `serverURL` and `token` are provided.

```yaml
apiVersion: rkeprep/v1
kind: Agent
metadata:
  name: c1-a1
spec:
  ip: 10.0.0.11
  prefix: 24
  gateway: 10.0.4.1
  hostname: c1-a1
  dns: ["10.0.1.34", "10.231.1.34"]
  searchDomains: ["corp.local", "dev.kube"]

  # Optional join details (write into /etc/rancher/rke2/config.yaml):
  serverURL: https://10.0.0.10:9345
  token: <cluster-join-token>
```

> When using `-f/--file`, you **don’t** need to pass a subcommand; the script reads the `kind` and runs the correct mode automatically.

---

## Subcommands in detail

### `pull`
- Detects latest RKE2 version (if not provided) using GitHub releases API.
- Downloads:
  - `rke2-images.linux-amd64.tar.zst`
  - `rke2.linux-amd64.tar.gz`
  - `sha256sum-amd64.txt`
  - `install.sh` (from `get.rke2.io`)
- Verifies checksums.
- **Loads** the image archive into the local runtime **cache** (so your VM already has them).

### `push`
- Uses the cached images and **retags** them to your registry namespace.
- **Logs in** to the registry.
- **Pushes** all images.
- Writes:
  - `outputs/images-manifest.txt`
  - `outputs/images-manifest.json`
  - SBOMs under `outputs/sbom/` (SPDX via `syft`, else `inspect` JSON).

> `--dry-push` generates the manifest & SBOMs but does not push images.

### `image`
- Installs **RKE2 prerequisites** (packages, kernel modules, sysctls, swapoff).
- Installs and trusts the **registry CA** at `/usr/local/share/ca-certificates/kuberegistry-ca.crt`.
- Stages artifacts for offline usage:
  - Copies `rke2-images.linux-amd64.tar.zst` to `/var/lib/rancher/rke2/agent/images/`
  - Copies `rke2.linux-amd64.tar.gz` and `install.sh` to `/opt/rke2/stage/`
- Writes `/etc/rancher/rke2/config.yaml` and `registries.yaml` (system-default-registry, auth, CA).
- Disables **IPv6** via sysctl.
- Saves **site defaults** (DNS/search domains) to `/etc/rke2image.defaults` for later prompts.
- Applies **all security updates** and **reboots automatically** (you are warned before reboot).

### `server`
- Prompts for any missing values (IP, prefix, hostname, optional gateway, DNS, search domains).
- Validates input and writes an idempotent **netplan** config:
  - **Single gateway** (if provided).
  - Multiple DNS servers & search domains.
- Performs an **offline RKE2 server install** using staged artifacts.
- Enables `rke2-server` service.
- Prompts to reboot (or auto‑reboots with `-y`).

### `agent`
- Same as `server` for networking.
- Performs an **offline RKE2 agent install** using staged artifacts.
- Enables `rke2-agent` service.
- Optionally writes `server:` and `token:` to `/etc/rancher/rke2/config.yaml` when provided.
- Prompts to reboot (or auto‑reboots with `-y`).

### `verify`
Checks:
- Kernel modules: `br_netfilter`, `overlay`
- Sysctls: `bridge-nf-call-iptables=1`, `ip_forward=1`
- Swap: **disabled**
- Runtime: `containerd+nerdctl` preferred; `docker` acceptable fallback
- Artifacts: images tar, RKE2 tarball, installer staged
- Registry config & CA trust

Exits non‑zero if any blocking issue is found.

---

## Security & best practices

- **Run as root** (`sudo`). The script edits `/etc`, installs packages, manages services.
- **Logs** are written to file **and** console. They are structured (RFC 5424‑like) and compress after 60 days.
- **Secrets** shown in YAML (`registryPassword`, `token`) are masked when printing with `-P`.
- **Swap** is disabled, nftables is preferred, and kernel modules/sysctls required by Kubernetes are set.
- Only a **single gateway** is supported by design (determinism and simplicity for image-based provisioning).
- Keep your **CA** private and properly stored; rotate credentials as needed.

---

## Troubleshooting

- If a prompt feels like it “ended the script,” this version adds a global **trap** showing the failure line and exit code, plus more progress logs right after prompts.
- If `verify` fails, re‑run `image` (or ensure prereqs), reboot, then `verify` again.
- If SBOMs are missing, install [`syft`](https://github.com/anchore/syft) for SPDX output; otherwise inspect JSON is produced.

---

## FAQ

**Q: Can I skip the `pull` step?**  
A: You can, but then `image` cannot stage artifacts and `push` cannot mirror images. Run `pull` once on a connected VM.

**Q: Where do images come from in offline mode?**  
A: Nodes can pull from your **offline registry** after `push`, or they use the **staged image archive** if RKE2 does so during install (per Rancher air‑gap procedure).

**Q: containerd vs Docker?**  
A: We prefer `containerd+nerdctl`. If containerd is not installed/running and Docker is present, Docker will be used. If neither is present, containerd+nerdctl are installed automatically.

---

## Examples (see `examples/` folder)

- `pull.yaml`, `push.yaml`, `image.yaml`, `server.yaml`, `agent.yaml` are ready to edit.

Happy clustering! 🚀
