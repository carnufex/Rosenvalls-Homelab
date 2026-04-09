param(
    [string]$Namespace = "media",
    [string]$LabelSelector = "app.kubernetes.io/name=deluge-vpn"
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

$ErrorActionPreference = "Stop"
Set-HomelabKubeconfig
Assert-Command -Name "kubectl"

$podsJson = & kubectl get pod -n $Namespace -l $LabelSelector -o json
if ($LASTEXITCODE -ne 0 -or -not $podsJson) {
    throw "Failed to list deluge-vpn pods in namespace '$Namespace' with selector '$LabelSelector'."
}

$pods = ($podsJson | ConvertFrom-Json).items
if (-not $pods -or $pods.Count -eq 0) {
    throw "No running deluge-vpn pod was found in namespace '$Namespace' with selector '$LabelSelector'."
}

$runningPod = $pods |
    Where-Object { $_.metadata.deletionTimestamp -eq $null -and $_.status.phase -eq "Running" } |
    Select-Object -First 1

if (-not $runningPod) {
    throw "No active Running deluge-vpn pod was found in namespace '$Namespace' with selector '$LabelSelector'."
}

$podName = $runningPod.metadata.name
$podJson = & kubectl get pod -n $Namespace $podName -o json
if ($LASTEXITCODE -ne 0 -or -not $podJson) {
    throw "Failed to inspect deluge-vpn pod '$Namespace/$podName'."
}

$pod = $podJson | ConvertFrom-Json
$containerNames = @($pod.spec.containers | ForEach-Object { $_.name })
$execContainer = if ($containerNames -contains "wireguard") { "wireguard" } elseif ($containerNames.Count -gt 0) { $containerNames[0] } else { $null }
if (-not $execContainer) {
    throw "The deluge-vpn pod '$Namespace/$podName' has no containers."
}

$checkScript = @"
set -eu
test -f /config/wg_confs/wg0.conf
ip link show wg0 >/dev/null 2>&1
ip -4 rule show | grep -Eq 'lookup 51820'
ip -4 route show table 51820 | grep -Eq '^default .* dev wg0([[:space:]]|$)'
"@
Invoke-PodShell -Namespace $Namespace -PodName $podName -Container $execContainer -Script $checkScript

$ipCheck = @"
set -eu
if command -v curl >/dev/null 2>&1; then
  curl -fsSL https://api.ipify.org || curl -fsSL https://ifconfig.me
elif command -v wget >/dev/null 2>&1; then
  wget -qO- https://api.ipify.org || wget -qO- https://ifconfig.me
else
  echo "curl or wget not found; skipping external IP check." >&2
  exit 0
fi
"@

$stdout = & kubectl exec -n $Namespace -c $execContainer $podName -- sh -ec $ipCheck 2>$null
if ($LASTEXITCODE -eq 0 -and $stdout) {
    Write-Host "External IP via VPN: $stdout" -ForegroundColor Green
} else {
    Write-Host "VPN route verified, but curl/wget was unavailable for external IP confirmation." -ForegroundColor Yellow
}

Write-Host "deluge-vpn pod '$Namespace/$podName' has wg0 and WireGuard policy routing active in table 51820." -ForegroundColor Green
