$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    throw "KUBECONFIG is not set."
}

function Assert-NodesReady {
    $nodes = kubectl get nodes -o json | ConvertFrom-Json
    foreach ($node in $nodes.items) {
        $ready = ($node.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
        if ($ready -ne "True") {
            throw "Node '$($node.metadata.name)' is not Ready."
        }
    }
    Write-Host "[OK] All nodes Ready" -ForegroundColor Green
}

function Assert-ClusterSecretStoreReady {
    $store = kubectl get clustersecretstore bitwarden-secretsmanager -o json | ConvertFrom-Json
    $ready = ($store.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
    if ($ready -ne "True") {
        throw "ClusterSecretStore bitwarden-secretsmanager is not Ready."
    }
    Write-Host "[OK] ClusterSecretStore bitwarden-secretsmanager Ready" -ForegroundColor Green
}

function Assert-ExternalSecretsReady {
    $items = (kubectl get externalsecret -A -o json | ConvertFrom-Json).items
    $notReady = @()
    foreach ($item in $items) {
        $ready = ($item.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
        if ($ready -ne "True") {
            $notReady += "$($item.metadata.namespace)/$($item.metadata.name)"
        }
    }

    if ($notReady.Count -gt 0) {
        throw "ExternalSecrets not Ready: $($notReady -join ', ')"
    }

    Write-Host "[OK] All ExternalSecrets Ready" -ForegroundColor Green
}

function Assert-CertificateReady {
    $cert = kubectl get certificate cert-wildcard -n gateway -o json | ConvertFrom-Json
    $ready = ($cert.status.conditions | Where-Object { $_.type -eq "Ready" } | Select-Object -First 1).status
    if ($ready -ne "True") {
        throw "gateway/cert-wildcard is not Ready."
    }
    Write-Host "[OK] gateway/cert-wildcard Ready" -ForegroundColor Green
}

function Assert-GatewayExternalResolved {
    $gw = kubectl get gateway external -n gateway -o json | ConvertFrom-Json
    $https = $gw.status.listeners | Where-Object { $_.name -eq "https" }
    if (-not $https) {
        throw "gateway/external has no HTTPS listener status."
    }

    $programmed = ($https.conditions | Where-Object { $_.type -eq "Programmed" } | Select-Object -First 1).status
    $resolved = ($https.conditions | Where-Object { $_.type -eq "ResolvedRefs" } | Select-Object -First 1).status

    if ($programmed -ne "True" -or $resolved -ne "True") {
        throw "gateway/external HTTPS listener is not ready (Programmed=$programmed, ResolvedRefs=$resolved)."
    }

    Write-Host "[OK] gateway/external HTTPS listener ready" -ForegroundColor Green
}

function Assert-HttpRoutesAccepted {
    $routes = (kubectl get httproute -A -o json | ConvertFrom-Json).items
    $notAccepted = @()

    foreach ($route in $routes) {
        $parents = $route.status.parents
        if (-not $parents) {
            $notAccepted += "$($route.metadata.namespace)/$($route.metadata.name)"
            continue
        }

        $hasAccepted = $false
        foreach ($parent in $parents) {
            $accepted = ($parent.conditions | Where-Object { $_.type -eq "Accepted" } | Select-Object -First 1).status
            if ($accepted -eq "True") {
                $hasAccepted = $true
                break
            }
        }

        if (-not $hasAccepted) {
            $notAccepted += "$($route.metadata.namespace)/$($route.metadata.name)"
        }
    }

    if ($notAccepted.Count -gt 0) {
        throw "HTTPRoutes without accepted parent: $($notAccepted -join ', ')"
    }

    Write-Host "[OK] All HTTPRoutes accepted" -ForegroundColor Green
}

Assert-NodesReady
Assert-ClusterSecretStoreReady
Assert-ExternalSecretsReady
Assert-CertificateReady
Assert-GatewayExternalResolved
Assert-HttpRoutesAccepted

Write-Host "Preflight checks passed." -ForegroundColor Green
