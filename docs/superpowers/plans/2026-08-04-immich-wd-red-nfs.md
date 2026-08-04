# Immich WD Red NFS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a generic 2 TiB NFS VM on the WD Red disk and reset Immich so its photo library uses that export instead of the media-stack disk.

**Architecture:** OpenTofu creates and protects `nfs-01` on Proxmox `desktop`; an idempotent PowerShell/SSH bootstrap configures the guest filesystem and NFS export. Kubernetes GitOps switches Immich to a distinctly named PV/PVC after a clean PostgreSQL reset, verifies the new storage chain, and only then removes the obsolete `wedding-minio` directory.

**Tech Stack:** OpenTofu 1.6+, bpg/proxmox 0.66, Proxmox VE, Debian 12 cloud image, NFSv4.2, PowerShell, Talos Kubernetes, Kustomize, ArgoCD, Longhorn.

---

## File Map

- Create `tofu/nfs.tf`: Debian image and protected `nfs-01` VM resources.
- Modify `tofu/variables.tf`: typed optional NFS server configuration.
- Modify `tofu/outputs.tf`: non-sensitive NFS VM identity output.
- Modify `tofu/terraform.tfvars.example`: reproducible example configuration.
- Modify local ignored `tofu/terraform.tfvars`: enable the real VM without committing credentials.
- Create `scripts/bootstrap-nfs-01.ps1`: guarded, idempotent guest filesystem and NFS configuration.
- Create `scripts/verify-nfs-export.ps1`: disposable Kubernetes read/write probe for a generic export.
- Create `scripts/assert-immich-wd-red-storage.ps1`: rendered-manifest contract assertions.
- Modify `kubernetes/applications/immich/library-storage.yaml`: new 2 TiB PV/PVC on `nfs-01`.
- Modify `kubernetes/applications/immich/server-deployment.yaml`: new claim and no legacy `subPath`.
- Modify `kubernetes/applications/immich/README.md`: runtime dependency and reset/recovery notes.
- Modify `docs/storage-and-backups/README.md`: WD Red NFS topology and backup posture.
- Modify `docs/operations/README.md`: provisioning and verification commands.

### Task 1: Prove the physical targets are safe

**Files:** None.

- [ ] **Step 1: Verify the repository and cluster baseline**

Run:

```powershell
git status --short
$env:KUBECONFIG = (Resolve-Path 'tofu/output/kubeconfig')
kubectl get application immich media -n argocd
kubectl get nodes -o wide
```

Expected: only the plan document may be untracked; both applications are `Synced/Healthy`; current workers are Ready except deliberately cordoned/stopped nodes.

- [ ] **Step 2: Verify the WD Red identity, allocation, and free space**

Run:

```powershell
ssh root@192.168.1.121 @'
set -euo pipefail
test "$(lsblk -dn -o MODEL /dev/sda | xargs)" = "WDC WD40EFRX-68WT0N0"
test "$(lsblk -dn -o SERIAL /dev/sda | xargs)" = "WD-WCC4E5HHTR12"
pvs --noheadings -o vg_name /dev/sda | grep -qw WD-red
vgs WD-red --units g --nosuffix -o vg_free
lvs WD-red -o lv_name,lv_size
'@
```

Expected: VG `WD-red`, the existing 20 GiB and 100 GiB VM volumes, and more than 2100 GiB free. Stop if the model, serial, VG, or free capacity differs.

- [ ] **Step 3: Prove VMID and IP are unallocated**

Run:

```powershell
ssh root@192.168.1.111 "pvesh get /cluster/resources --type vm --output-format json" |
  Select-String '"vmid":8011|"name":"nfs-01"'
Test-NetConnection 192.168.1.231 -Port 22 -InformationLevel Quiet
Resolve-DnsName 192.168.1.231 -ErrorAction SilentlyContinue
kubectl get ciliumloadbalancerippool first-pool -o yaml
```

Expected: no matching VM, SSH returns `False`, no conflicting DNS record, and the Cilium LoadBalancer pool ends below `.231`. Any positive ownership signal blocks provisioning.

### Task 2: Add the OpenTofu NFS VM

