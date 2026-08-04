$ErrorActionPreference = "Stop"

$scriptPaths = @(
    (Join-Path $PSScriptRoot "bootstrap-nfs-01.ps1"),
    (Join-Path $PSScriptRoot "verify-nfs-export.ps1")
)

foreach ($scriptPath in $scriptPaths) {
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null
    if ($errors.Count) {
        throw ("PowerShell parser errors in " + $scriptPath + [Environment]::NewLine + ($errors | Out-String))
    }
}

$bootstrap = Get-Content -LiteralPath $scriptPaths[0] -Raw
$requiredBootstrapGates = @(
    'lsblk -dpno NAME,SERIAL,TYPE',
    '2190000000000',
    '2210000000000',
    'wipefs --noheadings --output TYPE',
    'awk ''NF { print $1 }'' | sort -u | paste -sd, -',
    'disk_signature_set',
    'lsblk -s -nrpo NAME "$root_source"',
    'root_ancestors',
    'flock -n 9',
    'validate_export_path',
    'prepare_export_path',
    'assert_blank_disk',
    'verify_existing_layout',
    'verify_export_mount',
    'mounted_uuid',
    'mounted_fstype',
    'RequiresMountsFor=$export_path',
    'defaults,nofail,noatime',
    'rm -f ''$remoteScript'''
)
foreach ($gate in $requiredBootstrapGates) {
    if (-not $bootstrap.Contains($gate)) {
        throw "Missing bootstrap safety gate: $gate"
    }
}
if ($bootstrap.Contains('$data_disk}1')) {
    throw "Unsafe concatenated partition device naming found."
}

$bash = @(
    Get-Command bash -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -notmatch '\\(?:System32|WindowsApps)\\bash\.exe$' } |
        Select-Object -First 1
)[0]
if ($bash) {
    $normalizationTest = Join-Path ([IO.Path]::GetTempPath()) ("nfs-signature-normalization-" + [Guid]::NewGuid().ToString("n") + ".sh")
    try {
        [IO.File]::WriteAllText($normalizationTest, @'
set -euo pipefail
normalized="$(printf ' gpt \n\tgpt\n' | awk 'NF { print $1 }' | sort -u | paste -sd, -)"
test "$normalized" = "gpt"
'@, [Text.UTF8Encoding]::new($false))
        & $bash.Source $normalizationTest
        if ($LASTEXITCODE -ne 0) {
            throw "Repeated GPT signature normalization did not produce exactly one gpt."
        }
    }
    finally {
        Remove-Item -LiteralPath $normalizationTest -Force -ErrorAction SilentlyContinue
    }
}
else {
    # No usable local Bash is available (for example, only the WSL shim exists).
    # Exercise the same record-preserving normalization against repeated GPT values.
    $normalized = (
        @(" gpt ", ([char]9 + "gpt")) |
            ForEach-Object { (($_.Trim()) -split '\s+')[0] } |
            Sort-Object -Unique
    ) -join ","
    if ($normalized -ne "gpt") {
        throw "Repeated GPT signature normalization did not produce exactly one gpt."
    }
}

$verifier = Get-Content -LiteralPath $scriptPaths[1] -Raw
$verifierCompact = $verifier -replace '\s+', ' '
foreach ($gate in @(
    'finally {',
    'Remove-Item -LiteralPath $manifestPath',
    'kubectl delete pod $podName',
    '.nfs-write-check-',
    'automountServiceAccountToken = $false',
    'enableServiceLinks = $false',
    'imagePullSecrets = @([ordered]@{ name = "immich-image-pull" })',
    'seccompProfile = [ordered]@{ type = "RuntimeDefault" }',
    'runAsNonRoot = $true',
    'runAsUser = 1000',
    'runAsGroup = 1000',
    'fsGroup = 1000',
    'allowPrivilegeEscalation = $false',
    'readOnlyRootFilesystem = $true',
    'capabilities = [ordered]@{ drop = @("ALL") }',
    'requests = [ordered]@{ cpu = "10m"; memory = "16Mi" }',
    'limits = [ordered]@{ cpu = "100m"; memory = "32Mi" }',
    'subPath = ".verification"',
    'ConvertTo-Json',
    'trap cleanup_marker EXIT INT TERM',
    'DNS-1123 label',
    'Test-SafeNfsServer',
    'Test-CanonicalAbsolutePath'
)) {
    if (-not $verifierCompact.Contains($gate)) {
        throw "Missing NFS verifier gate: $gate"
    }
}
if ($verifier -notmatch 'registry\.rosenvall\.se/library/busybox:pinned-(?<short>[0-9a-f]{8})@sha256:\k<short>[0-9a-f]{56}') {
    throw "NFS verifier image is not a digest-pinned, GC-safe BusyBox mirror."
}

$pullSecretPath = Join-Path $PSScriptRoot "..\kubernetes\applications\immich\image-pull-secret.yaml"
if (-not (Test-Path -LiteralPath $pullSecretPath)) {
    throw "Immich image-pull ExternalSecret is missing."
}
$pullSecret = Get-Content -LiteralPath $pullSecretPath -Raw
foreach ($gate in @(
    'namespace: immich',
    'kind: ClusterSecretStore',
    'name: bitwarden-secretsmanager',
    'name: immich-image-pull',
    'type: kubernetes.io/dockerconfigjson',
    '"ghcr.io"',
    '"registry.rosenvall.se"',
    '09b625aa-6a80-46bb-bf35-b41901624bb3',
    '227aad11-f6ec-4696-ae94-b47c00a93cd1'
)) {
    if (-not $pullSecret.Contains($gate)) {
        throw "Missing Immich image-pull secret gate: $gate"
    }
}
$immichKustomization = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\kubernetes\applications\immich\kustomization.yaml") -Raw
if (-not $immichKustomization.Contains('  - image-pull-secret.yaml')) {
    throw "Immich kustomization does not include image-pull-secret.yaml."
}

Write-Host "[OK] NFS bootstrap and export verifier static safety checks passed." -ForegroundColor Green
