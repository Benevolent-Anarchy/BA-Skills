#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Project.psm1')
Import-Module (Join-Path $PSScriptRoot 'State.psm1')
Import-Module (Join-Path $PSScriptRoot 'GitHub.psm1')
Import-Module (Join-Path $PSScriptRoot 'Obsidian.psm1')
$script:DefaultRequest={param($Method,$Endpoint,$Body) Invoke-GitHubRequest $Method $Endpoint $Body}
$script:DefaultGit={param($Repository,$Arguments) Invoke-BootstrapGit $Repository $Arguments}
function Invoke-CheckedApi($Request,$Method,$Endpoint,$Body=$null,$Allowed=@(200,201,204)) {
    $response=& $Request $Method $Endpoint $Body
    if ($null -eq $response -or $response.StatusCode -notin $Allowed) {throw "GitHub $Method $Endpoint failed (HTTP $($response.StatusCode))."}
    return $response
}
function Invoke-CheckedGit($Git,$Repository,$Arguments) {
    $result=& $Git $Repository $Arguments
    if ($result.ExitCode -ne 0) {throw "Git $($Arguments[0]) failed: $($result.Output)"}
    return $result.Output.Trim()
}
function Get-BootstrapReport($Identity,$Journal,$Status,$Pending=@(),$Conflicts=@(),[string]$StateRoot=(Get-BootstrapStateRoot)) {
    @{status=$Status;identity=$Identity;phases=$(if ($null -ne $Journal) {$Journal.phases} else {@{}});pending=@($Pending);conflicts=@($Conflicts);browserEvidence=$(if ($null -ne $Journal) {$Journal.browserEvidence} else {@{}});obsidian=$(if ($null -ne $Journal -and $Journal.ContainsKey('obsidian')) {$Journal.obsidian} else {@{}});journalPath=(Get-BootstrapJournalPath $Identity $StateRoot)}
}
function Get-CreationFailureMessage($Kind,$Failure) {
    $details=if (@($Failure.errors).Count) {' Errors: '+($Failure.errors | ConvertTo-Json -Depth 12 -Compress)} else {''}
    "GitHub $Kind repository creation failed (HTTP $($Failure.statusCode)): $($Failure.message)$details Repair the reported condition, then explicitly resume using the stored inputs."
}
function Get-BootstrapStoredIdentity([string]$Name,[string]$Owner='Benevolent-Anarchy',[string]$StateRoot=(Get-BootstrapStateRoot)) {
    $repository=Resolve-BootstrapRepositoryName $Name
    $journal=Read-BootstrapJournal (Get-BootstrapJournalPath @{owner=$Owner;repository=$repository} $StateRoot)
    if ($null -eq $journal) {throw "No bootstrap journal exists for $Owner/$repository."}
    if ($journal.identity.owner -ine $Owner -or $journal.identity.repository -ine $repository -or $journal.inputHash -ne (Get-BootstrapInputHash $journal.identity)) {throw 'Stored journal identity/input hash is inconsistent.'}
    return $journal.identity
}
function Assert-BootstrapPublicSettings($Identity,$Request) {
    $public=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)").Data
    foreach ($key in @('has_issues','has_wiki','has_projects','has_discussions','allow_auto_merge')) {
        if (-not $public.ContainsKey($key) -or $public[$key] -ne $false) {throw "Public setting did not verify: $key"}
    }
    if ($public.ContainsKey('has_pull_requests') -and $public.has_pull_requests -ne $false) {throw 'Public Pull requests are enabled.'}
    if ($public.private -or $public.archived -or $public.default_branch -ne 'main' -or -not $public.permissions.push) {throw 'Public visibility/main/release write access is wrong.'}
    $actions=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/actions/permissions").Data
    if ($actions.enabled) {throw 'Public Actions are enabled.'}
    $pages=Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/pages" $null @(200,404)
    if ($pages.StatusCode -ne 404) {throw 'Public repository has unexpected Pages configuration.'}
}
function Assert-BootstrapInitialCommit($Identity,$Manifest,$Git,[string]$Head) {
    # Inspect the real commit and tree; replacement refs must not supply recovery proof.
    $commit=Invoke-CheckedGit $Git $Identity.projectPath @('--no-replace-objects','cat-file','-p',$Head)
    $headers=($commit -split "`n`n",2)[0]
    if ($headers -notmatch '^tree [0-9a-f]+' -or $headers -match '(?m)^parent ') {throw 'Unrecorded HEAD must be a single root foundation commit.'}
    $tree=Invoke-CheckedGit $Git $Identity.projectPath @('--no-replace-objects','ls-tree','-r','--full-tree',$Head)
    $blobs=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($line in @($tree -split "`n" | Where-Object {$_})) {
        if ($line -notmatch '^(?:100644|100755) blob ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)$') {throw 'Unrecorded foundation tree contains an unexpected entry.'}
        $blobs.Add($Matches[2],$Matches[1])
    }
    if ($blobs.Count -ne @($Manifest).Count) {throw 'Unrecorded foundation tree differs from the manifest paths.'}
    foreach ($entry in $Manifest) {
        if (-not $blobs.ContainsKey($entry.path)) {throw "Unrecorded foundation tree is missing $($entry.path)."}
        # Local-state validation already proves these bytes match the SHA-256 manifest.
        $expected=Invoke-CheckedGit $Git $Identity.projectPath @('hash-object','--no-filters','--',$entry.path)
        if ($expected -cne $blobs[$entry.path]) {throw "Unrecorded foundation blob differs: $($entry.path)."}
    }
}
function Test-BootstrapLocalState($Identity,$Journal,$Manifest,$Git,$Completed=$false) {
    $path=$Identity.projectPath
    if (-not (Test-Path -LiteralPath $path)) {return}
    $item=Get-Item -LiteralPath $path -Force
    if (-not $item.PSIsContainer -or $item.LinkType) {throw 'Project path is a file or linked directory.'}
    if ($null -eq $Journal -and @(Get-ChildItem -LiteralPath $path -Force).Count) {throw 'Project path already contains files without bootstrap ownership evidence.'}
    if (-not $Completed) {
        foreach ($entry in $Manifest) {
            $target=Join-Path $path $entry.path
            $cursor=$target
            while ($cursor -ne $path) {
                if (Test-Path -LiteralPath $cursor) {
                    $existing=Get-Item -LiteralPath $cursor -Force
                    if ($existing.LinkType -or ($cursor -ne $target -and -not $existing.PSIsContainer)) {throw "Generated path conflicts at $($entry.path)."}
                }
                $cursor=Split-Path $cursor -Parent
            }
            if (Test-Path -LiteralPath $target) {
                if (-not (Test-Path -LiteralPath $target -PathType Leaf) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $entry.sha256) {throw "Generated file differs: $($entry.path)."}
            }
        }
    }
    if (Test-Path -LiteralPath (Join-Path $path '.git')) {
        if ($null -eq $Journal -or -not $Journal.repositories.ContainsKey('private')) {throw 'Existing Git checkout has no recorded bootstrap repository identity.'}
        $actualRoot=Invoke-CheckedGit $Git $path @('rev-parse','--show-toplevel')
        if ([IO.Path]::GetFullPath($actualRoot) -ne $path) {throw 'Git root differs from the project path.'}
        $origin=Invoke-CheckedGit $Git $path @('remote','get-url','origin')
        if ($origin -ne "https://github.com/$($Identity.fullName).git") {throw 'Existing Git origin differs from the recorded project.'}
        if (-not $Completed) {
            $branch=Invoke-CheckedGit $Git $path @('branch','--show-current')
            if ($branch -ne 'main') {throw 'Partial project must be on main.'}
            $staged=Invoke-CheckedGit $Git $path @('diff','--cached','--name-only')
            foreach ($file in @($staged -split "`n" | Where-Object {$_})) {if ($file -notin $Manifest.path) {throw "Unexpected staged file: $file"}}
            $head=& $Git $path @('rev-parse','--verify','HEAD')
            if ($head.ExitCode -eq 0) {
                if (-not $Journal.refs.ContainsKey('privateMain')) {Assert-BootstrapInitialCommit $Identity $Manifest $Git $head.Output.Trim()}
                elseif ($head.Output.Trim() -ne $Journal.refs.privateMain) {throw 'Unexpected local commit; it is not the recorded initial foundation.'}
            }
        }
    } elseif ($null -ne $Journal -and $Journal.phases.ContainsKey('privateContent') -and $Journal.phases.privateContent -eq 'verified') {throw 'Recorded private checkout is missing its Git repository.'}
}
function Get-BootstrapPlan([hashtable]$Identity,[scriptblock]$Request=$script:DefaultRequest,[string]$StateRoot=(Get-BootstrapStateRoot),[scriptblock]$Git=$script:DefaultGit) {
    $conflicts=[Collections.Generic.List[string]]::new();$journal=$null;$ownerType=$null
    try {
        $manifest=Get-ProjectManifest $Identity
        $journal=Read-BootstrapJournal (Get-BootstrapJournalPath $Identity $StateRoot)
        if ($null -ne $journal -and $journal.inputHash -ne (Get-BootstrapInputHash $Identity)) {throw 'Journal input differs from the requested identity.'}
        if ($null -ne $journal -and -not ($journal.phases.ContainsKey('complete') -and $journal.phases.complete -eq 'verified')) {Assert-BootstrapJournal $journal $Identity $manifest}
        Test-BootstrapLocalState $Identity $journal $manifest $Git ($null -ne $journal -and $journal.phases.ContainsKey('complete') -and $journal.phases.complete -eq 'verified')
        $user=(Invoke-CheckedApi $Request GET '/user').Data
        $owner=(Invoke-CheckedApi $Request GET "/users/$($Identity.owner)").Data
        $ownerType=$owner.type
        if ($ownerType -eq 'Organization') {
            $membership=(Invoke-CheckedApi $Request GET "/user/memberships/orgs/$($Identity.owner)").Data
            if ($membership.state -ne 'active' -or $membership.role -ne 'admin') {throw 'Organization ownership/access is not confirmed. Creation requires an active organization owner.'}
        } elseif ($ownerType -ne 'User' -or $user.login -ne $Identity.owner) {throw 'Personal repository owner must be the authenticated GitHub user.'}
    } catch {$conflicts.Add($_.Exception.Message)}
    foreach ($kind in @('private','public')) {
        $name=if ($kind -eq 'private') {$Identity.fullName} else {$Identity.notesFullName}
        try {
            $response=Invoke-CheckedApi $Request GET "/repos/$name" $null @(200,404)
            if ($response.StatusCode -eq 200) {
                if ($null -eq $journal -or -not $journal.repositories.ContainsKey($kind)) {
                    if ($null -ne $journal -and $journal.phases.ContainsKey($kind+'Repository') -and $journal.phases[$kind+'Repository'] -eq 'creating') {$conflicts.Add("identity-unconfirmed: $name exists with ID $($response.Data.id), without a durably recorded returned ID.")}
                    else {$conflicts.Add("Repository name already exists: $name")}
                } elseif ($journal.repositories[$kind] -ne $response.Data.id -or $response.Data.full_name -ine $name -or $response.Data.private -ne ($kind -eq 'private')) {$conflicts.Add("Recorded repository identity/visibility differs: $name")}
            } elseif ($null -ne $journal -and $journal.repositories.ContainsKey($kind)) {$conflicts.Add("Recorded repository is missing or inaccessible: $name")}
            elseif ($null -ne $journal -and $journal.phases.ContainsKey($kind+'Repository') -and $journal.phases[$kind+'Repository'] -eq 'creating') {$conflicts.Add("identity-unconfirmed: prior creation of $name has an unresolved outcome; do not retry automatically.")}
        } catch {$conflicts.Add($_.Exception.Message)}
    }
    $report=Get-BootstrapReport $Identity $journal $(if ($conflicts.Count) {'blocked'} else {'ready'}) @() $conflicts.ToArray()
    if (@($conflicts | Where-Object {$_ -like 'identity-unconfirmed:*'}).Count) {$report.status='identity-unconfirmed'}
    $report.ownerType=$ownerType;$report.journalPath=Get-BootstrapJournalPath $Identity $StateRoot
    return $report
}
function Get-BootstrapStatus([hashtable]$Identity,[string]$StateRoot=(Get-BootstrapStateRoot),[scriptblock]$Request=$script:DefaultRequest) {
    try {
        $journal=Read-BootstrapJournal (Get-BootstrapJournalPath $Identity $StateRoot)
        if ($null -eq $journal) {return Get-BootstrapReport $Identity $null 'not-started' -StateRoot $StateRoot}
        foreach ($kind in @('private','public')) {
            if ($journal.repositories.ContainsKey($kind)) {
                $name=if ($kind -eq 'private') {$Identity.fullName} else {$Identity.notesFullName}
                $repo=(Invoke-CheckedApi $Request GET "/repos/$name").Data
                if ($repo.id -ne $journal.repositories[$kind] -or $repo.full_name -ine $name -or $repo.private -ne ($kind -eq 'private')) {throw "Recorded repository identity differs: $name"}
            }
        }
        if ($journal.phases.ContainsKey('publicSettings') -and $journal.phases.publicSettings -eq 'verified') {Assert-BootstrapPublicSettings $Identity $Request}
        $pending=@()
        foreach ($phase in @('privateRepository','publicRepository','privateContent','publicContent','labels','publicSettings')) {
            if (-not ($journal.phases.ContainsKey($phase) -and $journal.phases[$phase] -eq 'verified')) {$pending+="Unfinished bootstrap phase: $phase"}
        }
        if (-not ($journal.phases.ContainsKey('pullRequests') -and $journal.phases.pullRequests -eq 'verified')) {$pending+="Disable Pull requests and verify in https://github.com/$($Identity.notesFullName)/settings"}
        if (-not ($journal.phases.ContainsKey('obsidian') -and $journal.phases.obsidian -eq 'verified')) {$pending+='Obsidian installation and first-use enablement verification'}
        $status=if ($journal.phases.ContainsKey('complete') -and $journal.phases.complete -eq 'verified') {'complete'} else {'partial'}
        $conflicts=@()
        foreach ($kind in @('private','public')) {
            if ($journal.repositories.ContainsKey($kind) -or -not $journal.phases.ContainsKey($kind+'Repository')) {continue}
            if ($journal.phases[$kind+'Repository'] -eq 'failed') {
                $pending+=Get-CreationFailureMessage $kind $journal.creationFailures[$kind]
                $status='blocked'
            } elseif ($journal.phases[$kind+'Repository'] -eq 'creating') {
                $conflicts+="identity-unconfirmed: prior $kind repository creation has an unresolved outcome; do not retry automatically."
            }
        }
        if ($conflicts.Count) {$status='identity-unconfirmed'}
        $report=Get-BootstrapReport $Identity $journal $status $pending $conflicts
        $report.journalPath=Get-BootstrapJournalPath $Identity $StateRoot
        return $report
    } catch {return Get-BootstrapReport $Identity $null 'blocked' @() @($_.Exception.Message) -StateRoot $StateRoot}
}
function Invoke-Bootstrap(
    [hashtable]$Identity,[string]$StateRoot=(Get-BootstrapStateRoot),[scriptblock]$Request=$script:DefaultRequest,[scriptblock]$Git=$script:DefaultGit,
    [scriptblock]$ObsidianSetup={param($id,$state,$refresh) Install-ProjectObsidian -Identity $id -StateRoot $state -RefreshPlugins:$refresh},[switch]$RefreshPlugins
) {
    $lock=$null;$journal=$null;$path=Get-BootstrapJournalPath $Identity $StateRoot
    try {
        $plan=Get-BootstrapPlan $Identity $Request $StateRoot $Git
        if ($plan.status -ne 'ready') {return $plan}
        $lock=Enter-BootstrapLock $path
        # Repeat preflight after locking; another completed invocation may have changed state.
        $plan=Get-BootstrapPlan $Identity $Request $StateRoot $Git
        if ($plan.status -ne 'ready') {return $plan}
        $manifest=Get-ProjectManifest $Identity
        $journal=Read-BootstrapJournal $path
        if ($null -eq $journal) {$journal=New-BootstrapJournal $Identity $manifest;Write-BootstrapJournal $path $journal $lock}
        if ($journal.phases.ContainsKey('complete') -and $journal.phases.complete -eq 'verified') {
            $report=Get-BootstrapStatus $Identity $StateRoot $Request
            if ($RefreshPlugins) {
                $report.status='blocked'
                $report.pending+="Completed bootstrap preserves project development. Run local-setup with -Repository '$($Identity.projectPath)' -RefreshPlugins to update this vault."
            }
            return $report
        }
        function Save-Phase($Name,$Status='verified') {$journal.phases[$Name]=$Status;Write-BootstrapJournal $path $journal $lock}
        foreach ($kind in @('private','public')) {
            if ($journal.repositories.ContainsKey($kind)) {continue}
            $name=if ($kind -eq 'private') {$Identity.repository} else {$Identity.notesRepository}
            $body=@{name=$name;private=($kind -eq 'private');has_issues=($kind -eq 'private');auto_init=$false}
            if ($kind -eq 'private') {$body.description=$Identity.description} else {$body.has_projects=$false;$body.has_wiki=$false}
            Save-Phase ($kind+'Repository') 'creating'
            $endpoint=if ($plan.ownerType -eq 'Organization') {"/orgs/$($Identity.owner)/repos"} else {'/user/repos'}
            try {$response=& $Request POST $endpoint $body} catch {
                $message=$_.Exception.Message
                $report=Get-BootstrapPlan $Identity $Request $StateRoot $Git
                $report.status='identity-unconfirmed';$report.pending+=$message;return $report
            }
            $statusCode=if ($null -ne $response) {[int]$response.StatusCode} else {0}
            # A definite client rejection has no created identity. A timeout can still
            # follow a server-side creation, so keep HTTP 408 quarantined with lost/5xx results.
            if ($statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 408) {
                $failure=@{statusCode=$statusCode;message='GitHub rejected the request.';errors=@()}
                if ($null -ne $response.Data) {
                    if ($response.Data.ContainsKey('message')) {$failure.message=$response.Data.message}
                    if ($response.Data.ContainsKey('errors')) {$failure.errors=@($response.Data.errors)}
                }
                if (-not $journal.ContainsKey('creationFailures')) {$journal.creationFailures=@{}}
                $journal.creationFailures[$kind]=$failure
                Save-Phase ($kind+'Repository') 'failed'
                return Get-BootstrapReport $Identity $journal 'blocked' @(Get-CreationFailureMessage $kind $failure) -StateRoot $StateRoot
            }
            if ($statusCode -ne 201 -or $null -eq $response.Data -or -not $response.Data.id) {
                # Never bind a GET observation to an invocation whose create result was lost.
                $report=Get-BootstrapPlan $Identity $Request $StateRoot $Git
                $report.status='identity-unconfirmed';return $report
            }
            $fullName=if ($kind -eq 'private') {$Identity.fullName} else {$Identity.notesFullName}
            if ($response.Data.full_name -ine $fullName -or $response.Data.private -ne ($kind -eq 'private')) {throw 'Created repository response has unexpected identity or visibility.'}
            $journal.repositories[$kind]=$response.Data.id
            if ($journal.ContainsKey('creationFailures')) {$journal.creationFailures.Remove($kind)}
            Save-Phase ($kind+'Repository')
        }
        if (-not ($journal.phases.ContainsKey('privateContent') -and $journal.phases.privateContent -eq 'verified')) {
            Write-ProjectFoundation $Identity | Out-Null
            if (-not (Test-Path -LiteralPath (Join-Path $Identity.projectPath '.git'))) {
                Invoke-CheckedGit $Git $Identity.projectPath @('init','--initial-branch=main') | Out-Null
                Invoke-CheckedGit $Git $Identity.projectPath @('remote','add','origin',"https://github.com/$($Identity.fullName).git") | Out-Null
            }
            $gate=& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $Identity.projectPath 'tools/verify.ps1') 2>&1
            if ($LASTEXITCODE -ne 0) {throw "Initial documentation gate failed: $gate"}
            if (-not $journal.refs.ContainsKey('privateMain')) {
                $head=& $Git $Identity.projectPath @('rev-parse','--verify','HEAD')
                if ($head.ExitCode -eq 0) {
                    Assert-BootstrapInitialCommit $Identity $manifest $Git $head.Output.Trim()
                    $journal.refs.privateMain=$head.Output.Trim()
                } else {
                    Invoke-CheckedGit $Git $Identity.projectPath (@('add','-f','--')+@($manifest.path)) | Out-Null
                    Invoke-CheckedGit $Git $Identity.projectPath @('commit','-m','Initial project foundation') | Out-Null
                    $journal.refs.privateMain=Invoke-CheckedGit $Git $Identity.projectPath @('rev-parse','HEAD')
                }
                Write-BootstrapJournal $path $journal $lock
            }
            $remote=Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)/git/ref/heads/main" $null @(200,404,409)
            # GitHub uses this specific conflict for a newly created repository with no commits.
            if ($remote.StatusCode -eq 409 -and ($null -eq $remote.Data -or $remote.Data.message -cne 'Git Repository is empty.')) {throw 'Initial main ref has an unresolved GitHub conflict; preserve the checkout.'}
            if ($remote.StatusCode -in @(404,409)) {
                $push=& $Git $Identity.projectPath @('push','--set-upstream','origin','main')
                $remote=Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)/git/ref/heads/main" $null @(200,404)
                if ($remote.StatusCode -ne 200) {throw "Initial main push is unresolved (exit $($push.ExitCode)); resume to compare the remote ref."}
            }
            if ($remote.Data.object.sha -ne $journal.refs.privateMain) {throw 'Remote main differs from the intended initial commit; do not force-push.'}
            $tree=(Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)/git/trees/$($journal.refs.privateMain)?recursive=1").Data
            if ($tree.truncated -or (@($tree.tree | Where-Object type -ne 'tree' | ForEach-Object path | Sort-Object) -join "`n") -cne (@($manifest.path | Sort-Object) -join "`n")) {throw 'Private remote tree differs from the generated manifest.'}
            Invoke-CheckedApi $Request PATCH "/repos/$($Identity.fullName)" @{default_branch='main'} | Out-Null
            $repo=(Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)").Data
            if ($repo.default_branch -ne 'main' -or -not $repo.has_issues) {throw 'Private main/Issues settings did not verify.'}
            Save-Phase 'privateContent'
        }
        if (-not ($journal.phases.ContainsKey('publicContent') -and $journal.phases.publicContent -eq 'verified')) {
            $expected=Get-PublicReadme $Identity
            $readme=Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/contents/README.md" $null @(200,404)
            if ($readme.StatusCode -eq 404) {
                $body=@{message='Initial public release-notes record';content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($expected))}
                & $Request PUT "/repos/$($Identity.notesFullName)/contents/README.md" $body | Out-Null
                $readme=Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/contents/README.md"
            }
            if ($readme.Data.encoding -ne 'base64' -or [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($readme.Data.content)) -cne $expected) {throw 'Public README differs from the intended public record; preserve it.'}
            $public=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)").Data
            if ($public.default_branch -ne 'main') {Invoke-CheckedApi $Request POST "/repos/$($Identity.notesFullName)/branches/$([uri]::EscapeDataString($public.default_branch))/rename" @{new_name='main'} | Out-Null}
            $ref=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/git/ref/heads/main").Data
            $tree=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/git/trees/$($ref.object.sha)?recursive=1").Data
            if ($tree.truncated -or $tree.tree.Count -ne 1 -or $tree.tree[0].path -ne 'README.md' -or $tree.tree[0].type -ne 'blob') {throw 'Public repository must contain only the initial README.'}
            $journal.refs.publicMain=$ref.object.sha;Save-Phase 'publicContent'
        }
        if (-not ($journal.phases.ContainsKey('labels') -and $journal.phases.labels -eq 'verified')) {
            $labels=@{}
            for ($page=1; ;$page++) {
                $batch=@((Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)/labels?per_page=100&page=$page").Data)
                foreach ($label in $batch) {$labels[$label.name]=$label}
                if ($batch.Count -lt 100) {break}
            }
            $snapshot=[IO.File]::ReadAllText((Join-Path $PSScriptRoot '../assets/labels.json')) | ConvertFrom-Json -AsHashtable
            foreach ($label in $snapshot) {
                $endpoint="/repos/$($Identity.fullName)/labels";$method='POST'
                if ($labels.ContainsKey($label.name)) {
                    $current=$labels[$label.name]
                    if ($current.color -ieq $label.color -and $current.description -ceq $label.description) {continue}
                    $method='PATCH';$endpoint+='/'+[uri]::EscapeDataString($label.name)
                }
                Invoke-CheckedApi $Request $method $endpoint $label | Out-Null
            }
            $actual=@{}
            for ($page=1; ;$page++) {
                $batch=@((Invoke-CheckedApi $Request GET "/repos/$($Identity.fullName)/labels?per_page=100&page=$page").Data)
                foreach ($label in $batch) {$actual[$label.name]=$label}
                if ($batch.Count -lt 100) {break}
            }
            foreach ($label in $snapshot) {if (-not $actual.ContainsKey($label.name) -or $actual[$label.name].color -ine $label.color -or $actual[$label.name].description -cne $label.description) {throw "Label readback differs: $($label.name)"}}
            Save-Phase 'labels'
        }
        $settings=@{has_issues=$false;has_wiki=$false;has_projects=$false;has_discussions=$false;allow_auto_merge=$false}
        $before=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)").Data
        if ($before.ContainsKey('has_pull_requests')) {$settings.has_pull_requests=$false}
        Invoke-CheckedApi $Request PATCH "/repos/$($Identity.notesFullName)" $settings | Out-Null
        Invoke-CheckedApi $Request PUT "/repos/$($Identity.notesFullName)/actions/permissions" @{enabled=$false} | Out-Null
        $public=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)").Data
        foreach ($key in $settings.Keys) {if ($public[$key] -ne $settings[$key]) {throw "Public setting did not verify: $key"}}
        if ($public.private -or $public.archived -or $public.default_branch -ne 'main' -or -not $public.permissions.push) {throw 'Public repository visibility/main/release write access is wrong.'}
        $actions=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/actions/permissions").Data
        if ($actions.enabled) {throw 'Public Actions are still enabled.'}
        $pages=Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)/pages" $null @(200,404)
        if ($pages.StatusCode -ne 404) {throw 'Public repository has unexpected Pages configuration.'}
        Save-Phase 'publicSettings'
        if ($settings.ContainsKey('has_pull_requests')) {Save-Phase 'pullRequests'}
        elseif (-not $journal.phases.ContainsKey('pullRequests')) {Save-Phase 'pullRequests' 'needs-browser'}
        if ($RefreshPlugins -or -not ($journal.phases.ContainsKey('obsidian') -and $journal.phases.obsidian -eq 'verified')) {
            $obsidian=& $ObsidianSetup $Identity $StateRoot $RefreshPlugins.IsPresent
            $journal.obsidian=@{journalPath=$obsidian.journalPath;plugins=$obsidian.plugins;enabledVerified=$obsidian.enabledVerified;observedAt=[datetime]::UtcNow.ToString('o')}
            Save-Phase 'obsidian' $(if (-not $obsidian.installedVerified) {'incomplete'} elseif ($obsidian.enabledVerified) {'verified'} else {'needs-app'})
            if (-not $obsidian.installedVerified -or -not $obsidian.enabledVerified) {
                $report=Get-BootstrapStatus $Identity $StateRoot $Request
                $report.pending+=@($obsidian.pending)
                return $report
            }
        }
        if ($journal.phases.pullRequests -eq 'verified' -and $journal.phases.obsidian -eq 'verified') {Save-Phase 'complete'}
        return Get-BootstrapStatus $Identity $StateRoot $Request
    } catch {
        $status=if ($null -ne $journal) {'partial'} else {'blocked'}
        return Get-BootstrapReport $Identity $journal $status @($_.Exception.Message) -StateRoot $StateRoot
    } finally {if ($null -ne $lock) {$lock.Dispose()}}
}
function Set-BootstrapBrowserEvidence([hashtable]$Identity,[string]$Setting,[hashtable]$Evidence,[string]$StateRoot=(Get-BootstrapStateRoot),[scriptblock]$Request=$script:DefaultRequest) {
    if ($Setting -ne 'pullRequests' -or $Evidence.disabled -ne $true -or $Evidence.sourceUrl -ne "https://github.com/$($Identity.notesFullName)/settings") {throw 'Expected an authenticated observation of disabled Pull requests on the exact repository Settings page.'}
    $date=[datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse($Evidence.observedAt,[ref]$date)) {throw 'Browser evidence needs its observation timestamp.'}
    $path=Get-BootstrapJournalPath $Identity $StateRoot;$lock=Enter-BootstrapLock $path
    try {
        $journal=Read-BootstrapJournal $path
        $repo=(Invoke-CheckedApi $Request GET "/repos/$($Identity.notesFullName)").Data
        if ($null -eq $journal -or -not $journal.repositories.ContainsKey('public') -or $Evidence.repositoryId -ne $journal.repositories.public -or $repo.id -ne $journal.repositories.public -or $repo.full_name -ine $Identity.notesFullName) {throw 'Browser evidence repository identity does not match the recorded public repository.'}
        $journal.browserEvidence[$Setting]=$Evidence;$journal.phases[$Setting]='verified'
        Write-BootstrapJournal $path $journal $lock
        return Get-BootstrapStatus $Identity $StateRoot $Request
    } finally {$lock.Dispose()}
}
Export-ModuleMember -Function Get-BootstrapPlan,Get-BootstrapStatus,Invoke-Bootstrap,Set-BootstrapBrowserEvidence,Get-BootstrapStoredIdentity
