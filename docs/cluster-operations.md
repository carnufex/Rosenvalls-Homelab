# Cluster Operations

## Access

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
```

## OpenTofu Apply Notes

Treat `tofu apply` as a two-step flow, not a blind bootstrap shortcut:

```powershell
cd .\tofu
tofu init
tofu plan
tofu apply
cd ..
```

Observed contracts from live runs:

- `tofu/output/*` is written from inside `tofu/` and then consumed from repo root as `tofu/output/*`
- existing nodes can inherit new defaults unless they are pinned explicitly in the local `terraform.tfvars`
- a changed shared Talos download artifact may still appear in `tofu plan`; read the plan before apply even if you only intended a single-node change

Pre-bootstrap verification after infra apply:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl config info
talosctl --nodes 192.168.1.201 --endpoints 192.168.1.201 get members

$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
kubectl get nodes -o wide
kubectl get pods -n kube-system
```

Base health:

```powershell
kubectl get nodes -o wide
kubectl get applications.argoproj.io -n argocd
kubectl get pods -A
```

## Deterministic Bootstrap Gates

After `bootstrap.ps1`, run the strict gates:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
./scripts/argocd-health-gate.ps1
./scripts/preflight-core.ps1
```

`argocd-health-gate.ps1` validates core apps are `Synced+Healthy`.
`preflight-core.ps1` validates secret chain, cert chain, gateway listener, and route acceptance.

## Bootstrap Secret Recovery

If `ClusterSecretStore/bitwarden-secretsmanager` is not `Ready`, recreate the Bitwarden bootstrap secret first:

```powershell
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
kubectl -n external-secrets create secret generic bitwarden-access-token --from-literal=token=<token> --dry-run=client -o yaml | kubectl apply -f -
kubectl get clustersecretstore bitwarden-secretsmanager
kubectl get externalsecret -A
```

Expected downstream secrets after recovery:

- `cloudflared-secret` in `cloudflare`
- `cloudflare-api-token-secret` in `cert-manager`
- `argocd-secret` in `argocd`
- `authentik-core-secrets` and `authentik-blueprint-secrets` in `authentik`
- S3 backup secrets in `authentik`, `cnpg-system`, and `longhorn-system`

## Cloudflare DNS01 Token Contract

The token behind `cert-manager/cloudflare-api-token-secret` must be scoped for the `rosenvall.se` zone and allow:

- Zone read
- DNS edit

If the token does not meet this contract, ACME DNS01 issuance can stall and `gateway/cert-wildcard` will remain non-ready.

## Tunnel And Gateway Recovery

Verify the public routing chain in this order:

```powershell
kubectl get pods -n cloudflare
kubectl get certificate -n gateway cert-wildcard
kubectl get gateway -n gateway external -o yaml
kubectl get httproute -A
```

Useful external checks:

```powershell
Resolve-DnsName argo.rosenvall.se
Invoke-WebRequest -Uri https://argo.rosenvall.se -Method Head
```

Current tunnel contract:

- the in-cluster connector is Git-managed
- the published application routes for the token-managed tunnel are currently Cloudflare-dashboard-managed
- if a wildcard hostname returns `502` but the backing `HTTPRoute` is `Accepted`, inspect the wildcard published route in Cloudflare Zero Trust and ensure `Match SNI to Host` is enabled

## ArgoCD And Authentik

ArgoCD admin password:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
```

Local ArgoCD access:

```powershell
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Authentik is split into:

- `authentik-db-prereqs` (namespace, secrets, CNPG cluster)
- `authentik-runtime` (chart, route, blueprints)
- `authentik-db-ops` (scheduled and manual backups)

Default DB mode is `initdb`. DR restore is opt-in via overlay:

- `kubernetes/infrastructure/controllers/authentik-db-prereqs/overlays/dr-restore`

## Storage Triage

Do not start with Longhorn repairs unless the secret and routing chain is already healthy.

Current storage checks:

```powershell
kubectl get pvc -A
kubectl get volumes.longhorn.io -n longhorn-system
kubectl describe pod -n monitoring -l app.kubernetes.io/name=grafana
```

Storage class intent:

- `longhorn` (default): general workloads
- `longhorn-critical`: stateful critical data (for example CNPG)
- `longhorn-observability`: monitoring data (Prometheus/Alertmanager)

Talos node storage intent:

- The VM boot disk backs the Talos `EPHEMERAL` volume, which is where kubelet/containerd image layers, logs, and other transient workload data live.
- The separate worker `longhorn` disk backs only Longhorn replica data under `/var/lib/longhorn`.
- If a node reports `DiskPressure`, inspect the root/ephemeral path even if Longhorn still shows healthy free capacity.

Current provisioning contract:

- New nodes default to `boot_disk_size_gib = 64`.
- Override per-node in `tofu/terraform.tfvars` when needed.
- Existing nodes do not automatically re-provision Talos `EPHEMERAL`; plan a controlled node replacement if you need the larger boot disk to take effect.

## Rolling Worker Rebuild

Use this when a worker needs to pick up a larger Talos boot disk or otherwise be reprovisioned cleanly.

Start by choosing one of these paths:

- Rolling rebuild without full outage:
  pin existing nodes to their current `boot_disk_size_gib` in the local `tofu/terraform.tfvars`, then add the temporary worker
- Planned full outage / reprovision:
  remove the old disk-size pins and expect replacements for every node that still runs on the smaller boot disk

1. For the rolling path, pin existing nodes to their current boot disk size in the local `tofu/terraform.tfvars`, then add a temporary third worker with `boot_disk_size_gib = 64` and run:

```powershell
cd tofu
tofu plan
tofu apply
```

2. Wait for the temporary worker to become Ready, then run the maintenance gate from the repo root:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
./scripts/preflight-worker-rebuild.ps1 -TargetNode worker-01
```

3. Cordon and drain the target worker:

```powershell
kubectl cordon worker-01
kubectl drain worker-01 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m
```

4. Reset the old Talos node so it leaves the cluster cleanly:

```powershell
$env:TALOSCONFIG = "$PWD/tofu/output/talosconfig"
talosctl reset --nodes 192.168.1.211 --endpoints 192.168.1.201 --graceful=false --reboot=false
kubectl delete node worker-01
```

5. Recreate the worker through OpenTofu so the larger boot disk and fresh Talos `EPHEMERAL` volume are applied:

```powershell
cd tofu
tofu plan -replace='module.talos.proxmox_virtual_environment_vm.this["worker-01"]'
tofu apply -replace='module.talos.proxmox_virtual_environment_vm.this["worker-01"]'
```

6. Wait for `worker-01` to return as `Ready`, then run the same post-check gates used during bootstrap:

```powershell
$env:KUBECONFIG = "$PWD/tofu/output/kubeconfig"
./scripts/argocd-health-gate.ps1
./scripts/preflight-core.ps1
kubectl get clusters.postgresql.cnpg.io -A
kubectl get volumes.longhorn.io -n longhorn-system
```

7. Repeat the same flow for the next worker only after the cluster is fully healthy again.

8. Remove the temporary worker from `tofu/terraform.tfvars` and run `tofu apply` once both permanent workers are rebuilt and stable.

If `tofu plan` still shows more replacements than expected, stop and inspect:

- whether an existing node is still inheriting a new `boot_disk_size_gib`
- whether the shared Talos download file is being refreshed
- whether the requested maintenance mode was supposed to be rolling or full-outage

If a volume shows filesystem corruption, snapshot/backup first, then execute the documented restore path through GitOps changes.

## GitOps Notes

- ArgoCD syncs the remote GitHub repository, not this local checkout.
- Local `kubectl apply` commands are for verification and break-glass recovery only.
- Any manual recovery that should persist must be reflected back into Git.
