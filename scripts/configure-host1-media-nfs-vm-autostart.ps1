param(
    [string]$Host1SshHost = "192.168.1.111",
    [int]$VmId = 8010,
    [string]$VmName = "media-nfs-01",
    [string]$StorageMountPath = "/media/lagring",
    [string]$DataVolumePath = "/media/lagring/images/100/vm-100-disk-0.qcow2",
    [string]$UnitName = "media-nfs-01-vm.service"
)

$ErrorActionPreference = "Stop"

$remote = @'
set -euo pipefail

vmid="__VM_ID__"
vm_name="__VM_NAME__"
storage_mount_path="__STORAGE_MOUNT_PATH__"
data_volume_path="__DATA_VOLUME_PATH__"
unit_name="__UNIT_NAME__"

vmid="$(printf '%s' "${vmid}" | tr -d '\r')"
vm_name="$(printf '%s' "${vm_name}" | tr -d '\r')"
storage_mount_path="$(printf '%s' "${storage_mount_path}" | tr -d '\r')"
data_volume_path="$(printf '%s' "${data_volume_path}" | tr -d '\r')"
unit_name="$(printf '%s' "${unit_name}" | tr -d '\r')"

unit_path="/etc/systemd/system/${unit_name}"

if ! qm config "${vmid}" >/dev/null 2>&1; then
  echo "VM ${vmid} does not exist on this host." >&2
  exit 1
fi

actual_name="$(qm config "${vmid}" | awk -F': ' '/^name:/ {print $2; exit}')"
if [[ "${actual_name}" != "${vm_name}" ]]; then
  echo "VM ${vmid} is named ${actual_name}, not ${vm_name}; refusing to manage autostart." >&2
  exit 1
fi

if command -v ha-manager >/dev/null 2>&1 && ha-manager config 2>/dev/null | grep -Eq "vm:${vmid}([[:space:]]|$)"; then
  echo "VM ${vmid} is managed by Proxmox HA; refusing to install a parallel systemd autostart unit." >&2
  exit 1
fi

qm set "${vmid}" --onboot 0 >/dev/null

cat >"${unit_path}" <<EOF
[Unit]
Description=Start ${vm_name} after lagring media disk is available
After=local-fs.target pvedaemon.service
Wants=pvedaemon.service
RequiresMountsFor=${storage_mount_path}
ConditionPathExists=${data_volume_path}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/bin/test -f ${data_volume_path}
ExecStart=/bin/sh -c 'if ! /usr/sbin/qm status ${vmid} | /usr/bin/grep -q "status: running"; then /usr/sbin/qm start ${vmid}; fi'
ExecStop=/bin/sh -c 'if /usr/sbin/qm status ${vmid} | /usr/bin/grep -q "status: running"; then /usr/sbin/qm shutdown ${vmid} --timeout 120 || /usr/sbin/qm stop ${vmid}; fi'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${unit_name}" >/dev/null

echo "Configured guarded autostart for ${vm_name} (${vmid})."
echo "Proxmox onboot is disabled; ${unit_name} starts it only after ${storage_mount_path} is mounted and ${data_volume_path} exists."
echo
qm config "${vmid}" | grep -E '^(name|onboot|scsi1):' || true
echo
systemctl is-enabled "${unit_name}"
systemctl cat "${unit_name}"
'@

$remote = $remote.Replace("__VM_ID__", [string]$VmId)
$remote = $remote.Replace("__VM_NAME__", $VmName)
$remote = $remote.Replace("__STORAGE_MOUNT_PATH__", $StorageMountPath)
$remote = $remote.Replace("__DATA_VOLUME_PATH__", $DataVolumePath)
$remote = $remote.Replace("__UNIT_NAME__", $UnitName)
$remote = $remote.Replace("`r`n", "`n").Replace("`r", "")

$tempScript = [System.IO.Path]::GetTempFileName()
$remoteScript = "/tmp/media-nfs-vm-autostart-$([System.Guid]::NewGuid().ToString("n")).sh"
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempScript, $remote, $utf8NoBom)
    scp -q -o StrictHostKeyChecking=accept-new $tempScript "root@${Host1SshHost}:$remoteScript"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy guarded media-nfs VM autostart script to $Host1SshHost."
    }

    ssh -o StrictHostKeyChecking=accept-new "root@$Host1SshHost" "bash '$remoteScript'; rc=`$?; rm -f '$remoteScript'; exit `$rc"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure guarded media-nfs VM autostart on $Host1SshHost."
    }
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
