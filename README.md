# rke2nodeinit.sh

`rke2nodeinit.sh` is a hardened automation script for preparing and configuring Ubuntu/Debian hosts for fully offline Rancher RKE2 clusters. It orchestrates artifact caching, registry mirroring, operating system hardening, and the eventual server/agent installation using only Bash and standard GNU utilities, keeping the workflow portable inside air-gapped environments. Only the `image` action contacts the Internet to gather artifacts; all other actions are designed to run without network access.

---

## Table of Contents

- [rke2nodeinit.sh](#rke2nodeinitsh)
  - [Table of Contents](#table-of-contents)
  - [Key Capabilities](#key-capabilities)
  - [Supported Platforms \& Requirements](#supported-platforms--requirements)
  - [Workflow Overview](#workflow-overview)
  - [Actions Breakdown](#actions-breakdown)
  - [Command Reference](#command-reference)
    - [Common Flags](#common-flags)
    - [Makefile Helpers](#makefile-helpers)
  - [Development Helpers](#development-helpers)
  - [YAML Configuration Reference](#yaml-configuration-reference)
  - [Offline Registry \& CA Handling](#offline-registry--ca-handling)
  - [Network Configuration Strategy](#network-configuration-strategy)
  - [Logging \& Observability](#logging--observability)
  - [Safety Controls \& Idempotency](#safety-controls--idempotency)
  - [Generated Files \& Directory Layout](#generated-files--directory-layout)
  - [Verification \& Troubleshooting](#verification--troubleshooting)
  - [Maintenance \& Rollback Tips](#maintenance--rollback-tips)
  - [Appendix: Environment Variables](#appendix-environment-variables)

---

## Key Capabilities

- **Air-Gapped Friendly** – Downloads every RKE2 artifact (images, binaries, checksums, installer) in advance and stages them under `/opt/rke2/stage` for disconnected installs.
- **Container Runtime Alignment** – Installs the official `nerdctl` bundles (standalone + FULL) and enables containerd with systemd cgroup support while avoiding extra runtime dependencies.
- **Registry Mirroring & Trust** – Writes `/etc/rancher/rke2/registries.yaml` with mirror priorities, optional authentication, and custom certificate authorities. Automatically pushes cached images with SBOM metadata.
- **Network Hardening** – Disables cloud-init network rendering, purges legacy Netplan files, writes a single authoritative static IPv4 configuration, and applies it immediately.
- **Security Guardrails** – Runs with `set -Eeuo pipefail`, surfaces line numbers on failure, validates user input, masks secrets when printing YAML, and clamps file permissions.
- **Operational Transparency** – Streams all steps to `logs/` with timestamps and hostnames. Long-running tasks show CLI spinners while stdout remains concise.
- **Reusable Defaults** – Persistently stores DNS/search defaults and custom CA information so subsequent server/agent runs reuse the captured site context.

---

## Supported Platforms & Requirements

| Category | Details |
| --- | --- |
| Operating systems | Ubuntu/Debian variants with `systemd`, `apt`, and `netplan` |
| Privileges | Must be executed as `root` (use `sudo`) |
| Connectivity | `image` requires Internet access for artifact acquisition. `push`, `server`, `agent`, `verify`, and `airgap` must run without Internet access |
| Disk space | Several GB for RKE2 tarballs, images, SBOM data, and logs |
| Optional tooling | [`syft`](https://github.com/anchore/syft) for SPDX SBOMs. Without it, nerdctl inspect metadata is produced |
| External dependencies | Private registry endpoint, optional custom CA, and YAML configuration matching `apiVersion: rkeprep/v1` |

---

## Workflow Overview

1. **Image (online artifact gathering & base preparation):** Detect or pin an RKE2 release, download all artifacts, verify checksums, cache nerdctl bundles, install OS prerequisites, copy cached artifacts into `/opt/rke2/stage`, capture default DNS/search domains, install optional CA trust, and reboot so the VM can be templated. This step downloads supplemental content and therefore requires Internet access.
2. **Push (offline registry sync):** Load cached images into containerd, retag them against a private registry prefix, generate SBOM or inspect data, and push to an internally reachable registry without using the public Internet.
3. **Server / Add-Server (offline host):** Configure hostname, static networking, TLS SANs, registries, custom CA trust, and execute the cached RKE2 installer.
4. **Agent (offline host):** Mirror the server flow while collecting join tokens, optional CA trust, and persisting run artifacts to `outputs/<metadata.name>/`.
5. **Verify:** Perform prerequisite checks without mutating the system. Useful for smoke tests and compliance validation.

Each action can be driven directly from the CLI or from a YAML manifest (`apiVersion: rkeprep/v1`) that centralizes inputs and secrets.

---

## Actions Breakdown

| Action | Typical Location | Description |
| --- | --- | --- |
| `push` | Offline registry host | Push cached images into your private registry, emitting manifests + SBOMs without touching the public Internet |
| `image` | Connected template host (Internet required) | Download & verify RKE2 release artifacts and nerdctl bundles, install prereqs, stage artifacts, configure registry trust, capture defaults, and reboot |
| `server` | Offline RKE2 control-plane | Configure static networking, TLS, tokens, custom CA, and install `rke2-server` |
| `add-server` | Offline additional control-plane | Same as `server` but tailored for existing clusters |
| `agent` | Offline worker node | Configure network, join tokens, CA trust, and install `rke2-agent` |
| `verify` | Any host | Validate prerequisites without making changes |
| `airgap` | Offline template | Runs `image` but powers off instead of rebooting, ideal for VM templating |

Each action honors both CLI flags and YAML values. When both are provided, YAML values take precedence and are logged accordingly.

---

## Command Reference

```bash
# With a manifest
sudo ./rke2nodeinit.sh -f clusters/prod-image.yaml image

# Direct action without YAML
sudo ./rke2nodeinit.sh --dry-push push -r reg.example.local/rke2 -u svc -p 'secret'

# Print sanitized manifest for auditing
sudo ./rke2nodeinit.sh -f clusters/prod-server.yaml -P server
```

### Common Flags

| Flag | Purpose |
| --- | --- |
| `-f FILE` | Path to YAML manifest (must include `metadata.name`) |
| `-v VERSION` | Explicit RKE2 release (e.g., `v1.34.1+rke2r1`) |
| `-r REGISTRY` | Private registry (host[/namespace]) |
| `-u/-p` | Registry credentials |
| `-y` | Auto-confirm prompts (reboots, legacy runtime cleanup) |
| `-P` | Print sanitized YAML (passwords/tokens masked) |
| `--dry-push` | Simulate `push` without contacting the registry |
| `-h` | Display built-in help |

### Makefile Helpers

- `make token` generates a base64 token using OpenSSL. Override the byte length with `TOKEN_SIZE=<n>` (default `12`) to control the entropy, for example `make token TOKEN_SIZE=24`.
- Each invocation prints the token to stdout and stores it under `outputs/generated-token/token-<YYYYMMDD-HHMMSS>.txt` with restrictive permissions so it can be reused later.

## Development Helpers

- **Generate reusable random tokens** – Run `make token` to print a fresh Base64 token and save it under
  `outputs/generated-token/token-<timestamp>.txt`. Override the number of random bytes (default `12`) by
  supplying `TOKEN_SIZE`, for example: `make token TOKEN_SIZE=24`.

## YAML Configuration Reference

All manifests must set `apiVersion: rkeprep/v1` and `metadata.name`. The `kind` selects the action. Only relevant fields for each action are consumed; extra keys are ignored safely.

```yaml
apiVersion: rkeprep/v1
kind: Image
metadata:
  name: prod-image
spec:
  rke2Version: v1.34.1+rke2r1
  registry: registry.example.local/rke2
  registryUsername: svc
  registryPassword: superSecret123!
  defaultDns: [10.10.10.10, 10.10.20.10]
  defaultSearchDomains: [cluster.local, example.local]
  customCA:
    rootCrt: certs/root.crt
    intermediateCrt: certs/intermediate.crt
    installToOSTrust: true
```

**Supported spec keys (highlights):**

- **Networking:** `ip`, `prefix`, `gateway`, `dns`, `searchDomains`
- **TLS:** `tlsSans`, `token`, `tokenFile`
- **Registry:** `registry`, `registryUsername`, `registryPassword`, `customCA.*`
- **RKE2 Config:** `cluster-cidr`, `service-cidr`, `cluster-dns`, `cluster-domain`, `system-default-registry`, `node-taint`, `node-label`, `disable`, etc.

The script normalizes CSV values (commas or YAML lists) and masks secrets when printing sanitized output (`-P`).

---

## Offline Registry & CA Handling

- Custom CA bundles can be referenced by relative or absolute paths. They are installed into `/usr/local/share/ca-certificates` when `installToOSTrust: true`.
- `/etc/rancher/rke2/registries.yaml` is rendered with mirrors, optional fallback endpoints, and auth blocks derived from the manifest.
- Image pushes produce both `outputs/images-manifest.json` and `.txt` describing source → target retags, plus SBOM or inspect metadata per image under `outputs/sbom/`.
- Registry hosts can be pinned into `/etc/hosts` when IP addresses are provided, ensuring offline name resolution.

---

## Network Configuration Strategy

- Cloud-init network rendering is disabled (`/etc/cloud/cloud.cfg.d/99-disable-network-config.cfg`).
- Existing Netplan YAML files are backed up under `/etc/netplan/.backup-<timestamp>/` before being removed.
- A single authoritative file (`/etc/netplan/99-rke-static.yaml`) is written using the provided IPv4, prefix, gateway, DNS, and search domains.
- Netplan is applied immediately, and interfaces/routes are logged for post-check analysis.

---

## Logging & Observability

- Every execution streams to `logs/rke2nodeinit_<UTC>.log`. When a manifest sets `metadata.name`, action-specific logs are created (e.g., `logs/prod-image_<timestamp>.log`).
- `spinner_run()` ensures long-running downloads/installations emit real-time progress while keeping logs verbose.
- Sensitive values (passwords, tokens) are masked before being printed. Registry credentials are written with `chmod 600`.

---

## Safety Controls & Idempotency

- Script exits on error (`set -Eeuo pipefail`) and reports the failing line number.
- Input validation covers IPv4 addresses, prefixes, DNS lists, and search domains.
- Swap is disabled both immediately and persistently. Kernel modules and sysctl values required by Kubernetes are enforced.
- `verify` mode reuses the same validation logic without mutating the host, making it ideal for change control workflows.

---

## Generated Files & Directory Layout

```text
<repo>/
├─ downloads/                        # image/push cache (images, tarballs, installers, nerdctl bundles)
├─ outputs/
│  ├─ <metadata.name>/               # run-specific exports (README, configs, CA copies)
│  └─ sbom/                          # SBOM or inspect metadata per image
├─ logs/                             # structured execution logs
├─ certs/                            # example CA material consumed by manifests
├─ rke2nodeinit.sh                   # the script
└─ README.md
```

System locations used during installation:

- `/opt/rke2/stage/` – cached artifacts for offline installer
- `/var/lib/rancher/rke2/agent/images/` – pre-loaded image archive
- `/etc/rancher/rke2/` – generated configs, registries YAML, saved join info
- `/usr/local/share/ca-certificates/` – custom registry certificates
- `/etc/netplan/99-rke-static.yaml` – authoritative static network config
- `/etc/rke2image.defaults` – captured defaults reused by later actions

---

## Verification & Troubleshooting

- Run `sudo ./rke2nodeinit.sh verify` to confirm prerequisites (kernel modules, swap state, iptables backend, NetworkManager, UFW rules, staged artifacts).
- Log files provide timestamps and PIDs for forensic review. Search for `[ERROR]` or `[WARN]` entries to triage issues.
- `outputs/<name>/README.txt` summarizes what `image` staged, including versions, registry endpoints, and next steps.
- When custom CA installation fails, review `/usr/local/share/ca-certificates/` and rerun `update-ca-certificates` manually.

---

## Maintenance & Rollback Tips

- **Uninstall RKE2:** disable the services and remove `/etc/rancher`, `/var/lib/rancher`, `/var/lib/rke2`, `/var/lib/kubelet`, and RKE2 binaries.
- **Remove containerd/nerdctl:** stop the service, delete `/usr/local/bin/{containerd*,ctr,nerdctl,runc,buildkit*}`, `/opt/cni`, and `/etc/containerd`.
- **Restore networking:** delete `/etc/netplan/99-rke-static.yaml`, restore backup YAMLs, and `netplan apply`.
- **Re-enable IPv6:** remove `/etc/sysctl.d/99-disable-ipv6.conf` and run `sysctl --system`.

---

## Appendix: Environment Variables

The script honors several environment variables that can be set prior to execution:

| Variable | Purpose |
| --- | --- |
| `RKE2_VERSION` | Pin the release without using `-v` |
| `CONFIG_FILE` | Alternate method to point at a manifest |
| `AUTO_YES` | Set to `1` to auto-confirm prompts (same as `-y`) |
| `DRY_PUSH` | Set to `1` to simulate registry pushes |
| `NO_REBOOT` | Used internally by `action_airgap` to skip rebooting |

---

For more examples, inspect the `examples/` directory or review the inline help via `./rke2nodeinit.sh -h`.
