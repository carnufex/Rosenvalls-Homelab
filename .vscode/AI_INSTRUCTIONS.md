# AI Instructions & Context

## Project Goal
Build a resilient, production-grade Kubernetes homelab on Proxmox using GitOps principles.
The ultimate goal is **Disaster Recovery**: If the server is destroyed, we should be able to install Proxmox, pull this repository, and restore the entire cluster state with minimal manual intervention.

## Reference Architecture
This project is inspired by and modeled after: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab)

## Technology Stack
-   **Hypervisor**: Proxmox VE (Local)
-   **Infrastructure Provisioning**: OpenTofu (Terraform)
-   **Operating System**: Talos Linux
-   **GitOps**: ArgoCD
-   **Networking**: Cilium, Cloudflared
-   **Storage**: Longhorn
-   **Authentication**: Authentik

## Workflow
1.  **Infrastructure**: Defined in `tofu/` (Proxmox VMs, DNS, etc.)
2.  **OS Configuration**: Defined in `talos/` (Machine configs)
3.  **Kubernetes Manifests**: Defined in `k8s/` (Managed by ArgoCD)
4.  **Changes**: All changes are made via Pull Requests to the `main` branch.

## User Preferences
-   **Editor**: VS Code (implied by `.vscode` request)
-   **Communication**: Explain the "Why" and "How". Focus on teaching Infrastructure as Code concepts.
