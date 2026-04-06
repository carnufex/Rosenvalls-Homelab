# AI Instructions & Context

## Project Goal

Build and operate a resilient Kubernetes homelab on Proxmox using OpenTofu, Talos, and GitOps.

The repository should prioritize:

- predictable cluster rebuilds
- explicit source-of-truth boundaries
- honest documentation of manual dependencies and recovery gaps
- Git-managed changes that can be applied safely through ArgoCD

## Source Of Truth

- Infrastructure is defined in `tofu/`
- Talos configuration is generated from `tofu/talos/`
- Kubernetes manifests live under `kubernetes/`
- ArgoCD syncs `https://github.com/carnufex/Rosenvalls-Homelab.git`
- Local edits do not change the cluster until they are pushed to `origin`
- `bootstrap.ps1` is the imperative bridge from a fresh cluster into GitOps

## Current Architecture

- Hypervisor: Proxmox VE
- Infrastructure provisioning: OpenTofu
- Operating system: Talos Linux
- GitOps: ArgoCD
- Networking: Cilium, Gateway API, Cloudflare Tunnel
- Storage: Longhorn
- Databases: CloudNativePG
- Secrets: External Secrets Operator backed by Bitwarden

## Critical Manual Dependency

`bitwarden-access-token` in the `external-secrets` namespace is intentionally manual and outside Git.

If it is missing, expect failures in:

- `ClusterSecretStore/bitwarden-secretsmanager`
- `ExternalSecret` reconciliation
- `cloudflared`
- cert-manager DNS validation
- runtime secrets for ArgoCD, Authentik, and backup jobs

## Routing Model

- Public ArgoCD URL: `https://argo.rosenvall.se`
- Legacy ArgoCD alias: `https://argocd.rosenvall.se`
- Cloudflare Tunnel forwards public traffic to the external gateway service
- Monitoring routes should stay internal unless there is an explicit reason to publish them

## Documentation

- Root `README.md` is the public landing page
- `docs/` is the active operator wiki
- Component README files under `kubernetes/` are implementation notes close to the manifests

## User Preferences

- Editor: VS Code
- Communication: Explain the why and how when it adds value, but keep the repo grounded in current truth rather than aspirational architecture
