#requires -Version 7.2
[CmdletBinding()]
param([string]$Only='*')
$ErrorActionPreference='Stop'
$repository=Split-Path $PSScriptRoot -Parent
Import-Module "$PSScriptRoot/Verification.psm1" -Force
$work=Join-Path ([IO.Path]::GetTempPath()) ('ba-godot-selftest-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$cases=0;$failures=0
foreach ($expectation in @('fails','passes')) {
    foreach ($case in Get-ChildItem "$PSScriptRoot/verify_probes/$expectation" -Directory) {
        $name="$expectation/$($case.Name)"
        if ($name -notlike $Only) {continue}
        $cases++;$copy=Join-Path $work ($expectation+'-'+$case.Name)
        [IO.Directory]::CreateDirectory($copy) | Out-Null
        Get-ChildItem $repository -Force | Where-Object {$_.Name -notin @('.git','dist','.test-results')} | Copy-Item -Destination $copy -Recurse
        foreach ($file in Get-ChildItem $case.FullName -Recurse -File -Force) {
            $relative=[IO.Path]::GetRelativePath($case.FullName,$file.FullName)
            if ($relative -in @('expect.txt','remove.txt')) {continue}
            $target=Join-Path $copy $relative
            [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        }
        $remove=Join-Path $case.FullName 'remove.txt'
        if (Test-Path $remove) {
            foreach ($line in Get-Content $remove | Where-Object {$_}) {
                $target=[IO.Path]::GetFullPath((Join-Path $copy $line))
                if (-not $target.StartsWith($copy+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {throw 'Probe removal escapes its owned copy.'}
                Remove-Item -LiteralPath $target -Recurse -Force
            }
        }
        $result=Invoke-VerificationProcess (Get-Process -Id $PID).Path @('-NoProfile','-File',"$copy/tools/verify.ps1") $copy
        [IO.File]::WriteAllText("$copy.log",$result.Output)
        $expectedPass=$expectation -ceq 'passes'
        $ok=($result.ExitCode -eq 0) -eq $expectedPass
        if (-not $expectedPass) {
            foreach ($line in Get-Content (Join-Path $case.FullName 'expect.txt')) {if ($line.Trim() -and -not $result.Output.Contains($line.Trim())) {$ok=$false}}
        }
        if ($ok) {Write-Output "PASS $name"} else {$failures++;Write-Output "FAIL $name`: $($result.Output)"}
    }
}
if ($cases -eq 0 -or $failures -gt 0) {throw "Godot verifier self-tests: $cases cases, $failures failures. Evidence: $work"}
Write-Output "Godot verifier self-tests: $cases passed. Evidence: $work"
