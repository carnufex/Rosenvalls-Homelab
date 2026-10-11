# Lots

The agent shell [carnufex/Lots](https://github.com/carnufex/Lots): an OIDC-protected UI and API where AI runs use tools
through per-call policy, approvals and an append-only audit log. Public at `https://lots.rosenvall.se`.

## What runs here

- `lots` Deployment (1 replica, restricted pod/container security context, read-only root filesystem, non-root).
- `lots-postgresql` CloudNativePG cluster (runs, trace, approvals, audit). Migrations run at startup.
- Profile `cmdb` (ConfigMap `lots-profiles`): tools of the CMDB's MCP server, used as the `cmdb-agents` service account.
  The homelab (Docker) profile is not deployed: it needs Docker access, which does not exist in the cluster.
- Model: `qwen3.5:latest` on the Ollama host via Service `ollama/ollama` (so a run fails while that host is off).
- Voice: the Lots voice service (Whisper, Chatterbox, meeting diarization) on the same GPU PC at `192.168.1.215:8700`
  (`Speech__BaseUrl`; started there with `docker compose up -d` in `services/voice` of carnufex/Lots). By address, not a
  selector-less Service like Ollama's: ArgoCD's default resource exclusions skip `Endpoints`, so such a Service gets no
  endpoint from Git (ollama/ollama only has one from an older sync and would lose it if recreated).
  The cluster has no GPU. While the PC is off the UI says voice is unavailable; typing still works. Conversation audio and
  meeting recordings are not stored here (no volume), so the Meetings page answers that meetings are not configured.
- Tool pack (`toolpack.yaml`): the Lots MCP tool pack with the internet packs (weather, Wikipedia, exchange rates, maps, holidays,
  news feeds, arXiv, SMHI, Polisen, Krisinformation; no keys). Install the "Internet tools" plugin in Lots (Administration > Plugins)
  with `toolpackUrl` `http://lots-toolpack:8080/mcp`; users then switch the tools on under Account > Tools. Its egress is limited to
  those public hosts (`networkpolicy.yaml`, policy `lots-toolpack`); a new news feed needs its host added there.
- Plugins: the shell image ships its plugin catalog (internet, web-research, docker-ops); installed plugins live in the database.
- Knowledge: embeddings with `snowflake-arctic-embed2` on the same Ollama (alias `embed`); users add their own sources on the
  Knowledge page. Changing the model re-embeds in the background and switches when the new index is complete (#165).
- Documents: the Lots document service (Docling: layout, tables, OCR, page provenance) and its reranker (bge-reranker-v2-m3) on
  the GPU PC at `192.168.1.215:8710` (`docker compose up -d` in `services/documents` of carnufex/Lots, key in its `.env`).
  While the PC is off, new documents wait for the next index run; indexed ones stay searchable, without reranking.

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
| `LOTS_VOICE_KEY` | API key of the voice service on the GPU PC (its `VOICE_API_KEY`; shell `Speech__ApiKeyEnv`) |
| `LOTS_DOCUMENTS_KEY` | API key of the document service on the GPU PC (its `DOCUMENTS_API_KEY`; shell `Documents__ApiKeyEnv` and the rerank endpoint) |
| `GHCR_PAT`, registry password | image pull secret (same entries as the other apps) |

## Deploy a new version

```powershell
docker build --platform linux/amd64 -f src/Lots.Shell/Dockerfile -t registry.rosenvall.se/carnufex/lots-shell:sha-<short> .   # in carnufex/Lots
docker push registry.rosenvall.se/carnufex/lots-shell:sha-<short>
```

Put the new `tag@sha256:<digest>` into `app.yaml` and push; ArgoCD syncs it.

## Network

Default deny (`networkpolicy.yaml`). Ingress only from the Cilium Gateway. Egress: PostgreSQL, Authentik and the CMDB by
name (443), and the GPU PC `192.168.1.215`: Ollama `11434`, the voice service `8700` and the document service `8710`.

## Troubleshooting

- `kubectl -n lots get pods,cluster,externalsecret`
- Sign-in fails with 403/empty roles: the user is not in a `lots-*` group (token claim `groups`).
- Runs fail with a connection error: the Ollama host is off.
- Voice unavailable: the PC is off or the voice container is down (`curl http://192.168.1.215:8700/health` from the LAN).
- Documents listed as failed / no reranking: the document service is down (`curl http://192.168.1.215:8710/health`).
- Dropped traffic: `hubble observe -n lots --verdict DROPPED`.
