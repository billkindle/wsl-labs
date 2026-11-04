<#
.SYNOPSIS
    Builds a disposable Grafana lab in a dedicated WSL2 Ubuntu 26.04 distro, wired to the ZabbixLab distro
    (built by New-ZabbixWslLab.ps1) with a provisioned Zabbix data source and starter dashboard.

.DESCRIPTION
    1. Checks that the ZabbixLab distro exists and that zabbix-server + nginx are active in it, and opens a
       minimized ZabbixLab shell so that distro stays running (WSL stops idle distros).
    2. Reads Microsoft's WSL manifest, downloads + SHA256-verifies the Ubuntu 26.04 image, imports it as a NEW
       distro (GrafanaLab), enables systemd. Existing distros are untouched.
    3. Inside GrafanaLab, BEFORE installing anything big: calls the Zabbix API at localhost:<ZabbixWebPort>
       (all WSL2 distros share one network namespace) to prove the API is reachable, the token is accepted,
       and the target host is visible to the token's user.
    4. Installs Grafana OSS from apt.grafana.com and the Zabbix app plugin (alexanderzobnin-zabbix-app).
    5. Provisions: the Zabbix app (enabled), a Zabbix data source (API token auth), and a dashboard
       "ZabbixLab overview" (problems, CPU, memory, load, network, filesystem, server internals).
    6. Tests Grafana -> Zabbix through Grafana's own data source health endpoint.

    Grafana: http://localhost:<GrafanaPort>/   (admin / generated password printed at the end)

.PREREQUISITE (Zabbix 8.0 side, done once in the Zabbix UI)
    Zabbix 8.0 new installs have API access OFF for every role, so Grafana needs a role that allows it:
      Users > User groups > Create   'Grafana readers'  - Host permissions: Read on 'Zabbix servers'
      Users > User roles  > Create   'Grafana API'      - User type: User; Access to API: Enabled;
                                                          API methods: Allow list, *.get
      Users > Users       > Create   'grafana'          - Group 'Grafana readers', Role 'Grafana API'
      Users > API tokens  > Create   for user 'grafana' - copy the 64-character token (shown once)

.IMPACT / ROLLBACK
    Impact : one new WSL2 distro + its VHDX under -InstallPath. Nothing is changed in ZabbixLab (the script
             only reads from it). No .wslconfig or other distro changes.
             Grafana listens on -GrafanaPort in the shared WSL network namespace, so it must not collide
             with ports used by ZabbixLab (8080, 10050, 10051, 5432).
    Re-run : -Reprovision re-runs the provisioning on an existing GrafanaLab (e.g. wrong/rotated token).
    Snapshot: wsl --export GrafanaLab .\grafanalab.tar
    Remove : wsl --unregister GrafanaLab   (irreversibly deletes the distro and its disk)
             Then delete the 'grafana' user / API token in Zabbix if you no longer need them.

.NOTES
    Requires WSL2 (wsl --status works) and a working ZabbixLab. Does NOT need admin.
    Lab use only: the Grafana admin password is generated and printed; the Zabbix token is stored in the
    provisioning file /etc/grafana/provisioning/datasources/zabbixlab.yaml (root:grafana, 0640).
