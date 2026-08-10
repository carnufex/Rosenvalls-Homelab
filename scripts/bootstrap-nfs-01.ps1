param(
    [string]$VmIp = "192.168.1.231",
    [string]$ExportPath = "/srv/nfs/immich",
    [string]$ExpectedSerial = "NFS01DATA",
    [string[]]$AllowedClients = @(
        "192.168.1.211(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.212(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.213(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.214(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.217(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.218(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.219(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.232(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)",
        "192.168.1.233(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)"
    )
)

$ErrorActionPreference = "Stop"

function Test-CanonicalAbsolutePath {
    param([string]$Value)
    return $Value -match '^/[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$'
}

function Test-IPv4 {
    param([string]$Value)
    if ($Value -notmatch '^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$') { return $false }
    $octets = @($Value.Split('.') | ForEach-Object { [int]$_ })
    return -not ($octets | Where-Object { $_ -gt 255 })
}

if (-not (Test-IPv4 $VmIp)) { throw "VmIp must be an IPv4 address." }
if (-not (Test-CanonicalAbsolutePath $ExportPath)) { throw "ExportPath must be a canonical absolute component path." }
if ($ExpectedSerial -notmatch '^[A-Za-z0-9._-]+$') { throw "ExpectedSerial is unsafe." }
if ($AllowedClients.Count -eq 0) { throw "AllowedClients must not be empty." }
$clientPattern = '^(?<ip>(?:\d{1,3}\.){3}\d{1,3})\(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000\)$'
foreach ($client in $AllowedClients) {
    $match = [regex]::Match($client, $clientPattern)
    if (-not $match.Success -or -not (Test-IPv4 $match.Groups["ip"].Value)) {
        throw "AllowedClients entries must use an IPv4 address and the required NFS options."
    }
}

function Wait-ForSsh {
    param([string]$Target, [int]$TimeoutSeconds = 600)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-NetConnection -ComputerName $Target -Port 22 -WarningAction SilentlyContinue -InformationLevel Quiet) {
            & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "debian@$Target" "true" 2>$null
            if ($LASTEXITCODE -eq 0) { return }
        }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for SSH as debian on $Target."
}

function Invoke-NfsGuestBootstrap {
    param([Parameter(Mandatory = $true)][string]$Script)
    $localScript = [IO.Path]::GetTempFileName()
    $remoteScript = "/tmp/nfs-01-bootstrap-$([Guid]::NewGuid().ToString("n")).sh"
    $remoteTarget = ("debian@{0}:{1}" -f $VmIp, $remoteScript)
    try {
        [IO.File]::WriteAllText($localScript, $Script.Replace("`r`n", "`n").Replace("`r", ""), [Text.UTF8Encoding]::new($false))
        & scp -q -o StrictHostKeyChecking=accept-new $localScript $remoteTarget
        if ($LASTEXITCODE -ne 0) { throw "Failed to copy the NFS bootstrap payload to $VmIp." }
        & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "debian@$VmIp" "sudo bash '$remoteScript'"
        if ($LASTEXITCODE -ne 0) { throw "NFS guest bootstrap failed on $VmIp." }
    }
    finally {
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
        try {
            & ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "debian@$VmIp" "rm -f '$remoteScript'" 2>$null
            if ($LASTEXITCODE -ne 0) { Write-Warning ("Could not remove remote temporary payload {0} on {1}." -f $remoteScript, $VmIp) }
        }
        catch {
            Write-Warning ("Could not remove remote temporary payload {0} on {1}: {2}" -f $remoteScript, $VmIp, $_.Exception.Message)
        }
    }
}

$guestPayload = @'
set -euo pipefail
export LC_ALL=C
export_path="__EXPORT_PATH__"
expected_serial="__EXPECTED_SERIAL__"
expected_label="immich-nfs"
allowed_clients="__ALLOWED_CLIENTS__"

