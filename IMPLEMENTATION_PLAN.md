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
- [ ] **Install Cert-Manager**: Enable internal HTTPS and End-to-End encryption.
- [ ] Configure Let's Encrypt issuers.
- [ ] Update Cloudflared to use internal HTTPS with valid certs.
- [ ] **Secrets Management**: Set up **External Secrets Operator** with Bitwarden (to replace manual secrets).

### 2. Storage
- [ ] **Install Longhorn**: Distributed block storage for persistent volumes.
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
