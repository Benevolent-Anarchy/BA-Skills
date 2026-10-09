function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-Error([scriptblock]$Action,[string]$Pattern) {
    $message=$null
    try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
    Assert ($null -ne $message -and $message -match $Pattern) "Expected '$Pattern', got '$message'."
}
function Test([string]$Name,[scriptblock]$Body) {
    if ($Name -notlike $Filter) { return }
    try { & $Body; $script:Passed++; Write-Output "PASS $Name" }
    catch { $script:Failed++; Write-Output "FAIL $Name : $($_.Exception.Message)" }
}
function New-BootstrapFixture([string]$Name) {
    $path=Join-Path $sandbox ($Name+'-'+[guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}
function Write-FixtureText([string]$Path,[string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($false))
}
function Invoke-FixtureGit([string]$Repository,[string[]]$Arguments) {
    $output=& git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
    return ($output -join "`n")
}
