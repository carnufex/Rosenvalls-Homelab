param(
    [string]$Host1SshHost = "192.168.1.111",
    [string]$AliasIp = "192.168.1.230",
    [string]$Interface = "vmbr0",
    [int]$SourceVmId = 100,
    [string]$Qcow2Path = "/media/lagring/images/100/vm-100-disk-0.qcow2",
    [string]$NbdDevice = "/dev/nbd15",
    [string]$PartitionPath = "",
    [string]$ExportPath = "/srv/nfs/media",
    [string[]]$AllowedClients = @(
        "192.168.1.211(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.212(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.213(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.214(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)"
    ),
    [switch]$AllowDeprecatedHostLevelNfs
)

$ErrorActionPreference = "Stop"

if (-not $AllowDeprecatedHostLevelNfs) {
    throw "Deprecated host-level NFS path. Use .\scripts\provision-host1-media-nfs-vm.ps1 for the current media-nfs-01 VM design, or pass -AllowDeprecatedHostLevelNfs for an intentional rollback."
}

if (Test-Path env:KUBECONFIG) {
    $poolStop = & kubectl get ciliumloadbalancerippool first-pool -o jsonpath='{.spec.blocks[0].stop}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $poolStop -ge $AliasIp) {
        throw "Cilium LoadBalancer pool still includes $AliasIp (stop=$poolStop). Push/sync the pool change before moving NFS to host1."
    }
}

if ([string]::IsNullOrWhiteSpace($PartitionPath)) {
    $PartitionPath = "${NbdDevice}p1"
}

$allowedClientsJoined = ($AllowedClients -join " ").Trim()
$remote = @'
set -euo pipefail

alias_ip="__ALIAS_IP__"
interface="__INTERFACE__"
source_vm_id="__SOURCE_VM_ID__"
qcow2_path="__QCOW2_PATH__"
nbd_device="__NBD_DEVICE__"
partition_path="__PARTITION_PATH__"
export_path="__EXPORT_PATH__"
allowed_clients="__ALLOWED_CLIENTS__"

if ! ip link show "${interface}" >/dev/null 2>&1; then
  echo "Interface ${interface} does not exist on host1." >&2
  exit 1
fi

if [[ ! -f "${qcow2_path}" ]]; then
  echo "Media qcow2 ${qcow2_path} does not exist." >&2
  exit 1
fi

if qm status "${source_vm_id}" | grep -q "status: running"; then
  echo "VM ${source_vm_id} is still running. Shut it down before mounting ${qcow2_path} on host1." >&2
  exit 1
fi

if ip -4 address show dev "${interface}" | grep -q "${alias_ip}/"; then
  echo "${alias_ip} is already assigned to ${interface}; continuing idempotently."
else
  if ping -c 1 -W 1 "${alias_ip}" >/dev/null 2>&1; then
    echo "${alias_ip} is reachable before assignment. Stop old media-nfs-01 or resolve the IP conflict first." >&2
    exit 1
  fi
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nfs-kernel-server nfs-common

if [[ ! -x /usr/bin/qemu-nbd ]]; then
  echo "/usr/bin/qemu-nbd is missing. On Proxmox it should be provided by pve-qemu-kvm; refusing to install Debian qemu-utils automatically." >&2
  exit 1
fi

cat >/etc/systemd/system/media-nfs-ip.service <<EOF
[Unit]
Description=Media NFS stable LAN IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ip address replace ${alias_ip}/24 dev ${interface}
ExecStop=/usr/sbin/ip address del ${alias_ip}/24 dev ${interface}

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/media-nfs-qcow2.service <<EOF
[Unit]
Description=Attach old server media qcow2 for NFS
After=local-fs.target
ConditionPathExists=${qcow2_path}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sh -c '! qm status ${source_vm_id} | grep -q "status: running"'
ExecStart=/sbin/modprobe nbd max_part=16
ExecStart=/usr/bin/qemu-nbd --connect=${nbd_device} ${qcow2_path}
ExecStart=/usr/bin/udevadm settle
ExecStart=/bin/sh -c 'test -b ${partition_path}'
ExecStop=/bin/sh -c 'umount ${export_path} >/dev/null 2>&1 || true'
ExecStop=/usr/bin/qemu-nbd --disconnect ${nbd_device}

[Install]
WantedBy=multi-user.target
EOF

mount_unit="$(systemd-escape -p --suffix=mount "${export_path}")"
mkdir -p "${export_path}"
cat >"/etc/systemd/system/${mount_unit}" <<EOF
[Unit]
Description=Mount old server media library for Kubernetes NFS
Requires=media-nfs-qcow2.service
After=media-nfs-qcow2.service

[Mount]
What=${partition_path}
Where=${export_path}
Type=ext4
Options=rw,noatime

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /etc/exports.d
cat >/etc/exports.d/media.exports <<EOF
${export_path} ${allowed_clients}
EOF

mkdir -p /etc/systemd/system/nfs-kernel-server.service.d
cat >/etc/systemd/system/nfs-kernel-server.service.d/media-nfs-ordering.conf <<EOF
[Unit]
Requires=media-nfs-ip.service ${mount_unit}
After=media-nfs-ip.service ${mount_unit}
EOF

systemctl daemon-reload
systemctl enable --now media-nfs-ip.service
systemctl enable --now media-nfs-qcow2.service
systemctl enable --now "${mount_unit}"

for dir in downloads tv movies familjefilmer; do
  if [[ ! -d "${export_path}/${dir}" ]]; then
    echo "Expected ${export_path}/${dir} to exist after mounting ${partition_path}." >&2
    exit 1
  fi
  chown 1000:1000 "${export_path}/${dir}"
  chmod 0775 "${export_path}/${dir}"
done

qm set "${source_vm_id}" --onboot 0 >/dev/null
systemctl enable --now nfs-kernel-server
exportfs -ra
systemctl restart nfs-kernel-server

echo
echo "Source VM state:"
qm status "${source_vm_id}"
qm config "${source_vm_id}" | grep -E "^(name|onboot|scsi1):" || true
echo
echo "IP state:"
ip -4 address show dev "${interface}"
echo
echo "Media mount:"
findmnt "${export_path}"
df -h "${export_path}"
echo
echo "NFS exports:"
exportfs -v
'@

$remote = $remote.Replace("__ALIAS_IP__", $AliasIp)
$remote = $remote.Replace("__INTERFACE__", $Interface)
$remote = $remote.Replace("__SOURCE_VM_ID__", [string]$SourceVmId)
$remote = $remote.Replace("__QCOW2_PATH__", $Qcow2Path)
$remote = $remote.Replace("__NBD_DEVICE__", $NbdDevice)
$remote = $remote.Replace("__PARTITION_PATH__", $PartitionPath)
$remote = $remote.Replace("__EXPORT_PATH__", $ExportPath)
$remote = $remote.Replace("__ALLOWED_CLIENTS__", $allowedClientsJoined)
$remote = $remote.Replace("`r`n", "`n")

$tempScript = [System.IO.Path]::GetTempFileName()
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempScript, $remote, $utf8NoBom)
    Get-Content -LiteralPath $tempScript -Raw | ssh -o StrictHostKeyChecking=accept-new "root@$Host1SshHost" "bash -se"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure host1 qcow2 media NFS."
    }
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
