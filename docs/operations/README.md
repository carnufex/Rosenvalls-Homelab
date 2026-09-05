# Operations

Use this page for normal day-2 operations and first-response health checks.

## Access

```powershell
$env:KUBECONFIG = "$PWD\tofu\output\kubeconfig"
$env:TALOSCONFIG = "$PWD\tofu\output\talosconfig"
```

## Core Health Order

Use this order before digging into app-specific symptoms:

1. `kubectl get nodes -o wide`
2. `kubectl get applications.argoproj.io -n argocd`
3. `kubectl get clustersecretstore bitwarden-secretsmanager`
4. `kubectl get externalsecret -A`
5. `kubectl get pods -n cloudflare`
6. `kubectl get certificate -n gateway`
7. `kubectl get gateway -A`
8. `kubectl get httproute -A`

The goal is to validate the bootstrap secret chain and routing chain before spending time on downstream symptoms.

## Core Gates

```powershell
.\scripts\argocd-health-gate.ps1
.\scripts\preflight-core.ps1
.\scripts\cluster-health-report.ps1
```

After an unplanned power outage or breaker trip:

```powershell
$env:KUBECONFIG = (Resolve-Path .\tofu\output\kubeconfig)
.\scripts\post-power-loss-check.ps1
```

Use `-SkipMediaChecks` only when the NFS media VM or VPN endpoint is intentionally offline.
By default the script removes terminal non-Job controller pods left by node shutdown before running the final cluster health report. This includes `Failed` and `Succeeded` pods owned by ReplicaSets, DaemonSets, StatefulSets, and similar controllers, but leaves Job history intact. Use `-SkipFailedPodCleanup` when you want to inspect those pod objects manually.

Use these after:

- first bootstrap
- any rebuild or replace operation
- any routing incident
- any secret-chain incident
- before and after a recovery drill
- before deleting preview namespaces or PVCs

## Operational Scripts

```powershell
.\scripts\cluster-health-report.ps1
.\scripts\export-local-ca.ps1
.\scripts\post-power-loss-check.ps1
.\scripts\provision-host1-media-nfs-vm.ps1
.\scripts\r2-backup-audit.ps1
.\scripts\r2-critical-inventory.ps1
.\scripts\build-r2-dr-kit.ps1
.\scripts\bootstrap-nfs-01.ps1
.\scripts\seed-homeassistant.ps1
.\scripts\seed-media-configs.ps1
.\scripts\verify-local-routes.ps1
.\scripts\verify-media-nfs.ps1
.\scripts\verify-nfs-export.ps1
.\scripts\verify-deluge-vpn.ps1
.\scripts\upgrade-talos-node.ps1
.\scripts\prepare-node-for-drain.ps1
```

`pvc-seed-utils.ps1` is an internal helper used by seeding scripts. Do not run it directly.

## Generic NFS Export (nfs-01)

nfs-01 is separate from the media NFS VM at 192.168.1.230. It is VM 8011 at
192.168.1.231, with a 2048 GiB WD-red disk carrying serial NFS01DATA.

The current full OpenTofu plan contains unrelated drift. Provisioning `nfs-01`
is therefore an exceptional, targeted operation. **Do not run an unscoped
`tofu plan`/`apply`, and never apply a full plan, until that drift is repaired
and reviewed separately.** Only the two exact resource addresses below are in
scope.

~~~powershell
tofu -chdir=tofu fmt -check nfs.tf variables.tf outputs.tf
tofu -chdir=tofu validate

