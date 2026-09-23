param([switch]$PrepareOnly)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo
$secretPath = Join-Path $repo '.env.local-demo'
if (-not (Test-Path -LiteralPath $secretPath)) {
    $dbSecret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    $webSecret = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24)).ToLowerInvariant()
    "KC_POSTGRES_PASSWORD=$dbSecret`nKC_DEMO_RUNTIME_PASSWORD=$webSecret" | Set-Content -LiteralPath $secretPath -NoNewline
}
$secrets = @{}
foreach ($line in Get-Content -LiteralPath $secretPath) {
    $parts = $line.Split('=', 2)
    if ($parts.Count -eq 2) { $secrets[$parts[0]] = $parts[1] }
}
if (-not $secrets.KC_POSTGRES_PASSWORD -or -not $secrets.KC_DEMO_RUNTIME_PASSWORD) {
    throw 'Local demo secret file is incomplete.'
}
$env:KC_POSTGRES_PASSWORD = $secrets.KC_POSTGRES_PASSWORD
$env:KC_POSTGRES_PORT = '5434'
$env:KC_DEV_MODE = '1'
$env:KC_DEMO_RUNTIME_PASSWORD = $secrets.KC_DEMO_RUNTIME_PASSWORD
$env:KC_DEMO_ADMIN_DSN = "host=127.0.0.1 port=5434 dbname=knowledge_catalog user=kc_migration password=$($secrets.KC_POSTGRES_PASSWORD)"

docker compose -p knowledge-catalog-local-demo up -d --wait postgres
if ($LASTEXITCODE -ne 0) { throw 'Could not start the isolated demo database.' }
docker compose -p knowledge-catalog-local-demo run --rm --build migrate
if ($LASTEXITCODE -ne 0) { throw 'Could not migrate the isolated demo database.' }

$venvPython = Join-Path $repo '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython)) {
    $bundled = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if (Test-Path -LiteralPath $bundled) {
        & $bundled -m venv (Join-Path $repo '.venv')
    } else {
        $python = Get-Command py -ErrorAction SilentlyContinue
        if (-not $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $python -or $python.Source -like '*\WindowsApps\*') { throw 'Python 3.12 or newer is required.' }
        & $python.Source -m venv (Join-Path $repo '.venv')
    }
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the local Python environment.' }
}
& $venvPython -m pip install -e . --quiet
if ($LASTEXITCODE -ne 0) { throw 'Could not install Knowledge Catalog locally.' }

if ($PrepareOnly) {
    & $venvPython -c "from kc.local_demo import prepare; import os; prepare(os.environ['KC_DEMO_ADMIN_DSN'], os.environ['KC_DEMO_RUNTIME_PASSWORD']); print('Demo database and users are ready.')"
} else {
    & $venvPython -m kc.local_demo
}
if ($LASTEXITCODE -ne 0) { throw 'Local demo failed.' }
