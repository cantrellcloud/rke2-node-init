# rkeimage — RKE2 Air‑Gapped Image Preparation & Node Config

This repository provides a single Bash utility, **`rke2nodeinit.sh`**, to prepare and configure **Ubuntu 24.04 LTS** VMs for **RKE2** clusters in **internet‑limited / air‑gapped** environments. It’s designed for **entry‑level admins** while following **industry best practices** for security and reliability.

You can prepare **one golden VM template** and then stamp out **RKE2 server or agent** nodes across multiple data centers. The tool pulls and verifies RKE2 artifacts, pushes images to your private registry, stages everything for **offline installation**, configures static networking (including **multiple DNS servers** and **search domains**), and applies hardening like **disabling IPv6** (per your policy).

---

## Highlights

- **Air‑gapped ready**: download once (`pull`), mirror to your registry (`push`), stage for offline install (`image`).
- **containerd‑first** runtime selection for `pull/push`:
  - Use **containerd + nerdctl** if present.
  - If neither runtime exists, **installs containerd + nerdctl** and uses that.
  - If **Docker** is present but containerd isn’t, uses **Docker**.
- **Kubernetes‑style YAML** input (one manifest per file) with `apiVersion`, `kind`, `metadata`, and `spec` (camelCase). The `kind` **must match** the subcommand you run; otherwise the script **exits**.
- **Static network config** for server/agent: IP, **prefix**, optional single gateway, **multiple DNS servers**, **search domains**, and **hostnames**. Values can come from YAML or prompts.
- **Site defaults** (used if node values omitted):  
  - Default DNS: **`10.0.1.34,10.231.1.34`** (override via `Image.spec.defaultDns`)  
  - Default search domains: optional (`Image.spec.defaultSearchDomains`)
- **IPv6 disabled** during `image` via sysctl.
- **Checksum verification** of downloads.
- **RFC 5424‑style logging** to `./logs/` and console; archives logs older than **60 days**.
- **Input validation**: IPv4, prefix (0–32), gateway IPv4, comma‑separated DNS IPv4s, and comma‑separated search domains.
- **Safety prompts** and QoL flags:
  - Prompts before **reboot** (unless `-y/--yes` is used).
  - **`-P/--print-config`** prints the provided YAML with **secrets masked** (`registryPassword`, `token`) for troubleshooting.

---

## Requirements

- **OS**: Ubuntu **24.04 LTS**
- **Privileges**: Run with **sudo/root**.
- **Network**: Internet access is needed for **`pull`** (and typically **`push`**). Other stages are offline.
- **Registry CA**: Put `kuberegistry-ca.crt` in `./certs/` before running **`image`**.

> Defaults (overridable via CLI or YAML):  
> • Registry: `kuberegistry.dev.kube/rke2`  
> • Credentials: `admin` / `ZAQwsx!@#123`  
> • Default DNS (fallback): `10.0.1.34,10.231.1.34`  
> • Default search domains: none  
> • Default prefix: `/24`

---

## Quick Start (Typical Workflow)

1) **Clone/copy** this repo to a prep VM with internet access.  
2) Place your registry CA at: `./certs/kuberegistry-ca.crt`.  
3) **Pull** RKE2 artifacts (auto‑detects latest unless you set `rke2Version`):
```bash
sudo ./rke2nodeinit.sh pull
```
4) **Push** images to your private registry (prefers containerd/nerdctl; falls back to Docker if only Docker exists):
```bash
sudo ./rke2nodeinit.sh push
```
5) **Image** prep (stages offline artifacts, trusts your registry CA, disables IPv6):
```bash
sudo ./rke2nodeinit.sh image
```
6) Snapshot/shutdown this VM to make a **golden template**.  
7) In the air‑gapped DC, clone from the template and configure the role:
```bash
# Server node
sudo ./rke2nodeinit.sh server

# Agent node
sudo ./rke2nodeinit.sh agent
```
8) **Verify**:
```bash
sudo ./rke2nodeinit.sh verify
```

> You can also drive each step via **YAML** using `-f file.yaml`. When `-f` is used, the YAML values **override CLI flags** and **suppress prompts** (except reboots unless `-y` is given). The YAML must be a **single Kubernetes‑style manifest** whose `kind` matches the subcommand being run.

---

## Subcommands (What They Do)

### `pull`
- Downloads the RKE2 **images archive**, **tarball**, **checksums**, and **install.sh** (for offline install).
- Verifies checksums. No system changes yet.

### `push`
- Loads images from the archive, **retags** for your registry, and **pushes** them.
- **Runtime selection**: containerd/nerdctl preferred; Docker used if only Docker exists; installs containerd if neither is present.

### `image`
- Installs your **registry CA** into system trust.
- Stages the **RKE2 images archive** at `/var/lib/rancher/rke2/agent/images/` for air‑gap installation.
- Writes `/etc/rancher/rke2/config.yaml` with `system-default-registry` and a secure `/etc/rancher/rke2/registries.yaml` with TLS + auth.
- **Disables IPv6** via `/etc/sysctl.d/99-disable-ipv6.conf` and `sysctl --system`.
- Persists site defaults (DNS/search domains) for later `server`/`agent` prompts.