function Assert-SavedTofuPlan {
    param(
        [string]$PlanName,
        [string[]]$ExpectedAddresses,
        [int]$Creates,
        [int]$Updates,
        [int]$Deletes
    )
    $jsonPath = ".\tofu\$PlanName.json"
    tofu -chdir=tofu show -json "$PlanName.tfplan" |
        Set-Content -LiteralPath $jsonPath -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw "Unable to render saved plan $PlanName." }
    $plan = Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json
    $mutations = @($plan.resource_changes | Where-Object {
        $actions = @($_.change.actions)
        ($actions -contains "create") -or
        ($actions -contains "update") -or
        ($actions -contains "delete")
    })
    $actualCreates = @($mutations | Where-Object { @($_.change.actions) -contains "create" }).Count
    $actualUpdates = @($mutations | Where-Object { @($_.change.actions) -contains "update" }).Count
    $actualDeletes = @($mutations | Where-Object { @($_.change.actions) -contains "delete" }).Count
    if ($actualCreates -ne $Creates -or $actualUpdates -ne $Updates -or $actualDeletes -ne $Deletes) {
        throw "Saved plan gate failed: expected ${Creates}C/${Updates}U/${Deletes}D, got ${actualCreates}C/${actualUpdates}U/${actualDeletes}D."
    }
    $addressDiff = @(Compare-Object ($ExpectedAddresses | Sort-Object) ($mutations.address | Sort-Object))
    if ($addressDiff.Count) { throw "Saved plan contains an unexpected mutation address." }
}

$createAddresses = @(
    'proxmox_virtual_environment_download_file.nfs_debian["nfs"]'
    'proxmox_virtual_environment_vm.nfs["nfs"]'
)
tofu -chdir=tofu plan `
    "-target=$($createAddresses[0])" `
    "-target=$($createAddresses[1])" `
    -out=nfs-01-create.tfplan
if ($LASTEXITCODE -ne 0) { throw "Targeted nfs-01 plan failed." }
Assert-SavedTofuPlan -PlanName nfs-01-create -ExpectedAddresses $createAddresses -Creates 2 -Updates 0 -Deletes 0
tofu -chdir=tofu show nfs-01-create.tfplan
# Apply this exact saved plan only; do not replace it with an unscoped plan.
tofu -chdir=tofu apply nfs-01-create.tfplan
tofu -chdir=tofu output nfs_server
~~~

Targeted applies can leave the root `nfs_server` output absent or stale. That
does not justify an unscoped apply: confirm the managed VM with
`tofu -chdir=tofu state show 'proxmox_virtual_environment_vm.nfs["nfs"]'` and
repair state outputs only as part of the separately reviewed drift work.

After SSH is reachable, bootstrap and prove the export from a disposable
Kubernetes pod:

~~~powershell
.\scripts\bootstrap-nfs-01.ps1
.\scripts\verify-nfs-export.ps1
~~~

Bootstrap formats only one non-root disk with serial NFS01DATA, an
approximately 2 TiB byte size, no signatures, and no partition layout. Reruns
accept only one GPT/ext4 partition labeled immich-nfs; every other state
aborts for manual investigation.

Prove reboot persistence:

~~~powershell
ssh debian@192.168.1.231 "sudo reboot"
# Wait for SSH as debian to return.
ssh debian@192.168.1.231 "set -e; findmnt /srv/nfs/immich; systemctl is-active nfs-kernel-server; sudo exportfs -v"
.\scripts\verify-nfs-export.ps1
~~~

The QEMU agent starts disabled because the package is not present yet. After
bootstrap, set `agent_enabled = true` in ignored local
`tofu/terraform.tfvars`, then use a second VM-only saved plan. It must contain
exactly `0C/1U/0D` at the one VM address before applying that exact file:

~~~powershell
$vmAddress = 'proxmox_virtual_environment_vm.nfs["nfs"]'
tofu -chdir=tofu plan "-target=$vmAddress" -out=nfs-01-agent.tfplan
if ($LASTEXITCODE -ne 0) { throw "Targeted qemu-agent plan failed." }
Assert-SavedTofuPlan -PlanName nfs-01-agent -ExpectedAddresses @($vmAddress) -Creates 0 -Updates 1 -Deletes 0
tofu -chdir=tofu show nfs-01-agent.tfplan
# Apply this exact saved plan only; full/unscoped apply remains prohibited.
tofu -chdir=tofu apply nfs-01-agent.tfplan
~~~

nfs-01 is protected with OpenTofu prevent_destroy. For a real recovery,
preserve or restore the NFS data first and deliberately change that protection
in a reviewed recovery operation. Never use destruction as troubleshooting for
this VM or the WD Red disk.

## Talos Node Upgrades

`scripts/upgrade-talos-node.ps1` walks one node through a list of Talos
versions, one minor at a time, and waits for both the node and the whole
cluster to settle between steps. Talos only supports upgrading from the
previous minor, so 1.12 -> 1.14 must pass through 1.13.

```powershell
.\scripts\upgrade-talos-node.ps1 -NodeName worker-07 -NodeIp 192.168.1.219 `
  -Versions "v1.13.9,v1.14.0" `
  -TalosctlPath "$env:TEMP\talosctl-v1.14.0\talosctl.exe"
