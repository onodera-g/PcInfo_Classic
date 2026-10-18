param([string]$Python = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$environmentDir = Join-Path $projectRoot '.venv'
$temporaryDir = Join-Path $environmentDir '.tmp'
$savedVariables = @{}
foreach ($name in @('TEMP','TMP','TMPDIR','PIP_CACHE_DIR','PYTHONDONTWRITEBYTECODE')) {
    $savedVariables[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    New-Item -ItemType Directory -Force -Path $temporaryDir | Out-Null
    $env:TEMP = $temporaryDir
    $env:TMP = $temporaryDir
    $env:TMPDIR = $temporaryDir
    $env:PIP_CACHE_DIR = Join-Path $environmentDir '.pip-cache'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $environmentPython = Join-Path $environmentDir 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $environmentPython)) {
        if ($Python) {
            & $Python -B -m venv $environmentDir
        } elseif (Get-Command py.exe -ErrorAction SilentlyContinue) {
            & py.exe -3.12 -B -m venv $environmentDir
        } else {
            & python.exe -B -m venv $environmentDir
        }
        if ($LASTEXITCODE -ne 0) { throw 'Python 3.12 environment creation failed.' }
    }
    & $environmentPython -B -c "import sys; assert sys.platform == 'win32' and sys.version_info[:2] == (3, 12), 'Windows Python 3.12 is required'"
    if ($LASTEXITCODE -ne 0) { throw 'Unsupported Python environment.' }
    & $environmentPython -B -m pip install --disable-pip-version-check -r (Join-Path $projectRoot 'requirements-dev.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
    Write-Host 'Setup complete. Run the build command from this project.'
} finally {
    foreach ($name in $savedVariables.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedVariables[$name], 'Process')
    }
    $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDir)
    if ($resolvedTemporary -eq ([IO.Path]::GetFullPath((Join-Path $projectRoot '.venv\.tmp')))) {
        if (Test-Path -LiteralPath $resolvedTemporary) {
            [IO.Directory]::Delete($resolvedTemporary, $true)
        }
    }
}
