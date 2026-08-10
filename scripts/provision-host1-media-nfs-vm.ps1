param(
    [string]$Host1SshHost = "192.168.1.111",
    [int]$VmId = 8010,
    [string]$VmName = "media-nfs-01",
    [string]$VmIp = "192.168.1.230",
    [string]$Gateway = "192.168.1.1",
    [string]$BootDatastore = "local-lvm",
    [string]$ImageStoragePath = "/var/lib/vz/template/iso/debian-12-generic-amd64.qcow2",
    [string]$ImageUrl = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2",
    [string]$ExistingDataVolume = "lagring:100/vm-100-disk-0.qcow2",
    [string]$ExportPath = "/srv/nfs/media",
    [string[]]$AllowedClients = @(
        "192.168.1.211(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.212(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.213(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.214(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.217(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.218(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.219(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)"
    )
)

$ErrorActionPreference = "Stop"

function Get-LocalPublicKeys {
    $keyFiles = @(
        (Join-Path $HOME ".ssh\id_ed25519.pub"),
        (Join-Path $HOME ".ssh\id_rsa.pub")
    )

    $keys = foreach ($path in $keyFiles) {
        if (Test-Path -LiteralPath $path) {
            (Get-Content -LiteralPath $path -Raw).Trim()
        }
    }

    $keys = $keys | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    if (-not $keys) {
        throw "No local SSH public keys found under $HOME\.ssh."
    }

    return $keys
}

function Invoke-RemoteScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Script
    )

    $tempScript = [System.IO.Path]::GetTempFileName()
    $remoteScript = "/tmp/media-nfs-$([System.Guid]::NewGuid().ToString("n")).sh"
    try {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "")
        [System.IO.File]::WriteAllText($tempScript, $normalizedScript, $utf8NoBom)
        scp -q -o StrictHostKeyChecking=accept-new $tempScript "root@${Host1SshHost}:$remoteScript"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to copy remote script to $Host1SshHost."
        }

        ssh -o StrictHostKeyChecking=accept-new "root@$Host1SshHost" "bash '$remoteScript'; rc=`$?; rm -f '$remoteScript'; exit `$rc"
        if ($LASTEXITCODE -ne 0) {
            throw "Remote script failed on $Host1SshHost."
        }
    }
    finally {
        Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
    }
}

function Wait-ForSsh {
    param(
        [string]$Target,
        [int]$TimeoutSeconds = 600
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $open = Test-NetConnection -ComputerName $Target -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet
        if ($open) {
            ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "debian@$Target" "true" 2>$null
            if ($LASTEXITCODE -eq 0) {
                return
            }
        }
        Start-Sleep -Seconds 5
    }

    throw "Timed out waiting for SSH on $Target."
}

if (Test-Path env:KUBECONFIG) {
    $poolStop = & kubectl get ciliumloadbalancerippool first-pool -o jsonpath='{.spec.blocks[0].stop}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $poolStop -ge $VmIp) {
        throw "Cilium LoadBalancer pool still includes $VmIp (stop=$poolStop)."
    }
}

$authorizedKeys = (Get-LocalPublicKeys) -join "\n"
$allowedClientsJoined = ($AllowedClients -join " ").Trim()

$remote = @'
set -euo pipefail

vmid="__VM_ID__"
vm_name="__VM_NAME__"
vm_ip="__VM_IP__"
gateway="__GATEWAY__"
boot_datastore="__BOOT_DATASTORE__"
image_path="__IMAGE_PATH__"
image_url="__IMAGE_URL__"
existing_data_volume="__EXISTING_DATA_VOLUME__"
export_path="__EXPORT_PATH__"
allowed_clients="__ALLOWED_CLIENTS__"
authorized_keys_file="/tmp/media-nfs-authorized-keys"

cat >"${authorized_keys_file}" <<'EOF_KEYS'
__AUTHORIZED_KEYS__
EOF_KEYS

if qm status 100 | grep -q "status: running"; then
  echo "VM 100 is running. Stop it before attaching ${existing_data_volume} to ${vm_name}." >&2
  exit 1
fi

if qm config 100 | grep -E '^(scsi|sata|virtio|ide)[0-9]+:' | grep -Fq "${existing_data_volume}"; then
  echo "VM 100 still has ${existing_data_volume} attached as an active disk. Detach it before provisioning ${vm_name}." >&2
  exit 1
