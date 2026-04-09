param(
    [string]$OutputPath = (Join-Path $env:USERPROFILE "Downloads/rosenvall-local-ca.cer")
)

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

Set-HomelabKubeconfig
Assert-Command -Name "kubectl"

$secretValue = & kubectl -n gateway get secret gateway-local-ca -o jsonpath="{.data.tls\.crt}"
if ($LASTEXITCODE -ne 0 -or -not $secretValue) {
    throw "Unable to read gateway-local-ca from namespace gateway."
}

$bytes = [Convert]::FromBase64String($secretValue)
$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
}

[IO.File]::WriteAllBytes($OutputPath, $bytes)
Write-Host "Exported gateway-local-ca to $OutputPath" -ForegroundColor Green
