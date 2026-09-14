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

## Buttons and what they actually run

| Button | Flow | Rollback |
|---|---|---|
| Appar → **Uppdatera** | one Git commit (Git Data API) replacing every line that pins that value in the app, `argocd.argoproj.io/refresh=hard` on the app, wait ≤10 min for Synced/Healthy + rollout | `git revert` the commit (or click the older tag once the tool can see it — it can't; revert in Git) |
| Talos → **Uppgradera** | cordon → CNPG-aware drain (deletes CNPG instances so they rebuild elsewhere, evicts the rest, leaves Longhorn instance-manager) → for CPs `talosctl etcd status` + `etcd snapshot` (to the pod's `/tmp`) → `talosctl upgrade --image factory.talos.dev/nocloud-installer/<schematic>:<ver> --reboot-mode=powercycle --drain=false --wait` → stale DaemonSet pod cleanup + wait stable → uncordon. Steps through minors (latest patch each). | Talos keeps the previous install in the B partition: `talosctl rollback -n <ip>` |
| Talos → **Uppgradera Kubernetes** | etcd snapshot → `upgrade-k8s --dry-run` → `upgrade-k8s --to <ver>` | `upgrade-k8s --to <old>` |
| Proxmox → **Sök uppdateringar** | `POST /nodes/<n>/apt/update` (task) | — |
| Proxmox → **Installera uppdateringar** | SSH: `apt-get update && apt-get -y full-upgrade` (confdef/confold), `autoremove`, re-disables `pve-enterprise.sources` if the upgrade re-enabled it | apt logs on the host |
| Proxmox → **Starta om (säkert)** | drain every k8s node on the host (control planes last; refuses if <2 other CPs Ready) → `POST /nodes/<n>/status command=reboot` → wait offline → wait online → start guests that were running → wait Ready → stable → uncordon | if it stalls: nodes stay cordoned; `kubectl uncordon` after the host is back |
| Proxmox → **Flytta update-center** | shown only when the tool's own pod runs on that host: cordons the host's nodes and deletes its own pod so it reschedules elsewhere; then reload and click reboot (which uncordons at the end) | **Uncordon noder** button |

Only one job runs at a time; every button confirms first; the actor (SSO e-mail)
is logged with the job. Job logs stream live in the UI (kept in memory, last 50 jobs).

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

- `GITHUB_TOKEN saknas` / 401 on commit → check ExternalSecret `update-center-env` and the
  `ONCALL_GITHUB_TOKEN` entry (fine-grained PAT expiry).
- Proxmox 403 → token `root@pam!update-center` lost its ACL: `pveum acl modify / --tokens
  'root@pam!update-center' --roles UpdateCenter` on any host.
- Talos `certificate has expired` → regenerate: `talosctl config new --roles os:admin
  --crt-ttl 8760h` and replace Bitwarden `update-center-talosconfig`.
- ArgoCD app stuck Progressing after a bump: the job times out after 10 min but the commit
  is in Git — investigate in ArgoCD, revert in Git if needed.
