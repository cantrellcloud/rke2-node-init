# rke2nodeinit — Air‑Gapped RKE2 Node Image Prep (Ubuntu 24.04 LTS)

**Version:** v0.5  
**Supports:** RKE2 (Server/Agent), containerd‑first runtime, optional Docker fallback  
**Audience:** Entry‑level admins and SREs preparing air‑gapped Kubernetes (RKE2) clusters across multiple datacenters.

---

## What this project does

This repo builds and maintains a **single golden VM image** that can be turned into either an **RKE2 Server** or **RKE2 Agent** in **internet‑limited / air‑gapped** networks. It:

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
> **Default DNS (server/agent):** `10.0.1.34,10.231.1.34`

---

## Repository layout

```
rke2nodeinit_release_repo_v0_5_full/
├─ rke2nodeinit.sh          # Main script (extra‑detailed comments per section/function)
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

> Logs go to `./logs/rke2nodeinit_<UTC>.log` in RFC 5424‑like format; logs older than 60 days are compressed.

---

## Quick start

1. **Prepare a connected build VM (Ubuntu 24.04):**
   ```bash
   sudo apt-get update
   sudo apt-get install -y curl ca-certificates
   ```

2. **Pull artifacts (online):**
   ```bash
   cd rke2nodeinit_release_repo_v0_5_full
   sudo ./rke2nodeinit.sh -f examples/pull.yaml
   ```

3. **Push to your offline registry (still online):**
   ```bash
   sudo ./rke2nodeinit.sh -f examples/push.yaml
   # Preview only (no push), generate manifest & SBOMs:
   sudo ./rke2nodeinit.sh push --dry-push
   ```

4. **Prep the golden image (online preferred; offline OK if artifacts are staged):**
   ```bash
   sudo ./rke2nodeinit.sh -f examples/image.yaml
   ```

5. **Convert a cloned VM into a Server or Agent (offline OK):**
   ```bash
   sudo ./rke2nodeinit.sh -f examples/server.yaml -y
   sudo ./rke2nodeinit.sh -f examples/agent.yaml -y
   ```

6. **Verify node readiness:**
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
```yaml
apiVersion: rkeprep/v1
kind: Pull
metadata:
  name: rke2-artifacts
spec:
  rke2Version: v1.33.1+rke2r1
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### kind: Push
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
```yaml
apiVersion: rkeprep/v1
kind: Image
metadata:
  name: site-defaults
spec:
  defaultDns: ["10.0.1.34", "10.231.1.34"]
  defaultSearchDomains: ["corp.local", "dev.kube"]
  registry: kuberegistry.dev.kube/rke2
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### kind: Server
```yaml
apiVersion: rkeprep/v1
kind: Server
metadata:
  name: c1-s1
spec:
  ip: 10.0.0.10
  prefix: 24
  gateway: 10.0.4.1
  hostname: c1-s1
  dns: ["10.0.1.34", "10.231.1.34"]
  searchDomains: ["corp.local", "dev.kube"]
```

### kind: Agent
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
  serverURL: https://10.0.0.10:9345
  token: <cluster-join-token>
```

> With `-f/--file`, you **don’t** need to pass a subcommand; `kind` chooses the mode.

---

## Subcommands and how they work

### `pull`
- Auto‑detects RKE2 version (if not provided).
- Downloads artifacts, verifies checksums, and **loads** images into local cache.

### `push`
- Retags and pushes cached images to your offline registry.
- Writes manifest (txt/json) and SBOMs (SPDX via `syft`, else inspect JSON).

### `image`
- Installs **prereqs**, trusts your **CA**, stages artifacts, disables **IPv6**, saves site defaults, and **reboots** after OS updates.

### `server`
- Prompts for missing network values, writes **netplan** (single gateway), installs **rke2‑server** offline, enables service, and offers reboot.

### `agent`
- Same as server for networking; installs **rke2‑agent** offline and optionally writes `server:`/`token:`.

### `verify`
- Checks modules/sysctls/swap/runtime/artifacts/registry config & CA.

---

## Security & best practices

- Run with `sudo`. Logs printed to console and file (structured), rotated after 60 days.
- Secrets masked in `-P` output.
- Swap disabled, nftables preferred, required kernel modules and sysctls applied.
- **Single gateway** by design for predictability.
- Keep your CA secure; rotate credentials regularly.

---

## Troubleshooting

- Script prints a helpful error with **line number** on unexpected failures.
- If `verify` fails, re‑run `image`, reboot, then `verify` again.
- Install `syft` if you want SPDX SBOMs; otherwise inspect JSON is produced.

---

## FAQ

**Q: Do I have to run `pull` on the same VM that will become the final image?**  
A: You can, but you don’t have to. You can run `pull` and `push` on a connected staging VM, then move the prepared `/downloads` and staged artifacts to the image VM if needed.

**Q: What happens if both containerd and Docker are installed?**  
A: The script prefers **containerd+nerdctl**. If containerd is present/active, it will be used. Docker is used only if containerd isn’t available.

**Q: Where are images sourced from during `push`?**  
A: From the local runtime cache (which `pull` preloaded). `push` re-tags and pushes them to your offline registry and writes manifest/SBOMs.

**Q: Can I customize the registry mirror in `registries.yaml`?**  
A: Yes. The `image` step writes a default `registries.yaml` that points `docker.io` to your registry host. You can edit it afterward if your mirror layout differs.

**Q: Why only a single gateway?**  
A: To avoid routing ambiguity on cloned images. Multi-homing is best handled case-by-case after provisioning.

**Q: Offline mode install specifics?**  
A: `image` stages the RKE2 image archive under `/var/lib/rancher/rke2/agent/images/` and the tarball + `install.sh` under `/opt/rke2/stage/`. `server`/`agent` then invoke the staged `install.sh` with `INSTALL_RKE2_ARTIFACT_PATH` to avoid internet access.

**Q: How do logs work?**  
A: Logs are printed to console and also written to `./logs/rke2nodeinit_<UTC>.log`. Files older than 60 days are compressed automatically.

---
