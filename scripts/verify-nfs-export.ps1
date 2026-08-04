param(
    [string]$Namespace = "immich",
    [string]$Server = "192.168.1.231",
    [string]$Path = "/srv/nfs/immich"
)

$ErrorActionPreference = "Stop"

function Test-CanonicalAbsolutePath {
    param([string]$Value)
    return $Value -match '^/[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*$'
}

function Test-SafeNfsServer {
    param([string]$Value)
    if ($Value -match '^(?:[0-9.]|0x)') { return Test-StrictIPv4 $Value }
    return $Value.Length -le 253 -and $Value -match '^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

function Test-StrictIPv4 {
    param([string]$Value)
    if ($Value -notmatch '^(?:0|[1-9]\d{0,2})(?:\.(?:0|[1-9]\d{0,2})){3}$') { return $false }
    return -not (@($Value.Split('.') | ForEach-Object { [int]$_ }) | Where-Object { $_ -gt 255 })
}

function Assert-NfsExportParameters {
    param([string]$Namespace, [string]$Server, [string]$Path)
    if ($Namespace.Length -gt 63 -or $Namespace -notmatch '^[a-z0-9](?:[-a-z0-9]*[a-z0-9])?$') { throw "Namespace must be a DNS-1123 label." }
    if (-not (Test-SafeNfsServer $Server)) { throw "Server must be a safe IPv4 address or hostname." }
    if (-not (Test-CanonicalAbsolutePath $Path)) { throw "Path must be a canonical absolute component path." }
}

if ($MyInvocation.InvocationName -eq '.') { return }
Assert-NfsExportParameters -Namespace $Namespace -Server $Server -Path $Path

. "$PSScriptRoot/pvc-seed-utils.ps1"

$suffix = [Guid]::NewGuid().ToString("n").Substring(0, 12)
$podName = "verify-nfs-export-$suffix"
$markerName = ".nfs-write-check-$suffix"
$markerValue = "nfs-export-verify-$suffix"
$manifestPath = Join-Path ([IO.Path]::GetTempPath()) "$podName.json"
$manifest = [ordered]@{
    apiVersion = "v1"
    kind       = "Pod"
    metadata   = [ordered]@{ name = $podName; namespace = $Namespace }
    spec       = [ordered]@{
        restartPolicy    = "Never"
        securityContext  = [ordered]@{ runAsUser = 1000; runAsGroup = 1000 }
        containers       = @([ordered]@{
            name         = "verify"
            image        = "busybox:1.36.1"
            command      = @("sh", "-c", "sleep 3600")
            volumeMounts = @([ordered]@{ name = "nfs-export"; mountPath = "/target" })
        })
        volumes          = @([ordered]@{
            name = "nfs-export"
            nfs  = [ordered]@{ server = $Server; path = $Path }
        })
    }
}

$primaryFailure = $null
try {
    Assert-Kubeconfig
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    Invoke-Kubectl apply -f $manifestPath | Out-Null
    Invoke-Kubectl wait --for=condition=Ready "pod/$podName" -n $Namespace --timeout=120s | Out-Null
    $output = Invoke-PodShell -Namespace $Namespace -PodName $podName -Script @"
set -eu
marker="/target/$markerName"
cleanup_marker() { rm -f -- "`$marker"; }
trap cleanup_marker EXIT INT TERM
printf '%s\n' '$markerValue' > "`$marker"
test "`$(cat "`$marker")" = '$markerValue'
df -h /target
rm -f -- "`$marker"
trap - EXIT INT TERM
test ! -e "`$marker"
"@
    $output | ForEach-Object { Write-Host $_ }
    Write-Host ("[OK] NFS export {0}:{1} was read and written as UID/GID 1000; the temporary marker was removed." -f $Server, $Path) -ForegroundColor Green
}
catch {
    $primaryFailure = $_
    throw
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    try {
        $deleteOutput = & kubectl delete pod $podName -n $Namespace --ignore-not-found=true --wait=true 2>&1
        if ($LASTEXITCODE -ne 0) {
            $cleanupMessage = ("Failed to delete verifier pod {0}/{1}: {2}" -f $Namespace, $podName, ($deleteOutput | Out-String))
            if ($primaryFailure) { Write-Warning $cleanupMessage } else { throw $cleanupMessage }
        }
    }
    catch {
        if ($primaryFailure) {
            Write-Warning "Verifier pod cleanup failed after the primary error: $($_.Exception.Message)"
        }
        else {
            throw
        }
    }
}
