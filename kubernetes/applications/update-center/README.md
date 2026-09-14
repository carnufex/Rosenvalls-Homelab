# update-center

One page that answers "what is out of date?" for the whole homelab and has a
button next to each answer: <https://updates.rosenvall.local> (LAN, Authentik SSO).

Source, image build and operator docs live in the separate repo
[`carnufex/update-center`](https://github.com/carnufex/update-center); this
folder only deploys it. The runbook for the deployed tool is
`docs/operations/update-center.md`.

| Domain | What is compared | Button does |
|---|---|---|
| Apps | every `image:` pin and kustomize `helmCharts` version under `kubernetes/**` (Git) vs the registry / chart index; live pod images vs Git | commits the bump to `master` (one commit per component, all lines), hard-refreshes the ArgoCD app, waits for Synced/Healthy + rollout |
| Talos / Kubernetes | node OS version vs latest `siderolabs/talos` release; kubelet vs the Kubernetes version that Talos minor ships | `talosctl upgrade` one node (own drain, factory installer, powercycle, etcd snapshot for CPs, stale-pod cleanup) / `talosctl upgrade-k8s` |
| Proxmox | `pve-manager` + kernel via the API, pending apt packages, reboot-required | apt refresh (API), `apt full-upgrade` (SSH), safe reboot (drain k8s nodes → reboot → start guests → uncordon) |

## Access model

- `HTTPRoute/update-center` binds `updates.rosenvall.local` on `gateway/internal` only.
- oauth2-proxy (Authentik OIDC client `update-center`, blueprint in `authentik-runtime`)
  fronts everything except `/api/health`. The proxied `X-Forwarded-Email` is recorded as the
  actor of every job.
- One job at a time, always behind a confirm dialog in the UI.

## Identities

| Credential | Where | Scope |
|---|---|---|
| ServiceAccount `update-center` | `rbac.yaml` | read inventory; patch nodes (cordon), evict/delete pods, patch ArgoCD Applications (refresh) |
| `GITHUB_TOKEN` | Bitwarden `ONCALL_GITHUB_TOKEN` (shared with the on-call copilot) | Contents r/w on this repo |
| `PROXMOX_TOKEN` | Bitwarden `update-center-proxmox-token` → `root@pam!update-center`, role `UpdateCenter` | apt status/refresh, node reboot, VM start |
| talosconfig | Bitwarden `update-center-talosconfig` (own client cert, os:admin, expires 2027-09) | talosctl upgrade / upgrade-k8s |
| SSH key | Bitwarden `update-center-ssh-key` → `root@<host>` with `from="192.168.1.0/24"` | `apt full-upgrade`, reboot-required check |

Rotate by replacing the Bitwarden value; ExternalSecrets refresh hourly.