#>
[CmdletBinding()]
param(
    [string]$DistroName       = 'GrafanaLab',
    [string]$InstallPath      = (Join-Path $env:LOCALAPPDATA 'WSL\GrafanaLab'),
    [ValidateRange(1024, 65535)]
    [int]$GrafanaPort         = 3000,
    [string]$ZabbixDistroName = 'ZabbixLab',
    [ValidateRange(1024, 65535)]
    [int]$ZabbixWebPort       = 8080,
    [ValidatePattern('^[A-Za-z0-9 ._-]+$')]
    [string]$ZabbixHostName   = 'Zabbix server',
    [securestring]$ZabbixApiToken,
    [switch]$Reprovision,
    [string]$ManifestUrl      = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json',
    [string]$ImageName        = 'Ubuntu-26.04'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$env:WSL_UTF8          = '1'
$OutputEncoding        = [System.Text.UTF8Encoding]::new($false)   # no BOM on pipes into wsl.exe

function Invoke-Wsl {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & wsl.exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "wsl.exe $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
}

function Write-DistroFile {
    # Pipes text into a root-only file inside the distro (keeps secrets off the command line).
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $Content | & wsl.exe -d $DistroName -u root -- sh -c "umask 077; cat > '$Path'"
    if ($LASTEXITCODE -ne 0) { throw "Failed to write $Path in $DistroName" }
}

# --- Preflight -------------------------------------------------------------------------------
if ($GrafanaPort -in @($ZabbixWebPort, 10050, 10051, 5432)) {
    throw "GrafanaPort $GrafanaPort collides with a ZabbixLab port. WSL2 distros share one network namespace."
}
if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe not found. From an elevated prompt run: wsl --install --no-distribution  (then reboot)'
}
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) { throw 'WSL is not ready. Run: wsl --install --no-distribution  (then reboot)' }

$existing = (& wsl.exe --list --quiet) | ForEach-Object { $_.Trim() } | Where-Object { $_ }
if ($existing -notcontains $ZabbixDistroName) {
    throw "Zabbix distro '$ZabbixDistroName' not found. Build it with New-ZabbixWslLab.ps1 or pass -ZabbixDistroName."
}
$distroExists = $existing -contains $DistroName
if ($distroExists -and -not $Reprovision) {
    throw "'$DistroName' already exists. Use -Reprovision to re-run provisioning on it, or: wsl --unregister $DistroName"
}
if ($Reprovision -and -not $distroExists) { throw "-Reprovision was given but '$DistroName' does not exist." }

# --- Keep ZabbixLab running + check its services -----------------------------------------------
Write-Host "Opening a minimized '$ZabbixDistroName' shell so it stays running (close it when you're done)..." -ForegroundColor Cyan
Start-Process -FilePath wsl.exe -ArgumentList @('-d', $ZabbixDistroName) -WindowStyle Minimized
Start-Sleep -Seconds 3
$zbxState = (& wsl.exe -d $ZabbixDistroName -u root -- systemctl is-active zabbix-server nginx) -join ' '
if ($LASTEXITCODE -ne 0) { throw "zabbix-server/nginx are not both active in $ZabbixDistroName (got: $zbxState)." }
Write-Host "ZabbixLab services active." -ForegroundColor Green

# --- Zabbix API token ----------------------------------------------------------------------------
if (-not $ZabbixApiToken) {
    Write-Host ""
    Write-Host "Paste the Zabbix API token for the 'grafana' user (see .PREREQUISITE in this script's help)." -ForegroundColor Yellow
    $ZabbixApiToken = Read-Host -Prompt 'Zabbix API token' -AsSecureString
}
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($ZabbixApiToken)
try     { $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim() }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
# Zabbix tokens are 64 hex chars. Validating also guarantees the token is safe inside YAML and
# can't trigger Grafana's $VAR interpolation in provisioning files.
if ($token -notmatch '^[0-9a-f]{64}$') { throw 'That does not look like a Zabbix API token (expected 64 lowercase hex characters).' }

# --- Distro: import + systemd (skipped with -Reprovision) --------------------------------------
if (-not $distroExists) {
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

    Write-Host "Importing as '$DistroName' into $InstallPath..." -ForegroundColor Cyan
    Invoke-Wsl -Arguments @('--import', $DistroName, $InstallPath, $imageFile, '--version', '2')
    Remove-Item $imageFile -Force

    "[boot]`nsystemd=true`n`n[user]`ndefault=root`n" | & wsl.exe -d $DistroName -u root -- sh -c 'cat > /etc/wsl.conf'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to write /etc/wsl.conf' }
    Invoke-Wsl -Arguments @('--terminate', $DistroName)
}

