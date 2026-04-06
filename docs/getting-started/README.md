# Getting Started

Use this guide for first bootstrap on a new workstation or a new cluster.

## Prerequisites

Install locally:

- OpenTofu
- `talosctl`
- `kubectl`
- Helm

You also need:

- Proxmox API access
- local `tofu/terraform.tfvars`
- a Bitwarden access token for the bootstrap secret

Treat `terraform.tfvars.example` as a syntax starter, not a production-sized topology. Review worker count, storage layout, and disk sizing before using it for real stateful workloads.

## Provision Infrastructure

```powershell
Copy-Item .\tofu\terraform.tfvars.example .\tofu\terraform.tfvars
cd .\tofu
tofu init
tofu plan
tofu apply
cd ..
```

Important behavior:

- `tofu/output/kubeconfig` and `tofu/output/talosconfig` are generated locally
- the plan must be reviewed carefully before apply, especially when disk sizing or Talos image drift appears
- existing nodes can still be affected by local `terraform.tfvars` choices

## Verify Talos Before GitOps

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl config info
talosctl --nodes 192.168.1.201 --endpoints 192.168.1.201 get members

$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

If the cluster already exists and Talos state has drifted, run:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
.\tofu\cleanup.ps1
```

## Bootstrap GitOps

`bootstrap.ps1`:

- installs ArgoCD
- ensures the manual `bitwarden-access-token`
- applies `kubernetes/bootstrap.yaml`
- waits for core apps and core routing to become healthy

```powershell
$env:BITWARDEN_ACCESS_TOKEN = "<token>"
.\bootstrap.ps1
```

## Validate The Cluster

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
```

These checks confirm:

- core ArgoCD applications are `Synced` and `Healthy`
- the Bitwarden secret chain is working
- the wildcard certificate is valid
- the external gateway listener is programmed
- `HTTPRoute` objects are accepted

## First Places To Go Next

- [Architecture](../architecture/README.md)
- [Operations](../operations/README.md)
- [Disaster recovery](../disaster-recovery/README.md)
