param(
    [string]$Namespace = "media",
    [string[]]$Apps = @("radarr", "sonarr")
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")
Set-HomelabKubeconfig

$definitions = @{
    radarr = @{
        Deployment = "radarr"
        Claim = "radarr-config"
    }
    sonarr = @{
        Deployment = "sonarr"
        Claim = "sonarr-config"
    }
}

$selectedApps = $Apps | ForEach-Object { $_.ToLowerInvariant() }
foreach ($app in $selectedApps) {
    if (-not $definitions.ContainsKey($app)) {
        throw "Unknown app '$app'. Supported apps: $($definitions.Keys -join ', ')."
    }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"

foreach ($app in $selectedApps) {
    $definition = $definitions[$app]
    $deployment = $definition.Deployment
    $claim = $definition.Claim

    Write-Host "Scaling $Namespace/$deployment to 0 before config reset..."
    Invoke-Kubectl -n $Namespace scale deployment $deployment --replicas=0 | Out-Host
    Invoke-Kubectl -n $Namespace rollout status deployment $deployment --timeout=120s | Out-Host

    $podName = New-PvcHelperPod -Namespace $Namespace -ClaimName $claim
    try {
        $script = @"
set -eu
backup_root="/target/.reset-backups"
backup_dir="`${backup_root}/${app}-${stamp}"
mkdir -p "`${backup_dir}"
found=0
for entry in /target/.[!.]* /target/..?* /target/*; do
  [ -e "`${entry}" ] || continue
  [ "`${entry}" = "`${backup_root}" ] && continue
  mv "`${entry}" "`${backup_dir}/"
  found=1
done
chown -R 1000:1000 /target
if [ "`${found}" = "1" ]; then
  echo "reset:${app}:backup=`${backup_dir}"
else
  echo "reset:${app}:already-empty"
fi
"@

        Invoke-PodShell -Namespace $Namespace -PodName $podName -Script $script | Out-Host
    }
    finally {
        Remove-PvcHelperPod -Namespace $Namespace -PodName $podName
    }
}

