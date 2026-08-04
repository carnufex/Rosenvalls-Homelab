$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "verify-nfs-export.ps1")
if (-not (Get-Command Invoke-NfsProbeScript -ErrorAction SilentlyContinue)) {
    throw "Invoke-NfsProbeScript is missing."
}

function Assert-ByteArrayEqual {
    param(
        [byte[]]$Expected,
        [byte[]]$Actual
    )

    if ($Expected.Length -ne $Actual.Length) {
        throw "Probe stdin byte length differed. Expected $($Expected.Length), got $($Actual.Length)."
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            throw "Probe stdin byte $index differed. Expected $($Expected[$index]), got $($Actual[$index])."
        }
    }
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("nfs-stdin-fixture-" + [Guid]::NewGuid().ToString("n"))
$fakeKubectl = Join-Path $testRoot "kubectl.exe"
$capturePath = Join-Path $testRoot "capture.txt"
$stdinCapturePath = Join-Path $testRoot "stdin.bin"
New-Item -ItemType Directory -Path $testRoot | Out-Null
$fakeSource = @'
using System;
using System.IO;
public static class FakeKubectl {
    public static int Main(string[] args) {
        File.WriteAllText(Environment.GetEnvironmentVariable("FAKE_KUBECTL_CAPTURE"), "ARGV:" + string.Join(" ", args));
        using (Stream input = Console.OpenStandardInput())
        using (FileStream output = File.Create(Environment.GetEnvironmentVariable("FAKE_STDIN_CAPTURE"))) {
            input.CopyTo(output);
        }
        Console.Out.Write(Environment.GetEnvironmentVariable("FAKE_KUBECTL_STDOUT"));
        Console.Error.Write(Environment.GetEnvironmentVariable("FAKE_KUBECTL_STDERR"));
        int exitCode;
        return int.TryParse(Environment.GetEnvironmentVariable("FAKE_KUBECTL_EXIT_CODE"), out exitCode) ? exitCode : 0;
    }
}
'@
Add-Type -TypeDefinition $fakeSource -Language CSharp -OutputAssembly $fakeKubectl -OutputType ConsoleApplication

$legacyProbe = "set -eu`nprintf '%s\n' 'legacy'`n"
$mixedProbe = "set -eu`r`nprintf '%s\n' 'räksmörgås'`rprintf '%s\n' 'slut'`r`n"
$normalizedProbe = "set -eu`nprintf '%s\n' 'räksmörgås'`nprintf '%s\n' 'slut'`n"
$utf8NoBom = [Text.UTF8Encoding]::new($false)
$expectedStdinBytes = $utf8NoBom.GetBytes($normalizedProbe)

$priorPath = $env:PATH
$priorCapture = $env:FAKE_KUBECTL_CAPTURE
$priorStdinCapture = $env:FAKE_STDIN_CAPTURE
$priorStdout = $env:FAKE_KUBECTL_STDOUT
$priorStderr = $env:FAKE_KUBECTL_STDERR
$priorExitCode = $env:FAKE_KUBECTL_EXIT_CODE
try {
    $env:PATH = $testRoot + ";" + $env:PATH
    $env:FAKE_KUBECTL_CAPTURE = $capturePath
    $env:FAKE_STDIN_CAPTURE = $stdinCapturePath
    $env:FAKE_KUBECTL_STDOUT = ""
    $env:FAKE_KUBECTL_STDERR = ""
    $env:FAKE_KUBECTL_EXIT_CODE = "0"

    . (Join-Path $PSScriptRoot "pvc-seed-utils.ps1")
    Invoke-PodShell -Namespace "immich" -PodName "fake-pod" -Script $legacyProbe | Out-Null
    $legacyCapture = Get-Content -LiteralPath $capturePath -Raw
    if (-not $legacyCapture.Contains("ARGV:exec -n immich fake-pod -- sh -ec")) {
        throw "Legacy reproduction did not place the probe in native argv."
    }
    if ([IO.File]::ReadAllBytes($stdinCapturePath).Length -ne 0) {
        throw "Legacy reproduction unexpectedly used stdin."
    }

    $env:FAKE_KUBECTL_STDOUT = "stdout-success`n"
    $env:FAKE_KUBECTL_STDERR = "stderr-success`n"
    $successOutput = Invoke-NfsProbeScript -Namespace "immich" -PodName "fake-pod" -Script $mixedProbe
    if ($successOutput -ne "stdout-success`nstderr-success`n") {
        throw "Successful probe did not retain both output streams. ACTUAL: $successOutput"
    }

    $capture = Get-Content -LiteralPath $capturePath -Raw
    if ($capture -ne "ARGV:exec -i -n immich fake-pod -- sh") {
        throw "kubectl argv was not the expected simple stdin form.`n$capture"
    }
    Assert-ByteArrayEqual -Expected $expectedStdinBytes -Actual ([IO.File]::ReadAllBytes($stdinCapturePath))

    $env:FAKE_KUBECTL_STDOUT = "stdout-failure`n"
    $env:FAKE_KUBECTL_STDERR = "stderr-failure`n"
    $env:FAKE_KUBECTL_EXIT_CODE = "23"
    $failure = $null
    try {
        Invoke-NfsProbeScript -Namespace "immich" -PodName "fake-pod" -Script $mixedProbe | Out-Null
    }
    catch {
        $failure = $_
    }
    if (-not $failure) {
        throw "Nonzero kubectl exit did not throw."
    }
    $failureMessage = $failure.Exception.Message
    foreach ($expectedFragment in @("stdout-failure", "stderr-failure", "23")) {
        if (-not $failureMessage.Contains($expectedFragment)) {
            throw "Nonzero diagnostic omitted '$expectedFragment'. ACTUAL: $failureMessage"
        }
    }
}
finally {
    $env:PATH = $priorPath
    $env:FAKE_KUBECTL_CAPTURE = $priorCapture
    $env:FAKE_STDIN_CAPTURE = $priorStdinCapture
    $env:FAKE_KUBECTL_STDOUT = $priorStdout
    $env:FAKE_KUBECTL_STDERR = $priorStderr
    $env:FAKE_KUBECTL_EXIT_CODE = $priorExitCode
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "[OK] NFS verifier preserves exact stdin bytes and combined process diagnostics." -ForegroundColor Green