$pid1 = (& wsl.exe -d $DistroName -u root -- ps -p 1 -o comm=) | Select-Object -First 1
if ("$pid1".Trim() -ne 'systemd') { throw "systemd is not PID 1 in $DistroName (got '$pid1')." }
Write-Host "systemd is running in $DistroName." -ForegroundColor Green

# --- Dashboard JSON (built here so quoting/escaping is handled by ConvertTo-Json) --------------
$ds = @{ type = 'alexanderzobnin-zabbix-datasource'; uid = 'zabbixlab' }

function New-MetricTarget([string]$Item, [string]$Host_ = $ZabbixHostName) {
    @{
        refId     = 'A'
        datasource = $ds
        queryType = '0'                       # 0 = Metrics
        group     = @{ filter = '/.*/' }
        host      = @{ filter = $Host_ }
        itemTag   = @{ filter = '' }
        item      = @{ filter = $Item }       # /.../ = regex, otherwise exact item name
        functions = @()
        options   = @{ showDisabledItems = $false; skipEmptyValues = $false; disableDataAlignment = $false; useZabbixValueMapping = $false }
    }
}

function New-TsPanel([int]$Id, [string]$Title, [string]$Item, [string]$Unit, [int]$X, [int]$Y, [int]$W = 12) {
    @{
        id          = $Id
        type        = 'timeseries'
        title       = $Title
        datasource  = $ds
        gridPos     = @{ x = $X; y = $Y; w = $W; h = 8 }
        fieldConfig = @{ defaults = @{ unit = $Unit }; overrides = @() }
        options     = @{ legend  = @{ displayMode = 'list'; placement = 'bottom'; showLegend = $true }
                         tooltip = @{ mode = 'multi'; sort = 'none' } }
        targets     = @(New-MetricTarget -Item $Item)
    }
}

$problemsPanel = @{
    id         = 1
    type       = 'alexanderzobnin-zabbix-triggers-panel'   # the plugin's Problems panel
    title      = 'Current problems (all hosts)'
    datasource = $ds
    gridPos    = @{ x = 0; y = 0; w = 24; h = 8 }
    targets    = @(@{
        refId        = 'A'
        datasource   = $ds
        queryType    = '5'                    # 5 = Problems
        group        = @{ filter = '/.*/' }
        host         = @{ filter = '/.*/' }
        proxy        = @{ filter = '' }
        application  = @{ filter = '' }
        trigger      = @{ filter = '' }
        tags         = @{ filter = '' }
        showProblems = 'problems'
        options      = @{ minSeverity = 0; acknowledged = 2; sortProblems = 'default'; limit = 100; hostsInMaintenance = $false; hostProxy = $false }
    })
}

$dashboard = @{
    uid           = 'zabbixlab-overview'
    title         = 'ZabbixLab overview'
    tags          = @('zabbix', 'lab')
    editable      = $true
    schemaVersion = 39
    refresh       = '1m'
    time          = @{ from = 'now-3h'; to = 'now' }
    templating    = @{ list = @() }
    annotations   = @{ list = @() }
    panels        = @(
        $problemsPanel
        (New-TsPanel 2 "$ZabbixHostName - CPU utilization"    'CPU utilization'               'percent' 0  8)
        (New-TsPanel 3 "$ZabbixHostName - Memory utilization" 'Memory utilization'            'percent' 12 8)
        (New-TsPanel 4 "$ZabbixHostName - Load average"       '/Load average/'                'short'   0  16)
        (New-TsPanel 5 "$ZabbixHostName - Network traffic"    '/Bits (received|sent)/'        'bps'     12 16)
        (New-TsPanel 6 "$ZabbixHostName - Filesystem used"    '/Space: Used, in %/'           'percent' 0  24)
        (New-TsPanel 7 'Zabbix server - processed values/sec' '/processed values per second/' 'short'   12 24)
        (New-TsPanel 8 'Zabbix server - data collector utilization' '/data collector processes/' 'percent' 0 32 24)
    )
}
$dashboardJson = $dashboard | ConvertTo-Json -Depth 20

