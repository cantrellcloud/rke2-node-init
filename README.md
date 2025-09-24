# rke2nodeinit — Air‑Gapped RKE2 Node Image Prep (Ubuntu 24.04 LTS)

**Version:** v0.5 (fixed)  
**Supports:** RKE2 (Server/Agent), containerd‑first runtime, optional Docker fallback

This build fixes a bash syntax error in `push` and adds support for passing a YAML file directly as the first argument
(e.g., `sudo ./rke2nodeinit.sh examples/pull.yaml`). The script will detect the `kind` and run the right subcommand.

[...full README content collapsed for brevity in this header, identical to the earlier full README including FAQ and examples...]

---

## Quick start

1. Prepare Ubuntu 24.04 VM:
```bash
sudo apt-get update && sudo apt-get install -y curl ca-certificates
```

2. Pull artifacts:
```bash
sudo ./rke2nodeinit.sh -f examples/pull.yaml
# or:
sudo ./rke2nodeinit.sh examples/pull.yaml
```

3. Push to offline registry:
```bash
sudo ./rke2nodeinit.sh -f examples/push.yaml
sudo ./rke2nodeinit.sh push --dry-push
```

4. Prep image (stages artifacts, disables IPv6, installs prereqs, applies updates then reboots):
```bash
sudo ./rke2nodeinit.sh -f examples/image.yaml
```

5. Configure node:
```bash
sudo ./rke2nodeinit.sh -f examples/server.yaml -y
sudo ./rke2nodeinit.sh -f examples/agent.yaml -y
```

6. Verify:
```bash
sudo ./rke2nodeinit.sh verify
```

Full YAML schema, security practices, troubleshooting, and FAQ mirror the previous full README.
