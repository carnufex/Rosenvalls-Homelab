# Kubernetes Homelab Setup - Implementation Plan

## Goal Description
Set up a Kubernetes homelab on Proxmox using **OpenTofu**, **Talos Linux**, and **ArgoCD**. The system is designed for complete disaster recovery from Git.
Reference: [theepicsaxguy/homelab](https://github.com/theepicsaxguy/homelab)

## User Review Required
- **Proxmox Credentials**: We will need to set up environment variables or a `secrets.tfvars` (gitignored) for Proxmox API access.
- **Domain Name**: Do you have a domain name to use with Cloudflare/Cloudflared?

## Proposed Changes

### 1. Repository Structure
Align with the reference architecture:
- `tofu/`: Infrastructure as Code (Proxmox VMs).
- `talos/`: Machine configurations.
- `k8s/`: Kubernetes manifests (ArgoCD applications).

### 2. Infrastructure Provisioning (OpenTofu)
- Create `tofu/main.tf` to define the Proxmox VMs for Control Plane and Worker nodes.
- Create `tofu/variables.tf` for cluster customization.

### 3. Talos Linux Setup
- Generate machine secrets and configurations.
- Bootstrap the cluster on the provisioned VMs.

### 4. GitOps (ArgoCD)
- Install ArgoCD on the new cluster.
- Configure ArgoCD to watch this repository (`k8s/` directory).

## Verification Plan
### Automated Tests
- `tofu plan`: Verify infrastructure changes before applying.
- `talosctl validate`: Check Talos config.

### Manual Verification
- Destroy and Rebuild: The ultimate test is to wipe the VMs and restore everything using `tofu apply` and ArgoCD.
