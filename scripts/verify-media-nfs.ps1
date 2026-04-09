param(
    [string]$Namespace = "media",
    [string]$ClaimName = "media-library"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/pvc-seed-utils.ps1"

Assert-Kubeconfig

$podName = New-PvcHelperPod -Namespace $Namespace -ClaimName $ClaimName

try {
    $output = Invoke-Kubectl exec -n $Namespace $podName -- sh -lc @'
set -eu
for dir in downloads tv movies familjefilmer; do
  test -d "/target/$dir"
  touch "/target/$dir/.nfs-write-check"
  rm -f "/target/$dir/.nfs-write-check"
  echo "verified:$dir"
done
df -h /target
'@

    $output | ForEach-Object { Write-Host $_ }
    Write-Host "[OK] media-library PVC is readable and writable across all expected directories." -ForegroundColor Green
}
finally {
    Remove-PvcHelperPod -Namespace $Namespace -PodName $podName
}