```

Compute-only workers (worker-05 .. worker-09) upgrade unattended in about ten
minutes each. **The three Longhorn storage workers (worker-01, worker-02,
worker-03) do not**, for two reasons:

1. From 1.14 Talos drains the node first, and two pods refuse eviction. A
   single-instance CNPG cluster - `authentik-postgresql` - has a primary PDB
   with `allowedDisruptions=0`; two-instance clusters have the same PDB on
   whichever pod is currently primary. Longhorn then keeps a PDB on
   `instance-manager-*` for as long as a volume is attached on the node, which
   the stuck CNPG pod guarantees. The two block each other, Talos retries
   evictions until the client rate limiter hits its deadline, and the upgrade
   fails with the node left cordoned.
2. A cordoned node is not a valid Longhorn replica target, so a node left
   cordoned by a failed drain never rebuilds its replicas. Uncordon it as soon
   as an upgrade fails, or its volumes sit degraded on a single replica.

Run `scripts/prepare-node-for-drain.ps1 -NodeName <node>` first. It cordons the
node, deletes (not evicts - deletion bypasses the PDB) any CNPG instance on it
so CNPG rebuilds elsewhere, and refuses to continue while any attached volume
is still degraded. Uncordon afterwards.

The drain itself comes from the client: talosctl 1.14 added `--drain`, defaulting
to true, which is why the same nodes upgraded fine under the 1.12 client. Once
prepare-node-for-drain.ps1 has emptied the node, only Longhorn's instance-manager
is left and its PDB never allows eviction - so pass `-SkipDrain` to
upgrade-talos-node.ps1, which forwards `--drain=false`. Prefer that over
`--force`, which also skips the etcd health checks that matter on control planes.
Uncordon and wait for replicas to rebuild before starting the next storage node.

Expect each storage-node reboot to cost a full round of replica rebuilds:
`concurrent-replica-rebuild-per-node-limit` is 1 on purpose, so ~25 replicas
rebuild one after another. Do not raise it to go faster - worker-01 already
reports NodeDiskIOSaturation under normal load.

After the fleet is on the new Talos version, bump `talos_version` in
`tofu/variables.tf` and `tofu/terraform.tfvars` so a future rebuild does not
reinstall the old release.

## High-Value Checks

```powershell
kubectl get pods -A
kubectl get pvc -A
kubectl get events -A --field-selector type=Warning
kubectl get clusters.postgresql.cnpg.io -A
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get gateway -A
kubectl get httproute -A
```

## App Status And Node Pressure

Use Grafana as the primary app status view:

- `https://grafana.rosenvall.local/d/homelab-app-status/homelab-app-status`

Fast terminal checks:

```powershell
kubectl top nodes
kubectl top pods -A --sort-by=memory
kubectl get pods -A --field-selector status.phase=Failed
kubectl get events -A --sort-by=.lastTimestamp
kubectl get nodes -L homelab.rosenvall.se/proxmox-host,topology.kubernetes.io/zone
```

If Metrics API is unavailable, query Prometheus directly until `metrics-server` has reconciled:

```powershell
$pod = kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}'
$query = [uri]::EscapeDataString('1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes')
kubectl -n monitoring exec $pod -c prometheus -- wget -qO- "http://127.0.0.1:9090/api/v1/query?query=$query"
```

During Docker cutover, `ragflow` and `matplan-whisper` may be intentionally paused to keep worker memory below eviction pressure. Re-enable them only after media and Home Assistant have run in Kubernetes without new evictions for at least one day.

