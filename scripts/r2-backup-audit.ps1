param(
    [decimal]$LonghornStoredBackupWarnGiB = 8,
    [decimal]$R2StoredObjectWarnGiB = 8,
    [string]$RawR2Remote = "r2:rosenvall-homelab-backup",
    [string]$CriticalR2Remote = "critical:"
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Failure {
    param([string]$Message)
    $script:failures.Add($Message)
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Add-Warning {
    param([string]$Message)
    $script:warnings.Add($Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Invoke-KubectlJson {
    param([string[]]$Arguments)

    $raw = & kubectl @Arguments -o json
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed."
    }

    if (-not $raw) {
        return $null
    }

    return $raw | ConvertFrom-Json
}

function Test-IsR2Reference {
    param([string]$Value)

    if (-not $Value) {
        return $false
    }

    return $Value -match "rosenvall-homelab-backup|r2\.cloudflarestorage\.com|cloudflarestorage\.com"
}

function Test-RcloneAvailable {
    return [bool](Get-Command rclone -ErrorAction SilentlyContinue)
}

Write-Host "== R2 Active Write Path Audit ==" -ForegroundColor Cyan

try {
    $backupTargets = Invoke-KubectlJson @("get", "backuptargets.longhorn.io", "-n", "longhorn-system")
    foreach ($target in @($backupTargets.items)) {
        $url = $target.spec.backupTargetURL
        if (Test-IsR2Reference $url) {
            Add-Failure "Longhorn BackupTarget $($target.metadata.name) still points at R2: $url"
        }
    }
} catch {
    Add-Warning "Unable to inspect Longhorn BackupTargets: $($_.Exception.Message)"
}

try {
    $recurringJobs = Invoke-KubectlJson @("get", "recurringjobs.longhorn.io", "-n", "longhorn-system")
    foreach ($job in @($recurringJobs.items)) {
        $groups = @($job.spec.groups) -join ","
        $backupTier = $null
        if ($job.spec.labels) {
            $backupTier = $job.spec.labels."backup-tier"
        }

        if ($job.spec.task -eq "backup" -and ($job.metadata.name -match "^r2-" -or $groups -match "r2-" -or $backupTier -match "r2")) {
            Add-Failure "Longhorn RecurringJob $($job.metadata.name) is still an R2 backup job."
        }
    }
} catch {
    Add-Warning "Unable to inspect Longhorn RecurringJobs: $($_.Exception.Message)"
}

try {
    $clusters = Invoke-KubectlJson @("get", "clusters.postgresql.cnpg.io", "-A")
    foreach ($cluster in @($clusters.items)) {
        $store = $cluster.spec.backup.barmanObjectStore
        if (-not $store) {
            continue
        }

        if ((Test-IsR2Reference $store.destinationPath) -or (Test-IsR2Reference $store.endpointURL)) {
            Add-Failure "CNPG cluster $($cluster.metadata.namespace)/$($cluster.metadata.name) still archives to R2."
        }
    }
} catch {
    Add-Warning "Unable to inspect CNPG clusters: $($_.Exception.Message)"
}

try {
    $scheduledBackups = Invoke-KubectlJson @("get", "scheduledbackups.postgresql.cnpg.io", "-A")
    if (@($scheduledBackups.items).Count -gt 0) {
        $scheduledBackups.items |
            Select-Object @{n="Namespace";e={$_.metadata.namespace}}, @{n="Name";e={$_.metadata.name}}, @{n="Cluster";e={$_.spec.cluster.name}}, @{n="Schedule";e={$_.spec.schedule}} |
            Format-Table -AutoSize
        Add-Warning "CNPG ScheduledBackup resources exist. They are fine only after their target cluster uses local MinIO, not R2."
    }
} catch {
    Add-Warning "Unable to inspect CNPG ScheduledBackups: $($_.Exception.Message)"
}

try {
    $pvcs = Invoke-KubectlJson @("get", "pvc", "-A")
    $r2LabeledPvcs = @()
    foreach ($pvc in @($pvcs.items)) {
        foreach ($label in @($pvc.metadata.labels.PSObject.Properties)) {
            if ($label.Name -match "recurring-job-group\.longhorn\.io/r2-") {
                $r2LabeledPvcs += "$($pvc.metadata.namespace)/$($pvc.metadata.name): $($label.Name)"
            }
        }
    }

    if ($r2LabeledPvcs.Count -gt 0) {
        Add-Failure "PVCs still carry R2 recurring-job labels: $($r2LabeledPvcs -join ', ')"
    }
} catch {
    Add-Warning "Unable to inspect PVC labels: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "== R2 Historical Backup Inventory ==" -ForegroundColor Cyan

try {
    $backups = Invoke-KubectlJson @("get", "backups.longhorn.io", "-n", "longhorn-system")
    $backupRows = @()
    foreach ($backup in @($backups.items)) {
        $sizeBytes = [int64]$backup.status.size
        $backupRows += [pscustomobject]@{
            Name    = $backup.metadata.name
            Volume  = $backup.status.volumeName
            SizeGiB = [math]::Round($sizeBytes / 1GB, 3)
            Created = $backup.status.created
        }
    }

    if ($backupRows.Count -gt 0) {
        $backupRows | Sort-Object SizeGiB -Descending | Format-Table -AutoSize
        $totalGiB = [math]::Round((($backupRows | Measure-Object SizeGiB -Sum).Sum), 3)
        if ($totalGiB -gt $LonghornStoredBackupWarnGiB) {
            Add-Warning "Longhorn still indexes about ${totalGiB}GiB of historical backups. Build an explicit keep/delete list before deleting R2 objects."
        } else {
            Write-Ok "Longhorn historical backup inventory is under ${LonghornStoredBackupWarnGiB}GiB."
        }
    } else {
        Write-Ok "No Longhorn backup CRs found."
    }
} catch {
    Add-Warning "Unable to inspect Longhorn backup inventory: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "== R2 Object Guard ==" -ForegroundColor Cyan

if (-not (Test-RcloneAvailable)) {
    Add-Warning "rclone is not available locally; skipped raw R2 object guard."
} else {
    try {
        $rawObjects = & rclone lsf -R --files-only $RawR2Remote 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "rclone lsf failed for $RawR2Remote"
        }

        $outsideCritical = @($rawObjects | Where-Object { $_ -and ($_ -notmatch "^critical-dr/") })
        if ($outsideCritical.Count -gt 0) {
            Add-Failure "R2 contains $($outsideCritical.Count) object(s) outside critical-dr/. Run scripts/r2-critical-inventory.ps1 before deleting anything."
        } else {
            Write-Ok "All listable R2 objects are under critical-dr/."
        }

        $sizeJson = & rclone size --json $RawR2Remote 2>$null
        if ($LASTEXITCODE -eq 0 -and $sizeJson) {
            $size = $sizeJson | ConvertFrom-Json
            $sizeGiB = [math]::Round([decimal]$size.bytes / 1GB, 3)
            if ($sizeGiB -gt $R2StoredObjectWarnGiB) {
                Add-Warning "R2 raw object size is about ${sizeGiB}GiB, above ${R2StoredObjectWarnGiB}GiB warning threshold."
            } else {
                Write-Ok "R2 raw object size is about ${sizeGiB}GiB."
            }
        }
    } catch {
        Add-Warning "Unable to inspect raw R2 objects with rclone: $($_.Exception.Message)"
    }

    try {
        foreach ($category in @("authentik", "app-configs", "bootstrap")) {
            $dirs = @(& rclone lsf --dirs-only "$CriticalR2Remote$category/" 2>$null | Where-Object { $_ })
            if ($LASTEXITCODE -ne 0) {
                continue
            }

            if ($category -eq "authentik" -and $dirs.Count -gt 3) {
                Add-Warning "R2 critical Authentik backup retention has $($dirs.Count) month directories; expected at most 3."
            }
        }
    } catch {
        Add-Warning "Unable to inspect critical R2 retention with rclone: $($_.Exception.Message)"
    }
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "Failures:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Ok "No active R2 backup write paths detected."
