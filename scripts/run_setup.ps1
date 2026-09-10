param(
    [Parameter(Mandatory = $true)] [string] $DataRoot,
    [string] $DbHost,
    [int] $Port = 5432,
    [string] $Database,
    [string] $User,
    [int] $Workers = 4
)

$ErrorActionPreference = "Stop"
$bundle = Split-Path -Parent $PSScriptRoot
python -m pip install -r (Join-Path $bundle "requirements.txt")
$arguments = @(
    (Join-Path $bundle "run_setup.py"),
    "--data-root", $DataRoot,
    "--port", $Port,
    "--workers", $Workers
)
if ($DbHost) { $arguments += @("--host", $DbHost) }
if ($Database) { $arguments += @("--database", $Database) }
if ($User) { $arguments += @("--user", $User) }
python @arguments