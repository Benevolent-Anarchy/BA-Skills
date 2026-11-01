# A child process keeps the production scripts' exit behavior, while the test-only git
# transport seam stays outside production and below repository identity validation.
param([string]$ScriptPath, [string]$ParametersPath)
. (Join-Path $PSScriptRoot 'fixture-git.ps1')
$parameters = Import-Clixml -LiteralPath $ParametersPath
& $ScriptPath @parameters
exit $LASTEXITCODE
