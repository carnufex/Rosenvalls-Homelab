param(
  [Parameter(Mandatory = $true)]
  [string]$ClusterSshHost,

  [Parameter(Mandatory = $true)]
  [string]$NodeName,

  [string]$NodeSshHost = "",

  [Parameter(Mandatory = $true)]
  [int]$VmId,

  [Parameter(Mandatory = $true)]
  [string]$VmIp,

  [string]$HostName = "media-nfs-01",
  [string]$Gateway = "192.168.1.1",
  [string]$DnsServer = "192.168.1.1",
  [string]$SearchDomain = "rosenvall.local",
  [string]$ExportPath = "/srv/nfs/media",
  [string[]]$AllowedClients = @(
    "192.168.1.211(rw,sync,no_subtree_check)",
    "192.168.1.212(rw,sync,no_subtree_check)",
    "192.168.1.213(rw,sync,no_subtree_check)"
  ),
  [int]$SshTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false

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

function Invoke-Ssh {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetHost,
    [Parameter(Mandatory = $true)]
    [string]$Command
  )

  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $process = Start-Process -FilePath "ssh" `
      -ArgumentList @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "root@$TargetHost", $Command) `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru `
      -Wait
    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { "" }
    if ($process.ExitCode -ne 0) {
      throw "SSH command failed on $TargetHost`nCommand: $Command`n$stdout`n$stderr"
    }
    return ($stdout + $stderr).Trim()
  }
  finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
  }
}

function Invoke-SshScript {
  param(
    [Parameter(Mandatory = $true)]
    [string]$TargetHost,
    [Parameter(Mandatory = $true)]
    [string]$Script
  )

  $tmp = [System.IO.Path]::GetTempFileName()
  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $Script, $utf8NoBom)
    $process = Start-Process -FilePath "ssh" `
      -ArgumentList @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "root@$TargetHost", "bash -se") `
      -RedirectStandardInput $tmp `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru `
      -Wait
    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { "" }
    if ($process.ExitCode -ne 0) {
      throw "SSH script failed on $TargetHost`n$stdout`n$stderr"
    }
    return ($stdout + $stderr).Trim()
  }
  finally {
    Remove-Item -LiteralPath $tmp, $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
  }
}

function Wait-ForGuestSsh {
  param(
    [Parameter(Mandatory = $true)]
    [string]$GuestHost,
    [Parameter(Mandatory = $true)]
    [int]$TimeoutSeconds
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $portOpen = Test-NetConnection -ComputerName $GuestHost -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet
    if ($portOpen) {
      $stdoutFile = [System.IO.Path]::GetTempFileName()
      $stderrFile = [System.IO.Path]::GetTempFileName()
      try {
        $process = Start-Process -FilePath "ssh" `
          -ArgumentList @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "debian@$GuestHost", "true") `
          -RedirectStandardOutput $stdoutFile `
          -RedirectStandardError $stderrFile `
          -NoNewWindow `
          -PassThru `
          -Wait
        if ($process.ExitCode -eq 0) {
          return
        }
      }
      finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
      }

      $stdoutFile = [System.IO.Path]::GetTempFileName()
      $stderrFile = [System.IO.Path]::GetTempFileName()
      try {
        $process = Start-Process -FilePath "ssh" `
          -ArgumentList @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "root@$GuestHost", "true") `
          -RedirectStandardOutput $stdoutFile `
          -RedirectStandardError $stderrFile `
          -NoNewWindow `
          -PassThru `
          -Wait
        if ($process.ExitCode -eq 0) {
          return
        }
      }
      finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
      }
    }

    Start-Sleep -Seconds 5
  }

  throw "Timed out waiting for SSH on $GuestHost."
}

function Invoke-Guest {
  param(
    [Parameter(Mandatory = $true)]
    [string]$GuestHost,
    [Parameter(Mandatory = $true)]
    [string]$User,
    [Parameter(Mandatory = $true)]
    [string]$Command
  )

  $stdoutFile = [System.IO.Path]::GetTempFileName()
  $stderrFile = [System.IO.Path]::GetTempFileName()
  try {
    $process = Start-Process -FilePath "ssh" `
      -ArgumentList @("-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new", "-o", "LogLevel=ERROR", "$User@$GuestHost", $Command) `
      -RedirectStandardOutput $stdoutFile `
      -RedirectStandardError $stderrFile `
      -NoNewWindow `
      -PassThru `
      -Wait
    $stdout = if (Test-Path -LiteralPath $stdoutFile) { Get-Content -LiteralPath $stdoutFile -Raw } else { "" }
    $stderr = if (Test-Path -LiteralPath $stderrFile) { Get-Content -LiteralPath $stderrFile -Raw } else { "" }
    if ($process.ExitCode -ne 0) {
      throw "SSH guest command failed on $GuestHost as $User`n$stdout`n$stderr"
    }
    return ($stdout + $stderr).Trim()
  }
  finally {
    Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
  }
}

