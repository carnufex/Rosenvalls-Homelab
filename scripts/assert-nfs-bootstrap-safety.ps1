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
foreach ($gate in @(
    'finally {',
    'Remove-Item -LiteralPath $manifestPath',
    'kubectl delete pod $podName',
    '.nfs-write-check-',
    'runAsUser = 1000',
    'runAsGroup = 1000',
    'ConvertTo-Json',
    'trap cleanup_marker EXIT INT TERM',
    'DNS-1123 label',
    'Test-SafeNfsServer',
    'Test-CanonicalAbsolutePath'
)) {
    if (-not $verifier.Contains($gate)) {
        throw "Missing NFS verifier gate: $gate"
    }
}

Write-Host "[OK] NFS bootstrap and export verifier static safety checks passed." -ForegroundColor Green
