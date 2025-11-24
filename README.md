# Rosenvalls-Homelab

A production-grade Kubernetes homelab on Proxmox, managed with GitOps.

##  Architecture

This project uses **Infrastructure as Code (IaC)** to manage the entire lifecycle of the cluster:
-   **Provisioning**: [OpenTofu](https://opentofu.org/) creates Virtual Machines on Proxmox.
-   **OS**: [Talos Linux](https://www.talos.dev/) runs on the nodes (immutable, minimal, secure).
-   **GitOps**: [ArgoCD](https://argo-cd.readthedocs.io/) manages all Kubernetes manifests from this repository.
-   **Networking**: [Cilium](https://cilium.io/) (CNI) managed via ArgoCD.
-   **Secrets**: [External Secrets Operator](https://external-secrets.io/) syncing from Bitwarden.

##  Getting Started

Follow these steps to bootstrap the cluster from scratch.

### 1. Prerequisites

Ensure you have the following tools installed on your local machine:
-   **[OpenTofu](https://opentofu.org/docs/intro/install/)**: Infrastructure provisioning (`winget install opentofu`).
-   **[Talosctl](https://www.talos.dev/v1.8/talosctl/install/)**: Talos CLI (`winget install siderolabs.talosctl`).
-   **[Kubectl](https://kubernetes.io/docs/tasks/tools/)**: Kubernetes CLI (`winget install kubectl`).
-   **[Helm](https://helm.sh/docs/intro/install/)**: Package manager (`winget install Helm.Helm`).

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
    Edit `terraform.tfvars` and fill in your details (Proxmox endpoint, API token, etc.).

3.  **Apply Infrastructure**:
    ```powershell
    tofu init
    tofu apply
    ```
    This will:
    -   Download the Talos ISO to Proxmox.
    -   Create the Control Plane and Worker VMs.
    -   Bootstrap the Talos cluster.
    -   Generate `kubeconfig` and `talosconfig` in `tofu/output/`.

### 3. Accessing the Cluster

1.  **Configure Kubectl**:
    ```powershell
    $env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
    ```

2.  **Verify Connection**:
    Until the Cluster VIP (Virtual IP) is configured via Cilium/Kube-VIP, you may need to point directly to the control plane node IP.
    ```powershell
    kubectl config set-cluster hemma-k8s --server=https://192.168.1.201:6443
    kubectl get nodes
    ```
    *Note: Nodes will be `NotReady` because no CNI (Networking) is installed yet.*

### 4. Bootstrap Cluster (The Magic Step)

We have automated the installation of GitOps (ArgoCD) and Secrets connection.
*Note: Cilium (Networking) is now installed automatically by Talos during boot.*

1.  **Run the Bootstrap Script**:
    ```powershell
    .\bootstrap.ps1
    ```
    This script will:
    -   Install **ArgoCD** (GitOps).
    -   Apply the **Bootstrap Application** (starts syncing this repo).
    -   Prompt you for your **Bitwarden Access Token**.

### 5. Access ArgoCD

Once the bootstrap is complete:

1.  **Get Admin Password**:
    ```powershell
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
    ```

2.  **Port Forward**:
    ```powershell
    kubectl -n argocd port-forward svc/argocd-server 8080:443
    ```
    *   Open [http://localhost:8080](http://localhost:8080).


```powershell
helm repo add cilium https://helm.cilium.io/
### 6. Repository Structure

-   `tofu/`: Infrastructure definitions (Proxmox VMs, Talos config).
-   `kubernetes/`:
    -   `applications/`: ArgoCD Application definitions (The "App of Apps").
    -   `infrastructure/`: Helm charts and manifests for core services.
    -   `bootstrap.yaml`: The entry point for ArgoCD.

##  Troubleshooting Notes

-   **ArgoCD Redis Issues**: If ArgoCD complains about `NOAUTH` or pods are stuck, restart the Redis and Server pods:
    ```powershell
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-redis
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
    ```
-   **Windows & Kustomize**: `kubectl apply -k` with Helm charts can be flaky on Windows. Prefer `helm template | kubectl apply -f -`.
