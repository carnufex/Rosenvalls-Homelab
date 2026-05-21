param(
    [string]$Namespace = "media",
    [string]$SonarrUrl = "https://sonarr.rosenvall.local",
    [string]$RadarrUrl = "https://radarr.rosenvall.local",
    [string]$DelugeHost = "deluge.media.svc.cluster.local",
    [int]$DelugePort = 8112,
    [string]$OldJackettBase = "http://192.168.1.112:9117/",
    [string]$NewJackettBase = "http://jackett.media.svc.cluster.local:9117/",
    [switch]$Test
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")

Set-HomelabKubeconfig
Assert-Command -Name "curl.exe"

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-ArrApiKey {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DeploymentName
    )

    $script = "sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml"
    $output = & kubectl @("-n", $Namespace, "exec", "deploy/$DeploymentName", "--", "sh", "-lc", $script) 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read API key from '$Namespace/$DeploymentName'.`n$($output | Out-String)"
    }

    $apiKey = ($output | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        throw "API key was empty for '$Namespace/$DeploymentName'."
    }

    return $apiKey
}

function Invoke-ArrApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,
        [Parameter(Mandatory = $true)]
        [string]$ApiKey,
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [object]$Body,
        [switch]$ForceSave
    )

    $query = "apikey=$([Uri]::EscapeDataString($ApiKey))"
    if ($ForceSave) {
        $query += "&forceSave=true"
    }

    $methodName = $Method.ToUpperInvariant()
    $uri = "$BaseUrl/api/v3/$Path`?$query"
    $responsePath = Join-Path ([System.IO.Path]::GetTempPath()) ("arr-api-response-$([System.Guid]::NewGuid().ToString("n")).json")
    $bodyPath = $null

    try {
        $curlArgs = @(
            "-k",
            "-sS",
            "-o", $responsePath,
            "-w", "%{http_code}",
            "-X", $methodName,
            "-H", "Accept: application/json"
        )

        if ($PSBoundParameters.ContainsKey("Body")) {
            $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("arr-api-body-$([System.Guid]::NewGuid().ToString("n")).json")
            [System.IO.File]::WriteAllText($bodyPath, ($Body | ConvertTo-Json -Depth 100 -Compress), $Utf8NoBom)
            $curlArgs += @("-H", "Content-Type: application/json", "--data-binary", "@$bodyPath")
        }

        $curlArgs += $uri
        $statusText = (& curl.exe @curlArgs 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed for $methodName $Path.`n$statusText"
        }

        $responseText = ""
        if (Test-Path -LiteralPath $responsePath) {
            $responseText = [System.IO.File]::ReadAllText($responsePath)
        }

        $statusCode = [int]$statusText
        if ($statusCode -ge 400) {
            throw "$methodName $Path returned HTTP $statusCode.`n$responseText"
        }

        if ([string]::IsNullOrWhiteSpace($responseText)) {
            return $null
        }

        return ($responseText | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $responsePath -Force -ErrorAction SilentlyContinue
        if ($bodyPath) {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Set-ArrField {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [object]$Value
    )

    $changed = $false
    foreach ($field in @($Item.fields)) {
        if ($field.name -ne $Name) {
            continue
        }

        if ($null -eq $Value) {
            if ($null -ne $field.value) {
                $field.value = $null
                $changed = $true
            }
        }
        elseif ($field.value -ne $Value) {
            $field.value = $Value
            $changed = $true
        }
    }

    return $changed
}

function Get-SafeFields {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item
    )

    $fields = [ordered]@{}
    foreach ($field in @($Item.fields)) {
        if (@("host", "port", "useSsl", "baseUrl", "apiPath", "tvCategory", "movieCategory") -contains $field.name) {
            $fields[$field.name] = $field.value
        }
    }

    return [pscustomobject]@{
        id = $Item.id
        name = $Item.name
        implementation = $Item.implementation
        fields = $fields
    }
}

function Update-ArrApp {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$BaseUrl
    )

    $apiKey = Get-ArrApiKey -DeploymentName $Name

    Write-Host "Updating $Name endpoints..." -ForegroundColor Cyan

    $downloadClients = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Get -Path "downloadclient"
    foreach ($client in @($downloadClients)) {
        $changed = $false
        if ($client.implementation -eq "Deluge") {
            $changed = (Set-ArrField -Item $client -Name "host" -Value $DelugeHost) -or $changed
            $changed = (Set-ArrField -Item $client -Name "port" -Value $DelugePort) -or $changed
            $changed = (Set-ArrField -Item $client -Name "useSsl" -Value $false) -or $changed
        }

        if ($changed) {
            $client = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Put -Path "downloadclient/$($client.id)" -Body $client -ForceSave
            Write-Host "  updated downloadclient: $($client.name) -> $DelugeHost`:$DelugePort"
        }
        else {
            Write-Host "  kept downloadclient: $($client.name)"
        }

        Get-SafeFields -Item $client | ConvertTo-Json -Depth 10
    }

    $indexers = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Get -Path "indexer"
    foreach ($indexer in @($indexers)) {
        $changed = $false
        foreach ($field in @($indexer.fields)) {
            if ($field.name -eq "baseUrl" -and $field.value -is [string]) {
                $newValue = $field.value.Replace($OldJackettBase, $NewJackettBase).Replace($OldJackettBase.Replace("http://", "https://"), $NewJackettBase)
                if ($newValue -ne $field.value) {
                    $field.value = $newValue
                    $changed = $true
                }
            }

            if ($field.name -eq "seedCriteria.seedRatio" -and $field.value -eq 0) {
                $field.value = $null
                $changed = $true
            }
        }

        if ($changed) {
            $indexer = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Put -Path "indexer/$($indexer.id)" -Body $indexer -ForceSave
            Write-Host "  updated indexer: $($indexer.name) -> $NewJackettBase"
        }
        else {
            Write-Host "  kept indexer: $($indexer.name)"
        }

        Get-SafeFields -Item $indexer | ConvertTo-Json -Depth 10
    }

    if ($Test) {
        foreach ($kind in @("downloadclient", "indexer")) {
            $items = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Get -Path $kind
            foreach ($item in @($items)) {
                try {
                    $null = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Post -Path "$kind/test" -Body $item
                    Write-Host "  test ok: $kind/$($item.name)" -ForegroundColor Green
                }
                catch {
                    Write-Warning "  test failed: $kind/$($item.name) - $($_.Exception.Message)"
                }
            }
        }

        $health = Invoke-ArrApi -BaseUrl $BaseUrl -ApiKey $apiKey -Method Get -Path "health"
        if (@($health).Count -eq 0) {
            Write-Host "  health ok" -ForegroundColor Green
        }
        else {
            foreach ($entry in @($health)) {
                Write-Warning "  health: $($entry.message)"
            }
        }
    }
}

Update-ArrApp -Name "sonarr" -BaseUrl $SonarrUrl
Update-ArrApp -Name "radarr" -BaseUrl $RadarrUrl
