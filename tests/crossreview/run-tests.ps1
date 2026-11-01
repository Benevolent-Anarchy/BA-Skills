# Runs the cross-review suite, which is Python, with the first Python 3.10 or newer found.
#requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false
$suite=Join-Path $PSScriptRoot 'test_crossreview.py'
# The launcher comes first on Windows, where python may be the Store's stand-in, which fails the version check.
$candidates=if ($IsWindows) {@('py -3','python')} else {@('python3','python')}
foreach ($candidate in $candidates) {
    $parts=@($candidate -split ' ')
    $command=Get-Command $parts[0] -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) {continue}
    $arguments=@($parts | Select-Object -Skip 1)
    & $command.Source @arguments -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
    if ($LASTEXITCODE -ne 0) {continue}
    & $command.Source @arguments -B $suite -v
    exit $LASTEXITCODE
}
Write-Output "FAIL cross-review suite: no Python 3.10 or newer found (tried $($candidates -join ', '))."
exit 1
