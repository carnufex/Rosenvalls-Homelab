param(
    [string]$Namespace = "media",
    [string]$Deployment = "seerr",
    [string]$OauthProxyDeployment = "seerr-oauth2-proxy",
    [string]$PvcName = "overseerr-config"
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

Invoke-KubectlChecked -Args @("-n", $Namespace, "scale", "deployment", $Deployment, "--replicas=0") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "scale", "deployment", $OauthProxyDeployment, "--replicas=0") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "rollout", "status", "deployment/$Deployment", "--timeout=120s") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "rollout", "status", "deployment/$OauthProxyDeployment", "--timeout=120s") | Out-Host

$podName = "seerr-media-reset-" + ([System.Guid]::NewGuid().ToString("n").Substring(0, 6))
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
    - name: reset
      image: python:3.12-alpine
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: config
          mountPath: /config
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: $PvcName
"@ | Set-Content -Path $manifestPath -Encoding utf8

$resetCode = @'
import json
import os
import shutil
import sqlite3
import time

root = "/config"
db_path = os.path.join(root, "db", "db.sqlite3")
stamp = time.strftime("%Y%m%d-%H%M%S")
backup_dir = os.path.join(root, "db", "backups", f"before-media-reset-{stamp}")
os.makedirs(backup_dir, exist_ok=True)

for name in ["db.sqlite3", "db.sqlite3-wal", "db.sqlite3-shm"]:
    src = os.path.join(root, "db", name)
    if os.path.exists(src):
        shutil.copy2(src, os.path.join(backup_dir, name))

settings = os.path.join(root, "settings.json")
if os.path.exists(settings):
    shutil.copy2(settings, os.path.join(backup_dir, "settings.json"))

con = sqlite3.connect(db_path)
con.row_factory = sqlite3.Row
con.execute("pragma foreign_keys=off")
tables = {row[0] for row in con.execute("select name from sqlite_master where type='table'")}

clear_tables = [
    "issue_comment",
    "issue",
    "season_request",
    "media_request",
    "season",
    "watchlist",
    "media",
]

before = {}
after = {}
for table in clear_tables:
    if table not in tables:
        continue
    before[table] = con.execute(f'select count(*) from "{table}"').fetchone()[0]
    con.execute(f'delete from "{table}"')
    after[table] = con.execute(f'select count(*) from "{table}"').fetchone()[0]

if "sqlite_sequence" in tables:
    for table in clear_tables:
        con.execute("delete from sqlite_sequence where name=?", (table,))

con.commit()
con.execute("pragma wal_checkpoint(truncate)")
con.close()

print("backup_dir", backup_dir)
print("before", json.dumps(before, sort_keys=True))
print("after", json.dumps(after, sort_keys=True))
'@

try {
    Invoke-KubectlChecked -Args @("apply", "-f", $manifestPath) | Out-Null
    Invoke-KubectlChecked -Args @("-n", $Namespace, "wait", "--for=condition=Ready", "pod/$podName", "--timeout=120s") | Out-Host

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resetCode))
    Invoke-KubectlChecked -Args @("-n", $Namespace, "exec", $podName, "--", "sh", "-lc", "echo $encoded | base64 -d >/tmp/reset_seerr.py && python /tmp/reset_seerr.py && chown -R 1000:1000 /config/db /config/settings.json") | Out-Host
}
finally {
    Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
    $null = & kubectl -n $Namespace delete pod $podName --ignore-not-found=true --wait=true 2>$null
}

Invoke-KubectlChecked -Args @("-n", $Namespace, "scale", "deployment", $Deployment, "--replicas=1") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "scale", "deployment", $OauthProxyDeployment, "--replicas=1") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "rollout", "status", "deployment/$Deployment", "--timeout=180s") | Out-Host
Invoke-KubectlChecked -Args @("-n", $Namespace, "rollout", "status", "deployment/$OauthProxyDeployment", "--timeout=180s") | Out-Host

