<#
.SYNOPSIS
    Clears the PodDisruptionBudgets that block a Talos node drain.

.DESCRIPTION
    Talos 1.14 cordons and drains a node before it upgrades. Two kinds of pod
    refuse eviction on this cluster and deadlock that drain:

      * CNPG instances. A single-instance cluster (authentik-postgresql) has a
        primary PDB with allowedDisruptions=0, so its pod can never be evicted.
        Two-instance clusters have the same PDB on whichever pod is primary.
      * longhorn-system/instance-manager-*. Longhorn keeps a PDB on it while a
        volume is still attached on the node - which stays true for as long as
        the CNPG pod above refuses to move. The two block each other.

    Deleting a pod is not an eviction, so it bypasses the PDB. With the node
    cordoned first, CNPG rebuilds the instance on another node and Longhorn
    releases the instance-manager on its own.

    Run this before scripts/upgrade-talos-node.ps1 for the three Longhorn
    storage workers (worker-01, worker-02, worker-03). Compute-only workers
    hold neither CNPG pods nor Longhorn replicas and need no preparation.

.PARAMETER NodeName
    Kubernetes node to prepare.

.PARAMETER TimeoutSeconds
    How long to wait for CNPG clusters to report healthy again.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$NodeName,

    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = "Stop"

if (-not $env:KUBECONFIG) {
    $env:KUBECONFIG = (Resolve-Path "./tofu/output/kubeconfig").Path
}

function Get-CnpgPodsOnNode([string]$Node) {
    $pods = kubectl get pods -A -l cnpg.io/podRole=instance --field-selector "spec.nodeName=$Node" -o json | ConvertFrom-Json
    return @($pods.items)
}

function Wait-CnpgHealthy([string]$Namespace, [string]$ClusterName, [int]$Timeout) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        $cluster = kubectl -n $Namespace get cluster.postgresql.cnpg.io $ClusterName -o json | ConvertFrom-Json
        $desired = $cluster.spec.instances
        $ready = $cluster.status.readyInstances
        if ($ready -eq $desired) {
            Write-Host "  $Namespace/$ClusterName ready ($ready/$desired)"
            return
        }
        Write-Host "  waiting for $Namespace/$ClusterName ($ready/$desired)"
        Start-Sleep -Seconds 10
    }
    throw "Timed out waiting for CNPG cluster $Namespace/$ClusterName to become healthy"
}

Write-Host "cordoning $NodeName"
kubectl cordon $NodeName | Out-Host

$cnpgPods = Get-CnpgPodsOnNode $NodeName
if ($cnpgPods.Count -eq 0) {
    Write-Host "no CNPG instances on $NodeName"
} else {
    $clusters = @{}
    foreach ($pod in $cnpgPods) {
        $ns = $pod.metadata.namespace
        $clusterName = $pod.metadata.labels."cnpg.io/cluster"
        $clusters["$ns/$clusterName"] = @{ Namespace = $ns; Name = $clusterName }
        Write-Host "deleting CNPG pod $ns/$($pod.metadata.name) (delete bypasses the primary PDB)"
        kubectl -n $ns delete pod $pod.metadata.name --wait=$false | Out-Host
    }

    foreach ($cluster in $clusters.Values) {
        Wait-CnpgHealthy -Namespace $cluster.Namespace -ClusterName $cluster.Name -Timeout $TimeoutSeconds
    }
}

# Longhorn refuses to release instance-manager while it holds the last healthy
# replica of a volume, so the node is only safe to drain once every volume is
# back to full redundancy.
Write-Host "checking Longhorn volume health"
$volumes = kubectl get volumes.longhorn.io -n longhorn-system -o json | ConvertFrom-Json
$degraded = @($volumes.items | Where-Object { $_.status.state -eq "attached" -and $_.status.robustness -ne "healthy" })
if ($degraded.Count -gt 0) {
    Write-Host "WARNING: $($degraded.Count) attached volume(s) are still degraded:"
    $degraded | ForEach-Object { Write-Host "  $($_.metadata.name) = $($_.status.robustness)" }
    throw "Refusing to prepare $NodeName while volumes are degraded - wait for Longhorn to finish rebuilding"
}

Write-Host "$NodeName is cordoned and free of drain blockers"