# --- Provisioning script (runs inside GrafanaLab) ----------------------------------------------
$chars   = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$gfPass  = -join (1..20 | ForEach-Object { $chars | Get-Random })

$bash = @'
set -Eeuo pipefail
# Name the failing line + command so a generic non-zero exit is diagnosable.
trap 'rc=$?; echo "FAILED (exit $rc) at line $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
GF_PORT='__GF_PORT__'
GF_PASS_NEW='__GF_PASS__'
ZBX_URL='http://localhost:__ZBX_PORT__/api_jsonrpc.php'
ZBX_HOST='__ZBX_HOST__'
TOKEN_FILE=/root/.zabbix-api-token
DASH_SRC=/root/zabbixlab-dashboard.json
INI=/etc/grafana/grafana.ini
PLUGIN_DIR=/var/lib/grafana/plugins
ZBX_TOKEN=$(tr -d '\r\n' < "$TOKEN_FILE")

echo "== Base packages"
apt-get update -q
apt-get install -y -q curl ca-certificates iproute2

echo "== Zabbix API checks from inside $(hostname) -> ${ZBX_URL}"
zapi() {  # $1 = JSON-RPC body; $2 = optional bearer token
    if [ -n "${2:-}" ]; then
        curl -fsS --max-time 15 -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $2" -d "$1" "$ZBX_URL"
    else
        curl -fsS --max-time 15 -H 'Content-Type: application/json-rpc' -d "$1" "$ZBX_URL"
    fi
}
VER=$(zapi '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}') \
    || { echo "ERROR: cannot reach ${ZBX_URL}. Is ZabbixLab running and nginx listening there?"; exit 10; }
case "$VER" in *'"result"'*) echo "Zabbix API answered: $VER" ;; *) echo "ERROR: unexpected reply: $VER"; exit 10 ;; esac

HOSTS=$(zapi '{"jsonrpc":"2.0","method":"host.get","params":{"output":["host"]},"id":2}' "$ZBX_TOKEN") \
    || { echo "ERROR: host.get HTTP request failed"; exit 11; }
case "$HOSTS" in
    *'"error"'*) echo "ERROR: Zabbix rejected the call (token, API access on the role, or allow list): $HOSTS"; exit 11 ;;
esac
case "$HOSTS" in
    *"\"host\":\"${ZBX_HOST}\""*) echo "Token accepted; host '${ZBX_HOST}' is visible." ;;
    *) echo "ERROR: token works but '${ZBX_HOST}' isn't visible to it (user group host permissions?): $HOSTS"; exit 12 ;;
esac

echo "== Grafana repository + package"
mkdir -p /etc/apt/keyrings
curl -fsSLo /etc/apt/keyrings/grafana.asc https://apt.grafana.com/gpg-full.key
chmod 644 /etc/apt/keyrings/grafana.asc
echo "deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -q
apt-get install -y -q grafana

echo "== Port ${GF_PORT}"
if ! systemctl is-active --quiet grafana-server; then
    # Command substitution (not a pipe into grep -q) so pipefail can't trip on SIGPIPE.
    if [ -n "$(ss -ltnH "sport = :${GF_PORT}")" ]; then
        echo "ERROR: port ${GF_PORT} is already in use in the shared WSL network (another distro?). Use -GrafanaPort."
        exit 13
    fi
fi

echo "== grafana.ini"
sed -i -E "s/^;?http_port = .*/http_port = ${GF_PORT}/" "$INI"
grep -qE "^http_port = ${GF_PORT}$" "$INI" || { echo "ERROR: http_port line not found in $INI"; grep -nE 'http_port' "$INI" || true; exit 15; }
if [ ! -f /var/lib/grafana/grafana.db ]; then
    # admin_password only takes effect when Grafana creates its database on first start.
    sed -i -E "s/^;?admin_password = .*/admin_password = ${GF_PASS_NEW}/" "$INI"
    grep -qE "^admin_password = ${GF_PASS_NEW}$" "$INI" || { echo "ERROR: admin_password line not found in $INI"; grep -nE 'admin_password' "$INI" || true; exit 15; }
