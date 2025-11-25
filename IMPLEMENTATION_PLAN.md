# Kubernetes Homelab Setup - Implementation Plan

## Project Goal
Build a resilient, production-grade Kubernetes homelab on Proxmox using GitOps principles.
Reference: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab)

## Current Status (2025-11-25)
- **Infrastructure**: ✅ Provisioned with OpenTofu & Talos Linux.
- **GitOps**: ✅ ArgoCD installed and syncing.
- **Networking**: ✅ Cilium CNI + Ingress Controller (L2 Announcements enabled).
- **Secrets**: ✅ External Secrets Operator syncing with Bitwarden.
- **Storage**: ✅ Longhorn installed and Ingress configured.

## Roadmap / Next Steps

### 1. Networking & Ingress (Completed)
- [x] **Cilium Ingress**: Enabled Ingress Controller in `values.yaml`.
- [x] **L2 Announcements**: Configured IP Pool (`192.168.1.240/28`) and Policy.
- [x] **Remove NodePorts**: Cleaned up Service definitions.

### 2. Security & Certificates
- [x] **Install Cert-Manager**: Configured in `kubernetes/infrastructure/controllers/cert-manager`.
- [x] **Secrets Management**: Installed External Secrets Operator.
- [x] **Configure Bitwarden Secret Store**: Token configured and secrets syncing.
- [ ] **Verify Let's Encrypt**: Check if `ClusterIssuer` is issuing valid certificates for `longhorn.rosenvall.se`.

### 3. Storage
- [x] **Install Longhorn**: Distributed block storage for persistent volumes.
- [x] **Configure Ingress**: `longhorn.rosenvall.se` exposed via Cilium Ingress.
- [ ] Configure backup targets (e.g., NFS or S3).

### 4. Authentication (In Progress)
- [ ] **Install Authentik**: Configured in `kubernetes/infrastructure/controllers/authentik`.
    - [ ] Create Bitwarden secret `authentik-secrets` with `secret-key` and `postgresql-password`.
    - [ ] Verify Pods are running.
    - [ ] Verify Ingress `authentik.rosenvall.se`.
- [ ] Protect ArgoCD and other apps behind Authentik.

### 5. Observability
- [ ] Prometheus/Grafana stack.
- [ ] Loki for logs.

### 6. Applications
- [ ] Home Assistant
- [ ] Plex/Jellyfin
- [ ] ...

## Notes
- **Access**:
    - ArgoCD: `https://argo.rosenvall.se`
    - Longhorn: `https://longhorn.rosenvall.se` (IP: `192.168.1.241`)
