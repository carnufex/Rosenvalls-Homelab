# Kubernetes Homelab Setup - Implementation Plan

## Project Goal
Build a resilient, production-grade Kubernetes homelab on Proxmox using GitOps principles.
Reference: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab)

## Current Status (2025-11-23)
- **Infrastructure**: ✅ Provisioned with OpenTofu & Talos Linux.
- **GitOps**: ✅ ArgoCD installed and bootstrapping from `kubernetes/applications`.
- **Networking**: ✅ Cilium installed (CNI).
- **Ingress**: ✅ Cloudflared Tunnel active (`argo.rosenvall.se`).

## Roadmap / Next Steps

### 1. Security & Certificates (Priority)
- [x] **Install Cert-Manager**: Configured in `kubernetes/infrastructure/controllers/cert-manager`.
- [ ] Configure Let's Encrypt issuers (Update email in `cluster-issuer.yaml`).
- [ ] Update Cloudflared to use internal HTTPS with valid certs.
- [x] **Secrets Management**: Installed External Secrets Operator.
- [ ] Configure Bitwarden Secret Store (Update IDs in `cluster-secret-store.yaml` and create manual secret).

### 2. Storage
- [x] **Install Longhorn**: Distributed block storage for persistent volumes.
    - [ ] Verify Pods are running.
    - [ ] Configure Cloudflare Tunnel for UI access.
- [ ] Configure backup targets (e.g., NFS or S3).

### 3. Authentication
- [ ] **Install Authentik**: SSO and Identity Provider.
- [ ] Protect ArgoCD and other apps behind Authentik.

### 4. Observability (Optional/Later)
- [ ] Prometheus/Grafana stack.
- [ ] Loki for logs.

### 5. Applications


## Notes
- **Cloudflare Tunnel**: Currently running in "Offloading" mode (HTTPS external -> HTTP internal). Will be upgraded to full E2E encryption once Cert-Manager is in place.
- **ArgoCD Access**: Available at `https://argo.rosenvall.se`.
