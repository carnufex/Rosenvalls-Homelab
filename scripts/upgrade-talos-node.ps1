param(
    [Parameter(Mandatory = $true)]
    [string]$NodeName,

    [Parameter(Mandatory = $true)]
    [string]$NodeIp,

    [string]$Endpoint = "192.168.1.201",
    [string]$TalosctlPath = "",
    [string]$Schematic = "53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83",
    [string[]]$Versions = @("v1.9.6", "v1.10.9", "v1.11.6", "v1.12.11"),
    [int]$StabilizeAttempts = 90
)

$ErrorActionPreference = "Continue"
$Versions = @($Versions | ForEach-Object { $_ -split "," } | Where-Object { $_ })

if (-not $env:KUBECONFIG) {
    $env:KUBECONFIG = (Resolve-Path "./tofu/output/kubeconfig").Path
}

if (-not $env:TALOSCONFIG) {
    $env:TALOSCONFIG = (Resolve-Path "./tofu/output/talosconfig").Path
}

if (-not $TalosctlPath) {
    $candidate = Join-Path $env:TEMP "talosctl-v1.12.11\talosctl.exe"
    if (Test-Path -LiteralPath $candidate) {
        $TalosctlPath = $candidate
    } else {
        $TalosctlPath = "talosctl"
    }
}

function Fail([string]$Message) {
    throw $Message
}

function Remove-StaleDaemonPods([string]$Name) {
    $allPods = @(kubectl get pods -A -o json | ConvertFrom-Json | ForEach-Object { $_.items })
    $stalePods = @(
        $allPods | Where-Object {
            (($_.spec.nodeName -eq $Name) -or (-not $_.spec.nodeName -and $_.metadata.namespace -eq "kube-system" -and $_.metadata.name -like "cilium-envoy-*")) -and (
                $_.metadata.deletionTimestamp -or
                $_.status.phase -eq "Failed" -or
                $_.status.phase -eq "Unknown" -or
                (@($_.status.containerStatuses + $_.status.initContainerStatuses | Where-Object { $_.state.terminated.reason -eq "ContainerStatusUnknown" }).Count -gt 0) -or
                ($_.metadata.namespace -eq "longhorn-system" -and ($_.metadata.name -like "engine-image-*" -or $_.metadata.name -like "longhorn-manager-*") -and $_.status.phase -eq "Succeeded")
            )
        }
    )

    foreach ($pod in $stalePods) {
        Write-Host "delete stale $($pod.metadata.namespace)/$($pod.metadata.name) phase=$($pod.status.phase) node=$($pod.spec.nodeName)"
        kubectl -n $pod.metadata.namespace delete pod $pod.metadata.name --force --grace-period=0 --ignore-not-found=true | Out-Host
    }
}

function Wait-NodeStable([string]$Name) {
    for ($i = 0; $i -lt $StabilizeAttempts; $i++) {
        Remove-StaleDaemonPods $Name

        $nodeReady = (kubectl get node $Name -o json | ConvertFrom-Json).status.conditions | Where-Object { $_.type -eq "Ready" }
        $clusterBad = @(kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o json | ConvertFrom-Json | ForEach-Object { $_.items })
        $targetPods = @(
            kubectl get pods -A -o json |
                ConvertFrom-Json |
                ForEach-Object { $_.items } |
                Where-Object { $_.spec.nodeName -eq $Name -and $_.status.phase -ne "Succeeded" }
        )
        $targetBad = @(
            $targetPods | Where-Object {
                $_.metadata.deletionTimestamp -or
                $_.status.phase -ne "Running" -or
                (@($_.status.containerStatuses | Where-Object { $_.ready -eq $false }).Count -gt 0)
            }
        )

        if ($nodeReady.status -eq "True" -and $clusterBad.Count -eq 0 -and $targetBad.Count -eq 0) {
            Write-Host "stabilized $Name"
            return
        }

        if (($i % 6) -eq 0) {
            Write-Host "waiting $Name nodeReady=$($nodeReady.status) clusterBad=$($clusterBad.Count) targetBad=$($targetBad.Count)"
        }

        Start-Sleep -Seconds 10
    }

    Fail "Timed out waiting for $Name to stabilize"
}

foreach ($version in $Versions) {
    $image = "factory.talos.dev/nocloud-installer/$Schematic`:$version"
    Write-Host "upgrade $NodeName to $version"

    $upgradeOutput = & $TalosctlPath --nodes $NodeIp --endpoints $Endpoint upgrade --image $image --reboot-mode=powercycle --timeout=30m --wait 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $upgradeOutput | Select-Object -Last 80 | Out-Host
        Fail "talos upgrade failed for $NodeName $version exit=$exitCode"
    }

    Wait-NodeStable $NodeName
    $osImage = (kubectl get node $NodeName -o json | ConvertFrom-Json).status.nodeInfo.osImage
    Write-Host "$NodeName ready on $osImage"
}

& $TalosctlPath --nodes $NodeIp --endpoints $Endpoint version | Select-String -Pattern "Tag:|NODE:"
& $TalosctlPath --nodes $NodeIp --endpoints $Endpoint get extensions
