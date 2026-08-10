param(
    [string]$Namespace = "media",
    [switch]$RadarrOnly,
    [switch]$SonarrOnly,
    [switch]$DeleteFiles
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")
Set-HomelabKubeconfig

function Invoke-KubectlChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $output = & kubectl @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Args -join ' ') failed.`n$($output | Out-String)"
    }

    return $output
}

function Get-ArrApiKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Deployment
    )

    $script = "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
    $key = (Invoke-KubectlChecked -Args @("-n", $Namespace, "exec", "deploy/$Deployment", "--", "sh", "-lc", $script) | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "Could not read API key from $Namespace/$Deployment."
    }

    return $key
}

function Invoke-ArrJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Deployment,
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [string]$Method = "GET"
    )

    $args = @("-n", $Namespace, "exec", "deploy/$Deployment", "--", "curl", "-fsS", "-H", "X-Api-Key: $ApiKey")
    if ($Method -ne "GET") {
        $args += @("-X", $Method)
    }
    $args += $Url

    $output = Invoke-KubectlChecked -Args $args
    $text = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text | ConvertFrom-Json
}

function ConvertTo-Array {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return , @()
    }

    return , @($Value)
}

function Clear-ArrLibrary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Deployment,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$ListPath,
        [Parameter(Mandatory = $true)]
        [string]$DeletePathTemplate
    )

    $apiKey = Get-ArrApiKey -Deployment $Deployment
    $items = ConvertTo-Array (Invoke-ArrJson -Deployment $Deployment -ApiKey $apiKey -Url "$BaseUrl$ListPath")
    Write-Host "$Name library items before clear: $($items.Count)"

    foreach ($item in $items) {
        $deletePath = $DeletePathTemplate.Replace("{id}", [string]$item.id)
        $null = Invoke-ArrJson -Deployment $Deployment -ApiKey $apiKey -Method "DELETE" -Url "$BaseUrl$deletePath"
    }

    $itemsAfter = ConvertTo-Array (Invoke-ArrJson -Deployment $Deployment -ApiKey $apiKey -Url "$BaseUrl$ListPath")
    $indexers = ConvertTo-Array (Invoke-ArrJson -Deployment $Deployment -ApiKey $apiKey -Url "$BaseUrl/api/v3/indexer")
    $downloadClients = ConvertTo-Array (Invoke-ArrJson -Deployment $Deployment -ApiKey $apiKey -Url "$BaseUrl/api/v3/downloadclient")

    Write-Host "$Name library items after clear: $($itemsAfter.Count)"
    Write-Host "$Name indexers preserved: $($indexers.Count)"
    Write-Host "$Name download clients preserved: $($downloadClients.Count)"

    if ($itemsAfter.Count -ne 0) {
        throw "$Name still has $($itemsAfter.Count) library items after clear."
    }
}

if ($RadarrOnly -and $SonarrOnly) {
    throw "-RadarrOnly and -SonarrOnly are mutually exclusive."
}

$deleteFilesValue = $DeleteFiles.IsPresent.ToString().ToLowerInvariant()

if (-not $SonarrOnly) {
    Clear-ArrLibrary `
        -Name "radarr" `
        -Deployment "radarr" `
        -BaseUrl "http://127.0.0.1:7878" `
        -ListPath "/api/v3/movie" `
        -DeletePathTemplate "/api/v3/movie/{id}?deleteFiles=$deleteFilesValue&addImportExclusion=false"
}

if (-not $RadarrOnly) {
    Clear-ArrLibrary `
        -Name "sonarr" `
        -Deployment "sonarr" `
        -BaseUrl "http://127.0.0.1:8989" `
        -ListPath "/api/v3/series" `
        -DeletePathTemplate "/api/v3/series/{id}?deleteFiles=$deleteFilesValue&addImportListExclusion=false"
}
