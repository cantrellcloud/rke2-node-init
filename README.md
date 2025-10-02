# rke2nodeinit.sh — README

> **Purpose:** Prepare and configure Ubuntu/Debian hosts for **offline/air-gapped Rancher RKE2** using **containerd + nerdctl only** — no Docker.
> **Scope:** End-to-end workflow: download → optionally push to a private registry → stage an offline image → install server/agent → verify.
> **Safety:** Hardened by `set -Eeuo pipefail`, an error trap with line numbers, root checks, input validation, and explicit logging with progress spinners.

---

## Table of Contents

1. [At a Glance](#at-a-glance)
2. [Requirements](#requirements)
3. [What the Script Does](#what-the-script-does)
4. [Directory Layout & Key Files](#directory-layout--key-files)
5. [Command Syntax](#command-syntax)
6. [YAML Spec (rkeprep/v1)](#yaml-spec-rkeprepv1)
7. [Typical Offline Workflow](#typical-offline-workflow)
8. [Action Details](#action-details)
9. [Networking & Netplan Behavior](#networking--netplan-behavior)
10. [Logging, Progress, and Exit Codes](#logging-progress-and-exit-codes)
11. [Verification Checklist](#verification-checklist)
12. [Troubleshooting](#troubleshooting)
13. [Security Notes](#security-notes)
14. [Known Limitations & Tips](#known-limitations--tips)
15. [Uninstall / Rollback Pointers](#uninstall--rollback-pointers)
16. [FAQ](#faq)

---

## At a Glance

* **Container runtime:** Installs and enforces **containerd + nerdctl (FULL bundle)**. If Docker is detected, the script **asks to remove** it before proceeding.
* **Modes (actions):**

  * `pull`   – Download RKE2 artifacts and preload images (online host).
  * `push`   – Tag & push all preloaded images into your private registry (online host).
  * `image`  – Stage artifacts, CA trust, registries config, and OS prereqs (offline target). **Auto-reboots.**
  * `server` – Configure network/hostname and install **rke2-server** (offline).
  * `agent`  – Configure network/hostname and install **rke2-agent** (offline).
  * `verify` – Validate node prerequisites and staging.
* **Netplan hardening:** Disables cloud-init network rendering and **purges old YAMLs** before writing a clean static config so stale IP/GW **do not** return after reboot.
* **Progress & logs:** Every long step shows a spinner; all output is logged with timestamps and PIDs.

---

## Requirements

**Supported OS:** Ubuntu/Debian family with systemd, netplan, and APT.
**Privileges:** Run as **root** (or via `sudo`).
**Online steps:** `pull`/`push` need internet access (GitHub releases & your registry).
**Offline steps:** `image`/`server`/`agent`/`verify` run without internet (artifacts pre-staged).
**Disk space:** Several GB for images & tarballs.
**Optional tools:** `syft` (if present) is used to produce SPDX SBOMs; otherwise image inspect metadata is captured.

---

## What the Script Does

* Validates environment, sets strict shell behavior, and writes detailed logs.
* **Installs containerd+nerdctl (FULL)** from upstream releases, sets `SystemdCgroup=true`, enables/starts containerd.
* **Removes Docker** on request if detected (packages purged, data dirs removed, services disabled).
* Downloads and verifies **RKE2 artifacts**: `rke2-images.linux-<arch>.tar.zst`, `rke2.linux-<arch>.tar.gz`, `sha256sum-<arch>.txt`, and the `install.sh` installer.
* **Preloads** images into containerd (`k8s.io` namespace).
* Creates **SBOM / inspect** outputs for images when pushing (optional but encouraged).
* Stages **CA trust** and generates `/etc/rancher/rke2/registries.yaml` with credentials & CA pinning.
* Hardens OS for Kubernetes (modules, sysctls, nftables iptables, swap off; IPv6 disabled by default).
* Writes a single, authoritative **netplan** with static IPv4, DNS, and search domains. Applies immediately.
* Runs the **RKE2 offline installer** for server/agent, and enables `rke2-server` or `rke2-agent`.

---

## Directory Layout & Key Files

```
<repo>/
├─ rke2nodeinit.sh                  # This script
├─ downloads/                       # Artifacts downloaded by `pull`
│  ├─ rke2-images.linux-<arch>.tar.zst
│  ├─ rke2.linux-<arch>.tar.gz
│  ├─ sha256sum-<arch>.txt
│  └─ install.sh
├─ outputs/
│  ├─ images-manifest.txt|json      # Built by `push`
│  └─ sbom/                         # SBOMs or inspect metadata
├─ logs/
│  └─ rke2nodeinit_<UTC-timestamp>.log
└─ certs/
   └─ rke2ca-cert.crt           # Your private registry CA (you provide)
```

**System paths used:**

* Stage: `/opt/rke2/stage/` (installer & tarballs for offline install)
* Image preload: `/var/lib/rancher/rke2/agent/images/`
* RKE2 config: `/etc/rancher/rke2/config.yaml`, `/etc/rancher/rke2/registries.yaml`
* CA trust: `/usr/local/share/ca-certificates/rke2ca-cert.crt` (then `update-ca-certificates`)
* Netplan: `/etc/netplan/99-rke-static.yaml` (others are backed up and removed)
* Site defaults (DNS/search): `/etc/rke2image.defaults`

---

## Command Syntax

```bash
# With a YAML file (apiVersion: rkeprep/v1; kind selects the action)
sudo ./rke2nodeinit.sh -f file.yaml [options]

# Direct action (no YAML)
sudo ./rke2nodeinit.sh [options] <pull|push|image|server|agent|verify>

# Example quick start:
sudo ./rke2nodeinit.sh examples/pull.yaml
```

**Options**

* `-f FILE`    YAML config (see spec below)
* `-v VER`     RKE2 version (e.g., `v1.34.1+rke2r1`). If omitted in `pull`, the latest is auto-detected.
* `-r REG`     Private registry (e.g., `reg.example.org/rke2`)
* `-u USER`    Registry username
* `-p PASS`    Registry password
* `-y`         Auto-confirm prompts (including Docker removal and reboots)
* `-P`         Print a **sanitized** version of the YAML (secrets masked)
* `--dry-push` Simulate `push` (write manifests/SBOMs, skip actual pushes)
* `-h`         Help

---

## YAML Spec (rkeprep/v1)

Set `apiVersion: rkeprep/v1` and choose a `kind`: `Pull|Push|Image|Server|Agent`.
Values are read from `spec:`. Secrets are masked by `-P`.

### Pull

```yaml
apiVersion: rkeprep/v1
kind: Pull
spec:
  rke2Version: "v1.34.1+rke2r1"         # optional; latest auto-detected if omitted
  registry: "rke2registry.dev.local/rke2"
  registryUsername: "admin"
  registryPassword: "********"
```

### Push

```yaml
apiVersion: rkeprep/v1
kind: Push
spec:
  registry: "rke2registry.dev.local/rke2"
  registryUsername: "admin"
  registryPassword: "********"
```

### Image

```yaml
apiVersion: rkeprep/v1
kind: Image
spec:
  registry: "rke2registry.dev.local/rke2"   # host is used for system-default-registry
  registryUsername: "admin"
  registryPassword: "********"
  defaultDns: [ "10.0.1.34", "10.231.1.34" ]       # optional
  defaultSearchDomains: [ "dev.kube", "svc.cluster.local" ]  # optional
```

### Server

```yaml
apiVersion: rkeprep/v1
kind: Server
spec:
  hostname: "cp-01"
  ip: "10.0.4.21"
  prefix: 24
  gateway: "10.0.4.1"                          # optional but recommended (SSH safety)
  dns: [ "10.0.1.34", "10.231.1.34" ]          # optional (defaults available)
  searchDomains: [ "dev.kube" ]                # optional
```

### Agent

```yaml
apiVersion: rkeprep/v1
kind: Agent
spec:
  hostname: "node-01"
  ip: "10.0.4.31"
  prefix: 24
  gateway: "10.0.4.1"                          # optional but recommended
  dns: [ "10.0.1.34", "10.231.1.34" ]          # optional
  searchDomains: [ "dev.kube" ]                # optional
  serverURL: "https://10.0.4.21:9345"          # optional (can also join later)
  token: "********"                             # optional (masked by -P)
```

---

## Typical Offline Workflow

1. **On an online machine**

   * Download & preload:

     ```bash
     sudo ./rke2nodeinit.sh pull -v v1.34.1+rke2r1
     ```
   * (Optional) Push images to your private registry:

     ```bash
     sudo ./rke2nodeinit.sh push -r rke2registry.dev.local/rke2 -u admin -p '…'
     ```
   * Review generated manifests: `outputs/images-manifest.txt|json`, SBOMs in `outputs/sbom/`.

2. **Move artifacts to the offline target**

   * Copy `downloads/` and `certs/rke2ca-cert.crt` to the target host (keep same structure).

3. **On the offline target**

   * Stage the image and prep OS (**auto-reboot**):

     ```bash
     sudo ./rke2nodeinit.sh image -r rke2registry.dev.local/rke2 -u admin -p '…'
     ```
   * After reboot, configure as **server** or **agent**:

     ```bash
     sudo ./rke2nodeinit.sh server   # or: agent
     ```

     You’ll be prompted for IP/prefix/gateway/hostname and optional DNS/search.
   * Verify:

     ```bash
     sudo ./rke2nodeinit.sh verify
     ```

---

## Action Details

### `pull` (online)

* Detects the **RKE2 version** (unless `-v` given).
* Downloads:

  * `rke2-images.linux-<arch>.tar.zst`
  * `rke2.linux-<arch>.tar.gz`
  * `sha256sum-<arch>.txt`
  * `install.sh` (from `https://get.rke2.io`)
* Verifies checksums (`sha256sum -c`).
* **Preloads** images into `containerd` (`k8s.io` namespace).

### `push` (online)

* Loads images (if needed), enumerates all **non-dangling images** in `k8s.io` and **re-tags** them under your registry.
* Writes planned mappings to:

  * `outputs/images-manifest.txt`
  * `outputs/images-manifest.json`
* Generates **SBOMs** (`syft`) or **inspect** metadata per image (saved to `outputs/sbom/`).
* Logs in (`nerdctl login`), **pushes** each image, then logs out.
* Use `--dry-push` first to **review** before pushing.

> **Tip:** Run `push` on a clean host or after `nerdctl image prune` to avoid pushing unrelated images found in `k8s.io`.

### `image` (offline target, **auto-reboots**)

* Installs OS prereqs, sets nftables iptables, loads kernel modules, sysctls, disables swap, and **disables IPv6**.
* Ensures **containerd + nerdctl FULL** are present (installs if missing).
* Installs your **private registry CA** (from `certs/rke2ca-cert.crt`) into the system trust and updates CA store.
* Stages:

  * Images archive to `/var/lib/rancher/rke2/agent/images/`
  * RKE2 tarball, checksums, and installer to `/opt/rke2/stage/`
* Creates `/etc/rancher/rke2/config.yaml` with `system-default-registry`.
* Creates `/etc/rancher/rke2/registries.yaml` with auth and `ca_file` pinning.
* Saves **site defaults** (DNS/search) to `/etc/rke2image.defaults`.
* Performs system updates and **reboots automatically**.

### `server` (offline target)

* Prompts (or reads from YAML) for `ip`, `prefix`, `hostname`, optional `gateway`, `dns`, `searchDomains`.
* Enforces **containerd+nerdctl**, runs **RKE2 offline installer** with `INSTALL_RKE2_TYPE=server`.
* Enables `rke2-server`.
* Writes hardened **netplan** (cloud-init network disabled; old YAMLs moved aside).
* Sets hostname and `/etc/hosts` entry.
* Offers to **reboot** (recommended).

### `agent` (offline target)

* Same as `server`, plus optional `serverURL` and `token`.
  If provided, appends to `/etc/rancher/rke2/config.yaml` so the node can join the cluster on first boot.
* Runs **RKE2 offline installer** with `INSTALL_RKE2_TYPE=agent`.
* Enables `rke2-agent`.
* Writes netplan, sets hostname/hosts, offers to reboot.

### `verify`

* Confirms:

  * `br_netfilter` and `overlay` **loaded**
  * `net.bridge.*=1`, `net.ipv4.ip_forward=1`
  * **Swap disabled**
  * `containerd` active and `nerdctl` available
  * Artifacts staged, `registries.yaml` present, and **registry CA** installed
* Returns **0** on success; non-zero otherwise.

---

## Networking & Netplan Behavior

When writing netplan the script:

1. **Disables cloud-init network rendering** via `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`.
2. **Backs up and removes** any existing `/etc/netplan/*.y*ml` except `99-rke-static.yaml`.
3. Detects the primary interface (default route → device) and writes a **single** file:

   * `/etc/netplan/99-rke-static.yaml`
   * Static IPv4 address, optional default route, DNS servers, and search domains.
4. Runs `netplan generate` and `netplan apply` **immediately**.

> **Important:** If you’re connected over SSH, applying netplan with a new IP/gateway can drop your session. Prefer console access or ensure the new network settings are correct before confirming prompts.

---

## Logging, Progress, and Exit Codes

* **Logs:** `logs/rke2nodeinit_<UTC>.log` (older than 60 days are gzipped).
* **Progress:** Long steps show a spinner (e.g., downloads, pushes, service actions).
* **Exit codes:**

  * `0` success
  * `1` usage / bad options
  * `2` missing prerequisites / runtime issues
  * `3` data missing (artifacts, certs, etc.)
  * `4` registry auth problems *(reserved; actual rc propagated from the failing command)*
  * `5` YAML issues (bad/missing `apiVersion`/`kind`, file not found)

---

## Verification Checklist

After `image` (post-reboot) and again after `server`/`agent`:

```bash
# Script-level verification
sudo ./rke2nodeinit.sh verify

# Runtime
systemctl status containerd --no-pager
nerdctl --version
nerdctl -n k8s.io images | head

# RKE2 service (depending on role)
systemctl status rke2-server --no-pager
systemctl status rke2-agent  --no-pager

# Registry trust & config
ls -l /usr/local/share/ca-certificates/rke2ca-cert.crt
sudo update-ca-certificates -v | tail
sudo cat /etc/rancher/rke2/registries.yaml

# Network
ip -o -4 addr show
ip route
cat /etc/netplan/99-rke-static.yaml
```

### Manual regression: nested YAML keys

When your site definition includes nested values under `spec:` (for example `customCA.rootCrt`), run the desired action with the
same YAML file and confirm that the referenced artifacts show up in both locations:

```bash
sudo ./rke2nodeinit.sh -f clusters/dc1manager/dc1manager-ctrl01.yaml server
ls -l /var/lib/rancher/rke2/server/tls/root-ca.pem
ls -l /usr/local/share/ca-certificates/
```

The helper that parses `spec.customCA.*` tracks indentation, so the certificates copied into `/var/lib/rancher/rke2/server/tls/`
and the OS trust store should match the values defined in the YAML.

---

## Troubleshooting

### General

* **See the log first:** `logs/rke2nodeinit_<timestamp>.log` contains full command output with timestamps and PIDs.
* **Rerun with fewer variables:** Prefer running actions separately (`image` → reboot → `server`/`agent` → `verify`) to isolate issues.

### Common Issues & Fixes

1. **“Docker detected on this host.” → Script exits if you refuse removal**

   * Rerun with `-y` to auto-confirm removal **or** manually remove Docker:

     ```bash
     sudo systemctl stop docker && sudo systemctl disable docker || true
     sudo apt-get purge -y docker.io docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin moby-engine moby-cli
     sudo apt-get autoremove -y
     sudo rm -rf /var/lib/docker /etc/docker
     ```

2. **`Failed to detect latest nerdctl/RKE2 release` (GitHub API rate-limit / offline)**

   * Provide explicit versions:

     ```bash
     sudo ./rke2nodeinit.sh pull -v v1.34.1+rke2r1
     ```
   * Or place the correct artifacts manually into `downloads/` (names must match).

3. **`cp: cannot stat '/opt/rke2/stage/sha256sum-<arch>.txt'`**

   * Run `pull` first. Then ensure `image` or `ensure_staged_artifacts` copied files:

     ```
     ls /opt/rke2/stage/{rke2.linux-<arch>.tar.gz,sha256sum-<arch>.txt,install.sh}
     ```
   * If missing, copy from `downloads/` and re-run the action.

4. **Registry login/push fails (`x509: unknown authority` or auth error)**

   * Ensure the **CA file** exists and is installed:

     ```
     sudo cp certs/rke2ca-cert.crt /usr/local/share/ca-certificates/
     sudo update-ca-certificates
     ```
   * Confirm `registries.yaml` points to that CA and contains valid credentials.
   * If you are pushing **from the online machine**, that machine must also trust the registry CA.

5. **Images pushed to an unexpected path**

   * `push` re-tags each image as `<REGISTRY>/<original-repo>:<tag>`.
     If you set `REGISTRY=reg.example.org/rke2`, targets will look like:
     `reg.example.org/rke2/<original-repo>:<tag>`.
     Adjust `REGISTRY` accordingly or move images server-side.

6. **Netplan applied but old IP/gateway reappear after reboot**

   * This script **disables cloud-init networking** and **purges** old netplan files.
     If you still see reverts:

     * Confirm `/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg` exists and is correct.
     * Ensure no external tooling rewrites netplan.
     * Check `/etc/netplan/.backup-<timestamp>/` to verify older YAMLs were moved.

7. **Connectivity lost after `server`/`agent` (SSH cut off)**

   * Likely a wrong IP/prefix/gateway. From console:

     * Edit `/etc/netplan/99-rke-static.yaml`
     * `netplan generate && netplan apply`
     * Validate with `ip -o -4 addr show`, `ip route`

8. **`verify` fails: modules/sysctls**

   * Re-run `image` (which sets modules/sysctls) or apply manually:

     ```
     sudo modprobe br_netfilter overlay
     sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
     sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1
     sudo sysctl -w net.ipv4.ip_forward=1
     ```
   * Make persistent via `/etc/modules-load.d/rke2.conf` and `/etc/sysctl.d/90-rke2.conf`.

9. **Swap is still on**

   * The script comments swap lines in `/etc/fstab` and runs `swapoff -a`.
     Double-check `/etc/fstab` and remove or comment any remaining swap entries.

10. **Installer errors (`install.sh`)**

    * Ensure `INSTALL_RKE2_ARTIFACT_PATH=/opt/rke2/stage` contains the tarball and checksums.
    * Review `/var/log/syslog` and the script log for the installer’s output.

11. **SBOM generation missing**

    * Install `syft` (optional). Otherwise, the script will write `inspect` metadata instead.

---

## Security Notes

* `/etc/rancher/rke2/registries.yaml` contains **registry credentials**. The script sets `chmod 600`. Protect backups and logs accordingly.
* Custom CA is installed system-wide. Verify certificate provenance.
* The script disables IPv6 by default (`/etc/sysctl.d/99-disable-ipv6.conf`). If you require IPv6, remove that file and run `sysctl --system`.

---

## Known Limitations & Tips

* **OS family:** Designed for Ubuntu/Debian with `apt`, `systemd`, `netplan`. Other distros are out of scope.
* **Action granularity:** `push` enumerates **all** non-dangling images in the `k8s.io` namespace. Use `--dry-push` and review manifests or prune images first.
* **Auto-reboots:** `image` reboots automatically after updates. Plan maintenance windows accordingly.
* **Version pinning:** Prefer passing `-v` during `pull` to avoid surprises from “latest”.

---

## Uninstall / Rollback Pointers

> These are **guidelines**; adapt to your environment.

* **RKE2:**

  ```bash
  sudo systemctl disable --now rke2-server rke2-agent || true
  sudo rm -rf /etc/rancher /var/lib/rancher /var/lib/kubelet /etc/systemd/system/rke2* /usr/local/bin/rke2* /var/lib/rke2
  sudo systemctl daemon-reload
  ```
* **containerd/nerdctl (FULL bundle):**

  ```bash
  sudo systemctl disable --now containerd
  sudo rm -rf /usr/local/bin/{containerd,containerd-shim*,ctr,nerdctl,runc,buildkit*} \
              /usr/local/lib/systemd/system/containerd.service \
              /opt/cni /etc/containerd
  sudo systemctl daemon-reload
  ```
* **Netplan (restore):**

  * Remove `/etc/netplan/99-rke-static.yaml`
  * Restore from `/etc/netplan/.backup-<timestamp>/`
  * `netplan generate && netplan apply`
* **CA trust:** Remove the CA from `/usr/local/share/ca-certificates/` and run `update-ca-certificates`.
* **IPv6 restore:** Delete `/etc/sysctl.d/99-disable-ipv6.conf` and `sysctl --system`.

---

## FAQ

**Q: Where are the logs?**
A: `logs/rke2nodeinit_<UTC>.log`. Older than 60 days are gzipped automatically.

**Q: Can I run with only CLI flags and no YAML?**
A: Yes. Use `pull|push|image|server|agent|verify` directly. YAML just centralizes inputs and picks the action via `kind:`.

**Q: How do I preview what `push` will do?**
A: Run with `--dry-push`. Review `outputs/images-manifest.*` and `outputs/sbom/`.

**Q: I already have containerd installed. Will the script reuse it?**
A: If `containerd` is active and `nerdctl` is present, the script proceeds. Otherwise it installs the official nerdctl **FULL** bundle and enables `containerd`.

**Q: Why is IPv6 disabled?**
A: To reduce complexity in air-gapped environments. If you need IPv6, remove `/etc/sysctl.d/99-disable-ipv6.conf` and run `sysctl --system`.

**Q: How does offline install work?**
A: The script sets `INSTALL_RKE2_TYPE` and `INSTALL_RKE2_ARTIFACT_PATH` for `install.sh` so RKE2 installs using the locally staged tarball and checksums (no internet).

---

### Quick Commands Reference

```bash
# Detect latest & download (online)
sudo ./rke2nodeinit.sh pull -v v1.34.1+rke2r1

# Simulate and review pushes
sudo ./rke2nodeinit.sh --dry-push push -r rke2registry.dev.local/rke2 -u admin -p '…'

# Stage offline image (auto-reboot)
sudo ./rke2nodeinit.sh image -r rke2registry.dev.local/rke2 -u admin -p '…'

# Configure a server node (offline)
sudo ./rke2nodeinit.sh server

# Configure an agent node (offline)
sudo ./rke2nodeinit.sh agent

# Verify prerequisites
sudo ./rke2nodeinit.sh verify
```

---

## Support Snapshot (optional)

To collect a quick diagnostics bundle:

```bash
sudo tar -C / \
  -czf rke2nodeinit-support-$(date -u +%Y%m%dT%H%M%SZ).tgz \
  etc/rancher/rke2 \
  etc/netplan \
  etc/cloud/cloud.cfg.d/99-disable-network-config.cfg \
  etc/sysctl.d \
  etc/modules-load.d \
  usr/local/share/ca-certificates \
  var/lib/rancher/rke2/agent/images \
  opt/rke2/stage \
  var/log/syslog \
  $(pwd)/logs
```

---