fi
GF_PASS=$(sed -n -E 's/^admin_password = (.*)$/\1/p' "$INI")

echo "== Zabbix plugin"
# Grafana 13's grafana-cli wrapper is deprecated and doesn't pass --homepath (it fails with
# "Could not find config defaults" and can still exit 0), so call the 'grafana cli' subcommand
# with explicit paths and verify the result on disk instead of trusting the exit code.
GCLI=(grafana cli --homepath /usr/share/grafana --config "$INI" --pluginsDir "$PLUGIN_DIR")
if [ -f "$PLUGIN_DIR/alexanderzobnin-zabbix-app/plugin.json" ]; then
    echo "Plugin already installed."
else
    "${GCLI[@]}" plugins install alexanderzobnin-zabbix-app
fi
[ -f "$PLUGIN_DIR/alexanderzobnin-zabbix-app/plugin.json" ] \
    || { echo "ERROR: plugin install reported done but $PLUGIN_DIR/alexanderzobnin-zabbix-app/plugin.json is missing"; exit 16; }
chown -R grafana:grafana "$PLUGIN_DIR"

echo "== Provisioning"
mkdir -p /etc/grafana/provisioning/plugins /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
cat > /etc/grafana/provisioning/plugins/zabbixlab-app.yaml <<'EOF'
apiVersion: 1
apps:
  - type: alexanderzobnin-zabbix-app
    org_id: 1
    disabled: false
EOF

cat > /etc/grafana/provisioning/datasources/zabbixlab.yaml <<EOF
apiVersion: 1
datasources:
  - name: ZabbixLab
    uid: zabbixlab
    type: alexanderzobnin-zabbix-datasource
    access: proxy
    url: ${ZBX_URL}
    isDefault: true
    editable: true
    jsonData:
      authType: token
      trends: true
      trendsFrom: '7d'
      trendsRange: '4d'
      cacheTTL: '1h'
      timeout: 30
    secureJsonData:
      apiToken: ${ZBX_TOKEN}
EOF
chown root:grafana /etc/grafana/provisioning/datasources/zabbixlab.yaml
chmod 0640 /etc/grafana/provisioning/datasources/zabbixlab.yaml

cat > /etc/grafana/provisioning/dashboards/zabbixlab.yaml <<'EOF'
apiVersion: 1
providers:
  - name: zabbixlab
    folder: ZabbixLab
    type: file
    disableDeletion: false
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards/zabbixlab
EOF
install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards/zabbixlab
install -o grafana -g grafana -m 0644 "$DASH_SRC" /var/lib/grafana/dashboards/zabbixlab/zabbixlab-overview.json
rm -f "$TOKEN_FILE" "$DASH_SRC"

echo "== Start Grafana"
systemctl daemon-reload
systemctl enable grafana-server
systemctl restart grafana-server
for i in $(seq 1 45); do
    if curl -fsS --max-time 3 "http://127.0.0.1:${GF_PORT}/api/health" >/dev/null 2>&1; then break; fi
    sleep 2
done
curl -fsS --max-time 5 "http://127.0.0.1:${GF_PORT}/api/health" >/dev/null || { echo "ERROR: Grafana not healthy; see: journalctl -u grafana-server"; exit 14; }

echo "== Admin password"
# admin_password in grafana.ini only applies when Grafana creates its DB, so if anything created
# grafana.db earlier the printed password would be wrong. Set it explicitly so the printed value is true.
# Run as the grafana user so the sqlite DB/WAL files keep their ownership.
runuser -u grafana -- grafana cli --homepath /usr/share/grafana --config "$INI" admin reset-admin-password "$GF_PASS"

echo "== Grafana -> Zabbix data source test"
DSH=$(curl -sS --max-time 30 -u "admin:${GF_PASS}" "http://127.0.0.1:${GF_PORT}/api/datasources/uid/zabbixlab/health" || true)
echo "$DSH"
case "$DSH" in
    *'"status":"OK"'*) echo "Data source OK." ;;
    *) echo "WARNING: data source test did not return OK (see above). Grafana is up; check Connections > Data sources > ZabbixLab." ;;