$publicKeys = Get-LocalPublicKeys
$authorizedKeys = ($publicKeys -join "`n").Trim()
$authorizedKeysB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($authorizedKeys))
$allowedClientsJoined = ($AllowedClients -join " ").Trim()
$nodeIp = $NodeSshHost
if ([string]::IsNullOrWhiteSpace($nodeIp)) {
  $nodeIp = Invoke-Ssh -TargetHost $ClusterSshHost -Command "getent hosts $NodeName | sed -n 's/[[:space:]].*//p;q'"
  if ([string]::IsNullOrWhiteSpace($nodeIp)) {
    $nodeIp = Invoke-Ssh -TargetHost $ClusterSshHost -Command "grep -A5 -B1 'name: $NodeName' /etc/pve/corosync.conf | sed -n 's/.*ring0_addr: //p' | head -n1"
    if ([string]::IsNullOrWhiteSpace($nodeIp)) {
      throw "Unable to resolve Proxmox node '$NodeName' from $ClusterSshHost."
    }
  }
}

$networkConfig = @'
[Match]
MACAddress=__MAC_ADDRESS__

[Network]
Address=__VM_IP__/24
Gateway=__GATEWAY__
DNS=__DNS_SERVER__
Domains=__SEARCH_DOMAIN__
'@

$networkConfig = $networkConfig.Replace("__VM_IP__", $VmIp)
$networkConfig = $networkConfig.Replace("__GATEWAY__", $Gateway)
$networkConfig = $networkConfig.Replace("__DNS_SERVER__", $DnsServer)
$networkConfig = $networkConfig.Replace("__SEARCH_DOMAIN__", $SearchDomain)

$bootstrapScript = @'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export_path="__EXPORT_PATH__"

systemctl stop apt-daily.service apt-daily-upgrade.service || true
systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service || true

apt-get update
apt-get install -y --no-install-recommends qemu-guest-agent nfs-common nfs-kernel-server xfsprogs rsync openssh-server

ssh-keygen -A

root_source="$(findmnt -no SOURCE / || true)"
root_disk="$(lsblk -no PKNAME "${root_source}" 2>/dev/null | head -n1 || true)"
data_disk="$(lsblk -dnbo NAME,SIZE,TYPE | awk '$3 == "disk" { print $1" "$2 }' | sort -k2 -nr | awk -v root="${root_disk}" '$1 != root { print "/dev/"$1; exit }')"

if [[ -z "${data_disk}" ]]; then
  echo "Unable to locate the media data disk" >&2
  exit 1
fi

mkdir -p "${export_path}"

if ! blkid "${data_disk}" >/dev/null 2>&1; then
  mkfs.ext4 -F "${data_disk}"
fi

uuid="$(blkid -s UUID -o value "${data_disk}")"
if ! grep -q "${uuid}" /etc/fstab; then
  echo "UUID=${uuid} ${export_path} ext4 defaults,nofail 0 2" >> /etc/fstab
fi

if ! mountpoint -q "${export_path}"; then
  mount "${export_path}"
fi

install -d -m 0775 -o 1000 -g 1000 \
  "${export_path}/downloads" \
  "${export_path}/tv" \
  "${export_path}/movies" \
  "${export_path}/familjefilmer"

mkdir -p /etc/exports.d
cat >/etc/exports.d/media.exports <<'EOF'
__EXPORT_PATH__ __ALLOWED_CLIENTS__
EOF

systemctl enable --now qemu-guest-agent
systemctl enable --now ssh
systemctl enable --now nfs-server || systemctl enable --now nfs-kernel-server
exportfs -ra
systemctl restart nfs-server || systemctl restart nfs-kernel-server
'@

$bootstrapScript = $bootstrapScript.Replace("__EXPORT_PATH__", $ExportPath)
$bootstrapScript = $bootstrapScript.Replace("__ALLOWED_CLIENTS__", $allowedClientsJoined)

$bootstrapScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($bootstrapScript))

$offlineBootstrap = @'
set -euo pipefail

vmid='__VM_ID__'
host_name='__HOST_NAME__'
mount_dir='/mnt/media-nfs-root'
boot_disk='/dev/pve/vm-__VM_ID__-disk-0'
mac_address="$(qm config "__VM_ID__" | awk -F'[=,]' '/^net0:/ {print $2}')"

