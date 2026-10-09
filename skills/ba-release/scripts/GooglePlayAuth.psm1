# Obtains a keyless Android Publisher token and limits its environment lifetime to one action.
#requires -Version 7.2
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ProcessTools.psm1') -Force

# Uses an existing, separately authorized CLI login; never signs in or grants permissions.
function Invoke-WithGooglePlayAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$ServiceAccount,
        [Parameter(Mandatory)][string]$GcloudConfigDirectory,
        [string]$GcloudExecutable='gcloud',
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(DontShow)][scriptblock]$TokenTransport
    )
    if ($Account -notmatch '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') {throw 'Supply the explicitly authorized Google account.'}
    if ($ServiceAccount -notmatch '^[a-z][a-z0-9-]{4,29}@[a-z][a-z0-9-]{4,29}\.iam\.gserviceaccount\.com$') {throw 'Supply a valid authorized service account email.'}
    if (-not (Test-Path -LiteralPath $GcloudConfigDirectory -PathType Container)) {throw 'The existing Google CLI credential directory is required.'}
    $directory=(Resolve-Path -LiteralPath $GcloudConfigDirectory).Path
    $git=@(Get-Command git -CommandType Application -ErrorAction Stop)[0]
    $boundary=Invoke-ReleaseProbe $git.Source @('-C',$directory,'rev-parse','--git-dir') $directory
    if ($boundary.exitCode -eq 124 -or $boundary.exitCode -eq 0) {throw 'Keep Google CLI credentials outside Git checkouts.'}
    if (-not (Test-Path -LiteralPath $GcloudExecutable -PathType Leaf)) {
        $GcloudExecutable=@(Get-Command $GcloudExecutable -CommandType Application -ErrorAction Stop)[0].Source
    }
    $priorConfig=$env:CLOUDSDK_CONFIG
    $priorToken=$env:BA_GOOGLE_PLAY_ACCESS_TOKEN
    $userToken=$null;$mint=$null
    try {
        $env:CLOUDSDK_CONFIG=$directory
        try {
            $identity=Invoke-ReleaseProbe $GcloudExecutable @('auth','list','--format=json','--quiet') $directory 30
            if ($identity.exitCode -ne 0) {throw 'identity probe failed'}
            $active=@(($identity.text | ConvertFrom-Json) | Where-Object {$_.status -ceq 'ACTIVE'})
        } catch {throw 'Could not verify the Google CLI active account.'}
        if ($active.Count -ne 1 -or $active[0].account -cne $Account) {throw 'Google CLI active account does not match the authorized account.'}
        try {
            $credentials=Invoke-ReleaseProbe $GcloudExecutable @('auth','print-access-token',('--account='+$Account),'--quiet') $directory 30
            if ($credentials.exitCode -ne 0 -or [string]::IsNullOrWhiteSpace($credentials.text)) {throw 'token probe failed'}
            $userToken=ConvertTo-SecureString $credentials.text.Trim() -AsPlainText -Force
            $credentials=$null
        } catch {throw 'Google CLI token acquisition failed; sign in separately in the authorized profile.'}
        $request=@{
            Uri="https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/${ServiceAccount}:generateAccessToken"
            Method='Post';Authentication='Bearer';Token=$userToken;ContentType='application/json'
            Body='{"scope":["https://www.googleapis.com/auth/androidpublisher"],"lifetime":"3600s"}'
            TimeoutSec=30;ErrorAction='Stop'
        }
        try {
            $mint=if ($TokenTransport) {& $TokenTransport $request} else {Invoke-RestMethod @request}
        } catch {throw 'Google Play token generation failed.'}
        try {
            # Invoke-RestMethod can parse a Z timestamp into a UTC DateTime.
            # Parsing its culture-formatted text again would discard that UTC kind.
            $expiry=if ($mint.expireTime -is [DateTime]) {[DateTimeOffset]::new($mint.expireTime)} else {[DateTimeOffset]::Parse($mint.expireTime,[Globalization.CultureInfo]::InvariantCulture)}
            if ([string]::IsNullOrWhiteSpace($mint.accessToken) -or $expiry -le [DateTimeOffset]::UtcNow.AddMinutes(2) -or $expiry -gt [DateTimeOffset]::UtcNow.AddMinutes(65)) {throw 'invalid token'}
        } catch {throw 'Google Play did not return a usable short-lived token.'}
        $env:BA_GOOGLE_PLAY_ACCESS_TOKEN=$mint.accessToken
        $userToken=$null;$mint=$null;$request=$null
        & $Action
    } finally {
        $env:BA_GOOGLE_PLAY_ACCESS_TOKEN=$priorToken
        $env:CLOUDSDK_CONFIG=$priorConfig
        $userToken=$null;$mint=$null;$credentials=$null;$request=$null
    }
}
Export-ModuleMember -Function Invoke-WithGooglePlayAccessToken
