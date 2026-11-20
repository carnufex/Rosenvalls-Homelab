# Lots

The agent shell [carnufex/Lots](https://github.com/carnufex/Lots): an OIDC-protected UI and API where AI runs use tools
through per-call policy, approvals and an append-only audit log. Public at `https://lots.rosenvall.se`.

## What runs here

- `lots` Deployment (1 replica, restricted pod/container security context, read-only root filesystem, non-root).
- `lots-postgresql` CloudNativePG cluster (runs, trace, approvals, audit). Migrations run at startup.
- Profile `cmdb` (ConfigMap `lots-profiles`): tools of the CMDB's MCP server, used as the `cmdb-agents` service account.
  The homelab (Docker) profile is not deployed: it needs Docker access, which does not exist in the cluster.
- Model: `gemma4-26b` (Gemma 4 26B-A4B; `qwen3.5` until 2026-10-31, since removed from the server) on the GPU PC's model server (llama-server, Lots `services/models`) at `192.168.1.215:8720`, key
  `LOTS_MODEL_KEY` (so a run fails while that host is off). Until 2026-10-31 it was `qwen3.5:latest` on Ollama via Service
  `ollama/ollama`, which stays for Rosenvall DevOps; going back is `Model__BaseUrl`, `Model__Model` and dropping `Model__ApiKeyEnv`.
- Voice: the Lots voice service (Whisper, Chatterbox, meeting diarization) on the same GPU PC at `192.168.1.215:8700`
  (`Speech__BaseUrl`; started there with `docker compose up -d` in `services/voice` of carnufex/Lots). By address, not a
  selector-less Service like Ollama's: ArgoCD's default resource exclusions skip `Endpoints`, so such a Service gets no
  endpoint from Git (ollama/ollama only has one from an older sync and would lose it if recreated).
  The cluster has no GPU. While the PC is off the UI says voice is unavailable; typing still works. Conversation audio and
  meeting recordings are stored encrypted on the 10 Gi Longhorn volume `lots-audio` (`audio.yaml`, mounted at /data/audio, kept
  30 days). It is ReadWriteOnce, so the deployment's pod affinity keeps a new pod on the running one's node during a rollout.
- Tool pack (`toolpack.yaml`): the Lots MCP tool pack with the internet packs (weather, Wikipedia, exchange rates, maps, holidays,
  news feeds, arXiv, SMHI, Polisen, Krisinformation; no keys). Install the "Internet tools" plugin in Lots (Administration > Plugins)
  with `toolpackUrl` `http://lots-toolpack:8080/mcp`; users then switch the tools on under Account > Tools. Its egress is limited to
  those public hosts (`networkpolicy.yaml`, policy `lots-toolpack`); a new news feed needs its host added there.
- Plugins: the shell image ships its plugin catalog (internet, web-research, docker-ops); installed plugins live in the database.
- Knowledge: embeddings with `snowflake-arctic-embed2` on the same model server (alias `embed`; the same vectors as Ollama's); users add their own sources on the
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
| Slack incoming webhook (the Alertmanager entry) | Lots' admin notices: dependency down/up, price changes, approval requests (`Notifications__Webhooks__0__Url`) |
| `LOTS_BWS_ACCESS_TOKEN` | access token of the machine account `lots-prod` in Lots' own Bitwarden Secrets Manager organisation (EU), read access to its project `Lots` only (`BWS_ACCESS_TOKEN`, used by the bitwarden-secrets plugin) |
| `GHCR_PAT`, registry password | image pull secret (same entries as the other apps) |

Lots' own Bitwarden organisation (separate from the homelab one) holds what Lots itself reads as `bitwarden:<name>`: project `Lots`
(`d9ca876d-4722-4c61-9798-b4e1007de5b8`) with `BERGET_API_KEY` (a key of its own, not the homelab one; the berget plugin's `apiKey`
setting is `bitwarden:BERGET_API_KEY`). The homelab entry `BERGET_API_KEY` is no longer read by Lots.

## Deploy a new version

```powershell
docker build --platform linux/amd64 -f src/Lots.Shell/Dockerfile -t registry.rosenvall.se/carnufex/lots-shell:sha-<short> .   # in carnufex/Lots
docker push registry.rosenvall.se/carnufex/lots-shell:sha-<short>
```

Put the new `tag@sha256:<digest>` into `app.yaml` and push; ArgoCD syncs it.

## Incidents demo

A demo of Lots' Incidents (carnufex/Lots `docs/incidents.md`, `docs/demo.md` "The incident path") on synthetic data. Nothing in it
touches a real system: the "network" is the tool pack's demo pack, a made-up fibre network in Malmö, and the investigation is
answered by the pack's scripted model, so it is the same every time.

- **Run it:** sign in as an admin, **Incidents > Sources**, source `demo-network`, **Cut a cable**, confirm. The shell asks the tool
  pack to cut cable MAL-019; the pack sends the alert to `POST /signals/demo-network`; after the 5 s settle time one run investigates
  it in the `network` context. Follow **See the incidents**: about 12 s after pressing, the incident has a confirmed finding with two
  pieces of evidence. The button is refused a second time within a minute.
- **Restore it** (the cable stays cut and the incident open until then; a second drill only adds an occurrence):

  ```bash
  kubectl -n lots port-forward deploy/lots-toolpack 18080:8080
  ```

  ```bash
  curl -X POST http://localhost:18080/demo/reset
  ```

  The pack restores the cable and sends the alert as resolved, which closes the incident. Restarting the tool pack also restores
  the cable but sends nothing, so the incident stays open.
- **Parts:** `Demo__*` on the tool pack (`toolpack.yaml`); the context `network` and the model alias `scripted` (`app.yaml`); the
  alert source `demo-network` with its drill, the service `malmo-fibre` and the runbook skill (`gitops/incidents-demo.yaml`); the
  tool pack to shell rule (`networkpolicy.yaml`); the alert source's secret `LOTS_DEMO_SIGNAL_SECRET` (`secrets.yaml`).
- **Remove it:** delete those parts; the incidents it made stay in the database until Lots' retention removes them.
- The tool pack image is built by hand (Lots' pipeline publishes only the shell): from a clean checkout of carnufex/Lots,
  `docker build --platform linux/amd64 -f src/Lots.Mcp.Toolpack/Dockerfile -t registry.rosenvall.se/carnufex/lots-mcp-toolpack:sha-<short> .`,
  push that tag, and pin it here by tag and digest.

## Incidents on the real cluster

Lots' Incidents on a real fault in this cluster: an admin breaks the demo service `demo-api` in `oncall-demo` on purpose, the
cluster's own alerting sends the alert to Lots, and one run investigates it with read-only Kubernetes tools, as the service identity
`svc-homelab-sre`, and reports a finding with evidence. When the finding says a release caused it, the agent then proposes one
rollback, which waits for a person (the fix path, below); it changes nothing on its own.

- **Run it:** sign in as an admin, **Incidents > Sources**, source `homelab-alertmanager`, **Break demo-api**, confirm. Roughly:
  1. The shell calls `POST http://oncall-tools.oncall-demo.svc.cluster.local:8080/drill/break` (bearer `LOTS_DRILL_ONCALL_TOKEN`).
     oncall-tools commits `oncall-demo-api:1.1.0` in place of `1.0.0` to `applications/oncall-demo/demo-api-deployment.yaml` on
     `master` ("Drill triggered from Lots.") and asks ArgoCD to refresh; the button's outcome line shows the commit (1-3 s).
  2. ArgoCD rolls it out; the new pod crashes on boot and is in `CrashLoopBackOff` after its first restart (about 30 s). The old
     1.0.0 pod keeps serving, so nothing is down.
  3. `OncallDemoPodCrashLooping` fires on the next scrape and evaluation (up to about a minute; `for: 0s`), and Alertmanager's
     route `lots` posts it to `POST /signals/homelab-alertmanager` after 5 s.
  4. After the 20 s settle time the gate lets the incident through (service `demo-api`), and a run in the context `homelab-ops`
     investigates: describe the pod, read the crashed container's previous log, compare with the healthy pod, `report_finding`
     (about a minute). In all, about two to four minutes from the button to the finding.
- **Restore it** (the crashing pod stays until then):
  - `/oncall reset` in Slack; or
  - `kubectl -n oncall-demo port-forward deploy/oncall-tools 18081:8080`, then
    `curl -X POST -H "Authorization: Bearer <token>" http://localhost:18081/drill/reset` (the token is the Bitwarden entry
    `LOTS_DRILL_ONCALL_TOKEN`); or
  - revert the drill's commit on `master`.

  The new pod goes, the alert resolves, and Alertmanager sends the resolved alert, which resolves the incident.
- **What the agent can reach:** the tool pack's `k8s_list`, `k8s_describe` and `k8s_logs` (GET only), as the ServiceAccount
  `lots-toolpack` (`ops-rbac.yaml`, a ClusterRole): get, list and watch in every namespace on the kinds those tools know (pods,
  pods/log, events, services, PVCs, nodes, namespaces, deployments, statefulsets, daemonsets, jobs, cronjobs, ingresses). No
  Secrets, no ConfigMaps, no writes, no exec, and nothing outside Kubernetes (Proxmox, OpenTofu state). Every namespace since
  2026-11-20, when every alert started reaching Lots; until then `oncall-demo` alone. What it reads, pod specs with plain env
  values and logs included, goes to the context's model and is kept with the run. That model is the alias `default`, whose
  first targets are hosted (Berget AI, in Sweden; the GPU PC's model is the last fallback), so cluster logs leave the LAN. Its only way to
  change anything is the approved `rollback_service` above; the drill button (an admin) and the reset (a person) are not the agent's.
- **The fix path:** the service `demo-api` has `autonomy: propose`, so its investigation runs with the role `responder`
  (`proposeRoles` on the alert source) and may call oncall-tools' two operations through the tool pack's OpenAPI pack:
  `recent_changes` (`GET /ops/changes`, read) and `rollback_service` (`POST /ops/rollback`, write). The runbook has it compare the
  time of the last image change with when the pod started failing. After `report_finding`, and only when the finding says the
  release caused it, the run calls `rollback_service` once with a one-line reason; Lots holds the call.
  1. **Approve:** the proposal shows on the incident's page (Approve / Deny) and on **Approvals**; anyone with the `admin` role in
     `homelab-ops` decides. Unanswered, it lapses after four hours; after an hour `LotsApprovalBacklog` fires (`monitoring.yaml`).
  2. **After approval:** the tool pack calls `POST /ops/rollback` (bearer `LOTS_ONCALL_OPS_AUTH`); oncall-tools commits
     `oncall-demo-api:1.0.0` in place of `1.1.0` to `demo-api-deployment.yaml` on `master` as `oncall-copilot` ("Approved in
     Lots", with the reason), asks ArgoCD to refresh, and resolves the voice demo's open incidents in Slack as `/drill/reset` does
     (1-3 s). ArgoCD rolls it out and the crashing pod goes in about a minute; the alert resolves and so does the incident.
  3. **Denied** (or lapsed): nothing is committed; restore by hand as below.
- **What the agent can and cannot do:** read one namespace (below) and ask for one rollback. `rollback_service` rolls back only
  `demo-api` (oncall-tools' `ALLOWED_DEPLOYMENTS`), only to the healthy tag oncall-tools is configured with (`DEMO_GOOD_TAG`; the
  request cannot name a tag or an image), and only after a person approved it. The commit is made by oncall-tools with its own
  fine-grained GitHub token (limited to this repository; oncall-tools writes only `demo-api-deployment.yaml` with it); the agent
  holds no token for GitHub, Kubernetes writes or Secrets. A person with
  `admin` can approve but not call it (`policyTests` in `app.yaml`).
- **Turn proposing off:** `autonomy: observe` on the service `demo-api` (`gitops/incidents-homelab.yaml`); the run then only
  reports the finding. To remove the fix path: the OpenAPI lines, volume and mount (`toolpack.yaml`), `lots-oncall-openapi`
  (`kustomization.yaml`, `openapi/oncall-ops.json`), `LOTS_ONCALL_OPS_AUTH` (`secrets.yaml`), the tool pack's rule to oncall-tools
  (`networkpolicy.yaml`), `LotsApprovalBacklog` (`monitoring.yaml`), `proposeRoles` and the runbook's fix part, and in `homelab-ops`
  the two tools, the `responder` role, `approvals` and their policy tests.
- **What is sent to Lots:** every alert except Lots' own (`alertname !~ "Lots.+"`: it cannot investigate itself being down); the
  first child route in `infrastructure/monitoring/prometheus-stack/values.yaml`, with `continue: true`. Every alert still reaches
  Slack `#homelab-alerts` as before; the last child route is the catch-all to `slack-homelab` that keeps it so. The two cron
  checks come the same way, as alerts they raise in Alertmanager: the Proxmox storage check (`ProxmoxStorageFilling`,
  `ProxmoxStorageCheckFailed`; Alertmanager also tells Slack, once and then every `repeat_interval`) and the tofu-drift job
  (`OpenTofuDrift`, `OpenTofuDriftCheckFailed`; the job tells Slack itself, so their route after `lots` ends in `null`).
- **One thing, one incident:** Alertmanager repeats a firing alert every 4 h and both checks send theirs again on every run. In
  Lots each of those is an occurrence of the alert's open incident (also of one the gate skipped), never a second incident and
  never a second investigation or approval notice. A new incident starts only after the alert resolved and fires again. Only
  `demo-api` is a service; every other alert is one incident per `alertname` and `namespace` in `homelab-ops`, investigated
  read-only. An alert that resolves within the source's two-minute settle time is settled without an investigation.
- **Parts:** the context `homelab-ops` (`app.yaml`, `lots-profiles`); the runbook `crashloop-runbook`, the service `demo-api` and the
  alert source `homelab-alertmanager` with its drill (`gitops/incidents-homelab.yaml`); the ServiceAccount and the Role
  (`ops-rbac.yaml`); `Kubernetes__InCluster`, `serviceAccountName: lots-toolpack` and the `OpenApi__*` lines (`toolpack.yaml`);
  `lots-oncall-openapi` (`kustomization.yaml`); four rules in `networkpolicy.yaml` (Alertmanager to the shell, the shell and the
  tool pack to oncall-tools, the tool pack to the API server); `LOTS_SIGNAL_HOMELAB`, `LOTS_DRILL_ONCALL_TOKEN` and
  `LOTS_ONCALL_OPS_AUTH` (`secrets.yaml`); in `oncall-demo`, `DRILL_API_TOKEN` (`tools-externalsecret.yaml`); in
  `monitoring`, the ExternalSecret `alertmanager-lots`, the receiver and the three routes in `values.yaml` (`lots`, the
  OpenTofu route to `null`, the catch-all), and `oncall-demo-alerts.yaml`.
- **When it does not work:** the shell's log lines for signals and investigations, Lots' alerts `LotsSignalsRefused` (a wrong
  bearer: Alertmanager's copy of `LOTS_SIGNAL_HOMELAB`), `LotsInvestigationsFailing` and `LotsIncidentsNotInvestigated`
  (`monitoring.yaml`; `LotsSignalsSilent` is not deployed: the source has no heartbeat), `LotsApprovalBacklog` for a rollback nobody
  answered, a failed rollback as the tool's error in the run (`HTTP 502 ... commit_failed`, `HTTP 409 ... file_drifted`) and as a
  failed fix on the incident, oncall-tools' log lines `ops: ...`, the rollback commit by `oncall-copilot` in this repository's
  history, the drill's outcome line
  and audit row (`GET /audit?tool=incident.drill`), the tool pack pod's readiness, and `hubble observe -n lots --verdict DROPPED`.
- **Remove it:** delete those parts (the three Alertmanager routes and the receiver together); the incidents it made stay in the
  database until Lots' retention removes them. The storage check then still reaches Slack through Alertmanager; the tofu-drift
  job's alert block can stay (nothing routes it) or go.

## Updates

The homelab updates itself as far as rules allow, and asks a person for the rest.

- **What update-center does on its own** (carnufex/update-center, `docs/operations/update-center.md`): patch and digest bumps of
  apps, fixes for high and critical CVEs up to a minor, Talos patches (then the tofu pin) and Proxmox packages, in its nightly window
  (critical CVEs at once). Every bump is verified (ArgoCD synced and healthy, the new image running) and reverted automatically when
  it is not.
- **What comes to Lots:** everything its rules do not clear (majors, minors, databases and platform components under
  `kubernetes/infrastructure`, Kubernetes minors) as `UpdateNeedsDecision`, advisories no update covers as `SecurityAdvisory`, and
  every update that failed and was rolled back as `UpdateFailed`. update-center posts one alert per component to
  `POST /signals/update-center` and resolves it when the component is up to date.
- **What Lots does:** one incident per component (the service `updates`, `groupBy: [component]`), investigated in the context
  `homelab-updates` as `svc-homelab-updates`: `get_update`, `release_notes`, a finding, and, when no manual step comes first,
  the proposal `apply_update`. It waits for a person with admin on the incident page and on Approvals; the admin notice
  `approval.requested` announces it in `#homelab-alerts`. Approved, update-center applies it with the same verification and rollback.
- **Parts:** the context `homelab-updates` (`app.yaml`), `gitops/incidents-updates.yaml` (runbook, service, source),
  `toolpack-updates.yaml` (a second tool pack with only the OpenAPI pack, pointed at update-center's `/api/lots/openapi.json`),
  `Mcp__ToolServerAuth__Hosts__1` (`app.yaml`), the rules for update-center to the shell and the tool pack to update-center
  (`networkpolicy.yaml`), `LOTS_SIGNAL_UPDATES` and `LOTS_UPDATES_AUTH` (`secrets.yaml`; Bitwarden `lots-signal-update-center` and
  `update-center-lots-tool-token`, which update-center reads as `LOTS_SIGNAL_TOKEN` and `SERVICE_TOKENS`).
- **When it does not work:** update-center's log lines `lots-signal: <fingerprint> <status> -> <http status>` and `auto: ...`,
  `LotsSignalsRefused` (a wrong bearer), `LotsInvestigationsFailing`, `LotsApprovalBacklog`, the tool pack's startup warning when it
  could not fetch the OpenAPI document (restart `deploy/lots-toolpack-updates` once update-center answers), and a failed or
  rolled-back job on update-center's Jobs tab.
- **Turn it off:** `autonomy: observe` on the service (findings only), `enabled: false` on the source (nothing in), or
  `AUTO_ENABLED=false` on update-center (nothing applied on its own).

## Network

Default deny (`networkpolicy.yaml`). Ingress only from the Cilium Gateway, and from Prometheus to the metrics port `9090`.
Egress: PostgreSQL, Authentik and the CMDB by name (443), the OpenTelemetry Collector in `monitoring` (`4317`), and the GPU PC
`192.168.1.215`: the model server `8720`, Ollama `11434`, the voice service `8700`, the document service `8710` and the decision
models `8096`/`8097`.

## Observability

- Metrics: `/metrics` on port `9090` (`Metrics__Port`), scraped through `monitoring.yaml` (ServiceMonitor), alert rules
  `PrometheusRule/lots` (the Lots chart's rules), dashboard "Lots" in Grafana (`grafana/lots-dashboard.json`, a copy of the Lots
  repo's `deploy/grafana/lots-dashboard.json`: copy it again when that one changes).
- Traces: OTLP to `otel-collector.monitoring:4317` (every trace but the health probes'), stored a week in Tempo. The run log's **Trace** link opens the trace in Grafana Explore (`Telemetry__TraceUrlTemplate`,
  `grafana.rosenvall.local`, LAN only); a span links to its log lines in Loki and a log line's `trace_id` back to the trace.

## Troubleshooting

- `kubectl -n lots get pods,cluster,externalsecret`
- Sign-in fails with 403/empty roles: the user is not in a `lots-*` group (token claim `groups`).
- Runs fail with a connection error: the GPU PC is off, or its model server is down (`docker compose ps` in Lots
  `services/models`; the watchdog starts a stopped one within a minute).
- Voice unavailable: the PC is off or the voice container is down (`curl http://192.168.1.215:8700/health` from the LAN).
- Documents listed as failed / no reranking: the document service is down (`curl http://192.168.1.215:8710/health`).
- Routing page shows no decision model answers: the decision services are down (`curl http://192.168.1.215:8097/health`).
- Dropped traffic: `hubble observe -n lots --verdict DROPPED`.
