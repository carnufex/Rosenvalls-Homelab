param(
    [Parameter(Mandatory = $true)]
    [string]$TargetNode,
    [int]$MinimumReadyWorkers = 3,
    [int]$GateTimeoutSeconds = 900,
    [int]$GateSleepSeconds = 10
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

function Get-ConditionStatus {
    param(
        [object[]]$Conditions,
        [string]$Type
    )

    return ($Conditions | Where-Object { $_.type -eq $Type } | Select-Object -First 1).status
}

function Assert-TargetNodeReadyWorker {
    $nodes = (kubectl get nodes -o json | ConvertFrom-Json).items
    $node = $nodes | Where-Object { $_.metadata.name -eq $TargetNode } | Select-Object -First 1

    if (-not $node) {
        throw "Target node '$TargetNode' does not exist."
    }

    if ($node.metadata.labels.'node.longhorn.io/create-default-disk' -ne "true") {
        throw "Target node '$TargetNode' is not a Longhorn-capable worker in this cluster."
    }

    $ready = Get-ConditionStatus -Conditions $node.status.conditions -Type "Ready"
    if ($ready -ne "True") {
        throw "Target node '$TargetNode' is not Ready."
    }

    Write-Host "[OK] Target node '$TargetNode' is a Ready worker" -ForegroundColor Green
}

function Assert-ReadyWorkerCount {
    $nodes = (kubectl get nodes -o json | ConvertFrom-Json).items
    $workers = $nodes | Where-Object { $_.metadata.labels.'node.longhorn.io/create-default-disk' -eq "true" }
    $readyWorkers = $workers | Where-Object { (Get-ConditionStatus -Conditions $_.status.conditions -Type "Ready") -eq "True" }

    if ($readyWorkers.Count -lt $MinimumReadyWorkers) {
        throw "Only $($readyWorkers.Count) Ready workers found. At least $MinimumReadyWorkers are required before rebuilding '$TargetNode'."
    }

    Write-Host "[OK] Ready worker count $($readyWorkers.Count)/$MinimumReadyWorkers" -ForegroundColor Green
}

function Assert-NoNodeDiskPressure {
    $nodes = (kubectl get nodes -o json | ConvertFrom-Json).items
    $underPressure = @()

    foreach ($node in $nodes) {
        $diskPressure = Get-ConditionStatus -Conditions $node.status.conditions -Type "DiskPressure"
        if ($diskPressure -eq "True") {
            $underPressure += $node.metadata.name
        }
    }

    if ($underPressure.Count -gt 0) {
        throw "Nodes with DiskPressure: $($underPressure -join ', ')"
    }

    Write-Host "[OK] No nodes under DiskPressure" -ForegroundColor Green
}

function Assert-CNPGClustersReady {
    $clusters = (kubectl get clusters.postgresql.cnpg.io -A -o json | ConvertFrom-Json).items
    $notReady = @()

    foreach ($cluster in $clusters) {
        $ready = Get-ConditionStatus -Conditions $cluster.status.conditions -Type "Ready"
        if ($ready -ne "True") {
            $notReady += "$($cluster.metadata.namespace)/$($cluster.metadata.name)"
        }
    }

    if ($notReady.Count -gt 0) {
        throw "CNPG clusters not Ready: $($notReady -join ', ')"
    }

    Write-Host "[OK] All CNPG clusters Ready" -ForegroundColor Green
}

function Assert-LonghornAttachedVolumesHealthy {
    $volumes = (kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json).items
    $notHealthy = @()

    foreach ($volume in $volumes) {
        if ($volume.status.state -ne "attached") {
            continue
        }

        $scheduled = Get-ConditionStatus -Conditions $volume.status.conditions -Type "Scheduled"
        $robustness = $volume.status.robustness

        if ($scheduled -ne "True" -or $robustness -ne "healthy") {
            $pvcRef = "$($volume.status.kubernetesStatus.namespace)/$($volume.status.kubernetesStatus.pvcName)"
            $notHealthy += "$($volume.metadata.name)[$pvcRef,state=$($volume.status.state),robustness=$robustness,scheduled=$scheduled]"
        }
    }

    if ($notHealthy.Count -gt 0) {
        throw "Attached Longhorn volumes not healthy: $($notHealthy -join ', ')"
    }

    Write-Host "[OK] All attached Longhorn volumes healthy" -ForegroundColor Green
}

function Show-TargetNodeWorkloads {
    $pods = (kubectl get pods -A -o json | ConvertFrom-Json).items |
        Where-Object { $_.spec.nodeName -eq $TargetNode } |
        Sort-Object { $_.metadata.namespace }, { $_.metadata.name }

    Write-Host "[INFO] Workloads currently on $TargetNode" -ForegroundColor Cyan
    foreach ($pod in $pods) {
        $owner = $pod.metadata.ownerReferences | Select-Object -First 1
        $ownerKind = if ($owner) { $owner.kind } else { "Pod" }
        Write-Host " - $($pod.metadata.namespace)/$($pod.metadata.name) [$ownerKind]" -ForegroundColor DarkGray
    }
}

Write-Host "[INFO] Running core Argo health gate" -ForegroundColor Cyan
& "$PSScriptRoot/argocd-health-gate.ps1" -TimeoutSeconds $GateTimeoutSeconds -SleepSeconds $GateSleepSeconds

Write-Host "[INFO] Running core cluster preflight" -ForegroundColor Cyan
& "$PSScriptRoot/preflight-core.ps1"

Assert-TargetNodeReadyWorker
Assert-ReadyWorkerCount
Assert-NoNodeDiskPressure
Assert-CNPGClustersReady
Assert-LonghornAttachedVolumesHealthy
Show-TargetNodeWorkloads

Write-Host "Worker rebuild preflight passed for '$TargetNode'." -ForegroundColor Green
