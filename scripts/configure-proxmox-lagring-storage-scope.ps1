param(
    [string]$ProxmoxSshHost = "192.168.1.111",
    [string]$Host1Node = "host1",
    [string]$DesktopNode = "desktop",
    [string]$Host1Storage = "lagring",
    [string]$DesktopStorage = "desktop-lagring",
    [string]$StoragePath = "/media/lagring",
    [int[]]$DesktopVmIds = @(8002, 8003)
)

$ErrorActionPreference = "Stop"

$desktopVmIdsJoined = ($DesktopVmIds | ForEach-Object { [string]$_ }) -join " "

$remote = @'
set -euo pipefail

host1_node="__HOST1_NODE__"
desktop_node="__DESKTOP_NODE__"
host1_storage="__HOST1_STORAGE__"
desktop_storage="__DESKTOP_STORAGE__"
storage_path="__STORAGE_PATH__"
desktop_vm_ids="__DESKTOP_VM_IDS__"
stamp="$(date +%Y%m%d-%H%M%S)-lagring-scope"

cp /etc/pve/storage.cfg "/root/storage.cfg.before-${stamp}"

if ! grep -q "^dir: ${desktop_storage}$" /etc/pve/storage.cfg; then
  pvesm add dir "${desktop_storage}" \
    --path "${storage_path}" \
    --content images \
    --nodes "${desktop_node}" \
    --create-base-path 0 \
    --create-subdirs 0
fi

pvesm set "${host1_storage}" \
  --nodes "${host1_node}" \
  --is_mountpoint yes \
  --content backup,images

for vmid in ${desktop_vm_ids}; do
  config="/etc/pve/nodes/${desktop_node}/qemu-server/${vmid}.conf"
  if [[ -f "${config}" ]]; then
    cp "${config}" "/root/${desktop_node}-${vmid}.conf.before-${stamp}"
    sed -i "s#^scsi0: ${host1_storage}:#scsi0: ${desktop_storage}:#" "${config}"
  fi
done

echo "Storage scope configured."
echo
cat /etc/pve/storage.cfg
echo
grep -RInE "${host1_storage}|${desktop_storage}" \
  "/etc/pve/nodes/${desktop_node}/qemu-server" \
  "/etc/pve/nodes/${host1_node}/qemu-server" || true
'@

$remote = $remote.Replace("__HOST1_NODE__", $Host1Node)
$remote = $remote.Replace("__DESKTOP_NODE__", $DesktopNode)
$remote = $remote.Replace("__HOST1_STORAGE__", $Host1Storage)
$remote = $remote.Replace("__DESKTOP_STORAGE__", $DesktopStorage)
$remote = $remote.Replace("__STORAGE_PATH__", $StoragePath)
$remote = $remote.Replace("__DESKTOP_VM_IDS__", $desktopVmIdsJoined)
$remote = $remote.Replace("`r`n", "`n").Replace("`r", "")

$tempScript = [System.IO.Path]::GetTempFileName()
$remoteScript = "/tmp/proxmox-lagring-scope-$([System.Guid]::NewGuid().ToString("n")).sh"
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempScript, $remote, $utf8NoBom)
    scp -q -o StrictHostKeyChecking=accept-new $tempScript "root@${ProxmoxSshHost}:$remoteScript"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy storage scope script to $ProxmoxSshHost."
    }

    ssh -o StrictHostKeyChecking=accept-new "root@$ProxmoxSshHost" "bash '$remoteScript'; rc=`$?; rm -f '$remoteScript'; exit `$rc"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure Proxmox lagring storage scope on $ProxmoxSshHost."
    }
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
