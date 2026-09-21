# update-center — runbook

`https://updates.rosenvall.local` (LAN only, Authentik SSO). Source and build:
[carnufex/update-center](https://github.com/carnufex/update-center). Deployment:
`kubernetes/applications/update-center/` (README there lists every credential).

## What it does

Scans every 30 min (or on "Uppdatera listan"):

1. **Apps** — downloads the repo at `HEAD`, finds every `image:` line and kustomize
   `helmCharts` version under `kubernetes/applications` + `kubernetes/infrastructure`
   (vendored `charts/`, `vendor/`, `crds/` skipped), asks the registry (Docker Hub API,
   OCI `/v2/…/tags/list` for ghcr/quay/lscr/codeberg/…) or the chart `index.yaml` for
   newer tags **on the same track** (same prefix, same number of numeric segments, same
   suffix family: `-alpine`, `-rootless`, `-lsNNN`, plex build hash, MinIO `RELEASE.`).
   Digest-pinned tags are also checked for a rebuilt same tag. `registry.rosenvall.se`
   images are listed as *own build* and never bumped here. Live pod images are compared
   with Git and shown as *drift*.
2. **Talos / Kubernetes** — node `osImage` vs latest `siderolabs/talos` release; kubelet vs
   the Kubernetes version the running Talos minor ships (`DefaultKubernetesVersion`).
3. **Proxmox** — `/cluster/status`, `/nodes/*/status`, `/apt/versions`, `/apt/update`
   (pending packages), `/qemu` guests; over SSH: `/var/run/reboot-required`.

4. **Tofu pins** (Talos tab) - `talos_version` default in `tofu/variables.tf` vs the Talos version the nodes run,
   and the Cilium version in `tofu/talos/inline-manifests/cilium-install.yaml` vs the GitOps chart. These are what a
   cold rebuild starts from; upgrades happen in place, so they drift unless synced.

5. **Resurser** - requests/limits vs measured usage. Prometheus keeps 3 days, so the tool samples daily maxima/p95
   per workload container and node and keeps 30 days in ConfigMap `update-center/update-center-usage-history`
   (delete it to start over). Until 7 days exist the tab is marked *preliminärt* and *Tillämpa* is disabled.
   Categories: över-/underallokerad, saknar request, databas/cache (never auto-recommended). Also per-node
   requested vs really used vs VM RAM in Proxmox, and PVC used vs capacity.

## The Översikt order (top = next move)

The landing tab lists what to do in this fixed order, so the top group is always the
right next step: **Åtgärda först** (a NotReady node, an offline host, a Degraded Argo app:
nothing else should run, and the fleet health gates would stop there anyway) → safe patches
(one commit, no reboot) → minor updates → Proxmox hosts (hypervisor before OS; automated
with health gate) → Talos nodes then Kubernetes (OS before orchestrator) → major updates
(manual: release notes, DB snapshot, one at a time) → resources (optimisation) → lookup
failures (registry/GitHub timeouts, informational). Rule: automated and low-risk first,
manual and risky last.

## Buttons and what they actually run

| Button | Flow | Rollback |
|---|---|---|
| Översikt / Appar → **Uppdatera alla patchar** / **Uppdatera valda** | every selected image/chart bump as ONE commit (Git Data API; refuses before writing if any line drifted or two selections hit the same line), then `refresh=hard` + wait for each touched ArgoCD app in turn | `git revert` the single commit |
| Appar → **Uppdatera** | one Git commit (Git Data API) replacing every line that pins that value in the app, `argocd.argoproj.io/refresh=hard` on the app, wait ≤10 min for Synced/Healthy + rollout | `git revert` the commit (or click the older tag once the tool can see it — it can't; revert in Git) |
| Talos → **Uppgradera** | cordon → CNPG-aware drain (deletes CNPG instances so they rebuild elsewhere, evicts the rest, leaves Longhorn instance-manager) → for CPs `talosctl etcd status` + `etcd snapshot` (to the pod's `/tmp`) → `talosctl upgrade --image factory.talos.dev/nocloud-installer/<schematic>:<ver> --reboot-mode=powercycle --drain=false --wait` → stale DaemonSet pod cleanup + wait stable → uncordon. Steps through minors (latest patch each). | Talos keeps the previous install in the B partition: `talosctl rollback -n <ip>` |
| Talos → **Uppgradera alla noder** | every node behind the latest Talos, one at a time: compute-only workers, then Longhorn workers, then control planes. Per node: cluster health gate (same as the Proxmox run) → the *Uppgradera* flow above. The node running update-center is taken last: the job writes a continuation to the jobs ConfigMap, finishes itself, cordons the node and deletes its own pod; the new pod (on another node) starts "… (fortsättning)" ~20 s later and upgrades the old node. The UI loses contact for ~30 s. Any failure aborts the run | per node: `talosctl rollback` |
| Talos → **Flytta update-center** | shown only on the node the tool's own pod runs on: cordons the node and deletes its own pod so it reschedules elsewhere (node is uncordoned by the upgrade flow when it finishes) | `kubectl uncordon <node>` |
| Talos → **Uppgradera Kubernetes** | etcd snapshot → `upgrade-k8s --dry-run` → `upgrade-k8s --to <ver>` | `upgrade-k8s --to <old>` |
| Talos → **Synka tofu** | one commit bumping the `talos_version` default in `tofu/variables.tf` to the live version. Never touches state or nodes; `terraform.tfvars` is gitignored, bump it locally. Cilium bootstrap drift is display-only: run `scripts/render-cilium-bootstrap.ps1` and commit | `git revert` |
| Resurser → row expand | 30-day sparklines (max memory, p95 cpu per day) against the request and the recommendation; read-only | — |
| Resurser → **Tillämpa** | one commit replacing only that container's `resources:` block in its plain manifest (requests = measured max + 25 % / cpu p95; an existing memory limit is kept, a missing one is added; never a cpu limit). The edit is verified by re-parsing: anything else changing aborts. ArgoCD rolls the pod. Helm-managed workloads: change `values.yaml` by hand | `git revert` |
| Proxmox → **Sök uppdateringar** | `POST /nodes/<n>/apt/update` (task) | — |
| Proxmox → **Installera uppdateringar** | SSH: `apt-get update && apt-get -y full-upgrade` (confdef/confold), `autoremove`, re-disables `pve-enterprise.sources` if the upgrade re-enabled it | apt logs on the host |
| Proxmox → **Starta om (säkert)** | refuses while Longhorn volumes are not healthy if the host carries storage nodes; drain every k8s node on the host (control planes last; refuses if <2 other CPs Ready) → `POST /nodes/<n>/status command=reboot` → wait offline → wait online → start guests that were running → wait Ready → clean stale pods → uncordon → wait stable (uncordon first: pods pinned to the node, e.g. Plex on worker-01, otherwise deadlock the wait) | if it stalls: nodes stay cordoned; `kubectl uncordon` after the host is back |
| Proxmox → **Uppdatera alla** | every host with pending packages, one at a time ordered by blast radius (compute-only hosts first; control-plane/storage hosts last; the host running update-center last: if it needs a reboot the job hands over to a new pod on another host, which reboots it). Per host: health gate (all nodes Ready+schedulable, no new unhealthy workloads vs the start baseline, CNPG healthy, ALL Longhorn volumes healthy, up to 3 h) → `apt full-upgrade` → reboot only if required (same flow as *Starta om (säkert)*). Any failure aborts the run and leaves the remaining hosts untouched | per host as above |
| Proxmox → **Flytta update-center** | shown only when the tool's own pod runs on that host: cordons the host's nodes and deletes its own pod so it reschedules elsewhere; then reload and click reboot (which uncordons at the end) | **Uncordon noder** button |

Only one job runs at a time; every button confirms first; the actor (SSO e-mail)
is logged with the job. Every job shows its phases as a step checklist (with the live
log underneath) and an estimate from earlier runs; a running job is shown as a banner on
every tab. The last 40 jobs (log tail included) and per-action durations are persisted
in the ConfigMap `update-center-jobs`, so history survives pod restarts; a job that was
running when the pod died shows as failed.

## Known limits

- Images pinned by digest only (no tag) and `sha-<git>` own builds are not compared.
- Upstream lookups are anonymous: Docker Hub rate-limits bursts (the tool backs off and
  retries; a row can still show *error* for one scan — rescan).
- The Talos flow needs a talosctl matching the target version; it is downloaded from
  GitHub releases into the pod's `/tmp` on first use.
- The pod cannot reboot the host it runs on (see *Flytta update-center*). Node affinity
  prefers the compute-only workers.
- Proxmox `apt full-upgrade` needs the SSH key from `scripts/install-proxmox-ssh-key.ps1`
  in the update-center repo; until it is installed the host cards show an `ssh:` error
  and the button fails fast. API-only features (status, pending list, refresh, reboot)
  work without it.

## Troubleshooting

- **A node upgrade/reboot ends with "timeout: <node> blev inte stabil" although the node is
  Ready and its pods run**: the stability check used to count every non-Running pod in the
  cluster, including old `Evicted` (Failed) pods (2026-09-20: six 3-day-old portfolio pods
  failed an otherwise perfect worker-04 upgrade). Failed pods are ignored since the fix;
  `kubectl delete pods -A --field-selector=status.phase=Failed` cleans them up anyway.

- **A fleet run waits on "noder N (… cordonad)" or fails with "är cordonade men ingår inte i
  körningen"**: a node was cordoned by *Flytta update-center* and its host was never rebooted
  (happened 2026-09-20: worker-05/08 on clevoP150SM, the run waited 3 h). Either reboot that
  host (*Starta om (säkert)* uncordons at the end) or `kubectl uncordon <node>`. Since
  sha-d639ca9 the run handles cordoned nodes on hosts still in the plan itself and fails
  fast on any other cordon; the Översikt tab lists cordoned nodes under *Åtgärda först*.

- `GITHUB_TOKEN saknas` / 401 on commit → check ExternalSecret `update-center-env` and the
  `ONCALL_GITHUB_TOKEN` entry (fine-grained PAT expiry).
- Proxmox 403 → token `root@pam!update-center` lost its ACL: `pveum acl modify / --tokens
  'root@pam!update-center' --roles UpdateCenter` on any host.
- Talos `certificate has expired` → regenerate: `talosctl config new --roles os:admin
  --crt-ttl 8760h` and replace Bitwarden `update-center-talosconfig`.
- ArgoCD app stuck Progressing after a bump: the job times out after 10 min but the commit
  is in Git — investigate in ArgoCD, revert in Git if needed.
