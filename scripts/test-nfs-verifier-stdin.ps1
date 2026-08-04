$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-nfs-export.ps1")
if (-not (Get-Command Invoke-NfsProbeScript -ErrorAction SilentlyContinue)) {
    throw "Invoke-NfsProbeScript is missing."
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("nfs-stdin-fixture-" + [Guid]::NewGuid().ToString("n"))
$fakeKubectl = Join-Path $testRoot "kubectl.cmd"
$capturePath = Join-Path $testRoot "capture.txt"
New-Item -ItemType Directory -Path $testRoot | Out-Null
$percent = [char]37
$cmdLines = @(
    "@echo off",
    ("> `"" + $percent + "FAKE_KUBECTL_CAPTURE" + $percent + "`" echo ARGV:" + $percent + "*" + $percent),
    (">> `"" + $percent + "FAKE_KUBECTL_CAPTURE" + $percent + "`" echo STDIN"),
    ("more >> `"" + $percent + "FAKE_KUBECTL_CAPTURE" + $percent + "`""),
    "exit /b 0"
)
[IO.File]::WriteAllLines($fakeKubectl, $cmdLines, [Text.ASCIIEncoding]::new())

$probe = @'
set -eu
marker="/target/.nfs-write-check"
cleanup_marker() { rm -f -- "$marker"; }
trap cleanup_marker EXIT INT TERM
printf '%s\n' 'marker-value' > "$marker"
test "$(cat "$marker")" = 'marker-value'
'@

$priorPath = $env:PATH
$priorCapture = $env:FAKE_KUBECTL_CAPTURE
try {
    $env:PATH = $testRoot + ";" + $env:PATH
    $env:FAKE_KUBECTL_CAPTURE = $capturePath
    . (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")
    Invoke-PodShell -Namespace "immich" -PodName "fake-pod" -Script $probe | Out-Null
    $legacyCapture = (Get-Content -LiteralPath $capturePath -Raw).Replace("`r`n", "`n")
    if (-not $legacyCapture.Contains("ARGV:exec -n immich fake-pod -- sh -ec")) {
        throw "Legacy reproduction did not place the probe in native argv."
    }
    if ($legacyCapture.Substring($legacyCapture.IndexOf("STDIN`n") + 6).Trim()) {
        throw "Legacy reproduction unexpectedly used stdin."
    }

    Invoke-NfsProbeScript -Namespace "immich" -PodName "fake-pod" -Script $probe | Out-Null
    $capture = Get-Content -LiteralPath $capturePath -Raw
    $normalizedCapture = $capture.Replace("`r`n", "`n")
    $normalizedProbe = $probe.Replace("`r`n", "`n")
    if (-not $normalizedCapture.Contains("ARGV:exec -i -n immich fake-pod -- sh")) {
        throw "kubectl argv was not the expected simple stdin form.`n$capture"
    }
    $stdin = $normalizedCapture.Substring($normalizedCapture.IndexOf("STDIN`n") + 6).TrimEnd("`r", "`n")
    if ($stdin -ne $normalizedProbe.TrimEnd("`r", "`n")) {
        throw "Probe stdin was not preserved.`nEXPECTED:`n$normalizedProbe`nACTUAL:`n$stdin"
    }
}
finally {
    $env:PATH = $priorPath
    $env:FAKE_KUBECTL_CAPTURE = $priorCapture
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] NFS verifier streams the complete probe through kubectl stdin." -ForegroundColor Green
