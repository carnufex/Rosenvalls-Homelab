$ErrorActionPreference = "Stop"

$gitBash = @(
    (Join-Path $env:ProgramFiles "Git\bin\bash.exe"),
    (Join-Path ((Get-Item -LiteralPath 'env:ProgramFiles(x86)' -ErrorAction SilentlyContinue).Value) "Git\bin\bash.exe")
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
if (-not $gitBash) {
    Write-Warning "Git Bash is unavailable; production guest fixture tests were skipped."
    exit 0
}

$bootstrap = Get-Content -LiteralPath (Join-Path $PSScriptRoot "bootstrap-nfs-01.ps1") -Raw
$verifierPath = Join-Path $PSScriptRoot "verify-nfs-export.ps1"
$verifier = Get-Content -LiteralPath $verifierPath -Raw
. $verifierPath
$payloadMatch = [regex]::Match($bootstrap, '(?s)\$guestPayload = @''\r?\n(.*?)\r?\n''@')
if (-not $payloadMatch.Success) { throw "Unable to extract the production guest payload." }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("nfs-production-fixture-" + [Guid]::NewGuid().ToString("n"))
$payloadPath = Join-Path $testRoot "guest.sh"
$driverPath = Join-Path $testRoot "driver.sh"
$markerPath = Join-Path $testRoot "marker"
$markerPayloadPath = Join-Path $testRoot "marker-trap.sh"
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
    $nativeTarget = Join-Path $testRoot "native-link-target"
    $nativeLink = Join-Path $testRoot "native-link"
    New-Item -ItemType Directory -Path $nativeTarget | Out-Null
    try {
        New-Item -ItemType SymbolicLink -Path $nativeLink -Target $nativeTarget | Out-Null
    }
    catch {
        Write-Warning "Native symlink fixture is unavailable; Git Bash will explicitly skip that platform-specific check."
    }
    foreach ($case in @(
        @{ Parameters = @{ Namespace = "Invalid_Name"; Server = "192.168.1.231"; Path = "/srv/nfs/immich" }; Message = "Namespace must be a DNS-1123 label." },
        @{ Parameters = @{ Namespace = "immich"; Server = "server;injection"; Path = "/srv/nfs/immich" }; Message = "Server must be a safe IPv4 address or hostname." },
        @{ Parameters = @{ Namespace = "immich"; Server = "192.168.1.231"; Path = "/srv//nfs" }; Message = "Path must be a canonical absolute component path." }
    )) {
        try {
            $validationParameters = $case.Parameters
            Assert-NfsExportParameters @validationParameters
            throw "Verifier accepted invalid input."
        }
        catch {
            if ($_.Exception.Message -ne $case.Message) { throw }
        }
    }
    foreach ($badIp in @("1", "127.1", "0x7f000001")) {
        if (Test-StrictIPv4 $badIp -or (Test-SafeNfsServer $badIp)) { throw "Verifier accepted noncanonical IPv4: $badIp" }
        try { & (Join-Path $PSScriptRoot "bootstrap-nfs-01.ps1") -VmIp $badIp; throw "Bootstrap accepted noncanonical IPv4." }
        catch { if ($_.Exception.Message -ne "VmIp must be an IPv4 address.") { throw } }
    }
    if (-not (Test-StrictIPv4 "192.168.1.231")) { throw "Verifier rejected valid IPv4." }
    try { & (Join-Path $PSScriptRoot "bootstrap-nfs-01.ps1") -AllowedClients @(); throw "Bootstrap accepted empty AllowedClients." }
    catch { if ($_.Exception.Message -ne "AllowedClients must not be empty.") { throw } }

    $markerMatch = [regex]::Match($verifier, '(?s)Invoke-NfsProbeScript .*? -Script @"\r?\n(.*?)\r?\n"@')
    if (-not $markerMatch.Success) { throw "Unable to extract verifier marker payload." }
    $markerPayload = $markerMatch.Groups[1].Value
    $markerPayload = $markerPayload.Replace(([string][char]96 + '$'), '$')
    $markerPayload = $markerPayload.Replace('marker="/target/$markerName"', 'marker="$TEST_MARKER"')
    $markerPayload = $markerPayload.Replace('$markerValue', 'marker-value').Replace('df -h /target', 'false')
    [IO.File]::WriteAllText($markerPayloadPath, $markerPayload.Replace([Environment]::NewLine, [string][char]10), [Text.UTF8Encoding]::new($false))
    $priorMarker = $env:TEST_MARKER
    try {
        $env:TEST_MARKER = $markerPath
        & $gitBash $markerPayloadPath
        if ($LASTEXITCODE -eq 0 -or (Test-Path -LiteralPath $markerPath)) {
            throw "Verifier marker EXIT trap did not remove the marker on failure."
        }
    }
    finally {
        $env:TEST_MARKER = $priorMarker
    }

    $payload = $payloadMatch.Groups[1].Value
    $payload = $payload.Replace('export_path="__EXPORT_PATH__"', 'export_path="$TEST_EXPORT_PATH"')
    $payload = $payload.Replace("__EXPECTED_SERIAL__", "NFS01DATA")
    $payload = $payload.Replace("__ALLOWED_CLIENTS__", "192.168.1.211(rw,sync,no_subtree_check,all_squash,anonuid=1000,anongid=1000)")
    $payload = $payload.Replace('/run/lock/nfs-01-bootstrap.lock', '$TEST_ROOT/nfs-01-bootstrap.lock')
    $payload = $payload.Replace('/etc/fstab', '$TEST_ROOT/etc/fstab')
    $payload = $payload.Replace('/etc/exports.d', '$TEST_ROOT/etc/exports.d')
    $payload = $payload.Replace('/etc/systemd/system/nfs-kernel-server.service.d', '$TEST_ROOT/etc/systemd/system/nfs-kernel-server.service.d')
    [IO.File]::WriteAllText($payloadPath, $payload.Replace([Environment]::NewLine, [string][char]10), [Text.UTF8Encoding]::new($false))
    & $gitBash -n $payloadPath
    if ($LASTEXITCODE -ne 0) { throw "Production guest payload Bash syntax check failed." }

    [IO.File]::WriteAllText($driverPath, (@'
set -euo pipefail
root="$(cygpath -u "$1")"
payload="$(cygpath -u "$2")"
stub="$root/stub"
log="$root/log"
mkdir -p "$stub" "$root/etc/exports.d" "$root/etc/systemd/system/nfs-kernel-server.service.d"
: >"$root/etc/fstab"

write_stub() {
  name="$1"
  cat >"$stub/$name"
  chmod +x "$stub/$name"
}
write_stub apt-get <<'EOF'
#!/usr/bin/env bash
touch "$TEST_ROOT/apt-done"; echo apt >>"$TEST_ROOT/log"
EOF
write_stub findmnt <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "-nro SOURCE /") echo /dev/sda1; exit 0 ;;
  "-nro SOURCE --target "*) [[ -e "$TEST_ROOT/mounted" ]] && echo /dev/sdb1; exit 0 ;;
  "-nro FSTYPE --target "*) [[ -e "$TEST_ROOT/mounted" ]] && echo ext4; exit 0 ;;
