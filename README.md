# RKE2 Air-Gapped Image Prep – **rkeimage**
(abridged here for reconstruction; full details were provided earlier)

---

## New Quality-of-Life Flags

- **`-y` / `--yes` (auto-reboot)**: When used with `server` or `agent`, the script will auto-confirm the reboot needed to apply Netplan & hostname changes.
- **`-P` / `--print-config` (sanitized YAML)**: Prints the provided YAML manifest with secrets masked (`registryPassword`, `token`) for troubleshooting, then continues.
