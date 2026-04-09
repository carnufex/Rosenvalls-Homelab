param(
    [string]$Namespace = "media",
    [string]$Server = "192.168.1.230",
    [string]$Path = "/srv/nfs/media"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/pvc-seed-utils.ps1"

Assert-Kubeconfig

$podName = "verify-media-nfs-" + ([System.Guid]::NewGuid().ToString("n").Substring(0, 6))
$manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "$podName.yaml"

@"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
spec:
  restartPolicy: Never
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
  containers:
    - name: verify
      image: busybox:1.36.1
      command:
        - sh
        - -c
        - sleep 3600
      volumeMounts:
        - name: media
          mountPath: /target
  volumes:
    - name: media
      nfs:
        server: $Server
        path: $Path
"@ | Set-Content -Path $manifestPath -Encoding utf8

try {
    Invoke-Kubectl apply -f $manifestPath | Out-Null
    Invoke-Kubectl wait --for=condition=Ready "pod/$podName" -n $Namespace --timeout=120s | Out-Null

    $output = Invoke-PodShell -Namespace $Namespace -PodName $podName -Script @'
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
    Write-Host "[OK] NFS export ${Server}:${Path} is readable and writable across all expected directories." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    $null = & kubectl delete pod $podName -n $Namespace --ignore-not-found=true --wait=true 2>$null
}