cleanup() {
  set +e
  for d in run sys proc dev; do
    if mountpoint -q "$mount_dir/$d"; then
      umount "$mount_dir/$d"
    fi
  done
  if mountpoint -q "$mount_dir"; then
    umount "$mount_dir"
  fi
  qemu-nbd --disconnect /dev/nbd0 >/dev/null 2>&1 || true
}

trap cleanup EXIT

if qm status "$vmid" | grep -q running; then
  qm stop "$vmid" --skiplock 1 || true
  sleep 5
fi

modprobe nbd max_part=8
qemu-nbd -f raw --connect=/dev/nbd0 "$boot_disk"
sleep 2

mkdir -p "$mount_dir"
mount /dev/nbd0p1 "$mount_dir"
for d in dev proc sys run; do
  mount --bind "/$d" "$mount_dir/$d"
done

install -d "$mount_dir/etc/systemd/network" "$mount_dir/etc/ssh/sshd_config.d" "$mount_dir/etc/sudoers.d" "$mount_dir/usr/local/sbin" "$mount_dir/root/.ssh"

cat <<'EOF' | base64 -d > "$mount_dir/etc/systemd/network/10-uplink.network"
__NETWORK_CONFIG_B64__
EOF

sed -i "s/__MAC_ADDRESS__/$mac_address/" "$mount_dir/etc/systemd/network/10-uplink.network"

printf '%s\n' "$host_name" > "$mount_dir/etc/hostname"
cat > "$mount_dir/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $host_name $host_name.__SEARCH_DOMAIN__

::1 localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat <<'EOF' | base64 -d > "$mount_dir/usr/local/sbin/bootstrap-media-nfs.sh"
__BOOTSTRAP_SCRIPT_B64__
EOF
chmod 0755 "$mount_dir/usr/local/sbin/bootstrap-media-nfs.sh"

cat > "$mount_dir/etc/ssh/sshd_config.d/10-rosenvall.conf" <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
PubkeyAuthentication yes
EOF

cat > "$mount_dir/etc/sudoers.d/90-debian-nopasswd" <<'EOF'
debian ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 "$mount_dir/etc/sudoers.d/90-debian-nopasswd"

touch "$mount_dir/etc/cloud/cloud-init.disabled"

chroot "$mount_dir" /bin/bash -se <<'CHROOT'
set -euo pipefail

if ! id -u debian >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo debian
fi

passwd -l debian || true
install -d -m 0700 -o debian -g debian /home/debian/.ssh
install -d -m 0700 /root/.ssh
ssh-keygen -A
systemctl enable systemd-networkd
systemctl enable systemd-resolved || true
systemctl enable ssh
CHROOT

cat <<'EOF' | base64 -d > "$mount_dir/home/debian/.ssh/authorized_keys"
__AUTHORIZED_KEYS_B64__
EOF
chroot "$mount_dir" chown debian:debian /home/debian/.ssh/authorized_keys
chmod 0600 "$mount_dir/home/debian/.ssh/authorized_keys"

cat <<'EOF' | base64 -d > "$mount_dir/root/.ssh/authorized_keys"
__AUTHORIZED_KEYS_B64__
EOF
chmod 0600 "$mount_dir/root/.ssh/authorized_keys"

qm start "$vmid"
'@

$offlineBootstrap = $offlineBootstrap.Replace("__NETWORK_CONFIG_B64__", [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($networkConfig)))
$offlineBootstrap = $offlineBootstrap.Replace("__BOOTSTRAP_SCRIPT_B64__", $bootstrapScriptB64)
$offlineBootstrap = $offlineBootstrap.Replace("__AUTHORIZED_KEYS_B64__", $authorizedKeysB64)
$offlineBootstrap = $offlineBootstrap.Replace("__VM_ID__", $VmId.ToString())
$offlineBootstrap = $offlineBootstrap.Replace("__HOST_NAME__", $HostName)
$offlineBootstrap = $offlineBootstrap.Replace("__SEARCH_DOMAIN__", $SearchDomain)

Write-Host "Resolving Proxmox node '$NodeName' via $ClusterSshHost -> $nodeIp"
Invoke-SshScript -TargetHost $nodeIp -Script $offlineBootstrap | Out-Host

Write-Host "Waiting for SSH on $VmIp"
Wait-ForGuestSsh -GuestHost $VmIp -TimeoutSeconds $SshTimeoutSeconds

$guestCommand = "sudo /usr/local/sbin/bootstrap-media-nfs.sh && systemctl is-active ssh && (systemctl is-active nfs-server || systemctl is-active nfs-kernel-server) && sudo exportfs -v"
$guestOutput = Invoke-Guest -GuestHost $VmIp -User "debian" -Command $guestCommand
$guestOutput
