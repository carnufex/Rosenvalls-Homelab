<#
.SYNOPSIS
  Runs OpenTofu in tofu/ with the state backend and secrets loaded from Bitwarden.

.DESCRIPTION
  The OpenTofu state lives encrypted in R2 (tofu-state/hemma-k8s.tfstate) and the
  Proxmox token is not in terraform.tfvars, so plain `tofu` has neither. This
  wrapper reads them from Bitwarden Secrets Manager (homelab project), exports
  them for the one tofu process, and clears them again afterwards.

  Bitwarden access: $env:BWS_ACCESS_TOKEN if it is set, otherwise the cluster's
  bitwarden-access-token secret (needs a working tofu/output/kubeconfig). When
  the cluster is down, set BWS_ACCESS_TOKEN yourself (break-glass copy in your
  password manager).

.EXAMPLE
  .\scripts\tofu.ps1 plan
  .\scripts\tofu.ps1 plan -out=change.tfplan
  .\scripts\tofu.ps1 apply change.tfplan
#>
$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
$tofuDir = Join-Path $repo "tofu"
$bws = Join-Path $env:LOCALAPPDATA "bws\bws.exe"
$projectId = "e3b0b2ac-19f2-464d-a859-b39f00892f97"

if (-not (Test-Path $bws)) { throw "bws CLI not found at $bws." }
if (-not (Get-Command tofu -ErrorAction SilentlyContinue)) { throw "tofu not found on PATH." }

$ownToken = [string]::IsNullOrEmpty($env:BWS_ACCESS_TOKEN)
if ($ownToken) {
    $kubeconfig = Join-Path $tofuDir "output\kubeconfig"
    $b64 = & kubectl --kubeconfig $kubeconfig get secret bitwarden-access-token -n external-secrets -o "jsonpath={.data.token}" 2>$null
    if (-not $b64) {
        throw "Could not read bitwarden-access-token from the cluster. Set `$env:BWS_ACCESS_TOKEN and retry."
    }
    $env:BWS_ACCESS_TOKEN = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
}
$env:BWS_SERVER_URL = "https://vault.bitwarden.eu"

$wanted = @{
    "S3_ACCESS_KEY_ID"      = "AWS_ACCESS_KEY_ID"
    "S3_SECRET_ACCESS_KEY"  = "AWS_SECRET_ACCESS_KEY"
    "S3_ENDPOINT"           = "AWS_ENDPOINT_URL_S3"
    "tofu-state-passphrase" = "TF_VAR_state_passphrase"
    "proxmox-tofu-token"    = "TF_VAR_proxmox_api_token"
}

$exported = @()
try {
    $secrets = & $bws secret list $projectId -o json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "bws secret list failed." }
    foreach ($key in $wanted.Keys) {
        $match = @($secrets | Where-Object { $_.key -eq $key })
        if ($match.Count -ne 1) { throw "Bitwarden secret '$key' not found exactly once (found $($match.Count))." }
        Set-Item -Path "env:$($wanted[$key])" -Value $match[0].value
        $exported += $wanted[$key]
    }

    & tofu "-chdir=$tofuDir" @args
    $code = $LASTEXITCODE
}
finally {
    foreach ($name in $exported) { Remove-Item -Path "env:$name" -ErrorAction SilentlyContinue }
    if ($ownToken) { Remove-Item env:BWS_ACCESS_TOKEN -ErrorAction SilentlyContinue }
}
exit $code
