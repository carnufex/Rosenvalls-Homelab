# Rosenvalls-Homelab

A production-grade Kubernetes homelab on Proxmox, managed with GitOps.

## 🏗 Architecture

This project uses **Infrastructure as Code (IaC)** to manage the entire lifecycle of the cluster:
-   **Provisioning**: [OpenTofu](https://opentofu.org/) creates Virtual Machines on Proxmox.
-   **OS**: [Talos Linux](https://www.talos.dev/) runs on the nodes (immutable, minimal, secure).
-   **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/) manages all Kubernetes manifests from this repository.

## 🚀 Getting Started

Follow these steps to bootstrap the cluster from scratch.

### 1. Prerequisites

Ensure you have the following tools installed on your local machine:
-   **[OpenTofu](https://opentofu.org/docs/intro/install/)**: Infrastructure provisioning (`winget install opentofu`).
-   **[Talosctl](https://www.talos.dev/v1.8/talosctl/install/)**: Talos CLI (`winget install siderolabs.talosctl`).
-   **[Kubectl](https://kubernetes.io/docs/tasks/tools/)**: Kubernetes CLI (`winget install kubectl`).

### 2. Infrastructure Provisioning (OpenTofu)

We use OpenTofu to create the VMs on Proxmox.

1.  **Navigate to the directory**:
    ```powershell
    cd tofu
    ```

2.  **Configure Credentials**:
    Create a `terraform.tfvars` file (this file is gitignored to protect your secrets):
    ```powershell
    cp terraform.tfvars.example terraform.tfvars
    ```
    Edit `terraform.tfvars` and fill in your details:
    -   `proxmox_endpoint`: URL to your Proxmox server (e.g., `https://192.168.1.10:8006/`).
    -   `proxmox_api_token`: Your API token (User -> API Tokens -> Add).
    -   `target_node`: The name of your Proxmox node (e.g., `pve`).

    > [!IMPORTANT]
    > **SSH Configuration**: OpenTofu requires SSH access to the Proxmox node to provision disks.
    > 1. Generate a secure SSH key (ED25519 recommended): `ssh-keygen -t ed25519`
    > 2. Add the key to your local agent: `ssh-add ~/.ssh/id_ed25519`
    > 3. Add the public key to the Proxmox node's `/root/.ssh/authorized_keys`.
    > 4. **Verify** that you can SSH into the Proxmox node without a password before proceeding.

    > [!IMPORTANT]
    > **Proxmox Permissions**: The API Token needs permission to download ISOs to your storage.
    > 1. Go to **Datacenter** -> **Permissions**.

    > 2. Add **User Permission** (or API Token Permission).
    > 3. Path: `/storage/local` (or `/`).
    > 4. User: Your API Token User.
    > 5. Role: `PVEAdmin` or `PVEDatastoreAdmin`.

3.  **Initialize OpenTofu**:
    Downloads required providers (Proxmox, Talos).
    ```powershell
    tofu init
    ```

4.  **Preview Changes**:
    See what will be created.
    ```powershell
    tofu plan
    ```

5.  **Apply Infrastructure**:
    Create the VMs.
    ```powershell
    tofu apply
    ```

### 3. Cluster Bootstrap (Automated)

The OpenTofu configuration now handles the entire bootstrap process:
1.  Creates VMs.
2.  Generates Talos configuration (with Static IPs).
3.  Applies configuration to the nodes.
4.  Bootstraps the cluster.
5.  Retrieves `kubeconfig` and `talosconfig`.

**Just run:**
```powershell
tofu apply
```

### 4. Access the Cluster

Once `tofu apply` completes, you will see the `kubeconfig` and `talosconfig` in the output (marked as sensitive).

1.  **Save Kubeconfig**:
    ```powershell
    tofu output -raw kubeconfig > ~/.kube/config
    ```

2.  **Save Talosconfig**:
    ```powershell
    tofu output -raw talosconfig > ~/.talos/config
    talosctl config endpoint 192.168.1.201
    talosctl config node 192.168.1.201
    ```

3.  **Verify**:
    ```powershell
    kubectl get nodes
    ```

### 4. GitOps (ArgoCD)

*Instructions coming soon...*

## 📂 Repository Structure

-   `tofu/`: OpenTofu configuration for Proxmox VMs.
-   `talos/`: Talos Linux machine configurations.
-   `k8s/`: Kubernetes manifests (ArgoCD applications).
