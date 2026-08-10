param(
    [string]$Host1SshHost = "192.168.1.111",
    [string]$AliasIp = "192.168.1.230",
    [string]$Interface = "vmbr0",
    [string]$StoragePath = "/media/lagring",
    [string]$SourcePath = "",
    [string]$ExportPath = "/srv/nfs/media",
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
    ),
    [switch]$InitializeEmptyMediaRoot
)

$ErrorActionPreference = "Stop"

if (Test-Path env:KUBECONFIG) {
    $poolStop = & kubectl get ciliumloadbalancerippool first-pool -o jsonpath='{.spec.blocks[0].stop}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $poolStop -ge $AliasIp) {
        throw "Cilium LoadBalancer pool still includes $AliasIp (stop=$poolStop). Push/sync the pool change before moving NFS to host1."
    }
}

$allowedClientsJoined = ($AllowedClients -join " ").Trim()
$remote = @'
set -euo pipefail

alias_ip="__ALIAS_IP__"
interface="__INTERFACE__"
storage_path="__STORAGE_PATH__"
source_path="__SOURCE_PATH__"
export_path="__EXPORT_PATH__"
allowed_clients="__ALLOWED_CLIENTS__"
initialize_empty="__INITIALIZE_EMPTY__"

alias_ip="${alias_ip%$'\r'}"
interface="${interface%$'\r'}"
storage_path="${storage_path%$'\r'}"
source_path="${source_path%$'\r'}"
export_path="${export_path%$'\r'}"
allowed_clients="${allowed_clients%$'\r'}"
initialize_empty="${initialize_empty%$'\r'}"

if ! ip link show "${interface}" >/dev/null 2>&1; then
  echo "Interface ${interface} does not exist on host1." >&2
  exit 1
fi

if [[ -z "${source_path}" ]]; then
  candidates=(
    "${storage_path}"
    "${storage_path}/media"
    "${storage_path}/lagring"
    "/media/lagring"
    "/srv/nfs/media"
  )

  best_candidate=""
  best_score=0
  best_count=0

  for candidate in "${candidates[@]}"; do
    existing=0
    for dir in downloads tv movies familjefilmer; do
      [[ -d "${candidate}/${dir}" ]] && existing=$((existing + 1))
    done

    if [[ "${existing}" -gt "${best_score}" ]]; then
      best_candidate="${candidate}"
      best_score="${existing}"
      best_count=1
    elif [[ "${existing}" -eq "${best_score}" && "${existing}" -gt 0 ]]; then
      best_count=$((best_count + 1))
    fi
  done

  if [[ "${best_score}" -eq 4 ]]; then
    source_path="${best_candidate}"
  elif [[ "${best_score}" -gt 0 ]]; then
    echo "Found only ${best_score}/4 expected media directories under ${best_candidate}." >&2
    echo "Refusing auto-detection; re-run with -SourcePath set explicitly." >&2
    exit 1
  fi

  if [[ "${best_count}" -gt 1 ]]; then
    echo "Multiple candidate media roots matched equally well. Re-run with -SourcePath set explicitly." >&2
    exit 1
  fi
fi

if [[ -z "${source_path}" ]]; then
  source_path="${storage_path}/media"
fi

if ! mountpoint -q "${storage_path}"; then
  echo "${storage_path} is not a mountpoint. Refusing to export a root-filesystem fallback." >&2
  exit 1
fi

if findmnt -T "${storage_path}" -no OPTIONS | grep -qw ro; then
  if [[ "${initialize_empty}" != "true" ]]; then
    echo "${storage_path} is mounted read-only. Re-run with -InitializeEmptyMediaRoot if intentionally rebuilding the empty media root." >&2
    exit 1
  fi
  mount -o remount,rw "${storage_path}"
fi

if [[ ! -d "${source_path}" ]]; then
  if [[ "${initialize_empty}" != "true" ]]; then
    echo "Source path ${source_path} does not exist. Re-run with -InitializeEmptyMediaRoot to create a new empty media root." >&2
    exit 1
  fi
  mkdir -p "${source_path}"
fi

echo "Using media source path: ${source_path}"
echo "Using stable NFS export path: ${export_path}"

if systemctl list-unit-files media-nfs-01-vm.service >/dev/null 2>&1; then
  systemctl disable --now media-nfs-01-vm.service >/dev/null 2>&1 || true
