# AI Instructions & Context

## Project Goal
Build a resilient, production-grade Kubernetes homelab on Proxmox using GitOps principles based on [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab). The source is available in this workspace under theepicsaxguy/homelab.
The ultimate goal is to learn and understand while setting up a replica of the [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab) project.

## Reference Architecture
This project is inspired by and modeled after: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab)
Documentation available at: https://homelab.orkestack.com/docs/getting-started/detailed-setup

## Technology Stack
- **Hypervisor**: Proxmox VE
- **Infrastructure Provisioning**: OpenTofu
- **Operating System**: Talos Linux
- **GitOps**: ArgoCD
- **Networking**: Cilium, Gateway API, Cloudflared
- **Storage**: Longhorn
- **Authentication**: Authentik

## Workflow
1. **Infrastructure**: Defined in `tofu/`.
2. **OS Configuration**: Defined in `tofu/talos/`.
3. **Kubernetes Manifests**: Defined in `kubernetes/`.
4. **Bootstrap Secrets**: `bitwarden-access-token` is created manually in `external-secrets` and is intentionally not committed.
5. **Changes**: Local edits do not affect the cluster until they are pushed to `origin`, because ArgoCD syncs `https://github.com/carnufex/Rosenvalls-Homelab.git`.

## Current Routing
- Public ArgoCD URL: `https://argo.rosenvall.se`
- Legacy ArgoCD alias: `https://argocd.rosenvall.se`
- Cloudflare Tunnel forwards `*.rosenvall.se` to the external Gateway service over HTTPS.

## User Preferences
- **Editor**: VS Code
- **Communication**: Explain the "Why" and "How". Focus on teaching Infrastructure as Code concepts.
