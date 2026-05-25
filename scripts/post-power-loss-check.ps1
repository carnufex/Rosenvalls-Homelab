param(
    [switch]$SkipMediaChecks
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Step {
    param(
        [string]$Name,
        [scriptblock]$Command
    )

    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed."
    }
}

Push-Location $repoRoot
try {
    Invoke-Step "Core preflight" { & "$PSScriptRoot\preflight-core.ps1" }
    Invoke-Step "ArgoCD core health gate" { & "$PSScriptRoot\argocd-health-gate.ps1" }
    Invoke-Step "Cluster health report" { & "$PSScriptRoot\cluster-health-report.ps1" }

    if (-not $SkipMediaChecks) {
        Invoke-Step "Media NFS verification" { & "$PSScriptRoot\verify-media-nfs.ps1" }
        Invoke-Step "Deluge VPN verification" { & "$PSScriptRoot\verify-deluge-vpn.ps1" }
    }

    Write-Host ""
    Write-Host "[OK] Post power-loss recovery checks completed." -ForegroundColor Green
} finally {
    Pop-Location
}
