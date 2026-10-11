<#
.SYNOPSIS
    Exports a backup area on host1's 8 TB "lagring" disk over NFS for the cluster.

.DESCRIPTION
    host1 already runs nfs-kernel-server for the media library on the alias IP
    192.168.1.230 (scripts/configure-host1-media-nfs.ps1). This adds a second
    export on the same server and disk, outside every Longhorn data disk:

      /srv/nfs/backup            bind mount of /media/lagring/k8s-backup
        longhorn/                Longhorn BackupTarget (nfs://192.168.1.230:/srv/nfs/backup/longhorn)
        db-dumps/<namespace>/    nightly pg_dump CronJobs (uid/gid 1000)
        archive/                 final copies of decommissioned apps

    Longhorn writes its backupstore as root, so the export is no_root_squash and
    limited to the worker node IPs. It carries an explicit fsid because it lives
    on the same filesystem as /srv/nfs/media; without one both exports share the
    disk UUID in their file handles and nfsd can apply the wrong export options.
    Idempotent: re-run after adding a worker to extend AllowedClients.
#>
param(
    [string]$Host1SshHost = "192.168.1.111",
    [string]$StoragePath = "/media/lagring",
    [string]$SourceDir = "k8s-backup",
    [string]$ExportPath = "/srv/nfs/backup",
    [int]$Fsid = 1102,
    [string[]]$AllowedClients = @(
        "192.168.1.211", "192.168.1.212", "192.168.1.213", "192.168.1.214",
        "192.168.1.217", "192.168.1.218", "192.168.1.219",
        "192.168.1.232", "192.168.1.233"
    )
)

$ErrorActionPreference = "Stop"

$options = "rw,sync,no_subtree_check,no_root_squash,fsid=$Fsid"
$clients = ($AllowedClients | ForEach-Object { "$_($options)" }) -join " "

$remote = @'
set -euo pipefail
storage_path="__STORAGE_PATH__"
source_path="${storage_path}/__SOURCE_DIR__"
export_path="__EXPORT_PATH__"
clients="__CLIENTS__"

if ! mountpoint -q "${storage_path}"; then
  echo "${storage_path} is not a mountpoint. Refusing to export a root-filesystem fallback." >&2
  exit 1
fi
systemctl is-active --quiet nfs-kernel-server || { echo "nfs-kernel-server is not running; run configure-host1-media-nfs.ps1 first." >&2; exit 1; }

install -d -m 0755 "${source_path}"
install -d -m 0700 -o root -g root "${source_path}/longhorn"
install -d -m 0775 -o 1000 -g 1000 "${source_path}/db-dumps" "${source_path}/archive"
mkdir -p "${export_path}"

mount_unit="$(systemd-escape -p --suffix=mount "${export_path}")"
cat >"/etc/systemd/system/${mount_unit}" <<EOF
[Unit]
Description=Bind mount Kubernetes backup area for NFS
RequiresMountsFor=${storage_path}

[Mount]
What=${source_path}
Where=${export_path}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/systemd/system/nfs-kernel-server.service.d
cat >/etc/systemd/system/nfs-kernel-server.service.d/backup-nfs-ordering.conf <<EOF
[Unit]
Requires=${mount_unit}
After=${mount_unit}
EOF

systemctl daemon-reload
systemctl enable --now "${mount_unit}" 2>&1

cat >/etc/exports.d/backup.exports <<EOF
${export_path} ${clients}
EOF
exportfs -ra

echo "NFS exports:"; exportfs -v | grep -A1 "${export_path}" | head -4
findmnt "${export_path}"
df -h "${export_path}"
'@

$remote = $remote.Replace("__STORAGE_PATH__", $StoragePath).Replace("__SOURCE_DIR__", $SourceDir)
$remote = $remote.Replace("__EXPORT_PATH__", $ExportPath).Replace("__CLIENTS__", $clients)
$remote = $remote.Replace("`r`n", "`n").Replace("`r", "")

$tempScript = [System.IO.Path]::GetTempFileName()
$remoteScript = "/tmp/host1-backup-nfs-$([System.Guid]::NewGuid().ToString("n")).sh"
try {
    [System.IO.File]::WriteAllText($tempScript, $remote, [System.Text.UTF8Encoding]::new($false))
    scp -q -o StrictHostKeyChecking=accept-new $tempScript "root@${Host1SshHost}:$remoteScript"
    if ($LASTEXITCODE -ne 0) { throw "Failed to copy the backup NFS script to $Host1SshHost." }
    ssh -o StrictHostKeyChecking=accept-new "root@$Host1SshHost" "bash '$remoteScript'; rc=`$?; rm -f '$remoteScript'; exit `$rc"
    if ($LASTEXITCODE -ne 0) { throw "Failed to configure the host1 backup NFS export." }
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
