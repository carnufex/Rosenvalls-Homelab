param(
    [string]$RawRemote = "r2:rosenvall-homelab-backup",
    [string]$CriticalRemote = "critical:",
    [int]$RetentionMonths = 3,
    [switch]$Apply,
    [string]$ReportPath = (Join-Path $env:TEMP ("r2-critical-inventory-{0}.csv" -f (Get-Date -Format "yyyyMMdd-HHmmss")))
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command rclone -ErrorAction SilentlyContinue)) {
    throw "rclone is required."
}

function Get-MonthFromPath {
    param([string]$Path)
    if ($Path -match "(20\d{2}-\d{2})") {
        return $Matches[1]
    }
    return $null
}

function Get-Classification {
    param([string]$Path)

    if ($Path -match "^critical-dr/") {
        return "KEEP"
    }

    if ($Path -match "^(backupstore|volumes|authentik/live|authentik/dr|longhorn|manual|migration|plex|seerr|radarr|sonarr|jackett|deluge)") {
        return "DELETE"
    }

    return "REVIEW"
}

$rawObjects = @()
$rawListing = & rclone lsf -R --files-only $RawRemote 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Unable to list raw R2 remote $RawRemote."
}

foreach ($path in @($rawListing)) {
    if (-not $path) {
        continue
    }
    $rawObjects += [pscustomobject]@{
        Path = $path
        Classification = Get-Classification $path
        Reason = if ($path -match "^critical-dr/") { "critical DR prefix" } else { "legacy or unknown R2 object" }
    }
}

$criticalDirs = & rclone lsf --dirs-only $CriticalRemote 2>$null
if ($LASTEXITCODE -eq 0) {
    foreach ($category in @("authentik", "app-configs", "bootstrap")) {
        $dirs = & rclone lsf --dirs-only "$CriticalRemote$category/" 2>$null |
            ForEach-Object { $_.TrimEnd("/") } |
            Where-Object { $_ } |
            Sort-Object

        $delete = @($dirs | Select-Object -First ([Math]::Max(0, @($dirs).Count - $RetentionMonths)))
        foreach ($month in $delete) {
            $rawObjects += [pscustomobject]@{
                Path = "critical-dr/$category/$month/"
                Classification = "DELETE"
                Reason = "critical DR retention exceeds $RetentionMonths months"
            }
        }
    }
}

$rawObjects | Sort-Object Classification, Path | Export-Csv -NoTypeInformation -Encoding UTF8 $ReportPath
$rawObjects | Sort-Object Classification, Path | Format-Table -AutoSize
Write-Host "[OK] Inventory report written to $ReportPath" -ForegroundColor Green

$deleteCandidates = @($rawObjects | Where-Object { $_.Classification -eq "DELETE" })
if ($deleteCandidates.Count -eq 0) {
    Write-Host "[OK] No DELETE candidates found." -ForegroundColor Green
    exit 0
}

if (-not $Apply) {
    Write-Host "[DRY-RUN] $($deleteCandidates.Count) DELETE candidate(s) found. Re-run with -Apply to delete." -ForegroundColor Yellow
    exit 0
}

foreach ($candidate in $deleteCandidates) {
    Write-Host "[DELETE] $($candidate.Path)" -ForegroundColor Yellow
    if ($candidate.Path.EndsWith("/")) {
        rclone purge "$RawRemote/$($candidate.Path)"
    } else {
        rclone deletefile "$RawRemote/$($candidate.Path)"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to delete $($candidate.Path)."
    }
}

Write-Host "[OK] DELETE candidates removed." -ForegroundColor Green
