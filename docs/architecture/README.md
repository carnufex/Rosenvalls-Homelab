# Architecture

This repo manages the full platform lifecycle from VM provisioning to app routing.

## Source Of Truth Layers

| Layer | Source of truth | Notes |
| --- | --- | --- |
| Proxmox VMs | `tofu/` | OpenTofu provisions Talos nodes and local access artifacts |
| Talos machine config | `tofu/talos/` | Generated per node from the shared module |
| Cluster bootstrap | `bootstrap.ps1` | Installs ArgoCD and bridges a fresh cluster into GitOps |
| Cluster manifests | `kubernetes/` | ArgoCD syncs this repo from GitHub |
| Runtime secrets | Bitwarden -> External Secrets | Requires a manual bootstrap token in-cluster |

## Platform Model

- Proxmox hosts the Talos VMs.
- Talos provides immutable Kubernetes nodes.
- ArgoCD syncs `kubernetes/` from `origin`.
- Cilium provides networking and Gateway API support.
- Cloudflare Tunnel forwards public traffic to `gateway/external`.
- `gateway/internal` is reserved for internal-only services.
- Longhorn provides persistent storage.
- CloudNativePG backs PostgreSQL workloads.

## Current Topology

- The checked-in example node inventory currently shows one control plane and one worker
- Control plane VIP: `192.168.1.200`
- Public routing: Cloudflare Tunnel -> `gateway/external` -> `HTTPRoute` -> Service
- Internal routing: `gateway/internal` -> `HTTPRoute` -> Service

The configuration model supports more nodes, but the checked-in example posture is still a non-HA control plane and not a fully redundant worker topology for 2-replica storage classes.

## Critical Manual Dependency

`bitwarden-access-token` in the `external-secrets` namespace is intentionally outside Git.

If it is missing, expect failures in:

- `ClusterSecretStore/bitwarden-secretsmanager`
- `ExternalSecret` reconciliation
- `cloudflared`
- cert-manager DNS validation
- ArgoCD, Authentik, and backup credentials

## Component Notes Worth Keeping Close To The Manifests

- [External Secrets](../../kubernetes/infrastructure/controllers/external-secrets/README.md)
- [Cloudflared](../../kubernetes/infrastructure/network/cloudflared/README.md)
- [Longhorn](../../kubernetes/infrastructure/storage/longhorn/README.md)
- [Authentik DB prerequisites](../../kubernetes/infrastructure/controllers/authentik-db-prereqs/README.md)

## External Contracts

These dependencies are not fully represented in Git today:

- Proxmox credentials
- Bitwarden machine account access token
- Cloudflare Tunnel published routes
- Cloudflare DNS/token contracts for certificate issuance
- local `terraform.tfvars`
- any off-repo backup of `tofu/output/kubeconfig` and `tofu/output/talosconfig`

## Related Docs

- [Getting started](../getting-started/README.md)
- [Networking](../networking/README.md)
- [Storage and backups](../storage-and-backups/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
