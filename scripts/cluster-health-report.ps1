param(
    [int]$PreviewTtlHours = 24,
    [int]$TopPods = 15,
    [string[]]$AllowedOutOfSyncApps = @("ragflow-helm")
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

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

function Get-ConditionStatus {
    param(
        $Conditions,
        [string]$Type
    )

    $condition = $Conditions | Where-Object { $_.type -eq $Type } | Select-Object -First 1
    if (-not $condition) {
        return $null
    }

    return $condition.status
}

function Add-ReferencedPvc {
    param(
        [hashtable]$Set,
        [string]$Namespace,
        $Volumes
    )

    foreach ($volume in @($Volumes)) {
        if ($volume.persistentVolumeClaim -and $volume.persistentVolumeClaim.claimName) {
            $Set["$Namespace/$($volume.persistentVolumeClaim.claimName)"] = $true
        }
    }
}

Write-Section "Nodes"
$nodes = Invoke-KubectlJson @("get", "nodes")
$nodeRows = @()
foreach ($node in $nodes.items) {
    $ready = Get-ConditionStatus -Conditions $node.status.conditions -Type "Ready"
    $roles = ($node.metadata.labels.PSObject.Properties |
        Where-Object { $_.Name -like "node-role.kubernetes.io/*" } |
        ForEach-Object { $_.Name.Replace("node-role.kubernetes.io/", "") }) -join ","

    if (-not $roles) {
        $roles = "worker"
    }

    $nodeRows += [pscustomobject]@{
        Name    = $node.metadata.name
        Ready   = $ready
        Roles   = $roles
        Version = $node.status.nodeInfo.kubeletVersion
    }

    if ($ready -ne "True") {
        Add-Failure "Node $($node.metadata.name) is not Ready."
    }
}
$nodeRows | Format-Table -AutoSize
if ($failures.Count -eq 0) {
    Write-Ok "All nodes are Ready."
}

Write-Section "Longhorn Resilience Settings"
try {
    $longhornSettings = Invoke-KubectlJson @("get", "settings.longhorn.io", "-n", "longhorn-system")
    $settingsByName = @{}
    foreach ($setting in @($longhornSettings.items)) {
        $settingsByName[$setting.metadata.name] = $setting.value
    }

    $expectedSettings = @{
        "node-down-pod-deletion-policy" = "delete-deployment-pod"
        "orphan-resource-auto-deletion" = "instance"
        "auto-delete-pod-when-volume-detached-unexpectedly" = "true"
        "auto-salvage" = "true"
    }

    foreach ($expected in $expectedSettings.GetEnumerator()) {
        $actual = $settingsByName[$expected.Key]
        if ($actual -ne $expected.Value) {
            Add-Warning "Longhorn setting $($expected.Key) is '$actual', expected '$($expected.Value)' for power-loss recovery."
        }
    }

    if ($warnings.Count -eq 0) {
        Write-Ok "Longhorn power-loss recovery settings match expectations."
    }
} catch {
    Add-Warning "Unable to verify Longhorn resilience settings: $($_.Exception.Message)"
}

Write-Section "Node Metrics"
try {
    kubectl top nodes
    if ($LASTEXITCODE -ne 0) {
        Add-Warning "kubectl top nodes failed."
    }
} catch {
    Add-Warning "kubectl top nodes failed: $($_.Exception.Message)"
}

Write-Section "Top Pods By Memory"
try {
    $topPodLines = kubectl top pods -A --sort-by=memory
    if ($LASTEXITCODE -ne 0) {
        Add-Warning "kubectl top pods failed."
    } else {
        $topPodLines | Select-Object -First ($TopPods + 1)
    }
} catch {
    Add-Warning "kubectl top pods failed: $($_.Exception.Message)"
}

Write-Section "ArgoCD Applications"
$apps = Invoke-KubectlJson @("get", "applications.argoproj.io", "-n", "argocd")
$appRows = @()
foreach ($app in $apps.items) {
    $name = $app.metadata.name
    $sync = $app.status.sync.status
    $health = $app.status.health.status
    $revision = $app.status.sync.revision

    $appRows += [pscustomobject]@{
        Name     = $name
        Sync     = $sync
        Health   = $health
        Revision = $revision
    }

    if ($sync -ne "Synced") {
        if ($AllowedOutOfSyncApps -contains $name) {
            Add-Warning "ArgoCD app $name is $sync/$health and is currently allowed as a known exception."
        } else {
            Add-Failure "ArgoCD app $name is not Synced (sync=$sync health=$health)."
        }
    } elseif ($health -ne "Healthy") {
        Add-Failure "ArgoCD app $name is not Healthy (sync=$sync health=$health)."
    }
}
$appRows | Sort-Object Name | Format-Table -AutoSize

Write-Section "Pods"
$pods = Invoke-KubectlJson @("get", "pods", "-A")
$badPods = @()
foreach ($pod in $pods.items) {
    $phase = $pod.status.phase
    if ($phase -ne "Running" -and $phase -ne "Succeeded") {
        $badPods += [pscustomobject]@{
            Namespace = $pod.metadata.namespace
            Name      = $pod.metadata.name
            Phase     = $phase
            Node      = $pod.spec.nodeName
        }
    }
}

if ($badPods.Count -gt 0) {
    $badPods | Format-Table -AutoSize
    Add-Failure "Found $($badPods.Count) pod(s) outside Running/Succeeded."
} else {
    Write-Ok "No pods outside Running/Succeeded."
}

Write-Section "External Secrets"
$stores = Invoke-KubectlJson @("get", "clustersecretstore")
foreach ($store in $stores.items) {
    $ready = Get-ConditionStatus -Conditions $store.status.conditions -Type "Ready"
    if ($ready -ne "True") {
        Add-Failure "ClusterSecretStore $($store.metadata.name) is not Ready."
    }
}

$externalSecrets = Invoke-KubectlJson @("get", "externalsecret", "-A")
$notReadyExternalSecrets = @()
foreach ($secret in $externalSecrets.items) {
    $ready = Get-ConditionStatus -Conditions $secret.status.conditions -Type "Ready"
    if ($ready -ne "True") {
        $notReadyExternalSecrets += "$($secret.metadata.namespace)/$($secret.metadata.name)"
    }
}

if ($notReadyExternalSecrets.Count -gt 0) {
    Add-Failure "ExternalSecrets not Ready: $($notReadyExternalSecrets -join ', ')"
} else {
    Write-Ok "All ExternalSecrets are Ready."
}

Write-Section "HTTPRoutes"
$routes = Invoke-KubectlJson @("get", "httproute", "-A")
$badRoutes = @()
foreach ($route in $routes.items) {
    $accepted = $false
    foreach ($parent in @($route.status.parents)) {
        if ((Get-ConditionStatus -Conditions $parent.conditions -Type "Accepted") -eq "True") {
            $accepted = $true
            break
        }
    }

    if (-not $accepted) {
        $badRoutes += "$($route.metadata.namespace)/$($route.metadata.name)"
    }
}

if ($badRoutes.Count -gt 0) {
    Add-Failure "HTTPRoutes without accepted parent: $($badRoutes -join ', ')"
} else {
    Write-Ok "All HTTPRoutes have an accepted parent."
}

Write-Section "DevOps Preview Namespaces"
$namespaces = Invoke-KubectlJson @("get", "namespaces", "-l", "app.kubernetes.io/part-of=rosenvall-devops-preview")
$cutoff = (Get-Date).ToUniversalTime().AddHours(-1 * $PreviewTtlHours)
$previewCandidates = @()
foreach ($ns in $namespaces.items) {
    $name = $ns.metadata.name
    if ($name -eq "devops-previews") {
        continue
    }

    $keep = $null
    if ($ns.metadata.annotations) {
        $keep = $ns.metadata.annotations."rosenvall.devops/keep"
    }

    if ($keep -eq "true") {
        continue
    }

    $created = [DateTime]::Parse($ns.metadata.creationTimestamp).ToUniversalTime()
    if ($created -lt $cutoff) {
        $previewCandidates += [pscustomobject]@{
            Namespace = $name
            Created   = $created.ToString("u")
            AgeHours  = [math]::Round(((Get-Date).ToUniversalTime() - $created).TotalHours, 1)
        }
    }
}

if ($previewCandidates.Count -gt 0) {
    $previewCandidates | Sort-Object Created | Format-Table -AutoSize
    Add-Warning "Found $($previewCandidates.Count) preview namespace cleanup candidate(s) older than ${PreviewTtlHours}h."
} else {
    Write-Ok "No preview namespace cleanup candidates older than ${PreviewTtlHours}h."
}

Write-Section "PVC Reference Candidates"
$referencedPvcs = @{}
$statefulSetPvcPrefixes = New-Object System.Collections.Generic.List[string]
foreach ($pod in $pods.items) {
    Add-ReferencedPvc -Set $referencedPvcs -Namespace $pod.metadata.namespace -Volumes $pod.spec.volumes
}

$statefulSets = (Invoke-KubectlJson @("get", "statefulsets", "-A")).items
foreach ($statefulSet in @($statefulSets)) {
    foreach ($template in @($statefulSet.spec.volumeClaimTemplates)) {
        if ($template.metadata.name) {
            $statefulSetPvcPrefixes.Add("$($statefulSet.metadata.namespace)/$($template.metadata.name)-$($statefulSet.metadata.name)-")
        }
    }
}

$workloads = @(
    @(Invoke-KubectlJson @("get", "deployments", "-A")).items,
    @($statefulSets),
    @(Invoke-KubectlJson @("get", "daemonsets", "-A")).items,
    @(Invoke-KubectlJson @("get", "jobs", "-A")).items
)

foreach ($group in $workloads) {
    foreach ($item in @($group)) {
        Add-ReferencedPvc -Set $referencedPvcs -Namespace $item.metadata.namespace -Volumes $item.spec.template.spec.volumes
    }
}

$cronjobs = Invoke-KubectlJson @("get", "cronjobs", "-A")
foreach ($cronjob in $cronjobs.items) {
    Add-ReferencedPvc -Set $referencedPvcs -Namespace $cronjob.metadata.namespace -Volumes $cronjob.spec.jobTemplate.spec.template.spec.volumes
}

$pvcs = Invoke-KubectlJson @("get", "pvc", "-A")
$unreferencedPvcs = @()
foreach ($pvc in $pvcs.items) {
    $key = "$($pvc.metadata.namespace)/$($pvc.metadata.name)"
    $ownedByStatefulSet = $false
    foreach ($prefix in $statefulSetPvcPrefixes) {
        if ($key.StartsWith($prefix, [System.StringComparison]::Ordinal)) {
            $ownedByStatefulSet = $true
            break
        }
    }

    if (-not $referencedPvcs.ContainsKey($key) -and -not $ownedByStatefulSet) {
        $unreferencedPvcs += [pscustomobject]@{
            Namespace = $pvc.metadata.namespace
            Name      = $pvc.metadata.name
            Status    = $pvc.status.phase
            Class     = $pvc.spec.storageClassName
            Size      = $pvc.status.capacity.storage
        }
    }
}

if ($unreferencedPvcs.Count -gt 0) {
    $unreferencedPvcs | Sort-Object Namespace, Name | Format-Table -AutoSize
    Add-Warning "Found $($unreferencedPvcs.Count) PVC(s) not referenced by current pods or workload templates. Review before deleting anything."
} else {
    Write-Ok "All PVCs are referenced by current pods or workload templates."
}

Write-Section "Summary"
if ($warnings.Count -gt 0) {
    Write-Host "Warnings:" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
}

if ($failures.Count -gt 0) {
    Write-Host "Failures:" -ForegroundColor Red
    $failures | ForEach-Object { Write-Host " - $_" -ForegroundColor Red }
    exit 1
}

Write-Ok "Cluster health report completed without blocking failures."
