# Verifies keyless token scope, identity checks, secret handling and environment cleanup.
function New-PlayAuthFixture {
    $folder=Join-Path $sandbox ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $cli=Join-Path $folder 'gcloud.ps1'
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
if ($MyInvocation.ExpectingInput) {$input | Out-Null}
if ($Rest -contains 'list') { '[{"account":"cicely@benevolentanarchy.com","status":"ACTIVE"}]'; exit 0 }
if ($Rest -contains 'print-access-token') { 'user-fixture-secret'; exit 0 }
exit 92
'@ | Set-Content -LiteralPath $cli
    return @{Account='cicely@benevolentanarchy.com';ServiceAccount='ba-release@example-game.iam.gserviceaccount.com';GcloudExecutable=$cli;GcloudConfigDirectory=$folder;TokenTransport={throw 'Unexpected token request in a local fixture.'}}
}
function Import-PlayAuthFixtureModule {
    $path=Join-Path $root 'skills/ba-release/scripts/GooglePlayAuth.psm1'
    Assert (Test-Path -LiteralPath $path) 'Keyless Google Play auth helper is missing.'
    Import-Module $path -Force -Global
}
Test 'Google Play auth provides an Android Publisher token only during the requested action' {
    Import-PlayAuthFixtureModule
    $fixtureArgs=New-PlayAuthFixture
    $priorToken=$env:BA_GOOGLE_PLAY_ACCESS_TOKEN;$priorConfig=$env:CLOUDSDK_CONFIG
    try {
        $env:BA_GOOGLE_PLAY_ACCESS_TOKEN='prior-fixture-token';$env:CLOUDSDK_CONFIG='prior-fixture-directory'
        $transport={param($request)
            Assert ($request.Uri -ceq 'https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/ba-release@example-game.iam.gserviceaccount.com:generateAccessToken') 'Wrong impersonation target.'
            $body=$request.Body | ConvertFrom-Json
            Assert ($body.scope.Count -eq 1 -and $body.scope[0] -ceq 'https://www.googleapis.com/auth/androidpublisher' -and $body.lifetime -ceq '3600s') 'Wrong token scope or lifetime.'
            Assert ($request.Token -is [Security.SecureString]) 'User token is exposed as plain request metadata.'
            return @{accessToken='play-fixture-secret';expireTime=[DateTimeOffset]::UtcNow.AddMinutes(55).ToString('O')}
        }
        $result=Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport $transport -Action { Assert ($env:BA_GOOGLE_PLAY_ACCESS_TOKEN -ceq 'play-fixture-secret') 'Action got no minted Play token.'; 'action completed' }
        Assert ($result -ceq 'action completed') 'Auth emitted credentials or swallowed action output.'
        Assert ($env:BA_GOOGLE_PLAY_ACCESS_TOKEN -ceq 'prior-fixture-token' -and $env:CLOUDSDK_CONFIG -ceq 'prior-fixture-directory') 'Auth did not restore caller environment.'
        Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport $transport -Action {throw 'action failed'}} 'action failed'
        Assert ($env:BA_GOOGLE_PLAY_ACCESS_TOKEN -ceq 'prior-fixture-token') 'Failed action left its minted token behind.'
    } finally {$env:BA_GOOGLE_PLAY_ACCESS_TOKEN=$priorToken;$env:CLOUDSDK_CONFIG=$priorConfig}
}
Test 'Google Play auth refuses a different active identity before requesting tokens' {
    Import-PlayAuthFixtureModule
    $fixtureArgs=New-PlayAuthFixture
    @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
'[{"account":"private@example.com","status":"ACTIVE"}]'
'@ | Set-Content -LiteralPath $fixtureArgs.GcloudExecutable
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport {throw 'unexpected token request'} -Action {throw 'unexpected action'}} 'active account'
}
Test 'Google Play auth preserves a REST-parsed UTC expiry' {
    Import-PlayAuthFixtureModule
    $fixtureArgs=New-PlayAuthFixture
    $response=('{"accessToken":"play-fixture-secret","expireTime":"'+[DateTime]::UtcNow.AddMinutes(55).ToString('yyyy-MM-ddTHH:mm:ssZ')+'"}') | ConvertFrom-Json
    $transport={param($request) return $response}.GetNewClosure()
    $result=Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport $transport -Action {'completed with UTC expiry'}
    Assert ($result -ceq 'completed with UTC expiry') 'REST date conversion changed token expiry.'
}
Test 'Google Play auth sanitizes provider failures and rejects unusable tokens' {
    Import-PlayAuthFixtureModule
    $fixtureArgs=New-PlayAuthFixture
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport {throw 'user-fixture-secret private failure'} -Action {throw 'unexpected action'}} '^Google Play token generation failed\.$'
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport {return @{accessToken='expired-fixture-secret';expireTime='2000-01-01T00:00:00Z'}} -Action {throw 'unexpected action'}} 'usable short-lived token'
    $fixtureArgs.ServiceAccount='ba-release@example-game.iam.gserviceaccount.com/other'
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -Action {throw 'unexpected action'}} 'service account'
}
Test 'Google Play auth refuses a credential cache inside a Git checkout' {
    Import-PlayAuthFixtureModule
    $fixtureArgs=New-PlayAuthFixture
    $repo=New-Fixture 'auth-credential-boundary'
    $fixtureArgs.GcloudConfigDirectory=$repo
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -Action {throw 'unexpected action'}} 'outside Git'
    $fixtureArgs.GcloudConfigDirectory=Join-Path $repo '.git'
    Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -Action {throw 'unexpected action'}} 'outside Git'
}
if ($IsWindows) {
    Test 'Google Play auth skips extensionless gcloud and git shims before identity and token probes' {
        Import-PlayAuthFixtureModule
        $fixtureArgs=New-PlayAuthFixture
        $tools=Split-Path $fixtureArgs.GcloudExecutable -Parent
        $shims=Join-Path $sandbox 'gcloud-shims'
        New-Item -ItemType Directory $shims | Out-Null
        foreach ($name in @('gcloud','git')) {'#!/bin/sh' | Set-Content (Join-Path $shims $name)}
        $fixtureArgs.Remove('GcloudExecutable')
        $priorPath=$env:PATH;$priorToken=$env:BA_GOOGLE_PLAY_ACCESS_TOKEN;$priorConfig=$env:CLOUDSDK_CONFIG
        $env:PATH=$shims+';'+$tools+';'+$priorPath
        try {
            $transport={param($request) return @{accessToken='shim-test-play-token';expireTime=[DateTimeOffset]::UtcNow.AddMinutes(55).ToString('O')}}
            $result=Invoke-WithGooglePlayAccessToken @fixtureArgs -TokenTransport $transport -Action {
                Assert ($env:BA_GOOGLE_PLAY_ACCESS_TOKEN -eq 'shim-test-play-token') 'Resolved CLI did not acquire the scoped token.'
                'completed with runnable gcloud'
            }
            Assert ($result -eq 'completed with runnable gcloud') 'Shim prevented the identity/token workflow.'
            Assert ($env:BA_GOOGLE_PLAY_ACCESS_TOKEN -eq $priorToken -and $env:CLOUDSDK_CONFIG -eq $priorConfig) 'Shim test did not restore authentication environment.'
            Expect-Error {Invoke-WithGooglePlayAccessToken @fixtureArgs -GcloudExecutable (Join-Path $shims 'gcloud') -Action {throw 'unexpected action'}} 'Google CLI executable is missing or not runnable'
        } finally {$env:PATH=$priorPath}
    }
}
