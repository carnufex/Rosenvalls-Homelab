# Lots

The agent shell [carnufex/Lots](https://github.com/carnufex/Lots): an OIDC-protected UI and API where AI runs use tools
through per-call policy, approvals and an append-only audit log. Public at `https://lots.rosenvall.se`.

## What runs here

- `lots` Deployment (1 replica, restricted pod/container security context, read-only root filesystem, non-root).
- `lots-postgresql` CloudNativePG cluster (runs, trace, approvals, audit). Migrations run at startup.
- Profile `cmdb` (ConfigMap `lots-profiles`): tools of the CMDB's MCP server, used as the `cmdb-agents` service account.
  The homelab (Docker) profile is not deployed: it needs Docker access, which does not exist in the cluster.
- Model: `qwen3.5:latest` on the Ollama host via Service `ollama/ollama` (so a run fails while that host is off).

## Identity

Authentik application `lots` (blueprint `apps-lots.yaml`, public PKCE client `lots`). Roles come from Authentik groups
with the prefix `lots-`: `lots-admin` (approves writes, reads all runs and the audit), `lots-planner` (may draft CMDB
plans, with approval), `lots-operator` (read tools), `lots-auditor` (audit log). Only members of those groups can sign in.
Add a user to a group in Authentik to give access.

## Secrets (Bitwarden, via ExternalSecrets)

| Bitwarden entry | Used for |
|---|---|
| `LOTS_DB_PASSWORD` | CNPG bootstrap secret and the connection string |
| `CMDB_AGENT_TOKEN` | app password of the `cmdb-agent-demo` service account (profile `passwordEnv`) |
| `GHCR_PAT`, registry password | image pull secret (same entries as the other apps) |

## Deploy a new version

```powershell
docker build --platform linux/amd64 -f src/Lots.Shell/Dockerfile -t registry.rosenvall.se/carnufex/lots-shell:sha-<short> .   # in carnufex/Lots
docker push registry.rosenvall.se/carnufex/lots-shell:sha-<short>
```

Put the new `tag@sha256:<digest>` into `app.yaml` and push; ArgoCD syncs it.

## Network

Default deny (`networkpolicy.yaml`). Ingress only from the Cilium Gateway. Egress: PostgreSQL, Authentik and the CMDB by
name (443), and the Ollama host `192.168.1.215:11434`.

## Troubleshooting

- `kubectl -n lots get pods,cluster,externalsecret`
- Sign-in fails with 403/empty roles: the user is not in a `lots-*` group (token claim `groups`).
- Runs fail with a connection error: the Ollama host is off.
- Dropped traffic: `hubble observe -n lots --verdict DROPPED`.
