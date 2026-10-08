# Queries installed agent inventories without sending model prompts or executing releases.
#requires -Version 7.2
[CmdletBinding()]
param([string]$Directory = (Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent))
$ErrorActionPreference = 'Stop'

# Launches a hidden, bounded stdio protocol client and drains diagnostics without exposing them.
function Start-InventoryProcess([string]$Executable, [string[]]$Arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Executable
    $info.WorkingDirectory = (Get-Item -LiteralPath $Directory).FullName
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo=$info
    if (-not $process.Start()) { throw 'Could not start discovery client.' }
    $stderr = $process.StandardError.ReadToEndAsync()
    return $process
}

# Reads complete JSON messages until a matching response arrives, with a total deadline.
function Read-InventoryResponse($Process, [scriptblock]$MatchesResponse, [int]$TimeoutSeconds=30) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $read = $Process.StandardOutput.ReadLineAsync()
        $remaining = [Math]::Max(1,($TimeoutSeconds*1000 - [int]$timer.Elapsed.TotalMilliseconds))
        if (-not $read.Wait($remaining)) { throw 'Agent discovery inventory timed out.' }
        $line = $read.GetAwaiter().GetResult()
        if ($null -eq $line) { throw 'Agent discovery client closed before returning an inventory.' }
        try { $message = $line | ConvertFrom-Json -AsHashtable } catch { continue }
        if (& $MatchesResponse $message) { return $message }
    }
    throw 'Agent discovery inventory timed out.'
}

# Sends structured messages rather than a model prompt or shell command.
function Send-InventoryMessage($Process, $Message) {
    $Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Depth 15 -Compress))
    $Process.StandardInput.Flush()
}

$results = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[string]]::new()
foreach ($agent in @('codex','claude')) {
    $process = $null
    try {
        $command = Get-Command $agent -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ($agent -eq 'codex') {
            $process = Start-InventoryProcess $command.Source @('app-server','--stdio')
            Send-InventoryMessage $process @{id=1;method='initialize';params=@{clientInfo=@{name='ba-release-discovery';version='1.0'}}}
            $initial = Read-InventoryResponse $process {param($m) $m.Contains('id') -and $m.id -eq 1}
            if ($initial.Contains('error')) { throw 'Codex initialization failed.' }
            Send-InventoryMessage $process @{method='initialized';params=@{}}
            Send-InventoryMessage $process @{id=2;method='skills/list';params=@{cwds=@((Get-Item $Directory).FullName);forceReload=$true}}
            $inventory = Read-InventoryResponse $process {param($m) $m.Contains('id') -and $m.id -eq 2}
            if ($inventory.Contains('error')) { throw 'Codex skills/list failed.' }
            $skills = @($inventory.result.data | ForEach-Object {$_.skills} | Where-Object {$_.name -ceq 'ba-release'})
            if ($skills.Count -ne 1 -or -not $skills[0].enabled) { throw 'Codex did not discover exactly one enabled ba-release skill.' }
            $results.Add(@{agent=$agent;discovered=$true;path=$skills[0].path;scope=$skills[0].scope})
        } else {
            $process = Start-InventoryProcess $command.Source @('-p','--input-format','stream-json','--output-format','stream-json','--verbose','--no-session-persistence','--permission-mode','dontAsk')
            Send-InventoryMessage $process @{type='control_request';request_id='ba-release-discovery';request=@{subtype='initialize'}}
            $inventory = Read-InventoryResponse $process {param($m) $m.type -eq 'control_response' -and $m.response.request_id -eq 'ba-release-discovery'}
            if ($inventory.response.subtype -ne 'success') { throw 'Claude Code inventory initialization failed.' }
            $skills = @($inventory.response.response.commands | Where-Object {$_.name -ceq 'ba-release'})
            if ($skills.Count -ne 1) { throw 'Claude Code did not discover the ba-release command.' }
            $results.Add(@{agent=$agent;discovered=$true;command=$skills[0].name;description=$skills[0].description})
        }
    } catch { $errors.Add("${agent}: $($_.Exception.Message)") }
    finally { if ($process) { if (-not $process.HasExited) {$process.Kill($true)}; $process.Dispose() } }
}
@{results=$results.ToArray();errors=$errors.ToArray()} | ConvertTo-Json -Depth 10
if ($errors.Count) { exit 1 }
