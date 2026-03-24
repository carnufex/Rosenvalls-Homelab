# Rosenvalls-Homelab

A Talos-based Kubernetes homelab on Proxmox, managed with GitOps through ArgoCD.

## Architecture

This repository manages the full stack:

- OpenTofu provisions the Proxmox VMs.
- Talos Linux provides the immutable Kubernetes nodes.
- ArgoCD syncs `kubernetes/` from this repository.
- Cilium provides CNI and Gateway API support.
- Cloudflare Tunnel forwards `*.rosenvall.se` to the external Gateway.
- External Secrets syncs runtime secrets from Bitwarden.
- Longhorn provides persistent storage.

## Bootstrap

### Prerequisites

Install these tools locally:

- OpenTofu: `winget install opentofu`
- Talosctl: `winget install siderolabs.talosctl`
- Kubectl: `winget install kubectl`
- Helm: `winget install Helm.Helm`

### Provision infrastructure

```powershell
cd tofu
Copy-Item terraform.tfvars.example terraform.tfvars
tofu init
tofu apply
```

This generates `tofu/output/kubeconfig` and `tofu/output/talosconfig`.

If the cluster already exists and Talos state has drifted, run the cleanup script before re-applying:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
./cleanup.ps1
```

### Bootstrap GitOps

`bootstrap.ps1` installs ArgoCD, ensures the manual bootstrap secret `bitwarden-access-token`, applies `kubernetes/bootstrap.yaml`, and enforces a strict core health gate.

You can pass the token through an environment variable to avoid an interactive prompt:

```powershell
$env:BITWARDEN_ACCESS_TOKEN = "<token>"
.\bootstrap.ps1
```

That secret is intentionally outside Git. If it is missing, `ClusterSecretStore/bitwarden-secretsmanager` will fail and the cluster will stop minting app secrets, Cloudflare tunnel credentials, and certificate-manager API tokens.

You can run the same gates manually:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
./scripts/argocd-health-gate.ps1
./scripts/preflight-core.ps1
```

## Daily Access

### Kubectl

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
kubectl get nodes
```

### ArgoCD

Canonical URL: `https://argo.rosenvall.se`
Legacy alias still routed: `https://argocd.rosenvall.se`

Get the bootstrap admin password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
```

Local port-forward:

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Change the default password after first login:

```powershell
argocd login argo.rosenvall.se --username admin --grpc-web
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
```

### Authentik

Initial setup lives at `https://authentik.rosenvall.se/if/flow/initial-setup/`.

GitOps ownership is split into three apps:

- `authentik-db-prereqs`: namespace, secrets, CNPG cluster
- `authentik-runtime`: Authentik chart, route, blueprints
- `authentik-db-ops`: scheduled and manual backups

Default database bootstrap mode is `initdb`; DR restore is opt-in via:

- `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

## Repository Layout

- `tofu/`: Proxmox, Talos and generated local outputs.
- `kubernetes/`: GitOps source of truth.
- `kubernetes/infrastructure/`: cluster services, controllers and networking.
- `kubernetes/applications/`: app namespaces managed by the ArgoCD ApplicationSet.
- `docs/cluster-operations.md`: day-2 recovery and verification commands.
- `AGENTS.md`: repo-local operating instructions for agents and collaborators.

## Recovery Notes

### Secret chain recovery

If External Secrets is broken, recreate the Bitwarden bootstrap secret first:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -
kubectl get clustersecretstore bitwarden-secretsmanager
kubectl get externalsecret -A
```

When this secret is healthy again, these should recover automatically:

- `cloudflared-secret` in `cloudflare`
- `cloudflare-api-token-secret` in `cert-manager`
- ArgoCD and Authentik runtime secrets
- Longhorn and CloudNativePG backup secrets

### Routing recovery

Cloudflare Tunnel targets the external Gateway service over HTTPS, not individual app services. Verify the chain in this order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get gateway -n gateway external -o yaml
kubectl get httproute -A
```

Cloudflare DNS01 token contract for cert-manager:

- Zone scope: `rosenvall.se`
- Permissions: Zone Read + DNS Edit

### Talos bootstrap drift

If the control-plane node is stuck waiting for bootstrap:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl --nodes 192.168.1.201 --endpoints 192.168.1.201 bootstrap
```

### Storage issues

Grafana has already shown a Longhorn-backed filesystem inconsistency once. Treat PVC repair as a separate recovery step after the secret and routing chain is green. See `docs/cluster-operations.md` for the validation order before making storage changes.