fi

if command -v qm >/dev/null 2>&1 && qm config 8010 >/dev/null 2>&1; then
  qm set 8010 --onboot 0 >/dev/null || true
  if qm status 8010 | grep -q "status: running"; then
    qm shutdown 8010 --timeout 60 || qm stop 8010
  fi
fi

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nfs-kernel-server nfs-common

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

systemctl daemon-reload
systemctl enable --now media-nfs-ip.service

mkdir -p "${export_path}"
mount_unit=""

if [[ "$(readlink -f "${source_path}")" != "$(readlink -f "${export_path}")" ]]; then
  mount_unit="$(systemd-escape -p --suffix=mount "${export_path}")"
  if mountpoint -q "${export_path}"; then
    if [[ "$(stat -Lc '%d:%i' "${export_path}")" != "$(stat -Lc '%d:%i' "${source_path}")" ]]; then
      current_source="$(findmnt -n -o SOURCE --target "${export_path}" || true)"
      echo "${export_path} is already a mountpoint for ${current_source}, not ${source_path}. Refusing to change it automatically." >&2
      exit 1
    fi
  else
    if find "${export_path}" -mindepth 1 -maxdepth 1 | read -r _; then
      echo "${export_path} is not empty and is not a mountpoint. Refusing to hide existing files." >&2
      exit 1
    fi

    cat >"/etc/systemd/system/${mount_unit}" <<EOF
[Unit]
Description=Bind mount existing media library for Kubernetes NFS
RequiresMountsFor=${source_path}

[Mount]
What=${source_path}
Where=${export_path}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${mount_unit}"
  fi
fi

for dir in downloads tv movies familjefilmer; do
  install -d -m 0775 -o 1000 -g 1000 "${source_path}/${dir}"
done

mkdir -p /etc/exports.d
cat >/etc/exports.d/media.exports <<EOF
${export_path} ${allowed_clients}
EOF

mkdir -p /etc/systemd/system/nfs-kernel-server.service.d
cat >/etc/systemd/system/nfs-kernel-server.service.d/media-nfs-ordering.conf <<EOF
[Unit]
Requires=media-nfs-ip.service
After=media-nfs-ip.service
EOF

if [[ -n "${mount_unit:-}" ]]; then
  cat >>/etc/systemd/system/nfs-kernel-server.service.d/media-nfs-ordering.conf <<EOF
Requires=${mount_unit}
After=${mount_unit}
EOF
fi

systemctl daemon-reload
systemctl enable --now nfs-kernel-server
exportfs -ra
systemctl restart nfs-kernel-server

echo
echo "IP state:"
ip -4 address show dev "${interface}"
echo
echo "NFS exports:"
exportfs -v
echo
echo "Mount state:"
findmnt "${export_path}" || true
echo
echo "Filesystem:"
df -h "${export_path}"
'@

$remote = $remote.Replace("__ALIAS_IP__", $AliasIp)
$remote = $remote.Replace("__INTERFACE__", $Interface)
$remote = $remote.Replace("__STORAGE_PATH__", $StoragePath)
$remote = $remote.Replace("__SOURCE_PATH__", $SourcePath)
$remote = $remote.Replace("__EXPORT_PATH__", $ExportPath)
$remote = $remote.Replace("__ALLOWED_CLIENTS__", $allowedClientsJoined)
$remote = $remote.Replace("__INITIALIZE_EMPTY__", $InitializeEmptyMediaRoot.IsPresent.ToString().ToLowerInvariant())
$remote = $remote.Replace("`r`n", "`n").Replace("`r", "")

$tempScript = [System.IO.Path]::GetTempFileName()
$remoteScript = "/tmp/host1-media-nfs-$([System.Guid]::NewGuid().ToString("n")).sh"
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempScript, $remote, $utf8NoBom)
    scp -q -o StrictHostKeyChecking=accept-new $tempScript "root@${Host1SshHost}:$remoteScript"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to copy host1 media NFS script to $Host1SshHost."
    }

    ssh -o StrictHostKeyChecking=accept-new "root@$Host1SshHost" "bash '$remoteScript'; rc=`$?; rm -f '$remoteScript'; exit `$rc"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure host1 media NFS."
    }
}
finally {
    Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