Control-plane memory above 85% should be treated as an early warning, not an
automatic VM resize. First check whether workloads can move off `desktop` or
whether the physical host needs more RAM; `control-01` should only be increased
after the host has enough reserve.

## Cluster UI

Use Headlamp for live Kubernetes object inspection:

- `https://headlamp.rosenvall.se`
- `https://headlamp.rosenvall.local` redirects to the canonical `.se` URL
- Authentik OIDC login
- read-only cluster role by default
- shows nodes, namespaces, pods, workload placement, events, PVCs, routes, ArgoCD apps, ExternalSecrets, Longhorn objects, CNPG clusters, and Metrics API CPU/memory data

Use Grafana for history, alerting, and trend dashboards:

- `https://grafana.rosenvall.local/d/homelab-app-status/homelab-app-status`

If Headlamp does not show CPU or memory, verify the Metrics API first:

```powershell
kubectl top nodes
kubectl top pods -A
```

Headlamp is intentionally not an admin console in its first version. Do not grant create, patch, delete, exec, or secret-read permissions without a separate review.

## Authentik Native OIDC

Native OIDC app configuration lives in:

- `kubernetes/infrastructure/controllers/authentik-runtime/README.md`
- `kubernetes/infrastructure/controllers/authentik-runtime/blueprints.yaml`

Current rollout model:

- ArgoCD and Rosenvall DevOps already use Authentik.
- Grafana and Headlamp use Authentik after their GitOps sync completes.
- RAGFlow has an Authentik provider prepared, but app login is not enabled until its OAuth client secret can come from a Kubernetes Secret instead of a ConfigMap.
- Apps without clean native OIDC support stay unchanged. Do not add duplicate local login plus Authentik as the normal path.

## Rosenvall DevOps Preview Cleanup

Preview namespaces created by `rosenvall-devops` are expected to be temporary.

The cleanup job only targets namespaces with:

- label `app.kubernetes.io/part-of=rosenvall-devops-preview`
- age greater than 24 hours
- no annotation `rosenvall.devops/keep=true`

It never deletes the base namespace `devops-previews`. To preserve a preview manually:

```powershell
kubectl annotate namespace <preview-namespace> rosenvall.devops/keep=true
```

Report current candidates without deleting anything:

```powershell
.\scripts\cluster-health-report.ps1
kubectl get namespaces -l app.kubernetes.io/part-of=rosenvall-devops-preview
```

## What Broke

### Routing

```powershell
kubectl get gateway -A
kubectl get httproute -A
.\scripts\verify-local-routes.ps1
```

### PVC Or Longhorn State

```powershell
kubectl get pvc -A
kubectl describe pvc -n media media-library
kubectl -n longhorn-system get settings.longhorn.io node-down-pod-deletion-policy orphan-resource-auto-deletion
kubectl get volumes.longhorn.io -n longhorn-system
kubectl -n longhorn-system get orphan -o wide
kubectl get volumeattachment.storage.k8s.io
```

After node restarts, Longhorn can leave stale engine instances or stale Kubernetes `VolumeAttachment` objects. For app PVCs stuck in `ContainerCreating`, match the stuck PVC name to `kubectl -n longhorn-system get orphan -o wide` before deleting anything. Delete only orphan resources of type `engine-instance` that match the affected volume, then recreate the stuck workload pod.

For abrupt power loss, Longhorn should keep `node-down-pod-deletion-policy=delete-deployment-pod`. This allows single-replica Deployment workloads with RWO config PVCs to be recreated on a healthy worker when the original node is down. Do not broaden this to StatefulSets without a separate database/storage review.

Prometheus uses bounded local TSDB storage. If it crashloops with `panic: preallocate: no space left on device`, first expand or repair the Prometheus PVC and restart the pod so filesystem resize can complete. Avoid adding observability PVCs to R2 backup groups unless there is an explicit storage budget decision.

### R2 Backup Cost Guard

