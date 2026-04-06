# Rosenvalls-Homelab

A Proxmox-hosted Talos Kubernetes homelab managed through GitOps.

The design goal is simple: rebuild the platform from code, keep manual dependencies explicit, and make day-2 operations predictable instead of tribal knowledge.

## Design Goals

- Keep infrastructure, cluster config, and app manifests in Git.
- Make cluster bootstrap deterministic from `tofu/` and `bootstrap.ps1`.
- Prefer documented break-glass paths over hidden one-off fixes.
- Keep recovery posture honest: document what is easy, what is manual, and what is not proven yet.

## Explore The Docs

- [Docs index](docs/README.md)
- [Getting started](docs/getting-started/README.md)
- [Architecture](docs/architecture/README.md)
- [Operations](docs/operations/README.md)
- [Disaster recovery](docs/disaster-recovery/README.md)
- [Scaling](docs/scaling/README.md)
- [Networking](docs/networking/README.md)
- [Storage and backups](docs/storage-and-backups/README.md)

## Platform Snapshot

| Layer | Choice | Notes |
| --- | --- | --- |
| Hypervisor | Proxmox VE | OpenTofu provisions the Talos VMs |
| OS | Talos Linux | Immutable Kubernetes nodes |
| GitOps | ArgoCD | Syncs `kubernetes/` from `origin` |
| Networking | Cilium + Gateway API | Internal and external ingress split by gateway |
| Public access | Cloudflare Tunnel | Forwards to `gateway/external` |
| Secrets | External Secrets + Bitwarden | Runtime secrets depend on one manual bootstrap token |
| Storage | Longhorn + Cloudflare R2 | Longhorn for volumes, R2 for configured backup targets |
| Databases | CloudNativePG | Authentik has a documented restore overlay |

## Topology Snapshot

- The checked-in example variables currently describe one control plane and one worker.
- Kubernetes API endpoint: `https://192.168.1.200:6443`
- Public entry point: Cloudflare Tunnel -> `gateway/external`
- Internal-only entry point: `gateway/internal`
- Canonical ArgoCD URL: `https://argo.rosenvall.se`
- Legacy ArgoCD alias: `https://argocd.rosenvall.se`

This repo models additional nodes declaratively, but the checked-in example shape is not highly available. Stateful Longhorn profiles are tuned for multiple worker failure domains, so treat the example as a bootstrap template rather than a production-sized topology.

## Quick Start

Install locally:

- OpenTofu
- `talosctl`
- `kubectl`
- Helm

Provision infrastructure:

```powershell
Copy-Item .\tofu\terraform.tfvars.example .\tofu\terraform.tfvars
cd .\tofu
tofu init
tofu plan
tofu apply
cd ..
```

Verify the fresh cluster before GitOps bootstrap:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl config info
talosctl --nodes 192.168.1.201 --endpoints 192.168.1.201 get members

$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
kubectl get nodes -o wide
```

Bootstrap GitOps:

```powershell
$env:BITWARDEN_ACCESS_TOKEN = "<token>"
.\bootstrap.ps1
```

Run the core gates:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
```

The Bitwarden bootstrap secret remains intentionally manual. If it is missing, the external secret chain, Cloudflare tunnel, certificate issuance, and several app runtimes will fail downstream.

## Repository Layout

- `tofu/`: Proxmox VM provisioning, Talos config generation, local access artifacts
- `kubernetes/`: GitOps source of truth
- `kubernetes/infrastructure/`: controllers, networking, storage, monitoring, shared platform pieces
- `kubernetes/applications/`: per-app ArgoCD applications discovered by the `ApplicationSet`
- `docs/`: operator-facing wiki and runbooks
- `scripts/`: health gates and maintenance helpers

## Recovery Posture

Cold rebuild is reasonably strong today:

- infrastructure is codified in OpenTofu
- Talos config and Kubernetes access artifacts are generated automatically
- `bootstrap.ps1` bridges a fresh cluster into GitOps and validates core health
- Authentik has backup plus an explicit restore overlay

State-preserving recovery is only partially documented:

- `bitwarden-access-token` is still manual
- Cloudflare published routes still live in the Cloudflare dashboard
- `tofu/output/kubeconfig` and `tofu/output/talosconfig` are local artifacts without a documented off-machine backup policy
- Longhorn has a backup target, but this repo does not yet define a recurring offsite backup policy
- MatPlan does not yet have a documented restore story

See [Disaster recovery](docs/disaster-recovery/README.md) for the honest current-state runbook and recovery backlog.

## Current Backlog

- `P0`: finish a full new-server and stolen-server runbook, including every secret and external dependency needed outside Git
- `P1`: verify restore coverage per stateful system and standardize naming in examples and runbooks
- `P2`: harden backup policy, reduce dashboard-only dependencies, and evaluate HA control plane tradeoffs