### `server`
- Installs and enables **`rke2-server`** (offline) and configures **static networking** + **hostname**.
- Prompts for missing values (IP, prefix, optional gateway, DNS list, search domains); or reads them from YAML.
- Writes Netplan and advises reboot (auto‑reboots with `-y`).

### `agent`
- Installs and enables **`rke2-agent`** (offline) and configures **static networking** + **hostname**.
- Optionally includes **`serverURL`** and **`token`** in YAML to auto‑join; or you may set them later in `/etc/rancher/rke2/config.yaml`.
- Writes Netplan and advises reboot (auto‑reboots with `-y`).

### `verify`
- Confirms OS details, RKE2 binary presence, systemd units, Netplan, and registry configs.

---

## YAML Input — Kubernetes‑Style (One Manifest per File)

Each YAML file must include:
- `apiVersion: rke2nodeinit/v1`
- `kind: Pull | Push | Image | Server | Agent` (must match the subcommand you run)
- `metadata.name: <string>`
- `spec: { ... }` with camelCase keys

> If the `kind` doesn’t match the subcommand, the script **exits** with an error. Arrays may be provided as YAML lists or comma‑separated strings (the script accepts both).

### Pull
```yaml
apiVersion: rke2nodeinit/v1
kind: Pull
metadata:
  name: rke2-pull
spec:
  rke2Version: v1.33.1+rke2r1           # optional; auto-detects if omitted
  registry: kuberegistry.dev.kube/rke2  # optional; default provided
  registryUsername: admin               # optional; default provided
  registryPassword: ZAQwsx!@#123        # optional; default provided
```

### Push
```yaml
apiVersion: rke2nodeinit/v1
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
apiVersion: rke2nodeinit/v1
kind: Image
metadata:
  name: offline-prep
spec:
  defaultDns: ["10.0.1.34", "10.231.1.34"]          # optional; fallback if node DNS is blank
  defaultSearchDomains: ["corp.local", "dev.kube"]  # optional; fallback if node searchDomains is blank
  registry: kuberegistry.dev.kube/rke2              # optional; override defaults here too
  registryUsername: admin
  registryPassword: ZAQwsx!@#123
```

### Server
```yaml
apiVersion: rke2nodeinit/v1
kind: Server
metadata:
  name: cluster1-server1
spec:
  ip: 10.0.0.10
  prefix: 24
  hostname: cluster1-server1
  dns: ["10.0.1.34", "10.231.1.34"]        # comma-separated also accepted
  searchDomains: ["corp.local", "dev.kube"] # comma-separated also accepted
```

### Agent
```yaml
apiVersion: rke2nodeinit/v1
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

## Security & Best Practices

- **Run as root** and review prompts before confirming reboots (or use `-y` for unattended builds).
- **Checksum verification** for RKE2 artifacts prevents corruption/tampering.
- **Secret handling**: registry password and tokens are used but not echoed; use `-P/--print-config` to print **sanitized** YAML (secrets masked) for troubleshooting.
- **Registry trust**: installs your CA into system trust and configures TLS + auth inside `registries.yaml`. Keep this repo private.
- **Network hygiene**: robust validation for IP/prefix/DNS/search domains. Changes apply on reboot to avoid mid‑session disconnects.
- **containerd‑first** aligns with RKE2 defaults and reduces Docker footprint in air‑gapped deployments.
- **Logging**: console + RFC 5424 file logs in `./logs/` and archives after **60 days**.

---

## CLI Reference

```bash
sudo ./rke2nodeinit.sh [-f file.yaml] [-v rke2Version] [-r registry] [-u user] [-p pass] [-y] [-P] <subcommand>

Subcommands: pull | push | image | server | agent | verify
Notes:
- When using -f, the YAML's kind must match the subcommand.
- YAML values override CLI flags and skip prompts (except reboot unless -y).
- Use -P to print a sanitized view of the YAML before execution.
```
---

## Troubleshooting

- **Missing CA**: ensure `./certs/kuberegistry-ca.crt` exists before `image`.
- **No matching kind**: your YAML `kind` must match the subcommand (e.g., `Server` for `server`).
- **Registry login failed**: validate DNS, reachability, and credentials to the registry.
- **Images not found**: run `pull` again; confirm files under `./downloads/`.
- **Network not applied**: reboot (safer than `netplan apply` on headless nodes).

---

## Examples

Ready‑to‑use examples are in `./examples/`:
- `pull.yaml`, `push.yaml`, `image.yaml`, `server.yaml`, `agent.yaml`

Use like:
```bash
sudo ./rke2nodeinit.sh -f examples/pull.yaml pull
sudo ./rke2nodeinit.sh -f examples/push.yaml push
sudo ./rke2nodeinit.sh -f examples/image.yaml image
sudo ./rke2nodeinit.sh -f examples/server.yaml -y server
sudo ./rke2nodeinit.sh -f examples/agent.yaml agent
sudo ./rke2nodeinit.sh verify
```