**Files:**
- Create: `tofu/nfs.tf`
- Modify: `tofu/variables.tf`
- Modify: `tofu/outputs.tf`
- Modify: `tofu/terraform.tfvars.example`
- Modify locally: `tofu/terraform.tfvars`

- [ ] **Step 1: Add the typed NFS configuration**

Append to `tofu/variables.tf`:

```hcl
variable "nfs_server" {
  description = "Optional generic NFS service VM"
  type = object({
    enabled            = bool
    host_node          = string
    vm_id              = number
    name               = string
    ip                 = string
    gateway            = string
    boot_datastore     = string
    data_datastore     = string
    data_disk_size_gib = number
    ssh_public_keys    = list(string)
  })
  default = {
    enabled            = false
    host_node          = "desktop"
    vm_id              = 8011
    name               = "nfs-01"
    ip                 = "192.168.1.231"
    gateway            = "192.168.1.1"
    boot_datastore     = "local-lvm"
    data_datastore     = "WD-red"
    data_disk_size_gib = 2048
    ssh_public_keys    = []
  }

  validation {
    condition     = !var.nfs_server.enabled || (length(var.nfs_server.ssh_public_keys) > 0 && var.nfs_server.data_disk_size_gib == 2048)
    error_message = "Enabled nfs_server requires at least one SSH key and exactly 2048 GiB of data storage."
  }
}
```

- [ ] **Step 2: Add the image and protected VM resources**

Create `tofu/nfs.tf`:

```hcl
resource "proxmox_virtual_environment_download_file" "nfs_debian" {
  count        = var.nfs_server.enabled ? 1 : 0
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.nfs_server.host_node
  file_name    = "debian-12-generic-amd64.qcow2"
  url          = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2"
}

resource "proxmox_virtual_environment_vm" "nfs" {
  count       = var.nfs_server.enabled ? 1 : 0
  node_name   = var.nfs_server.host_node
  vm_id       = var.nfs_server.vm_id
  name        = var.nfs_server.name
  description = "Generic NFS server; 2 TiB data disk on WD Red"
  tags        = ["nfs", "storage", "tofu"]
  machine     = "q35"
  scsi_hardware = "virtio-scsi-single"
  on_boot     = true
  protection  = true
  started     = true

  lifecycle {
    prevent_destroy = true
  }

  agent {
    enabled = true
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
  }

  disk {
    datastore_id = var.nfs_server.boot_datastore
    file_id       = proxmox_virtual_environment_download_file.nfs_debian[0].id
    file_format   = "raw"
    interface     = "scsi0"
    size          = 32
    discard       = "on"
    iothread      = true
  }

  disk {
    datastore_id = var.nfs_server.data_datastore
    file_format   = "raw"
    interface     = "scsi1"
    size          = var.nfs_server.data_disk_size_gib
    serial        = "NFS01DATA"
    backup        = false
    iothread      = true
  }

  initialization {
    datastore_id = var.nfs_server.boot_datastore

    dns {
      domain  = "rosenvall.local"
      servers = [var.nfs_server.gateway]
    }

    ip_config {
      ipv4 {
        address = "${var.nfs_server.ip}/24"
        gateway = var.nfs_server.gateway
      }
    }

    user_account {
      username = "debian"
      keys     = var.nfs_server.ssh_public_keys
    }
  }

  operating_system {
    type = "l26"
  }
}
```

- [ ] **Step 3: Add a safe output and example values**

Append to `tofu/outputs.tf`:

```hcl
output "nfs_server" {
  value = var.nfs_server.enabled ? {
    name = proxmox_virtual_environment_vm.nfs[0].name
    vm_id = proxmox_virtual_environment_vm.nfs[0].vm_id
    ip = var.nfs_server.ip
    export = "${var.nfs_server.ip}:/srv/nfs/immich"
  } : null
}
```

Append the same object to `tofu/terraform.tfvars.example`, keeping
`enabled = false` and `ssh_public_keys = []`. The local enabled configuration
supplies the operator's real public key.

- [ ] **Step 4: Enable the local ignored configuration**