esac
echo "/dev/sdb1 $TEST_EXPORT_PATH ext4"
EOF
write_stub lsblk <<'EOF'
#!/usr/bin/env bash
echo "lsblk:$*" >>"$TEST_ROOT/log"
if [[ -e "$TEST_ROOT/apt-done" ]]; then echo lsblk-after-apt >>"$TEST_ROOT/log"; fi
if [[ "$1" == "-s" ]]; then
  if [[ "$TEST_MODE" == root ]]; then echo /dev/sdb; else echo /dev/sda; fi
elif [[ "$1" == "-dpno" ]]; then
  if [[ "$TEST_MODE" == changed && -e "$TEST_ROOT/apt-done" ]]; then printf '%s\n' "/dev/sdb NFS01CHANGED disk"; else printf '%s\n' "/dev/sdb NFS01DATA disk"; fi
elif [[ "$1" == "-nrpo" && "$2" == "NAME,TYPE" ]]; then
  if [[ "$TEST_MODE" == existing || -e "$TEST_ROOT/created" ]]; then echo "/dev/sdb1 part"; fi
fi
EOF
write_stub blockdev <<'EOF'
#!/usr/bin/env bash
echo 2200000000000
EOF
write_stub readlink <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do last="$arg"; done
if [[ "$1" == -e && "$last" == "$TEST_ROOT/symlink" ]]; then echo "$TEST_ROOT/real"; else echo "$last"; fi
EOF
write_stub wipefs <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do dev="$arg"; done
if [[ "$dev" == /dev/sdb ]]; then
  if [[ "$TEST_MODE" == unexpected ]]; then echo LVM2_member; echo gpt
  elif [[ "$TEST_MODE" == existing ]]; then echo PMBR; echo gpt
  elif [[ -e "$TEST_ROOT/created" ]]; then echo gpt; echo gpt; fi
