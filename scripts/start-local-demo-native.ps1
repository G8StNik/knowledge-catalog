param(
    [string]$PostgresBin = '',
    [string]$PostgresData = '',
    [int]$PostgresPort = 55440,
    [switch]$PrepareOnly
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $repo
Set-Location -LiteralPath $repo
if (-not $PostgresBin) { $PostgresBin = Join-Path $projectRoot '.local-postgres\pgsql\bin' }
if (-not $PostgresData) { $PostgresData = Join-Path $projectRoot '.local-postgres-qa-utf8\data' }
$pgCtl = Join-Path $PostgresBin 'pg_ctl.exe'
$psql = Join-Path $PostgresBin 'psql.exe'
$createdb = Join-Path $PostgresBin 'createdb.exe'
if (-not (Test-Path -LiteralPath $pgCtl) -or -not (Test-Path -LiteralPath $PostgresData)) {
    throw 'Local PostgreSQL runtime is unavailable. Use the Docker demo launcher or provide -PostgresBin and -PostgresData.'
}
& $pgCtl -D $PostgresData status *> $null
if ($LASTEXITCODE -ne 0) {
    & $pgCtl -D $PostgresData -l (Join-Path (Split-Path $PostgresData -Parent) 'postgres.log') -o "-p $PostgresPort -h 127.0.0.1" start
    if ($LASTEXITCODE -ne 0) { throw 'Could not start local PostgreSQL.' }
}
$exists = & $psql -h 127.0.0.1 -p $PostgresPort -U kc_migration -d postgres -Atc "SELECT 1 FROM pg_database WHERE datname='kc_demo_preview'"
if ($LASTEXITCODE -ne 0) { throw 'Could not access local PostgreSQL.' }
if ($exists -ne '1') {
    & $createdb -h 127.0.0.1 -p $PostgresPort -U kc_migration kc_demo_preview
    if ($LASTEXITCODE -ne 0) { throw 'Could not create preview database.' }
}
$secretPath = Join-Path $repo '.env.local-demo'
if (-not (Test-Path -LiteralPath $secretPath)) {
    $webSecret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    "KC_DEMO_RUNTIME_PASSWORD=$webSecret" | Set-Content -LiteralPath $secretPath -NoNewline
}
$secrets = @{}
foreach ($line in Get-Content -LiteralPath $secretPath) {
    $parts = $line.Split('=', 2)
    if ($parts.Count -eq 2) { $secrets[$parts[0]] = $parts[1] }
}
if (-not $secrets.KC_DEMO_RUNTIME_PASSWORD) { throw 'Local demo runtime secret is missing.' }
$venvPython = Join-Path $repo '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    $python = if (Test-Path -LiteralPath $bundled) { $bundled } else { (Get-Command py -ErrorAction Stop).Source }
    & $python -m venv (Join-Path $repo '.venv')
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the local Python environment.' }
}
& $venvPython -m pip install -e . --quiet
if ($LASTEXITCODE -ne 0) { throw 'Could not install Knowledge Catalog locally.' }
$env:KC_MIGRATION_DSN = "host=127.0.0.1 port=$PostgresPort dbname=kc_demo_preview user=kc_migration"
& $venvPython -m kc.migrate
if ($LASTEXITCODE -ne 0) { throw 'Could not migrate the preview database.' }
$env:KC_DEV_MODE = '1'
$env:KC_DEMO_ADMIN_DSN = $env:KC_MIGRATION_DSN
$env:KC_DEMO_RUNTIME_PASSWORD = $secrets.KC_DEMO_RUNTIME_PASSWORD
if ($PrepareOnly) {
    & $venvPython -c "from kc.local_demo import prepare; import os; prepare(os.environ['KC_DEMO_ADMIN_DSN'], os.environ['KC_DEMO_RUNTIME_PASSWORD']); print('Native demo database and users are ready.')"
} else {
    & $venvPython -m kc.local_demo
}
if ($LASTEXITCODE -ne 0) { throw 'Local preview failed.' }
