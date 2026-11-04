<#
.SYNOPSIS
    Builds a disposable Zabbix 8.0 (RC/pre-release) lab in a dedicated WSL2 Ubuntu 26.04 distro.

.DESCRIPTION
    1. Reads Microsoft's WSL distribution manifest to get the official Ubuntu 26.04 image URL + SHA256.
    2. Downloads and hash-verifies the image, then imports it as a NEW distro (existing distros untouched).
    3. Enables systemd in that distro only (/etc/wsl.conf), restarts it.
    4. Installs PostgreSQL + Zabbix 8.0 server, frontend (Nginx/PHP-FPM) and agent 2 from repo.zabbix.com.
       While 8.0 is pre-release, the 8.0 zabbix-release package enables Zabbix's "unstable" source,
       which is where the RC builds come from.
    5. Creates the DB, loads the schema, configures Nginx on the chosen port.

    Frontend: http://localhost:<WebPort>/   (8.0 serves from the web root, not /zabbix)

.IMPACT / ROLLBACK
    Impact : one new WSL2 distro + its VHDX under -InstallPath. No .wslconfig or other distro changes.
    Snapshot (do this before the RC -> GA upgrade):
             wsl --export ZabbixLab .\zabbixlab-rc.tar
    Restore: wsl --unregister ZabbixLab
             wsl --import ZabbixLab <InstallPath> .\zabbixlab-rc.tar --version 2
    Remove : wsl --unregister ZabbixLab   (irreversibly deletes the distro and its disk)

.NOTES
    Requires WSL2 already installed (wsl --status works). Does NOT need admin if WSL is present.
    Lab use only: DB password is generated and printed to the console.
#>
[CmdletBinding()]
param(
    [string]$DistroName  = 'ZabbixLab',
    [string]$InstallPath = (Join-Path $env:LOCALAPPDATA "WSL\ZabbixLab"),
    [ValidateRange(1024, 65535)]
    [int]$WebPort        = 8080,
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json',
    [string]$ImageName   = 'Ubuntu-26.04'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # Invoke-WebRequest is far faster without the progress bar
$env:WSL_UTF8          = '1'                  # wsl.exe emits UTF-16 otherwise, which breaks string matching

function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & wsl.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "wsl.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

# --- Preflight -------------------------------------------------------------------------------
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe not found. From an elevated prompt run: wsl --install --no-distribution  (then reboot)'
}
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'WSL is not ready. From an elevated prompt run: wsl --install --no-distribution  (then reboot)'
}
$existing = (& wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($existing -contains $DistroName) {
    throw "A distro named '$DistroName' already exists. Remove it (wsl --unregister $DistroName) or pass -DistroName."
}

# --- Get + verify the image --------------------------------------------------------------------
Write-Host "Reading WSL distribution manifest..." -ForegroundColor Cyan
$manifest = Invoke-RestMethod -Uri $ManifestUrl
$entry    = $manifest.ModernDistributions.Ubuntu | Where-Object { $_.Name -eq $ImageName }
if (-not $entry) { throw "'$ImageName' not found in the WSL manifest." }

$arch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'Arm64Url' } else { 'Amd64Url' }
$image = $entry.$arch
if (-not $image) { throw "No $arch image published for $ImageName." }

New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
$imageFile = Join-Path $env:TEMP ([IO.Path]::GetFileName($image.Url))

Write-Host "Downloading $($image.Url)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $image.Url -OutFile $imageFile -UseBasicParsing

$hash = (Get-FileHash -Path $imageFile -Algorithm SHA256).Hash
if ($hash -ne $image.Sha256.ToUpper()) {
    Remove-Item $imageFile -Force
    throw "SHA256 mismatch. Expected $($image.Sha256), got $hash. Image deleted."
}
Write-Host "SHA256 verified." -ForegroundColor Green

# --- Import + enable systemd ------------------------------------------------------------------
Write-Host "Importing as '$DistroName' into $InstallPath..." -ForegroundColor Cyan
Invoke-Wsl -Arguments @('--import', $DistroName, $InstallPath, $imageFile, '--version', '2')
Remove-Item $imageFile -Force

# Root as default user: no interactive account prompt; add your own user later if you want one.
$wslConf = "[boot]`nsystemd=true`n`n[user]`ndefault=root`n"
$wslConf | & wsl.exe -d $DistroName -u root -- sh -c 'cat > /etc/wsl.conf'
if ($LASTEXITCODE -ne 0) { throw 'Failed to write /etc/wsl.conf' }

Invoke-Wsl -Arguments @('--terminate', $DistroName)

$pid1 = (& wsl.exe -d $DistroName -u root -- ps -p 1 -o comm=) | Select-Object -First 1
if ("$pid1".Trim() -ne 'systemd') { throw "systemd is not PID 1 in $DistroName (got '$pid1')." }
Write-Host "systemd is running." -ForegroundColor Green

# --- Provision Zabbix inside the distro -------------------------------------------------------
# Lab password: letters + digits only so it is safe in sed and SQL.
$chars  = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$dbPass = -join (1..24 | ForEach-Object { $chars | Get-Random })

$bash = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
ZBX_DB_PASS='__ZBX_DB_PASS__'
WEB_PORT='__WEB_PORT__'

