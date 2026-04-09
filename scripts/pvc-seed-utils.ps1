$ErrorActionPreference = "Stop"

function Get-HomelabRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Set-HomelabKubeconfig {
    if ($env:KUBECONFIG) {
        if (-not (Test-Path -LiteralPath $env:KUBECONFIG)) {
            throw "KUBECONFIG is set to '$env:KUBECONFIG' but the file does not exist."
        }

        return
    }

    $defaultKubeconfig = Join-Path (Get-HomelabRepoRoot) "tofu/output/kubeconfig"
    if (-not (Test-Path -LiteralPath $defaultKubeconfig)) {
        throw "KUBECONFIG is not set and the default kubeconfig was not found at '$defaultKubeconfig'."
    }

    $env:KUBECONFIG = $defaultKubeconfig
}

function Assert-Kubeconfig {
    Set-HomelabKubeconfig
}

function Assert-Command {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-Kubectl {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Args
    )

    Assert-Command -Name "kubectl"
    $output = & kubectl @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $rendered = ($output | Out-String).Trim()
        throw "kubectl $($Args -join ' ') failed.`n$rendered"
    }

    return $output
}

function New-TemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1}" -f $Prefix, [System.Guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Copy-Tree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Source path '$SourcePath' does not exist."
    }

    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationPath | Out-Null
    }

    Get-ChildItem -LiteralPath $SourcePath -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $DestinationPath -Recurse -Force
    }
}

function New-PvcHelperPod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$ClaimName
    )

    Set-HomelabKubeconfig

    $podName = "seed-$($ClaimName.ToLowerInvariant())-" + ([System.Guid]::NewGuid().ToString("n").Substring(0, 6))
    $manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "$podName.yaml"

    @"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
    - name: seed
      image: busybox:1.36.1
      command:
        - sh
        - -c
        - sleep 3600
      volumeMounts:
        - name: target
          mountPath: /target
  volumes:
    - name: target
      persistentVolumeClaim:
        claimName: $ClaimName
"@ | Set-Content -Path $manifestPath -Encoding utf8

    try {
        Invoke-Kubectl apply -f $manifestPath | Out-Null
        Invoke-Kubectl wait --for=condition=Ready "pod/$podName" -n $Namespace --timeout=120s | Out-Null
        return $podName
    }
    finally {
        Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-PvcHelperPod {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$PodName
    )

    $null = & kubectl delete pod $PodName -n $Namespace --ignore-not-found=true --wait=true 2>$null
}

function Invoke-PodShell {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$PodName,
        [Parameter(Mandatory = $true)]
        [string]$Script,
        [string]$Container
    )

    $args = @("exec", "-n", $Namespace)
    if ($Container) {
        $args += @("-c", $Container)
    }

    $args += @($PodName, "--", "sh", "-ec", $Script)
    return (Invoke-Kubectl @args)
}

function Sync-DirectoryToPvc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$ClaimName,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [string]$Owner = "1000:1000",
        [string[]]$CleanupRelativePaths = @()
    )

    Set-HomelabKubeconfig

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        throw "Source path '$SourcePath' does not exist."
    }

    $podName = New-PvcHelperPod -Namespace $Namespace -ClaimName $ClaimName
    $sourceLeaf = Split-Path -Path (Resolve-Path -LiteralPath $SourcePath) -Leaf
    $remoteStage = "/seed/$sourceLeaf"

    try {
        Invoke-PodShell -Namespace $Namespace -PodName $podName -Script 'mkdir -p /seed /target && find /target -mindepth 1 -maxdepth 1 -exec rm -rf {} +'

        $copyResult = & kubectl cp $SourcePath "${Namespace}/${podName}:/seed"
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl cp to $Namespace/$podName failed.`n$($copyResult | Out-String)"
        }

        Invoke-PodShell -Namespace $Namespace -PodName $podName -Script "cp -a $remoteStage/. /target/"

        foreach ($relativePath in $CleanupRelativePaths) {
            Invoke-PodShell -Namespace $Namespace -PodName $podName -Script "rm -f /target/$relativePath"
        }

        Invoke-PodShell -Namespace $Namespace -PodName $podName -Script "chown -R $Owner /target"
        Write-Host "[OK] Seeded $Namespace/$ClaimName from '$SourcePath'" -ForegroundColor Green
    }
    finally {
        Remove-PvcHelperPod -Namespace $Namespace -PodName $podName
    }
}

function Seed-DirectoryToPvc {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,
        [Parameter(Mandatory = $true)]
        [string]$PvcName,
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [string]$MountPath = "/target"
    )

    Sync-DirectoryToPvc -Namespace $Namespace -ClaimName $PvcName -SourcePath $SourcePath
}