fi

if ip -4 address show | grep -q "${vm_ip}/"; then
  echo "${vm_ip} is still assigned on the Proxmox host. Stop host-level media-nfs services before provisioning the VM." >&2
  exit 1
fi

if pvesm path "${existing_data_volume}" >/dev/null 2>&1; then
  data_path="$(pvesm path "${existing_data_volume}")"
else
  echo "Existing data volume ${existing_data_volume} does not resolve through pvesm." >&2
  exit 1
fi

qemu-img info "${data_path}" | grep -q "corrupt: false"

if [[ ! -f "${image_path}" ]]; then
  mkdir -p "$(dirname "${image_path}")"
  wget -O "${image_path}.tmp" "${image_url}"
  mv "${image_path}.tmp" "${image_path}"
fi

if qm config "${vmid}" >/dev/null 2>&1; then
  existing_config="$(qm config "${vmid}")"
  if ! printf '%s\n' "${existing_config}" | grep -Fxq "name: ${vm_name}"; then
    echo "VMID ${vmid} already exists but is not named ${vm_name}; refusing to replace it automatically." >&2
    exit 1
  fi
  if ! printf '%s\n' "${existing_config}" | grep -Fq "scsi1: ${existing_data_volume}"; then
    echo "VMID ${vmid} exists but does not have expected data disk ${existing_data_volume} on scsi1; refusing to replace it automatically." >&2
    qm config "${vmid}" >&2
    exit 1
  fi

  qm set "${vmid}" --onboot 1 >/dev/null
  if ! qm status "${vmid}" | grep -q "status: running"; then
    qm start "${vmid}"
  fi
  echo "Reusing existing ${vm_name} (${vmid}) with ${existing_data_volume} attached as scsi1."
else

qm create "${vmid}" \
  --name "${vm_name}" \
  --machine q35 \
  --scsihw virtio-scsi-single \
  --ostype l26 \
  --agent enabled=1 \
  --cores 2 \
  --cpu host \
  --memory 4096 \
  --net0 virtio,bridge=vmbr0,firewall=0 \
  --serial0 socket \
  --vga serial0 \
  --onboot 1

qm importdisk "${vmid}" "${image_path}" "${boot_datastore}" --format raw
boot_volume="$(qm config "${vmid}" | awk -F'[:,]' '/^unused[0-9]+:/ && /vm-'"${vmid}"'-disk/ {gsub(/^ /, "", $2); print $2":"$3; exit}')"
if [[ -z "${boot_volume}" ]]; then
  echo "Unable to find imported boot volume for VM ${vmid}." >&2
  qm config "${vmid}" >&2
  exit 1
fi

qm set "${vmid}" \
  --scsi0 "${boot_volume},discard=on,iothread=1" \
  --scsi1 "${existing_data_volume},backup=0,iothread=1" \
  --ide2 "${boot_datastore}:cloudinit" \
  --boot order=scsi0 \
  --ciuser debian \
  --sshkeys "${authorized_keys_file}" \
  --ipconfig0 "ip=${vm_ip}/24,gw=${gateway}" \
  --nameserver "${gateway}" \
  --searchdomain "rosenvall.local"

qm resize "${vmid}" scsi0 32G
qm start "${vmid}"

echo "Provisioned ${vm_name} (${vmid}) with ${existing_data_volume} attached as scsi1."
fi
'@

$remote = $remote.Replace("__VM_ID__", [string]$VmId)
$remote = $remote.Replace("__VM_NAME__", $VmName)
$remote = $remote.Replace("__VM_IP__", $VmIp)
$remote = $remote.Replace("__GATEWAY__", $Gateway)
$remote = $remote.Replace("__BOOT_DATASTORE__", $BootDatastore)
$remote = $remote.Replace("__IMAGE_PATH__", $ImageStoragePath)
$remote = $remote.Replace("__IMAGE_URL__", $ImageUrl)
$remote = $remote.Replace("__EXISTING_DATA_VOLUME__", $ExistingDataVolume)
$remote = $remote.Replace("__EXPORT_PATH__", $ExportPath)
$remote = $remote.Replace("__ALLOWED_CLIENTS__", $allowedClientsJoined)
$remote = $remote.Replace("__AUTHORIZED_KEYS__", $authorizedKeys)