esac
DB=$(curl -sS --max-time 10 -u "admin:${GF_PASS}" "http://127.0.0.1:${GF_PORT}/api/dashboards/uid/zabbixlab-overview" || true)
case "$DB" in *'"uid":"zabbixlab-overview"'*) echo "Dashboard provisioned." ;; *) echo "WARNING: dashboard not found via API." ;; esac

echo "== Versions"
echo "grafana: $(dpkg-query -W -f='${Version}' grafana)"
echo "zabbix plugin: $(sed -n -E 's/.*"version": *"([^"]+)".*/\1/p' "$PLUGIN_DIR/alexanderzobnin-zabbix-app/plugin.json" | awk 'NR==1')"
echo "GRAFANA_ADMIN_PASSWORD=${GF_PASS}"
'@

$bash = $bash.Replace('__GF_PORT__', [string]$GrafanaPort)
$bash = $bash.Replace('__GF_PASS__', $gfPass)
$bash = $bash.Replace('__ZBX_PORT__', [string]$ZabbixWebPort)
$bash = $bash.Replace('__ZBX_HOST__', $ZabbixHostName)
$bash = $bash -replace "`r`n", "`n"

Write-DistroFile -Path '/root/.zabbix-api-token'        -Content $token
Write-DistroFile -Path '/root/zabbixlab-dashboard.json' -Content $dashboardJson
Write-DistroFile -Path '/root/grafana-provision.sh'     -Content $bash
$token = $null

Write-Host "Provisioning Grafana inside $DistroName (a few minutes)..." -ForegroundColor Cyan
& wsl.exe -d $DistroName -u root -- bash /root/grafana-provision.sh
switch ($LASTEXITCODE) {
    0       { }
    10      { throw "GrafanaLab can't reach the Zabbix API on localhost:$ZabbixWebPort. Is ZabbixLab running? Fix, then rerun with -Reprovision." }
    11      { throw "Zabbix rejected the token. Check API access + allow list on the 'Grafana API' role and the token itself, then rerun with -Reprovision." }
    12      { throw "Token works but '$ZabbixHostName' isn't visible. Give 'Grafana readers' Read on its host group, or pass -ZabbixHostName, then rerun with -Reprovision." }
    16      { throw "The Zabbix plugin didn't install (see the grafana cli output above)." }
    15      { throw "grafana.ini doesn't have the expected http_port/admin_password lines (shown above). Send me that output." }
    13      { throw "Port $GrafanaPort is in use. Rerun with -Reprovision -GrafanaPort <other>." }
    default { throw "Provisioning failed (exit $LASTEXITCODE). Fix, then rerun with -Reprovision (script: /root/grafana-provision.sh in $DistroName)." }
}

# --- Smoke test from Windows ------------------------------------------------------------------
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$GrafanaPort/api/health" -UseBasicParsing -TimeoutSec 15
    Write-Host "Grafana answered HTTP $($r.StatusCode) on 127.0.0.1:$GrafanaPort from Windows" -ForegroundColor Green
} catch {
    Write-Warning "Grafana did not answer from Windows on 127.0.0.1:$GrafanaPort : $($_.Exception.Message)"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Grafana      : http://localhost:$GrafanaPort/   (user admin, password printed above as GRAFANA_ADMIN_PASSWORD)"
Write-Host "  Dashboard    : Dashboards > ZabbixLab > ZabbixLab overview"
Write-Host "  Data source  : ZabbixLab -> http://localhost:$ZabbixWebPort/api_jsonrpc.php (API token)"
Write-Host "  Keep running : leave a 'wsl -d $DistroName' AND the minimized '$ZabbixDistroName' window open"
Write-Host "  Snapshot     : wsl --export $DistroName .\grafanalab.tar"
Write-Host "  Remove       : wsl --unregister $DistroName"
