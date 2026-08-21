---
name: cluster-diagnostics
description: >-
  Diagnose health and outages in the Rosenvalls-Homelab Kubernetes cluster
  (Talos + ArgoCD + Cilium Gateway + External Secrets). Use when something in
  the cluster is broken, degraded, or unreachable: pods crashing, ArgoCD apps
  OutOfSync/Degraded, ExternalSecrets not syncing, certificates not issuing,
  routes not accepted, or public sites returning errors. Establishes the correct
  top-down order of investigation so symptoms are not mistaken for root causes.
---

# Cluster Diagnostics

Use this when investigating cluster health in `Rosenvalls-Homelab`. The cluster
is GitOps-driven: ArgoCD syncs from `origin`, so the live state should match the
repo. Most "random" failures trace back to **one broken link early in the chain**
(usually the Bitwarden bootstrap secret), not to the app you are looking at.

## Golden rule: diagnose top-down, not at the symptom

Secrets → ArgoCD sync → routing/certs → app/storage. A failing app pod is almost
never the place to start. Walk the chain in order and stop at the first red link.

## Setup

The cluster is reached via the kubeconfig that OpenTofu writes locally:

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
kubectl config current-context   # sanity check you are pointed at the homelab
```

If `tofu/output/kubeconfig` is missing, the cluster was never provisioned/applied
locally — resolve that before anything else.

## Order of operations

1. **Nodes** — is the control plane even up?
2. **ArgoCD apps** — is GitOps converging, or is something `OutOfSync` / `Degraded`?
3. **Bitwarden ClusterSecretStore** — the root of most secret failures.
4. **ExternalSecrets** — are secrets materializing in each namespace?
5. **cloudflared + wildcard cert + Gateway** — is the public path healthy?
6. **HTTPRoutes** — are routes `Accepted` by their gateway?
7. **Only now** look at app-specific pods, PVCs, or Longhorn/storage.

## High-value commands

```powershell
# 1. Nodes
kubectl get nodes -o wide

# 2. ArgoCD applications (look for non-Synced / non-Healthy)
kubectl get applications.argoproj.io -n argocd

# 3. Secret store (must be Valid/Ready)
kubectl get clustersecretstore bitwarden-secretsmanager

# 4. External secrets across all namespaces (look for SecretSyncError)
kubectl get externalsecret -A

# 5. Public path
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get gateway -n gateway external -o yaml   # check listener status conditions

# 6. Routes (look for Accepted=False)
kubectl get httproute -A

# 7. App / storage (only after the above is green)
kubectl get pods -A | Select-String -NotMatch "Running|Completed"
```

## Root-cause first: the Bitwarden bootstrap secret

`bitwarden-access-token` in namespace `external-secrets` is a **manual,
out-of-Git bootstrap secret**. If it is missing or wrong, expect a cascade:

- `ClusterSecretStore/bitwarden-secretsmanager` goes invalid
- every `ExternalSecret` stops reconciling
- `cloudflared` cannot start (no tunnel token)
- cert-manager cannot complete DNS-01 → `cert-wildcard` never issues
- ArgoCD, Authentik, and backup jobs lose their runtime secrets

When you see broad, simultaneous failures across unrelated namespaces, **suspect
this secret first** and restore it before chasing individual apps.

```powershell
kubectl get secret bitwarden-access-token -n external-secrets
```

## Notes

- Public traffic reaches apps through Cloudflare Tunnel → `gateway/external`.
  For the routing layer specifically, use the **cloudflare-gateway-routing** skill.
- The repo is the source of truth: a fix that is not pushed to `origin` will be
  reverted by ArgoCD on the next sync.
- See also: **gitops-app-onboarding** when the failure is a newly added app.

## Recurring-failure cheat sheet (from past incidents — details in project memory)

- Broad, simultaneous failures across unrelated namespaces → the Bitwarden bootstrap
  secret (above). Check it before anything else.
- `*.rosenvall.local` dead from the LAN while `*.rosenvall.se` works → the announcing
  node's `cilium-envoy` lost xDS; restart that `cilium-envoy` pod
  (memory `cilium-envoy-xds-disconnect-gateways-down`).
- Longhorn volume `degraded` and not healing → check node free space first, then prune
  `Released` PVs + orphan Longhorn volumes (memory `longhorn-storage-pressure`). Longhorn
  only schedules on the disk nodes; small/compute-only workers are excluded on purpose.
- `DiskPressure` / mass evictions on one worker → something writes to the node overlay
  disk (e.g. Plex transcode), not Longhorn (memory `plex-transcode-not-mounted`).
- Proxmox thin-pool full → VMs freeze with io-error; a CronJob alerts `#homelab-alerts`
  at ≥85% pool fill (memory `incident-lvm-full-io-error`, `proxmox-storage-alert`).
- Slack is alert-only: Alertmanager + `daily-health-check` + `r2-dr-report` +
  `deluge-vpn-leak-check` post to `#homelab-alerts` only when something is wrong.
- Use the repo's scripts before hand-rolling checks: `scripts/cluster-health-report.ps1`,
  `scripts/post-power-loss-check.ps1`, `scripts/preflight-core.ps1`,
  `scripts/verify-media-nfs.ps1`, `scripts/verify-local-routes.ps1`.
- Never run `tofu apply` to "fix" a live cluster without a plan review — Talos image
  drift makes the plan cascade (memory `talos-image-drift-gotcha`).
