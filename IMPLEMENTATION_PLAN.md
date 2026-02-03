# Kubernetes Homelab Setup - Implementation Plan

## Project Goal
Build a resilient, production-grade Kubernetes homelab on Proxmox using GitOps principles.
Reference: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab), also available in workspace under ./homelab-main

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
- [x] **Verify Let's Encrypt**: Check if `ClusterIssuer` is issuing valid certificates for `longhorn.rosenvall.se`.

### 3. Storage
- [x] **Install Longhorn**: Distributed block storage for persistent volumes.
- [x] **Configure Ingress**: `longhorn.rosenvall.se` exposed via Cilium Ingress.
- [x] Configure backup targets (e.g., NFS or S3).

### 4. Authentication (Completed)
- [x] **Install Authentik**: Configured in `kubernetes/infrastructure/controllers/authentik`.
    - [x] Create Bitwarden secret `authentik-secrets` with `secret-key` and `postgresql-password`.
    - [x] Verify Pods are running.
    - [x] Verify Ingress `authentik.rosenvall.se`.
- [x] Protect ArgoCD and other apps behind Authentik.

- [ ] **Loki for logs**:
    - [x] Create `kubernetes/infrastructure/monitoring/loki-stack`.
    - [x] Deploy `loki-stack` Helm Chart (Grafana repo).
    - [x] Configure `values.yaml`:
        - `loki.persistence.enabled`: true (Longhorn).
        - `promtail.enabled`: true.
        - `grafana.enabled`: false (Already have one).
    - [x] Integrate with existing Grafana (Datasource).

### 6. Robustness & Disaster Recovery
- [ ] **Database Backups**:
    - [ ] Configure CloudNativePG to backup WAL to Minio (S3).
    - [ ] Verify point-in-time recovery.
    - [ ] Ensure `loki` has limits to prevent OOM.

### 7. Applications (Migration Phase)
> [!IMPORTANT]
> **Namespace Strategy**: Applications will be grouped by function into namespaces based on their directory name in `kubernetes/applications/`.
> - `home-automation`: Home Assistant, Hub Central
> - `media`: Plex, *Arr stack, Deluge, Wireguard

#### Phase 1: Home Automation (`kubernetes/applications/home-automation`)
- [ ] **Hub Central**
    - Deployment: `ghcr.io/carnufex/hub-central:latest`
    - Service: ClusterIP
    - Ingress: `hub.rosenvall.se` -> Port 80
- [ ] **Home Assistant**
    - Deployment: `ghcr.io/home-assistant/home-assistant:stable`
    - Network: `hostNetwork: true` (Required for discovery/native integrations) OR Service `type: LoadBalancer` (BGP).
    - Storage: Longhorn PVC (`/config`).
    - Ingress: `hass.rosenvall.se` (Proxy to host/service).

#### Phase 2: Media Stack (`kubernetes/applications/media`)
- [ ] **VPN Gateway (Gluetun/Wireguard)**
    - Use `qdm12/gluetun` or custom Sidecar for robust VPN handling.
    - **Crucial**: Deluge must route strictly through this.
- [ ] **Deluge**
    - **Architecture**: Sidecar container in the *same Pod* as VPN.
    - Storage: Longhorn PVC (`/config`, `/lagring`).
    - Ingress: `deluge.rosenvall.se`.
- [ ] **Examples/Templates**:
    - `radarr`, `sonarr`, `jackett`, `overseerr`
    - Standard Deployments with Longhorn PVCs for config.
    - Shared Media Volume: Either a ReadWriteMany (NFS/Longhorn) PVC or specific mounts. *Longhorn RWM is experimental/heavy, might prefer NFS for media content if available on the network, or separate PVCs if libraries are distinct.*
    - **Storage Decision**: The user utilizes `${LAGRING}`. If this refers to a NAS, we should use `nfs-client-provisioner` or direct NFS PVs. If it's local disk, we migrate to Longhorn. *Assumption: Use Longhorn for Configs, verify Media storage strategy.*
- [ ] **Plex**
    - Deployment: `plexinc/pms-docker:plexpass`
    - Networking: `hostNetwork: true` preferred for DLNA/Cast.
    - Resources: GPU Passthrough (Intel/Nvidia) if transcoding needed.
    - Storage: Mount media volumes.

## Notes
- **Access**:
    - ArgoCD: `https://argo.rosenvall.se`
    - Longhorn: `https://longhorn.rosenvall.se` (IP: `192.168.1.241`)