elif [[ "$dev" == /dev/sdb1 && "$TEST_MODE" == existing ]]; then echo ext4; fi
EOF
write_stub blkid <<'EOF'
#!/usr/bin/env bash
field=""
previous=""
for arg in "$@"; do
  [[ "$previous" == -s ]] && field="$arg"
  previous="$arg"; dev="$arg"
done
[[ "$dev" == /dev/sdb && -z "$field" ]] && exit 2
if [[ "$dev" == /dev/sdb1 && ( "$TEST_MODE" == existing || -e "$TEST_ROOT/formatted" ) ]]; then
  case "$field" in TYPE) echo ext4 ;; LABEL) echo immich-nfs ;; UUID) echo test-uuid ;; esac
fi
EOF
write_stub parted <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *mklabel* ]]; then touch "$TEST_ROOT/created"; echo parted-mutate >>"$TEST_ROOT/log"; else echo "Partition Table: gpt"; fi
EOF
write_stub partprobe <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub udevadm <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub mkfs.ext4 <<'EOF'
#!/usr/bin/env bash
touch "$TEST_ROOT/formatted"; echo mkfs >>"$TEST_ROOT/log"
EOF
write_stub install <<'EOF'
#!/usr/bin/env bash
directory=false
for arg in "$@"; do [[ "$arg" == -d ]] && directory=true; last="$arg"; done
if "$directory"; then mkdir -p "$last"; else : >"$last"; fi
EOF
write_stub mountpoint <<'EOF'
#!/usr/bin/env bash
[[ -e "$TEST_ROOT/mounted" ]]
EOF
write_stub mount <<'EOF'
#!/usr/bin/env bash
touch "$TEST_ROOT/mounted"; echo mount >>"$TEST_ROOT/log"
EOF
write_stub chown <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub chmod <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub systemctl <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub exportfs <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub df <<'EOF'
#!/usr/bin/env bash
:
EOF
write_stub flock <<'EOF'
#!/usr/bin/env bash
[[ "$TEST_MODE" != locked ]]
EOF

run_case() {
  mode="$1"; target="$2"; expected="$3"
  rm -f "$root/apt-done" "$root/created" "$root/formatted" "$root/mounted" "$log"
  : >"$log"
  set +e
  TEST_ROOT="$root" TEST_MODE="$mode" TEST_EXPORT_PATH="$target" PATH="$stub:$PATH" bash "$payload" >"$root/output" 2>&1
  rc=$?
  set -e
  [[ "$rc" == "$expected" ]] || { cat "$root/output"; cat "$log"; exit 90; }
}
assert_no_destructive() { ! grep -Eq 'parted-mutate|mkfs' "$log"; }
normal="$root/normal"
run_case blank "$normal" 0
grep -qx parted-mutate "$log"; grep -qx mkfs "$log"; grep -q lsblk-after-apt "$log"
run_case existing "$root/existing" 0
! grep -qx parted-mutate "$log"; ! grep -qx mkfs "$log"; grep -q lsblk-after-apt "$log"
run_case changed "$root/changed" 1 || true; assert_no_destructive
mkdir -p "$root/nonempty"; : >"$root/nonempty/file"
run_case blank "$root/nonempty" 1 || true; assert_no_destructive
mkdir -p "$root/real" "$root/symlink"
run_case blank "$root/symlink" 1 || true; assert_no_destructive
if [[ -L "$root/native-link" ]]; then
  run_case blank "$root/native-link" 1 || true; assert_no_destructive
else
  echo "SKIP: Git Bash cannot observe native symlinks on this platform." >&2
fi
run_case blank "$root//double" 1 || true; assert_no_destructive
run_case root "$root/root" 1 || true; assert_no_destructive
run_case unexpected "$root/unexpected" 1 || true; assert_no_destructive
run_case locked "$root/locked" 1 || true; assert_no_destructive
'@).Replace([Environment]::NewLine, [string][char]10), [Text.UTF8Encoding]::new($false))

    & $gitBash $driverPath $testRoot $payloadPath
    if ($LASTEXITCODE -ne 0) { throw "Production guest payload fixture tests failed." }
    Write-Host "[OK] Production guest payload fixture tests passed." -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
