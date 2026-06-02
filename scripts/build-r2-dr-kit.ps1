param(
    [switch]$Upload,
    [switch]$IncludeLiveSecrets,
    [string]$RcloneRemote = "critical:bootstrap",
    [string]$OutputRoot = (Join-Path $env:TEMP "rosenvall-r2-dr-kit"),
    [string]$KubeconfigPath = ".\tofu\output\kubeconfig",
    [string]$TalosconfigPath = ".\tofu\output\talosconfig",
    [string]$NewKubeconfigPath = ".\tofu\new_kubeconfig"
)

$ErrorActionPreference = "Stop"

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name is required."
    }
}

function Copy-IfExists {
    param(
        [string]$Path,
        [string]$Destination
    )

    if (Test-Path $Path) {
        Copy-Item -LiteralPath $Path -Destination $Destination
        Write-Host "[OK] Included $Path" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Missing optional artifact: $Path" -ForegroundColor Yellow
    }
}

Assert-Command git
Assert-Command tar
if ($Upload) {
    Assert-Command rclone
}

$month = (Get-Date).ToUniversalTime().ToString("yyyy-MM")
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$work = Join-Path $OutputRoot "dr-kit-$stamp"
$payload = Join-Path $work "payload"
$access = Join-Path $payload "access-artifacts"
New-Item -ItemType Directory -Force -Path $access | Out-Null

$commit = (git rev-parse HEAD).Trim()
$branch = (git branch --show-current).Trim()

@"
# Rosenvall Homelab R2 DR Kit

Created UTC: $stamp
Repo branch: $branch
Repo commit: $commit

This kit is a critical bootstrap helper only. It does not replace GitHub,
Bitwarden, Longhorn local snapshots, app-specific restore procedures, or media
file backups.

Minimum restore order:

1. Clone `https://github.com/carnufex/Rosenvalls-Homelab.git`.
2. Restore local operator access artifacts from `access-artifacts/`.
3. Bootstrap Talos/Kubernetes with `bootstrap.ps1`.
4. Recreate `bitwarden-access-token` in namespace `external-secrets`.
5. Wait for `ClusterSecretStore/bitwarden-secretsmanager` and ExternalSecrets.
6. Let ArgoCD sync infrastructure and applications.
7. Restore Authentik/app slim configs only after the base cluster is healthy.
"@ | Set-Content -Encoding utf8 (Join-Path $payload "README.md")

Copy-IfExists -Path $KubeconfigPath -Destination (Join-Path $access "kubeconfig")
Copy-IfExists -Path $TalosconfigPath -Destination (Join-Path $access "talosconfig")
Copy-IfExists -Path $NewKubeconfigPath -Destination (Join-Path $access "new_kubeconfig")

if ($IncludeLiveSecrets) {
    if (-not $env:KUBECONFIG) {
        throw "KUBECONFIG must be set when -IncludeLiveSecrets is used."
    }
    kubectl -n external-secrets get secret bitwarden-access-token -o yaml |
        Set-Content -Encoding utf8 (Join-Path $access "bitwarden-access-token.restore.yaml")
    Write-Host "[OK] Included live bitwarden-access-token restore YAML" -ForegroundColor Green
} else {
    @"
apiVersion: v1
kind: Secret
metadata:
  name: bitwarden-access-token
  namespace: external-secrets
type: Opaque
stringData:
  token: <restore-from-password-manager>
"@ | Set-Content -Encoding utf8 (Join-Path $access "bitwarden-access-token.restore.example.yaml")
    Write-Host "[WARN] Live bitwarden-access-token not included. Re-run with -IncludeLiveSecrets for a complete encrypted kit." -ForegroundColor Yellow
}

$archive = Join-Path $work "rosenvall-dr-kit-$stamp.tar.gz"
tar -C $payload -czf $archive .
if ($LASTEXITCODE -ne 0) {
    throw "tar failed."
}

Write-Host "[OK] DR kit archive created: $archive" -ForegroundColor Green

if (-not $Upload) {
    Write-Host "[DRY-RUN] Upload skipped. Re-run with -Upload to copy to $RcloneRemote/$month/." -ForegroundColor Yellow
    exit 0
}

rclone copy $archive "$RcloneRemote/$month/"
if ($LASTEXITCODE -ne 0) {
    throw "rclone upload failed."
}

Write-Host "[OK] Uploaded encrypted DR kit to $RcloneRemote/$month/" -ForegroundColor Green
