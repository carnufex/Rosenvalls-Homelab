# Immich WD Red NFS Design

## Goal

Move Immich's photo library off the shared 8 TB media disk and onto 2 TiB of
the mostly unused 4 TB WD Red disk in the Proxmox node `desktop`. Reset Immich
to a clean first-run state. No existing Immich uploads, accounts, albums, or
metadata need to be retained.

The media stack and its NFS export on `192.168.1.230` must remain unchanged.

## Existing Storage

- The WD Red is `/dev/sda` on `desktop`, model `WDC WD40EFRX-68WT0N0`, and is
  the Proxmox LVM storage `WD-red`.
- `WD-red` currently contains a 20 GiB disk for `control-01` and a 100 GiB disk
  for `worker-03`. Those volumes must not be modified.
- Immich currently mounts the media-stack export
  `192.168.1.230:/srv/nfs/media` with the `wedding-minio` subdirectory.
- The existing `wedding-minio` contents are disposable and will not be copied.

## Architecture

Create a generic Debian 12 NFS VM with the following shape:

- Name: `nfs-01`
- Proxmox node: `desktop`
- VMID: `8011`
- IP: `192.168.1.231/24`
- CPU and memory: 2 vCPU and 2 GiB RAM
- Boot disk: 32 GiB on `local-lvm`
- Data disk: 2 TiB on `WD-red`
- Data filesystem: ext4
- Mount point and export: `/srv/nfs/immich`

The implementation must stop before making changes if VMID `8011`, IP
`192.168.1.231`, the target LVM capacity, or the expected WD Red identity does
not match the preflight checks.

NFS access is limited to the Talos worker addresses that can schedule Immich.
The exported directory maps writes to UID/GID 1000, matching the established
media NFS convention. The VM starts the filesystem mount and NFS export
automatically after reboot.

## Ownership and Reproducibility

- OpenTofu owns the Proxmox VM, boot disk, and 2 TiB data disk. The NFS VM is a
  separate resource rather than an entry in the Talos-only `nodes_config` map.
- The data-bearing VM resource is protected against accidental destruction by
  an OpenTofu lifecycle guard.
- An idempotent repository script bootstraps the guest filesystem, persistent
  mount, directory ownership, NFS package, and export configuration.
- Kubernetes GitOps owns the Immich PV and PVC. The new PV points only to
  `192.168.1.231:/srv/nfs/immich` and does not use a `subPath`.
- The Immich README and storage runbook document the new dependency and
  recovery commands.

## Reset and Cutover

1. Provision `nfs-01` and verify its data disk is backed by `WD-red`.
2. Bootstrap the ext4 filesystem and NFS export, then prove read/write access
   from a Talos worker using a disposable test pod.
3. Quiesce all Immich deployments through a temporary GitOps revision.
4. Delete and recreate the Immich PostgreSQL PVC so accounts, assets, albums,
   jobs, and metadata start empty. The database credential may be reused
   because it contains no user data.
5. Replace the Immich library PV/PVC with distinctly named resources backed by
   the new export, remove the old `subPath`, and restore the deployments.
6. Verify the internal Immich endpoint reports `isInitialized: false`, all
   workloads are healthy, and a write test lands on the WD Red filesystem.
7. Remove the old `/srv/nfs/media/wedding-minio` directory from
   `media-nfs-01`. Before deletion, resolve and check the exact absolute path;
   do not operate on `/srv/nfs/media` itself or any sibling media directory.

No copy or rollback copy of the current Immich data is required. The original
photo source outside the homelab remains the user's recovery source.

## Failure Handling

- Do not reset Immich until the new NFS export passes a worker-side write test.
- If provisioning or NFS validation fails, leave the current Immich deployment
  and `wedding-minio` directory intact.
- If cutover fails after the database reset, keep Immich quiesced, repair the
  new export, and complete the clean deployment. Do not redirect it back to the
  old media export with a newly initialized database.
- Never initialize a filesystem unless the guest disk serial/slot and Proxmox
  storage mapping both identify the new 2 TiB `WD-red` volume.

## Acceptance Checks

- `tofu validate` and `tofu plan` show only the intended NFS VM/storage work.
- `nfs-01` survives a reboot with `/srv/nfs/immich` mounted and exported.
- A Kubernetes test pod can create and remove a file on the new export.
- ArgoCD reports Immich `Synced` and `Healthy`.
- All Immich pods are Ready with no restart loop.
- The new library PV resolves to `192.168.1.231:/srv/nfs/immich`.
- The Immich server can write to the new library and reports
  `isInitialized: false`.
- The live storage chain resolves to the WD Red disk on `desktop`.
- The old `wedding-minio` directory is absent while the media-stack directories
  and workloads remain healthy.

## Out of Scope

- Backing up or migrating the current Immich uploads or database.
- Adding a public Immich route.
- Moving the existing control-plane or worker volumes off `WD-red`.
- Redesigning or migrating the media stack.
- Adding backup automation for the new NFS filesystem in this change.