Add an `nfs_server` object to local `tofu/terraform.tfvars` with the approved values and the contents of the operator's existing `.pub` key. Never add the Proxmox API token or local tfvars file to Git.

- [ ] **Step 5: Format and validate**

Run:

```powershell
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu validate
tofu -chdir=tofu plan -out=nfs-01.tfplan
tofu -chdir=tofu show -json nfs-01.tfplan |
  Set-Content -Encoding utf8 "$env:TEMP/nfs-01-plan.json"
```

Expected: validation succeeds and the plan creates one Debian download plus VM
`8011`; it must not replace or destroy any Talos VM or existing WD Red LV.
Retain `nfs-01.tfplan` through Task 4, apply that exact reviewed plan, and then
delete the local plan artifact.

- [ ] **Step 6: Commit the declarative VM definition**

```powershell
git add tofu/nfs.tf tofu/variables.tf tofu/outputs.tf tofu/terraform.tfvars.example
git diff --cached --check
git commit -m "feat(storage): define generic WD Red NFS VM"
```

### Task 3: Build guarded guest bootstrap and export verification

**Files:**
- Create: `scripts/bootstrap-nfs-01.ps1`
- Create: `scripts/verify-nfs-export.ps1`
- Modify: `docs/operations/README.md`

- [ ] **Step 1: Create the guarded bootstrap script**

Create `scripts/bootstrap-nfs-01.ps1` with parameters `VmIp`, `ExportPath`, `ExpectedSerial`, and `AllowedClients`. Its remote Bash payload must implement these exact gates before formatting:

```bash
set -euo pipefail
export_path="/srv/nfs/immich"
expected_serial="NFS01DATA"
data_disk="$(lsblk -dpno NAME,SERIAL,TYPE | awk -v serial="$expected_serial" '$2 == serial && $3 == "disk" {print $1}')"
test -n "$data_disk"
test "$(printf '%s\n' "$data_disk" | wc -l)" -eq 1
test "$data_disk" != "$(findmnt -no SOURCE / | sed 's/[0-9]*$//')"
size_bytes="$(blockdev --getsize64 "$data_disk")"
test "$size_bytes" -ge 2190000000000
test "$size_bytes" -le 2210000000000

if blkid "$data_disk" >/dev/null 2>&1 || [ -n "$(lsblk -nro FSTYPE "$data_disk" | tr -d '[:space:]')" ]; then
  echo "Unexpected signature on $data_disk; refusing to format" >&2
  exit 1
fi

sudo parted -s "$data_disk" mklabel gpt mkpart primary ext4 1MiB 100%
sudo partprobe "$data_disk"
data_partition="${data_disk}1"
sudo mkfs.ext4 -L immich-nfs "$data_partition"
```

After first-run creation, reruns must locate an existing partition labeled `immich-nfs`, reject any other label/filesystem, and skip `parted`/`mkfs`. The remaining payload installs `qemu-guest-agent`, `nfs-kernel-server`, and `nfs-common`; mounts the UUID at `/srv/nfs/immich` with `defaults,nofail,noatime`; sets UID/GID 1000 and mode 0775; writes `/etc/exports.d/immich.exports`; adds a systemd `RequiresMountsFor=/srv/nfs/immich` drop-in; enables services; runs `exportfs -ra`; and prints `findmnt`, `df -h`, and `exportfs -v`.

Default clients must be the current schedulable worker IPs:

```powershell
@(
  '192.168.1.211(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)',
  '192.168.1.212(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)',
  '192.168.1.213(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)',
  '192.168.1.214(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)',
  '192.168.1.217(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)'
)
```

- [ ] **Step 2: Create the disposable Kubernetes verifier**

Create `scripts/verify-nfs-export.ps1` by reusing the kubeconfig helpers from `scripts/pvc-seed-utils.ps1`. Parameters default to namespace `immich`, server `192.168.1.231`, and path `/srv/nfs/immich`. The generated BusyBox pod runs as UID/GID 1000, mounts the NFS export at `/target`, creates `/target/.nfs-write-check`, reads it, removes it, and prints `df -h /target`. Its `finally` block always deletes the pod and temporary manifest.

- [ ] **Step 3: Verify script syntax before any disk mutation**

Run:

