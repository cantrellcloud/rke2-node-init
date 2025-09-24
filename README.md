# RKE2 Air-Gapped Image Prep (Consolidated)

- Search domains prompt and YAML keys (`server_search_domains`, `agent_search_domains`), plus `default_search_domains` fallback.
- Multiple DNS servers (comma-separated) for server/agent (`server_dns`, `agent_dns`).
- Runtime selection for pull/push: prefer containerd/nerdctl; install if absent; else use Docker if present.
- IPv6 disabled in `image` via `/etc/sysctl.d/99-disable-ipv6.conf`.
- CIDR validation: IPv4, prefix (0–32), single optional gateway IPv4, CSV DNS IPv4s, CSV search domains.
- Custom subnet prefix per node: `server_prefix`, `agent_prefix` (prompts if missing; default 24).

## YAML example
```yaml
rke2_version: v1.33.1+rke2r1
registry: kuberegistry.dev.kube/rke2
registry_username: admin
registry_password: ZAQwsx!@#123

default_search_domains: corp.local,dev.kube

server_ip: 10.0.0.10
server_prefix: 24
server_hostname: cluster1-server1
server_dns: 1.1.1.1,8.8.8.8
server_search_domains: corp.local,dev.kube

agent_ip: 10.0.0.11
agent_prefix: 24
agent_hostname: cluster1-agent1
agent_dns: 1.1.1.1,8.8.4.4
agent_search_domains: corp.local,dev.kube

server_url: https://10.0.0.10:9345
token: <cluster-join-token>
```


### Default DNS
- If per-node DNS is not provided, the script uses **10.0.1.34,10.231.1.34** as the default for both server and agent.
- You can optionally override the site-wide default via YAML:
  - `default_dns: 10.0.1.34,10.231.1.34`