echo "== Base packages + PostgreSQL"
apt-get update -q
apt-get install -y -q curl ca-certificates postgresql locales
# WSL Ubuntu image ships without en_US.UTF-8; the Zabbix frontend prerequisite check needs it
locale-gen en_US.UTF-8

echo "== Zabbix 8.0 repository"
. /etc/os-release
curl -fsSLo /tmp/zabbix-release.deb \
  "https://repo.zabbix.com/zabbix/8.0/release/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest_8.0+ubuntu${VERSION_ID}_all.deb"
dpkg -i /tmp/zabbix-release.deb
apt-get update -q

echo "== Zabbix server, frontend, agent 2"
# php-pgsql named explicitly: otherwise apt satisfies the frontend's DB-driver dependency with php-mysql
apt-get install -y -q zabbix-server-pgsql zabbix-frontend-php php-pgsql zabbix-nginx-conf zabbix-sql-scripts zabbix-agent2

echo "== Database"
systemctl enable --now postgresql
runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE USER zabbix WITH PASSWORD '${ZBX_DB_PASS}';"
runuser -u postgres -- createdb -O zabbix zabbix
# 8.0 path is /usr/share/zabbix/sql-scripts (7.0 used /usr/share/zabbix-sql-scripts)
zcat /usr/share/zabbix/sql-scripts/postgresql/server.sql.gz | runuser -u zabbix -- psql -q -v ON_ERROR_STOP=1 zabbix > /dev/null

echo "== Configuration"
sed -i "s/^# DBPassword=.*/DBPassword=${ZBX_DB_PASS}/" /etc/zabbix/zabbix_server.conf
grep -q "^DBPassword=${ZBX_DB_PASS}$" /etc/zabbix/zabbix_server.conf || { echo "DBPassword not set"; exit 1; }

sed -i -E \
  -e "s/^#?[[:space:]]*listen[[:space:]]+8080;/        listen ${WEB_PORT};/" \
  -e "s/^#?[[:space:]]*server_name[[:space:]]+example\.com;/        server_name localhost;/" \
  /etc/zabbix/nginx.conf
grep -qE "^[[:space:]]+listen ${WEB_PORT};" /etc/zabbix/nginx.conf || { echo "nginx listen not set"; exit 1; }
grep -qE "^[[:space:]]+server_name localhost;" /etc/zabbix/nginx.conf || { echo "nginx server_name not set"; exit 1; }
nginx -t

# awk 'NR==1' (not head) reads all input, so the writer never gets SIGPIPE under pipefail
PHPFPM=$(systemctl list-unit-files 'php*-fpm.service' --no-legend | awk 'NR==1 {print $1}')
[ -n "$PHPFPM" ] || { echo "No php-fpm unit found"; exit 1; }

echo "== Services"
systemctl enable zabbix-server zabbix-agent2 nginx "$PHPFPM"
systemctl restart zabbix-server zabbix-agent2 nginx "$PHPFPM"
sleep 3
systemctl is-active zabbix-server zabbix-agent2 nginx "$PHPFPM" postgresql

echo "== Versions"
zabbix_server -V | awk 'NR==1'
apt-cache policy zabbix-server-pgsql | awk 'NR<=3'
'@

$bash = $bash.Replace('__ZBX_DB_PASS__', $dbPass).Replace('__WEB_PORT__', [string]$WebPort)
$bash = $bash -replace "`r`n", "`n"   # bash chokes on CRLF

# Write the script to a file in the distro and run it from there, so commands inside it
# can't consume the remaining script text from stdin.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)   # no BOM on the pipe
$bash | & wsl.exe -d $DistroName -u root -- sh -c 'cat > /root/zbx-provision.sh && chmod 700 /root/zbx-provision.sh'
if ($LASTEXITCODE -ne 0) { throw 'Failed to write /root/zbx-provision.sh' }

Write-Host "Provisioning Zabbix inside $DistroName (several minutes)..." -ForegroundColor Cyan
& wsl.exe -d $DistroName -u root -- bash /root/zbx-provision.sh
if ($LASTEXITCODE -ne 0) { throw "Provisioning failed (exit $LASTEXITCODE). Partial installs aren't re-runnable: wsl --unregister $DistroName, then rerun this script." }

# --- Smoke test from Windows ------------------------------------------------------------------
try {
    $r = Invoke-WebRequest -Uri "http://localhost:$WebPort/" -UseBasicParsing -TimeoutSec 15
    Write-Host "Frontend answered HTTP $($r.StatusCode) on localhost:$WebPort" -ForegroundColor Green
} catch {
    Write-Warning "Frontend did not answer on localhost:$WebPort from Windows: $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Frontend     : http://localhost:$WebPort/"
Write-Host "  Setup wizard : DB type PostgreSQL, host localhost, DB 'zabbix', user 'zabbix'"
Write-Host "  DB password  : $dbPass"
Write-Host "  First login  : Admin / zabbix  (change it)"
Write-Host "  Shell        : wsl -d $DistroName"
Write-Host "  Snapshot     : wsl --export $DistroName .\zabbixlab-rc.tar"
Write-Host "  Remove       : wsl --unregister $DistroName"