R2 is not an active Longhorn or CNPG WAL/base backup backend in free-tier mode. It must not be used by Longhorn polling/backup jobs or CNPG `barmanObjectStore` without an explicit budget decision.

```powershell
.\scripts\r2-backup-audit.ps1
```

This check fails if Longhorn `BackupTarget/default`, Longhorn recurring backup jobs, CNPG `barmanObjectStore`, or PVC labels still point at R2. When local `rclone` is configured, it also fails if listable R2 objects exist outside `critical-dr/`, warns above 8GiB, and checks critical Authentik retention.

Critical R2 jobs are monthly and encrypted with `rclone crypt`:

- `CronJob/r2-critical-dr/authentik-critical-r2`
- `CronJob/r2-critical-dr/app-config-critical-r2`

Manual DR-kit and cleanup inventory:

```powershell
.\scripts\build-r2-dr-kit.ps1
.\scripts\r2-critical-inventory.ps1
```

Both scripts are dry-run by default. `build-r2-dr-kit.ps1` requires `-Upload` to copy anything to R2; `r2-critical-inventory.ps1` requires `-Apply` to delete anything.

### NFS Media Library

```powershell
kubectl get pv media-library -o yaml
kubectl get ciliumloadbalancerippool first-pool -o jsonpath='{.spec.blocks[0].stop}'
Test-NetConnection 192.168.1.230 -Port 22
Test-NetConnection 192.168.1.230 -Port 2049
.\scripts\verify-media-nfs.ps1
showmount -e 192.168.1.230
```

The Cilium pool stop value must be `192.168.1.229` or lower. `192.168.1.230`
should be owned by VM `8010` (`media-nfs-01`) on `host1`.

In the current host1 layout, the media data is inside VM `100`'s qcow2 disk,
attached to `media-nfs-01` as `scsi1`. VM `100` must stay stopped with
`onboot: 0` while `media-nfs-01` owns the disk. Do not destroy VM `100` with
"destroy unreferenced disks" while it still references the media qcow2 as an
unused disk.

Use `.\scripts\provision-host1-media-nfs-vm.ps1` to recreate or re-bootstrap
the VM.

### Host-Network Apps

```powershell
kubectl get pod -n media -o wide -l app.kubernetes.io/name=plex
kubectl get pod -n homeassistant -o wide -l app.kubernetes.io/name=homeassistant
kubectl logs -n media deploy/plex
kubectl logs -n homeassistant deploy/homeassistant
```

For Plex, also run the semantic health checks in `.\scripts\cluster-health-report.ps1`.
They verify `/identity`, the `plex-config` Longhorn volume, the direct LAN
endpoint, the local route, and the persisted `EasyAudioEncoder` codec cache.
`CronJob/plex-self-heal` may delete only the Plex pod if `/identity` or the
codec cache is broken; it does not delete Plex config or media files.

### Deluge VPN

```powershell
kubectl get pod -n media -l app.kubernetes.io/name=deluge-vpn
kubectl logs -n media deploy/deluge-vpn -c wireguard
kubectl logs -n media deploy/deluge-vpn -c deluge
.\scripts\verify-deluge-vpn.ps1
```

## Troubleshooting Priorities

- If `bitwarden-secretsmanager` is not ready, restore that first.
- If public traffic is broken, validate `cloudflared`, the wildcard certificate, and the external gateway before touching app manifests.
- If internal traffic is broken, validate `gateway/internal`, `HTTPRoute` acceptance, and the local CA trust chain before touching workloads.
- If storage is degraded, verify the secret chain and routing chain are already green before starting Longhorn repair work.
- If a node shows `DiskPressure`, inspect the Talos boot disk and `EPHEMERAL` usage before blaming Longhorn.

## Naming Conventions In The Docs

- Use `<control-plane-node>` and `<worker-node>` as placeholders in procedures.
- Use `control-01` and `worker-01` only when a concrete example is required.

## Related Docs

- [Disaster recovery](../disaster-recovery/README.md)
- [Scaling](../scaling/README.md)
- [Networking](../networking/README.md)
- [Storage and backups](../storage-and-backups/README.md)