Invoke-RemoteScript -Script $remote
Wait-ForSsh -Target $VmIp

$guest = @'
set -euo pipefail

export_path="__EXPORT_PATH__"
allowed_clients="__ALLOWED_CLIENTS__"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-guest-agent nfs-kernel-server nfs-common

root_source="$(findmnt -no SOURCE /)"
root_pkname="$(lsblk -no PKNAME "${root_source}" 2>/dev/null | head -n1 || true)"
root_disk="${root_pkname:+/dev/${root_pkname}}"
data_disk="$(lsblk -dnbo NAME,SIZE,TYPE | awk '$3 == "disk" { print "/dev/"$1" "$2 }' | sort -k2 -nr | awk -v root="${root_disk}" '$1 != root { print $1; exit }')"

if [[ -z "${data_disk}" ]]; then
  echo "No non-root data disk found." >&2
  exit 1
fi

data_partition="$(lsblk -rno NAME,TYPE,FSTYPE "${data_disk}" | awk '$2 == "part" && $3 == "ext4" { print "/dev/"$1; exit }')"
if [[ -z "${data_partition}" ]]; then
  echo "No existing ext4 partition found on ${data_disk}; refusing to format media disk." >&2
  lsblk -f "${data_disk}" >&2
  exit 1
fi

sudo mkdir -p "${export_path}"
uuid="$(sudo blkid -s UUID -o value "${data_partition}")"
if ! grep -q "${uuid}" /etc/fstab; then
  echo "UUID=${uuid} ${export_path} ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab >/dev/null
fi

if ! mountpoint -q "${export_path}"; then
  sudo mount "${export_path}"
fi

for dir in downloads tv movies familjefilmer; do
  if [[ ! -d "${export_path}/${dir}" ]]; then
    echo "Expected ${export_path}/${dir} to exist on existing media disk." >&2
    exit 1
  fi
  sudo chown 1000:1000 "${export_path}/${dir}"
  sudo chmod 0775 "${export_path}/${dir}"
done

sudo mkdir -p /etc/exports.d /etc/systemd/system/nfs-kernel-server.service.d
cat <<EOF | sudo tee /etc/exports.d/media.exports >/dev/null
${export_path} ${allowed_clients}
EOF
sudo sed -i 's/\r$//' /etc/exports.d/media.exports

cat <<EOF | sudo tee /etc/systemd/system/nfs-kernel-server.service.d/media-nfs-ordering.conf >/dev/null
[Unit]
RequiresMountsFor=${export_path}
After=local-fs.target
EOF
sudo sed -i 's/\r$//' /etc/systemd/system/nfs-kernel-server.service.d/media-nfs-ordering.conf

sudo systemctl daemon-reload
sudo systemctl enable --now qemu-guest-agent
sudo systemctl enable --now nfs-kernel-server
sudo exportfs -ra
sudo systemctl restart nfs-kernel-server

findmnt "${export_path}"
df -h "${export_path}"
sudo exportfs -v
'@

$guest = $guest.Replace("__EXPORT_PATH__", $ExportPath)
$guest = $guest.Replace("__ALLOWED_CLIENTS__", $allowedClientsJoined)
$guest = $guest.Replace("`r`n", "`n").Replace("`r", "")

$tempGuestScript = [System.IO.Path]::GetTempFileName()
$remoteGuestScript = "/tmp/media-nfs-guest-$([System.Guid]::NewGuid().ToString("n")).sh"
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempGuestScript, $guest, $utf8NoBom)
    scp -q -o StrictHostKeyChecking=accept-new $tempGuestScript "debian@${VmIp}:$remoteGuestScript"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy guest NFS bootstrap script to $VmIp."
    }

    ssh -o StrictHostKeyChecking=accept-new "debian@$VmIp" "bash '$remoteGuestScript'; rc=`$?; rm -f '$remoteGuestScript'; exit `$rc"
    if ($LASTEXITCODE -ne 0) {
        throw "Guest NFS bootstrap failed on $VmIp."
    }
}
finally {
    Remove-Item -LiteralPath $tempGuestScript -Force -ErrorAction SilentlyContinue
}