fail() { echo "$1" >&2; exit 1; }
signature_set() { wipefs --noheadings --output TYPE "$1" 2>/dev/null | awk 'NF { print $1 }' | sort -u | paste -sd, -; }
is_gpt_signature_set() { [[ "$1" == "gpt" || "$1" == "PMBR,gpt" || "$1" == "dos,gpt" ]]; }
validate_export_path() {
  [[ "$export_path" =~ ^/[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]] || fail "Export path is not canonical."
  path_probe=""
  while IFS= read -r component; do
    path_probe="$path_probe/$component"
    [[ ! -L "$path_probe" ]] || fail "Export path contains symlink $path_probe."
  done < <(printf '%s\n' "$export_path" | cut -d/ -f2- | tr / '\n')
  if [[ -e "$export_path" ]]; then
    [[ -d "$export_path" && ! -L "$export_path" ]] || fail "Export path is not a real directory."
    [[ "$(readlink -e "$export_path")" == "$export_path" ]] || fail "Export path canonical mismatch."
  fi
}
inspect_identity() {
  root_source="$(findmnt -nro SOURCE /)"
  [[ -b "$root_source" ]] || fail "Root source is not a block device."
  root_ancestors="$(lsblk -s -nrpo NAME "$root_source" | awk '{ print $1 }' | xargs -r -n1 readlink -f)"
  data_disks="$(lsblk -dpno NAME,SERIAL,TYPE | awk -v serial="$expected_serial" '$2 == serial && $3 == "disk" { print $1 }')"
  [[ -n "$data_disks" && "$(printf '%s\n' "$data_disks" | wc -l)" -eq 1 ]] || fail "Expected exactly one serial-matched disk."
  data_disk="$(readlink -f "$data_disks")"
  printf '%s\n' "$root_ancestors" | grep -Fqx "$data_disk" && fail "Serial-selected disk is in root ancestry."
  size_bytes="$(blockdev --getsize64 "$data_disk")"
  [[ "$size_bytes" -ge 2190000000000 && "$size_bytes" -le 2210000000000 ]] || fail "Serial-selected disk has unexpected size."
  child_devices="$(lsblk -nrpo NAME,TYPE "$data_disk" | awk '$2 != "disk" { print $1 " " $2 }')"
  disk_signature_set="$(signature_set "$data_disk")"
}
assert_blank_disk() {
  [[ -z "$child_devices" ]] || fail "Unexpected partition shape on blank disk."
  ! blkid "$data_disk" >/dev/null 2>&1 || fail "Unexpected signature on blank disk."
  [[ -z "$(lsblk -nro FSTYPE "$data_disk" | tr -d '[:space:]')" && -z "$disk_signature_set" ]] || fail "Unexpected filesystem or signature on blank disk."
}
single_partition() {
  [[ "$(printf '%s\n' "$child_devices" | wc -l)" -eq 1 && "$child_devices" == *" part" ]] || fail "Unexpected partition shape."
  data_partition="$(printf '%s\n' "$child_devices" | awk '{ print $1 }')"
}
verify_existing_layout() {
  single_partition
  parted -s "$data_disk" print | grep -qx 'Partition Table: gpt' || fail "Expected GPT partition table."
  verify_existing_metadata
}
verify_existing_metadata() {
  single_partition
  is_gpt_signature_set "$disk_signature_set" || fail "Unexpected disk signature set $disk_signature_set."
  filesystem_type="$(blkid -s TYPE -o value "$data_partition" 2>/dev/null || true)"
  filesystem_label="$(blkid -s LABEL -o value "$data_partition" 2>/dev/null || true)"
  [[ "$filesystem_type" == "ext4" && "$filesystem_label" == "$expected_label" ]] || fail "Existing partition is not expected ext4 label."
  [[ "$(signature_set "$data_partition")" == "ext4" ]] || fail "Unexpected partition signature set."
}
verify_export_mount() {
  mounted_source="$(findmnt -nro SOURCE --target "$export_path" 2>/dev/null || true)"
  mounted_fstype="$(findmnt -nro FSTYPE --target "$export_path" 2>/dev/null || true)"
  mounted_source="$(readlink -f "$mounted_source" 2>/dev/null || true)"
  mounted_uuid="$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)"
  [[ "$mounted_source" == "$(readlink -f "$data_partition")" && "$mounted_uuid" == "$uuid" && "$mounted_fstype" == "ext4" ]] || fail "Export path is not mounted from expected partition UUID."
}
prepare_export_path() {
  validate_export_path
  if [[ ! -e "$export_path" ]]; then install -d -m 0755 "$export_path"; fi
  validate_export_path
  if ! mountpoint -q "$export_path"; then
    [[ -d "$export_path" && ! -L "$export_path" ]] || fail "Unmounted export path is not a real directory."
    [[ -z "$(find "$export_path" -mindepth 1 -maxdepth 1 -print -quit)" ]] || fail "Unmounted export path is not empty."
  fi
}

exec 9>/run/lock/nfs-01-bootstrap.lock
flock -n 9 || fail "Another NFS bootstrap is already running."
validate_export_path
inspect_identity
if [[ -z "$child_devices" ]]; then
  assert_blank_disk
else
  verify_existing_metadata
fi
prepare_export_path

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qemu-guest-agent nfs-kernel-server nfs-common parted e2fsprogs util-linux

inspect_identity
if [[ -z "$child_devices" ]]; then
  assert_blank_disk
  inspect_identity
  assert_blank_disk
  parted -s "$data_disk" -- mklabel gpt mkpart primary ext4 1MiB 100%
  partprobe "$data_disk"; udevadm settle
  inspect_identity
  single_partition
  parted -s "$data_disk" print | grep -qx 'Partition Table: gpt' || fail "New partition table is not GPT."
  is_gpt_signature_set "$disk_signature_set" || fail "New disk signature set is unexpected."
  [[ -z "$(blkid -s TYPE -o value "$data_partition" 2>/dev/null || true)" && -z "$(signature_set "$data_partition")" ]] || fail "New partition is unexpectedly signed."
  mkfs.ext4 -F -L "$expected_label" "$data_partition"
else
  verify_existing_metadata
  verify_existing_layout
fi

uuid="$(blkid -s UUID -o value "$data_partition")"
[[ -n "$uuid" ]] || fail "Unable to read filesystem UUID."
prepare_export_path
if mountpoint -q "$export_path"; then verify_export_mount; fi
fstab_tmp="$(mktemp)"; trap 'rm -f "$fstab_tmp"' EXIT
awk -v target="$export_path" '$2 != target { print }' /etc/fstab >"$fstab_tmp"
printf 'UUID=%s %s ext4 defaults,nofail,noatime 0 2\n' "$uuid" "$export_path" >>"$fstab_tmp"
install -m 0644 "$fstab_tmp" /etc/fstab
if ! mountpoint -q "$export_path"; then mount "$export_path"; fi
verify_export_mount
chown 1000:1000 "$export_path"; chmod 0775 "$export_path"
install -d -o 1000 -g 1000 -m 0700 "$export_path/.verification"
install -d -m 0755 /etc/exports.d /etc/systemd/system/nfs-kernel-server.service.d
printf '%s %s\n' "$export_path" "$allowed_clients" > /etc/exports.d/immich.exports
cat > /etc/systemd/system/nfs-kernel-server.service.d/immich-nfs-ordering.conf <<EOF
[Unit]
RequiresMountsFor=$export_path
After=local-fs.target
EOF
systemctl daemon-reload
systemctl enable --now qemu-guest-agent
systemctl enable --now nfs-kernel-server
exportfs -ra
systemctl restart nfs-kernel-server
findmnt "$export_path"; df -h "$export_path"; exportfs -v
'@
$guestPayload = $guestPayload.Replace("__EXPORT_PATH__", $ExportPath).Replace("__EXPECTED_SERIAL__", $ExpectedSerial).Replace("__ALLOWED_CLIENTS__", ($AllowedClients -join " "))
Wait-ForSsh -Target $VmIp
Invoke-NfsGuestBootstrap -Script $guestPayload
