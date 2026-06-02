param(
    [int]$PreviewTtlHours = 24,
    [int]$TopPods = 15,
    [string[]]$AllowedOutOfSyncApps = @("ragflow-helm"),
    [hashtable[]]$PublicRouteChecks = @(
        @{ Host = "argo.rosenvall.se"; Path = "/api/dex/.well-known/openid-configuration"; GatewayIP = "192.168.1.222"; Expected = @(200) },
        @{ Host = "headlamp.rosenvall.se"; Path = "/"; GatewayIP = "192.168.1.222"; Expected = @(200, 302) },
        @{ Host = "plex.rosenvall.se"; Path = "/"; GatewayIP = "192.168.1.222"; Expected = @(200, 302, 401) }
    )
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

function Invoke-HttpStatus {
    param(
        [string]$HostName,
        [string]$Path = "/",
        [string]$GatewayIP
    )

    $url = "https://$HostName$Path"
    $arguments = @("-k", "-sS", "-o", "NUL", "-w", "%{http_code}", "-I", "--max-time", "15")
    if ($GatewayIP) {
        $arguments += @("--resolve", "${HostName}:443:${GatewayIP}")
    }
    $arguments += $url

    $status = & curl.exe @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $status) {
        return $null
    }

    return [int]($status | Select-Object -Last 1)
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

function Test-IsR2Reference {
    param([string]$Value)

    if (-not $Value) {
        return $false
    }

    return $Value -match "rosenvall-homelab-backup|r2\.cloudflarestorage\.com|cloudflarestorage\.com"
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

Write-Section "Longhorn Volume Health"
try {
    $longhornVolumes = Invoke-KubectlJson @("get", "volumes.longhorn.io", "-n", "longhorn-system")
    $stuckVolumes = @()
    $degradedVolumes = @()
    $faultedVolumes = @()

    foreach ($volume in @($longhornVolumes.items)) {
        $state = $volume.status.state
        $robustness = $volume.status.robustness

        if ($state -ne "attached" -and $state -ne "detached") {
            $stuckVolumes += [pscustomobject]@{
                Name       = $volume.metadata.name
                State      = $state
                Robustness = $robustness
                Node       = $volume.status.currentNodeID
            }
            continue
        }

        if ($state -eq "attached") {
            if ($robustness -eq "faulted") {
                $faultedVolumes += [pscustomobject]@{
                    Name       = $volume.metadata.name
                    State      = $state
                    Robustness = $robustness
                    Node       = $volume.status.currentNodeID
                }
            } elseif ($robustness -ne "healthy") {
                $degradedVolumes += [pscustomobject]@{
                    Name       = $volume.metadata.name
                    State      = $state
                    Robustness = $robustness
                    Node       = $volume.status.currentNodeID
                }
            }
        }
    }

    if ($stuckVolumes.Count -gt 0) {
        $stuckVolumes | Sort-Object Name | Format-Table -AutoSize
        Add-Failure "Found Longhorn volume(s) not attached or detached cleanly."
    }

    if ($faultedVolumes.Count -gt 0) {
        $faultedVolumes | Sort-Object Name | Format-Table -AutoSize
        Add-Failure "Found faulted attached Longhorn volume(s)."
    }

    if ($degradedVolumes.Count -gt 0) {
        $degradedVolumes | Sort-Object Name | Format-Table -AutoSize
        Add-Warning "Found attached Longhorn volume(s) that are not fully healthy."
    }

    if ($stuckVolumes.Count -eq 0 -and $faultedVolumes.Count -eq 0 -and $degradedVolumes.Count -eq 0) {
        Write-Ok "All attached Longhorn volumes are healthy and no volumes are stuck attaching/detaching."
    }
} catch {
    Add-Warning "Unable to verify Longhorn volume health: $($_.Exception.Message)"
}

Write-Section "Longhorn Orphans"
try {
    $longhornOrphans = Invoke-KubectlJson @("get", "orphans.longhorn.io", "-n", "longhorn-system")
    $engineOrphans = @()
    $replicaOrphans = @()

    foreach ($orphan in @($longhornOrphans.items)) {
        $orphanType = $orphan.spec.orphanType
        if (-not $orphanType) {
            $orphanType = $orphan.orphanType
        }

        $nodeID = $orphan.spec.nodeID
        if (-not $nodeID) {
            $nodeID = $orphan.nodeID
        }

        $row = [pscustomobject]@{
            Name = $orphan.metadata.name
            Type = $orphanType
            Node = $nodeID
        }

        if ($orphanType -eq "engine-instance") {
            $engineOrphans += $row
        } elseif ($orphanType -eq "replica") {
            $replicaOrphans += $row
        }
    }

    if ($engineOrphans.Count -gt 0) {
        $engineOrphans | Sort-Object Name | Format-Table -AutoSize
        Add-Failure "Found Longhorn engine-instance orphan(s), which can block RWO volume attach after power loss."
    }

    if ($replicaOrphans.Count -gt 0) {
        $replicaOrphans | Sort-Object Name | Format-Table -AutoSize
        Add-Warning "Found Longhorn replica orphan(s). Review before deleting; these are not usually immediate attach blockers."
    }

    if ($engineOrphans.Count -eq 0 -and $replicaOrphans.Count -eq 0) {
        Write-Ok "No Longhorn orphan resources found."
    }
} catch {
    Add-Warning "Unable to verify Longhorn orphan resources: $($_.Exception.Message)"
}

Write-Section "R2 Backup Cost Guard"
try {
    $r2RiskCount = 0
    $backupTargets = Invoke-KubectlJson @("get", "backuptargets.longhorn.io", "-n", "longhorn-system")
    foreach ($target in @($backupTargets.items)) {
        $url = $target.spec.backupTargetURL
        if (Test-IsR2Reference $url) {
            $r2RiskCount++
            Add-Warning "Longhorn BackupTarget $($target.metadata.name) still points at R2: $url"
        }
    }

    $recurringJobs = Invoke-KubectlJson @("get", "recurringjobs.longhorn.io", "-n", "longhorn-system")
    foreach ($job in @($recurringJobs.items)) {
        $groups = @($job.spec.groups) -join ","
        $backupTier = $null
        if ($job.spec.labels) {
            $backupTier = $job.spec.labels."backup-tier"
        }

        if ($job.spec.task -eq "backup" -and ($job.metadata.name -match "^r2-" -or $groups -match "r2-" -or $backupTier -match "r2")) {
            $r2RiskCount++
            Add-Warning "Longhorn RecurringJob $($job.metadata.name) is still an R2 backup job."
        }
    }

    $clusters = Invoke-KubectlJson @("get", "clusters.postgresql.cnpg.io", "-A")
    foreach ($cluster in @($clusters.items)) {
        $store = $cluster.spec.backup.barmanObjectStore
        if (-not $store) {
            continue
        }

        if ((Test-IsR2Reference $store.destinationPath) -or (Test-IsR2Reference $store.endpointURL)) {
            $r2RiskCount++
            Add-Warning "CNPG cluster $($cluster.metadata.namespace)/$($cluster.metadata.name) still archives to R2."
        }
    }

    $pvcsForR2Labels = Invoke-KubectlJson @("get", "pvc", "-A")
    $r2LabelCount = 0
    foreach ($pvc in @($pvcsForR2Labels.items)) {
        foreach ($label in @($pvc.metadata.labels.PSObject.Properties)) {
            if ($label.Name -match "recurring-job-group\.longhorn\.io/r2-") {
                $r2LabelCount++
            }
        }
    }

    if ($r2LabelCount -gt 0) {
        $r2RiskCount += $r2LabelCount
        Add-Warning "Found $r2LabelCount PVC R2 recurring-job label(s). Remove these before re-enabling any backup jobs."
    }

    if ($r2RiskCount -eq 0) {
        Write-Ok "No active R2 backup cost risk detected."
    }
} catch {
    Add-Warning "Unable to verify R2 backup cost guardrails: $($_.Exception.Message)"
}

Write-Section "Node Metrics"
try {
    $topNodeTable = kubectl top nodes
    if ($LASTEXITCODE -ne 0) {
        Add-Warning "kubectl top nodes failed."
    } else {
        $topNodeTable
        $controlPlaneNames = @($nodes.items |
            Where-Object { $_.metadata.labels.PSObject.Properties.Name -contains "node-role.kubernetes.io/control-plane" } |
            ForEach-Object { $_.metadata.name })

        foreach ($line in @($topNodeTable | Select-Object -Skip 1)) {
            $parts = @($line -split "\s+" | Where-Object { $_ })
            if ($parts.Count -lt 5) {
                continue
            }

            $nodeName = $parts[0]
            if ($controlPlaneNames -notcontains $nodeName) {
                continue
            }

            $memoryPercent = [int]($parts[4].TrimEnd("%"))
            if ($memoryPercent -ge 85) {
                Add-Warning "Control-plane node $nodeName memory usage is $memoryPercent%; review workload placement or VM memory before it reaches sustained pressure."
            }
        }
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

Write-Section "ArgoCD Dex"
try {
    kubectl -n argocd exec deploy/argocd-dex-server -- sh -c "nc -z -w 5 127.0.0.1 5556"
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "ArgoCD Dex pod is reachable by Kubernetes but is not listening on 5556."
    } else {
        Write-Ok "ArgoCD Dex is listening on 5556."
    }
} catch {
    Add-Failure "Unable to verify ArgoCD Dex listener on 5556: $($_.Exception.Message)"
}

Write-Section "Pods"
$pods = Invoke-KubectlJson @("get", "pods", "-A")
$badPods = @()
$runningNotReadyPods = @()
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

    if ($phase -eq "Running") {
        $ready = Get-ConditionStatus -Conditions $pod.status.conditions -Type "Ready"
        if ($ready -ne "True") {
            $runningNotReadyPods += [pscustomobject]@{
                Namespace = $pod.metadata.namespace
                Name      = $pod.metadata.name
                Ready     = $ready
                Node      = $pod.spec.nodeName
            }
        }
    }
}

if ($badPods.Count -gt 0) {
    $badPods | Format-Table -AutoSize
    Add-Failure "Found $($badPods.Count) pod(s) outside Running/Succeeded."
} else {
    Write-Ok "No pods outside Running/Succeeded."
}

if ($runningNotReadyPods.Count -gt 0) {
    $runningNotReadyPods | Format-Table -AutoSize
    Add-Failure "Found $($runningNotReadyPods.Count) Running pod(s) that are not Ready."
} else {
    Write-Ok "All Running pods report Ready=True."
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

Write-Section "Service Endpoints"
try {
    $services = Invoke-KubectlJson @("get", "services", "-A")
    $endpointSlices = Invoke-KubectlJson @("get", "endpointslices.discovery.k8s.io", "-A")
    $servicesWithoutEndpoints = @()

    foreach ($service in @($services.items)) {
        if ($service.spec.type -eq "ExternalName" -or -not $service.spec.selector) {
            continue
        }

        $serviceName = $service.metadata.name
        $namespace = $service.metadata.namespace
        $slices = @($endpointSlices.items | Where-Object {
            $_.metadata.namespace -eq $namespace -and
            $_.metadata.labels."kubernetes.io/service-name" -eq $serviceName
        })

        $readyEndpoints = 0
        foreach ($slice in $slices) {
            foreach ($endpoint in @($slice.endpoints)) {
                if ($endpoint.conditions.ready -ne $false) {
                    $readyEndpoints++
                }
            }
        }

        if ($readyEndpoints -eq 0) {
            $servicesWithoutEndpoints += [pscustomobject]@{
                Namespace = $namespace
                Service   = $serviceName
                Type      = $service.spec.type
            }
        }
    }

    if ($servicesWithoutEndpoints.Count -gt 0) {
        $servicesWithoutEndpoints | Sort-Object Namespace, Service | Format-Table -AutoSize
        Add-Warning "Found service(s) with selectors but no ready endpoints. Some may be intentionally idle, but app routes depending on them will fail."
    } else {
        Write-Ok "All selector-backed services have ready endpoints."
    }
} catch {
    Add-Warning "Unable to verify service endpoints: $($_.Exception.Message)"
}

Write-Section "Plex Semantic Health"
try {
    $plexPods = Invoke-KubectlJson @("get", "pods", "-n", "media", "-l", "app.kubernetes.io/name=plex")
    if (@($plexPods.items).Count -ne 1) {
        Add-Failure "Expected exactly one Plex pod, found $(@($plexPods.items).Count)."
    } else {
        $plexPod = $plexPods.items[0]
        $plexReady = Get-ConditionStatus -Conditions $plexPod.status.conditions -Type "Ready"
        [pscustomobject]@{
            Pod   = $plexPod.metadata.name
            Ready = $plexReady
            Node  = $plexPod.spec.nodeName
            IP    = $plexPod.status.podIP
        } | Format-Table -AutoSize

        if ($plexReady -ne "True") {
            Add-Failure "Plex pod is not Ready."
        }
    }

    $plexConfigPvc = Invoke-KubectlJson @("get", "pvc", "plex-config", "-n", "media")
    if ($plexConfigPvc.status.phase -ne "Bound") {
        Add-Failure "Plex config PVC is $($plexConfigPvc.status.phase), expected Bound."
    }

    $plexVolumeName = $plexConfigPvc.spec.volumeName
    if ($plexVolumeName) {
        try {
            $plexLonghornVolume = Invoke-KubectlJson @("get", "volumes.longhorn.io", $plexVolumeName, "-n", "longhorn-system")
            [pscustomobject]@{
                Volume     = $plexVolumeName
                State      = $plexLonghornVolume.status.state
                Robustness = $plexLonghornVolume.status.robustness
                Node       = $plexLonghornVolume.status.currentNodeID
            } | Format-Table -AutoSize

            if ($plexLonghornVolume.status.state -ne "attached") {
                Add-Failure "Plex config Longhorn volume is $($plexLonghornVolume.status.state), expected attached."
            } elseif ($plexLonghornVolume.status.robustness -ne "healthy") {
                Add-Warning "Plex config Longhorn volume robustness is $($plexLonghornVolume.status.robustness), expected healthy."
            }
        } catch {
            Add-Warning "Unable to verify Plex Longhorn volume ${plexVolumeName}: $($_.Exception.Message)"
        }
    }

    kubectl -n media exec deploy/plex -- sh -c 'curl -fsS --max-time 10 http://127.0.0.1:32400/identity | grep -q MediaContainer'
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "Plex /identity check failed from inside the pod."
    } else {
        Write-Ok "Plex /identity responds from inside the pod."
    }

    kubectl -n media exec deploy/plex -- sh -c 'dir="/config/Library/Application Support/Plex Media Server/Codecs"; [ ! -d "$dir" ] || ! find "$dir" -type f -name EasyAudioEncoder ! -perm -111 | grep -q .'
    if ($LASTEXITCODE -ne 0) {
        Add-Failure "Plex EasyAudioEncoder cache contains non-executable binaries; restart Plex after initContainer rollout or clear the codec cache."
    } else {
        Write-Ok "Plex EasyAudioEncoder cache has no non-executable binaries."
    }

    $plexDirectStatus = & curl.exe -sS -o NUL -w "%{http_code}" --max-time 15 "http://192.168.1.211:32400/identity" 2>$null
    if ($LASTEXITCODE -ne 0 -or [int]$plexDirectStatus -ne 200) {
        Add-Failure "Plex LAN direct identity endpoint returned '$plexDirectStatus', expected 200."
    } else {
        Write-Ok "Plex LAN direct identity endpoint returned 200."
    }

    $plexLocalStatus = Invoke-HttpStatus -HostName "plex.rosenvall.local" -Path "/identity"
    if ($plexLocalStatus -ne 200) {
        Add-Failure "plex.rosenvall.local/identity returned '$plexLocalStatus', expected 200."
    } else {
        Write-Ok "plex.rosenvall.local/identity returned 200."
    }
} catch {
    Add-Failure "Unable to verify Plex semantic health: $($_.Exception.Message)"
}

Write-Section "Public Route Reachability"
foreach ($check in $PublicRouteChecks) {
    $hostName = $check.Host
    $path = $check.Path
    $gatewayIP = $check.GatewayIP
    $expected = @($check.Expected)

    $publicStatus = Invoke-HttpStatus -HostName $hostName -Path $path
    $gatewayStatus = Invoke-HttpStatus -HostName $hostName -Path $path -GatewayIP $gatewayIP

    [pscustomobject]@{
        Host          = $hostName
        Path          = $path
        Cloudflare    = $publicStatus
        GatewayDirect = $gatewayStatus
    } | Format-Table -AutoSize

    $gatewayOk = $gatewayStatus -and ($expected -contains $gatewayStatus)
    $publicOk = $publicStatus -and ($expected -contains $publicStatus)

    if ($gatewayOk -and -not $publicOk) {
        Add-Failure "$hostName$path works through Cilium gateway ($gatewayStatus) but fails through Cloudflare ($publicStatus). Check Cloudflare Tunnel public hostname/origin settings."
    } elseif (-not $gatewayOk -and -not $publicOk) {
        Add-Failure "$hostName$path is not reachable through gateway or Cloudflare."
    } elseif (-not $gatewayOk) {
        Add-Failure "$hostName$path is reachable through Cloudflare but gateway-direct status is $gatewayStatus, expected one of $($expected -join ',')."
    } else {
        Write-Ok "$hostName$path returned expected status through Cloudflare and gateway-direct."
    }
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
