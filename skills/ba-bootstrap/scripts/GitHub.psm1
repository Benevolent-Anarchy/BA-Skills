#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'State.psm1')
function Invoke-GitHubRequest([string]$Method,[string]$Endpoint,[hashtable]$Body) {
    $temporary=$null
    try {
        $arguments=@('api',$Endpoint,'--method',$Method,'--include','--hostname','github.com','-H','Accept: application/vnd.github+json','-H','X-GitHub-Api-Version: 2026-03-10')
        if ($null -ne $Body) {
            $temporary=Join-Path ([IO.Path]::GetTempPath()) ('ba-bootstrap-api-'+[guid]::NewGuid().ToString('N')+'.json')
            [IO.File]::WriteAllText($temporary,($Body | ConvertTo-Json -Depth 30),[Text.UTF8Encoding]::new($false))
            $arguments+=@('--input',$temporary)
        }
        $raw=(& gh @arguments 2>&1 | ForEach-Object {$_.ToString()}) -join "`n"
        $status=[regex]::Match($raw,'(?m)^HTTP/\S+\s+(\d{3})')
        if (-not $status.Success) {return @{StatusCode=0;Data=@{message='GitHub CLI transport/authentication failed; inspect gh auth status separately.'}}}
        $code=[int]$status.Groups[1].Value
        $split=[regex]::Split($raw,"\r?\n\r?\n",2)
        $data=$null
        if ($split.Count -gt 1 -and $split[1].Trim()) {
            # gh appends a short stderr status after error JSON; parse the JSON alone.
            $bodyText=$split[1] -replace '(?m)^gh:.*$',''
            try {$data=ConvertFrom-BootstrapJson $bodyText.Trim()} catch {$data=@{message='GitHub returned an unreadable response.'}}
        }
        return @{StatusCode=$code;Data=$data}
    } finally {if ($temporary) {Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}}
}
function Invoke-BootstrapGit([string]$Repository,[string[]]$Arguments) {
    $output=(& git -C $Repository @Arguments 2>&1 | ForEach-Object {$_.ToString()}) -join "`n"
    @{ExitCode=$LASTEXITCODE;Output=$output}
}
Export-ModuleMember -Function Invoke-GitHubRequest,Invoke-BootstrapGit
