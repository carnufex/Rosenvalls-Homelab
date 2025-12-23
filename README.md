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

    > **Note:**
    > **Note:**
    > Om klustret redan finns (t.ex. efter en wipe eller om du återanvänder resurser) **måste du först köra cleanup-scriptet** för att ta bort Talos-resurserna ur state innan du kör `tofu apply` igen:
    >
    > ```powershell
    $env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
    ./cleanup.ps1
    ```
    >
    > Detta säkerställer att Talos-resurserna återskapas korrekt vid nästa apply och att du kan använda talosctl-kommandon direkt om du behöver felsöka.

### 3. Accessing the Cluster

1.  **Configure Kubectl**:
    ```powershell
    $env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
    ```

2.  **Verify Connection**:
    The Cluster VIP (Virtual IP) should be reachable as Cilium is installed during boot.
    ```powershell
    kubectl get nodes
    ```
    *Note: Nodes should be `Ready` as Cilium (CNI) is pre-installed.*

### 4. Bootstrap Cluster (The Magic Step)

We have automated the installation of GitOps (ArgoCD) and Secrets connection.

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

2.  **Access via Gateway**:
    ArgoCD is exposed via the Gateway API.
    -   **URL**: `https://argocd.rosenvall.se` (Requires Cloudflare Tunnel configured)
        > **Note:** Configure the Cloudflare Tunnel to point directly to the Service URL `http://argocd-server.argocd.svc.cluster.local:80` instead of the Gateway IP, to avoid internal routing issues.
    -   **Local Access (Port Forward)**:
        ```powershell
        kubectl -n argocd port-forward svc/argocd-server 8080:443
        ```
        Open [http://localhost:8080](http://localhost:8080).

### 6. Security (Post-Install)

Since the cluster is exposed to the internet via Cloudflare Tunnel, perform these steps immediately:

1.  **Secure Dashboards**:
    -   Go to Cloudflare Zero Trust -> Access -> Applications.
    -   Create policies for `argocd.rosenvall.se`, `longhorn.rosenvall.se`, etc.
    -   Restrict access to your email only.

2.  **Change Default Passwords**:
    -   **ArgoCD**: Login with the initial password and change it:
        ```powershell
        argocd login argocd.rosenvall.se --username admin --grpc-web
        argocd account update-password
        kubectl -n argocd delete secret argocd-initial-admin-secret
        ```
    -   **Authentik**: Complete the initial setup at `https://authentik.rosenvall.se/if/flow/initial-setup/`.

### 7. Repository Structure

-   `tofu/`: Infrastructure definitions (Proxmox VMs, Talos config).
-   `kubernetes/`:
    -   `applications/`: ArgoCD Application definitions (The "App of Apps").
    -   `infrastructure/`: Helm charts and manifests for core services.
    -   `bootstrap.yaml`: The entry point for ArgoCD.

##  Troubleshooting Notes
### Control Plane Stuck Waiting for Bootstrap

Om din control plane-node visar "waiting to join the cluster" och ber dig köra `talosctl bootstrap` trots att du förväntar dig att det ska ske automatiskt:

- Kontrollera att du har kört `cleanup.ps1` och att alla Talos/etcd-diskar är nollställda (wipade) innan du kör `tofu apply`.
- Talos bootstrap körs bara automatiskt första gången – om det finns gammal etcd-data på disken måste du wipa eller ta bort VM:n helt.
- Om Terraform-state och verkligheten är ur synk kan bootstrap-resursen hoppas över.

**Lösning:**

1. Säkerställ att du har en ren miljö (wipade diskar, ingen gammal state).
2. Kör `tofu apply` som vanligt.
3. Om noden ändå står och väntar, kör bootstrap manuellt:

    ```powershell
    $env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
    talosctl --nodes 192.168.1.201 --endpoints 192.168.1.201 bootstrap
    ```

Efter en lyckad bootstrap bör noden gå vidare och klustret bli hälsosamt.

-   **ArgoCD Redis Issues**: If ArgoCD complains about `NOAUTH` or pods are stuck, restart the Redis and Server pods:
    ```powershell
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-redis
    kubectl -n argocd delete pod -l app.kubernetes.io/name=argocd-server
    ```
-   **Authentik Database**: The `authentik` database is bootstrapped automatically via `database.yaml`. If you see "database does not exist" errors, ensure the `bootstrap.initdb` section is present in the manifest.
-   **Backups**: Authentik and Longhorn backups require the `longhorn-minio-credentials` secret. You must create an `ExternalSecret` mapping your Minio credentials from Bitwarden to this secret name in both `authentik` and `longhorn-system` namespaces.
-   **Windows & Kustomize**: `kubectl apply -k` with Helm charts can be flaky on Windows. Prefer `helm template | kubectl apply -f -`.
