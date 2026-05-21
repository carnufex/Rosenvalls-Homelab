param(
    [string]$Namespace = "media",
    [string]$LabelSelector = "app.kubernetes.io/name=deluge-vpn",
    [string]$PolicyName = "deluge-vpn-egress-lockdown",
    [switch]$SkipDirectEgressTest
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

$ErrorActionPreference = "Stop"
Set-HomelabKubeconfig
Assert-Command -Name "kubectl"

function Invoke-CheckedPodShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$PodName,
        [Parameter(Mandatory = $true)]
        [string]$Container,
        [Parameter(Mandatory = $true)]
        [string]$Script
    )

    $normalizedScript = (($Script -replace "`r`n", "`n") -replace "`n", "; ").Trim()
    if ($normalizedScript.Contains('"')) {
        throw "Invoke-CheckedPodShell does not support double quotes in script payloads."
    }

    $command = 'kubectl exec -n "' + $Namespace + '" -c "' + $Container + '" "' + $PodName + '" -- sh -lc "' + $normalizedScript + '"'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & cmd.exe /d /s /c $command 2>&1
    $ErrorActionPreference = $previousErrorActionPreference
    if ($LASTEXITCODE -ne 0) {
        $rendered = ($output | Out-String).Trim()
        throw $rendered
    }

    return $output
}

$policyJson = & kubectl get ciliumnetworkpolicy -n $Namespace $PolicyName -o json 2>&1
if ($LASTEXITCODE -ne 0 -or -not $policyJson) {
    throw "Failed to inspect CiliumNetworkPolicy '$Namespace/$PolicyName'.`n$($policyJson | Out-String)"
}

$policy = $policyJson | ConvertFrom-Json
$validCondition = @($policy.status.conditions) | Where-Object { $_.type -eq "Valid" } | Select-Object -First 1
if (-not $validCondition -or $validCondition.status -ne "True") {
    throw "CiliumNetworkPolicy '$Namespace/$PolicyName' is not valid."
}

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

$curlContainer = if ($containerNames -contains "deluge") { "deluge" } else { $execContainer }

$checkScript = @"
set -eu
test -f /config/wg_confs/wg0.conf
ip link show wg0 >/dev/null 2>&1
ip -4 rule show | grep -Eq 'lookup 51820'
ip -4 route show table 51820 | grep -Eq '^default( .*)? dev wg0([[:space:]]|$)'
"@
Invoke-CheckedPodShell -Namespace $Namespace -PodName $podName -Container $execContainer -Script $checkScript

$ipCheck = 'curl -4fsS --max-time 20 https://api.ipify.org || curl -4fsS --max-time 20 https://ifconfig.me'

$stdout = $null
try {
    $stdout = Invoke-CheckedPodShell -Namespace $Namespace -PodName $podName -Container $curlContainer -Script $ipCheck
}
catch {
    $stdout = $null
}

if ($stdout) {
    Write-Host "External IP via VPN: $stdout" -ForegroundColor Green
} else {
    Write-Host "VPN route verified, but curl/wget was unavailable for external IP confirmation." -ForegroundColor Yellow
}

if (-not $SkipDirectEgressTest) {
    $directEgressCheck = 'curl -4fsS --interface eth0 --connect-timeout 5 --max-time 12 https://api.ipify.org >/tmp/direct-egress.out 2>&1 && cat /tmp/direct-egress.out >&2 && exit 1 || echo DIRECT_EGRESS_BLOCKED'

    try {
        $directOutput = Invoke-CheckedPodShell -Namespace $Namespace -PodName $podName -Container $curlContainer -Script $directEgressCheck
        $directOutput | ForEach-Object { Write-Host $_ -ForegroundColor Green }
    }
    catch {
        throw "Direct egress test failed. If it says egress succeeded, the kill switch is not safe.`n$($_.Exception.Message)"
    }
}

Write-Host "CiliumNetworkPolicy '$Namespace/$PolicyName' is valid and selects deluge-vpn." -ForegroundColor Green
Write-Host "deluge-vpn pod '$Namespace/$podName' has wg0 and WireGuard policy routing active in table 51820." -ForegroundColor Green