```powershell
$files = @('scripts/bootstrap-nfs-01.ps1','scripts/verify-nfs-export.ps1')
foreach ($file in $files) {
  $errors = $null
  $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $file), [ref]$tokens, [ref]$errors
  ) | Out-Null
  if ($errors.Count) { throw ($errors | Out-String) }
}
```

Expected: no parser errors.

- [ ] **Step 4: Document the commands and commit**

Add the preflight, `tofu apply`, bootstrap, NFS verification, reboot verification, and `prevent_destroy` recovery note to `docs/operations/README.md`.

```powershell
git add scripts/bootstrap-nfs-01.ps1 scripts/verify-nfs-export.ps1 docs/operations/README.md
git diff --cached --check
git commit -m "feat(storage): bootstrap generic NFS export"
```

### Task 4: Provision and prove `nfs-01`

**Files:** None beyond local OpenTofu state.

- [ ] **Step 1: Apply the reviewed plan**

Run:

```powershell
tofu -chdir=tofu apply nfs-01.tfplan
tofu -chdir=tofu output nfs_server
```

Expected: VM `8011`, `nfs-01`, `192.168.1.231`, and export `/srv/nfs/immich`. Do not use `-auto-approve` on a newly generated or unreviewed plan.

- [ ] **Step 2: Verify Proxmox attached the correct storage**

Run:

```powershell
ssh root@192.168.1.121 "qm config 8011; lvs WD-red -o lv_name,lv_size,devices"
```

Expected: `scsi1` is 2048 GiB on `WD-red`, carries serial `NFS01DATA`, and existing VM 8001/8004 volumes are unchanged.

- [ ] **Step 3: Bootstrap and verify the new export**

Run:

```powershell
.\scripts\bootstrap-nfs-01.ps1
.\scripts\verify-nfs-export.ps1
```

Expected: ext4 label `immich-nfs`, NFS read/write succeeds as UID/GID 1000, and the temporary marker is removed.

- [ ] **Step 4: Prove reboot persistence**

Run:

```powershell
ssh debian@192.168.1.231 "sudo reboot"
```

Wait for SSH to return, then run:

```powershell
ssh debian@192.168.1.231 "findmnt /srv/nfs/immich; systemctl is-active nfs-kernel-server; sudo exportfs -v"
.\scripts\verify-nfs-export.ps1
```

Expected: mount and NFS service return automatically and the second worker-side write test passes.

### Task 5: Add a failing Immich storage contract

**Files:**
- Create: `scripts/assert-immich-wd-red-storage.ps1`

- [ ] **Step 1: Write the contract assertion before changing manifests**

The script must render `kubernetes/applications/immich`, split YAML documents, and assert all of the following literal contract points:

```powershell
$rendered = kubectl kustomize kubernetes/applications/immich
if ($LASTEXITCODE -ne 0) { throw 'Kustomize render failed' }
$yaml = $rendered -join "`n"
$required = @(
  'name: immich-library-wd-red',
  'storage: 2Ti',
  'server: 192.168.1.231',
  'path: /srv/nfs/immich',
  'claimName: immich-library-wd-red'
)
foreach ($text in $required) {
  if (-not $yaml.Contains($text)) { throw "Missing contract text: $text" }
}
if ($yaml.Contains('subPath: wedding-minio')) {
  throw 'Legacy wedding-minio subPath is still rendered'
}
```

- [ ] **Step 2: Run it and observe the expected RED result**

Run:

```powershell
.\scripts\assert-immich-wd-red-storage.ps1
```

Expected: failure on `immich-library-wd-red` because the live manifests still target the media disk.

- [ ] **Step 3: Commit the failing contract**

```powershell
git add scripts/assert-immich-wd-red-storage.ps1
git commit -m "test(immich): require WD Red library storage"
```

### Task 6: Quiesce and reset Immich

**Files:**
- Temporarily modify: all four `kubernetes/applications/immich/*-deployment.yaml` files.

- [ ] **Step 1: Set all Immich deployment replicas to zero**

Change `replicas: 1` to `replicas: 0` in:

```text
kubernetes/applications/immich/database-deployment.yaml
kubernetes/applications/immich/valkey-deployment.yaml
kubernetes/applications/immich/machine-learning-deployment.yaml
kubernetes/applications/immich/server-deployment.yaml
```

- [ ] **Step 2: Render, commit, and push the pause**

```powershell
kubectl kustomize kubernetes/applications/immich | Out-Null
git add kubernetes/applications/immich/*-deployment.yaml
git commit -m "chore(immich): quiesce for storage reset"
git push origin master
kubectl annotate application immich -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/immich -n argocd --timeout=180s
$deadline = (Get-Date).AddMinutes(3)
do {
  $pods = @(kubectl get pods -n immich --no-headers 2>$null)
  if ($pods.Count -eq 0) { break }
  Start-Sleep -Seconds 3
} while ((Get-Date) -lt $deadline)
if ($pods.Count -ne 0) { throw "Immich pods still exist: $($pods -join '; ')" }
```

Do not delete either PVC while a pod still mounts it.

- [ ] **Step 3: Reset PostgreSQL and record proof of replacement**

Run:

```powershell
$oldUid = kubectl get pvc immich-postgresql -n immich -o jsonpath='{.metadata.uid}'
kubectl delete pvc immich-postgresql -n immich --wait=true
kubectl annotate application immich -n argocd argocd.argoproj.io/refresh=hard --overwrite
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/immich-postgresql -n immich --timeout=180s
$newUid = kubectl get pvc immich-postgresql -n immich -o jsonpath='{.metadata.uid}'
if ($oldUid -eq $newUid) { throw 'PostgreSQL PVC was not replaced' }
```

Expected: a new Bound Longhorn PVC UID and no running PostgreSQL pod yet.

### Task 7: Switch GitOps to the WD Red export

**Files:**
- Modify: `kubernetes/applications/immich/library-storage.yaml`
- Modify: `kubernetes/applications/immich/server-deployment.yaml`
- Modify: the other three Immich deployment manifests to restore replicas
- Modify: `kubernetes/applications/immich/README.md`
- Modify: `docs/storage-and-backups/README.md`

- [ ] **Step 1: Replace the library PV/PVC definition**

In `library-storage.yaml`, rename both PV and PVC to `immich-library-wd-red`, set capacity/request to `2Ti`, and set:

```yaml
nfs:
  server: 192.168.1.231
  path: /srv/nfs/immich
```

Keep `ReadWriteMany`, empty `storageClassName`, NFSv4.2 mount options, sync waves, and `Retain` reclaim policy. Set `volumeName: immich-library-wd-red` on the claim.

- [ ] **Step 2: Point the server directly at the new claim**

Change the server volume to:

```yaml
volumeMounts:
  - name: library
    mountPath: /data
volumes:
  - name: library
    persistentVolumeClaim:
      claimName: immich-library-wd-red
```

Remove `subPath: wedding-minio` and restore `replicas: 1` in all four deployments.

- [ ] **Step 3: Update storage documentation**

Document `nfs-01`, VMID 8011, Proxmox `desktop`, WD Red, 2 TiB allocation, IP `.231`, export path, lack of current backup automation, and the fact that media NFS `.230` is unrelated.

- [ ] **Step 4: Turn the contract GREEN and run manifest validation**

Run:

```powershell
.\scripts\assert-immich-wd-red-storage.ps1
kubectl kustomize kubernetes/applications/immich | Out-Null
kubectl apply --dry-run=client -k kubernetes/applications/immich
git diff --check
```

Expected: contract passes, render succeeds, and every resource is accepted by client dry-run.

- [ ] **Step 5: Commit and push the cutover**

```powershell
git add kubernetes/applications/immich scripts/assert-immich-wd-red-storage.ps1 docs/storage-and-backups/README.md
git commit -m "feat(immich): move library to WD Red NFS"
git push origin master
kubectl annotate application immich -n argocd argocd.argoproj.io/refresh=hard --overwrite
```

### Task 8: Verify the clean deployment before destructive cleanup

**Files:** None.

- [ ] **Step 1: Wait for GitOps and workload health**

Run condition-based polling for at most ten minutes until:

```text
Application/immich: Synced, Healthy
immich-postgresql: 1/1 Ready
immich-valkey: 1/1 Ready
immich-machine-learning: 1/1 Ready
immich-server: 1/1 Ready
```

On failure, inspect events and logs; do not delete the old directory.

- [ ] **Step 2: Verify the live PV and storage chain**

Run:

```powershell
kubectl get pv immich-library-wd-red -o jsonpath='{.spec.nfs.server}{":"}{.spec.nfs.path}{"`n"}'
kubectl exec -n immich deployment/immich-server -- sh -c 'touch /data/.cutover-write-check && rm /data/.cutover-write-check'
ssh debian@192.168.1.231 "findmnt -T /srv/nfs/immich -o SOURCE,TARGET,FSTYPE,SIZE,USED,AVAIL; lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS,SERIAL"
ssh root@192.168.1.121 "qm config 8011 | grep '^scsi1:'; lvs WD-red -o lv_name,lv_size,devices"
```

Expected: `.231:/srv/nfs/immich`, successful write, ext4 label `immich-nfs`, guest serial `NFS01DATA`, and the backing Proxmox LV on `WD-red`.

- [ ] **Step 3: Verify the first-run state and internal-only route**

Run:

```powershell
$response = curl.exe -k -sS https://immich.rosenvall.local/api/server/config | ConvertFrom-Json
if ($response.isInitialized -ne $false) { throw 'Immich was not reset' }
kubectl get httproute immich-internal -n immich -o json
$public = kubectl get httproute immich-public -n immich --ignore-not-found -o name
if ($public) { throw 'Public Immich route unexpectedly exists' }
```

Expected: `isInitialized: false`, internal route Accepted/ResolvedRefs, public route absent.

### Task 9: Remove the obsolete data and prove media isolation

**Files:** None.

- [ ] **Step 1: Resolve and validate the exact deletion target**

Run read-only checks first:

```powershell
ssh debian@192.168.1.230 @'
set -euo pipefail
root="$(readlink -f /srv/nfs/media)"
target="$(readlink -f /srv/nfs/media/wedding-minio)"
test "$root" = "/srv/nfs/media"
test "$target" = "/srv/nfs/media/wedding-minio"
test "$(findmnt -T "$target" -no TARGET)" = "/srv/nfs/media"
du -sh -- "$target"
'@
```

Stop if any resolved path differs.

- [ ] **Step 2: Delete only the obsolete directory**

Run:

```powershell
ssh debian@192.168.1.230 @'
set -euo pipefail
root="$(readlink -f /srv/nfs/media)"
target="$(readlink -f /srv/nfs/media/wedding-minio)"
test "$root" = "/srv/nfs/media"
test "$target" = "/srv/nfs/media/wedding-minio"
sudo rm -rf --one-file-system -- "$target"
test ! -e "$target"
'@
```

This deletion is intentional and not recoverable from the homelab; the user confirmed the original photo source is retained elsewhere.

- [ ] **Step 3: Verify the media stack was not affected**

Run:

```powershell
kubectl get application media -n argocd
kubectl get pods -n media
.\scripts\verify-media-nfs.ps1
ssh debian@192.168.1.230 "test ! -e /srv/nfs/media/wedding-minio"
```

Expected: media remains `Synced/Healthy`, its pods are Ready, its expected directories remain writable, and `wedding-minio` is absent.

### Task 10: Final verification and publish

**Files:** All files listed above.

- [ ] **Step 1: Run the complete static verification**

```powershell
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu validate
.\scripts\assert-immich-wd-red-storage.ps1
kubectl kustomize kubernetes/applications/immich | Out-Null
kubectl apply --dry-run=client -k kubernetes/applications/immich
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Run the complete live verification**

Repeat the Task 8 health, PV, write, storage-chain, API, and route checks plus Task 9 media checks. Record the final Argo revision and pod restart counts.

- [ ] **Step 3: Confirm Git and remote state**

```powershell
git status --short
git fetch origin
git rev-list --left-right --count origin/master...HEAD
```

Expected: clean worktree and `0 0`. If the planning document remains uncommitted, add it in a final documentation commit and push `master`, then repeat the check.
