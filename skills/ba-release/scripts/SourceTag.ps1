# Names a shipped release's source with an annotated tag on origin, made only once a store is live and never moved.

# Names the commit a prepared plan's tag names, so a replan keeps it as it keeps the plan's baselines; null without a tag.
function Get-ReleasePlanTagCommit($Plan) {
    if ($Plan -is [Collections.IDictionary] -and $Plan.Contains('sourceTag')) {return $Plan.sourceTag.commit}
    return $null
}

# Gives a release's tag record, adding it, pending, for a plan that has a tag.
function Get-ReleaseSourceTagRecord($State) {
    if (-not $State.Contains('sourceTag')) {$State.sourceTag=[ordered]@{status='pending';error=$null}}
    return $State.sourceTag
}

# Gives the one URL a push to origin goes to, after the user's own URL rewriting, once origin's fetch and push settings are
# seen to name the plan's GitHub repository. A push goes to every push URL origin has, so all of them are counted, and
# origin with more than one is refused. A URL is never kept or reported, as one can carry credentials.
function Get-ReleaseTagPushUrl($Plan) {
    $repository=$Plan.repository
    if ((Get-ReleaseSourceRepository $repository) -ne $Plan.sourceTag.repository) {throw (New-ReleaseDiagnosticError "Origin no longer names $($Plan.sourceTag.repository).")}
    $configured=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$repository,'config','--get-all','remote.origin.pushurl') $repository
    foreach ($url in @(if ($configured.exitCode -eq 0) {$configured.text.Split("`n") | Where-Object {$_.Trim()}})) {
        try {$named=ConvertTo-ReleaseSourceRepository $url.Trim()} catch {$named=$null}
        if ($named -ne $Plan.sourceTag.repository) {throw (New-ReleaseDiagnosticError "Origin's push URL does not name $($Plan.sourceTag.repository) without credentials.")}
    }
    $urls=@((Read-ReleaseGit $repository @('remote','get-url','--push','--all','origin')).Split("`n") | Where-Object {$_.Trim()})
    if ($urls.Count -ne 1) {throw (New-ReleaseDiagnosticError 'Origin must push to exactly one URL for the release tag.')}
    return $urls[0].Trim()
}

# Reads the commit tag $Name names at $Url, or $null where it has none. A failed read throws, so an unreachable remote is
# never taken for one without the tag. An annotated tag's commit is listed only when its peeled name is asked for too.
function Get-ReleaseRemoteTagCommit([string]$Repository, [string]$Url, [string]$Name) {
    $ref="refs/tags/$Name"
    $result=Invoke-ReleaseTool 'git' @('-C',$Repository,'ls-remote','--quiet','--tags',$Url,$ref,"$ref^{}") $Repository -Environment @{GIT_TERMINAL_PROMPT='0'}
    if ($result.exitCode -ne 0) {throw (New-ReleaseDiagnosticError 'Cannot read tags from origin; check access to it.')}
    $direct=$null;$peeled=$null
    foreach ($line in $result.text.Split("`n")) {
        $parts=$line.Trim().Split("`t")
        if ($parts.Count -ne 2) {continue}
        if ($parts[1] -ceq $ref) {$direct=$parts[0]} elseif ($parts[1] -ceq "$ref^{}") {$peeled=$parts[0]}
    }
    if ($peeled) {return $peeled}
    return $direct
}

# Reads the commit this checkout's tag $Name names, or $null where it has no such tag.
function Get-ReleaseLocalTagCommit([string]$Repository, [string]$Name) {
    $exists=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'show-ref','--verify','--quiet',"refs/tags/$Name") $Repository
    if ($exists.exitCode -ne 0) {return $null}
    $commit=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Repository,'rev-parse','--verify','--quiet',"refs/tags/$Name^{commit}") $Repository
    if ($commit.exitCode -ne 0) {throw (New-ReleaseDiagnosticError "This checkout's tag $Name does not name a commit; a tag is never moved.")}
    return $commit.text.Trim()
}

# Makes the refusal for a tag that already names another commit. Commits are named; paths and URLs never are.
function New-ReleaseTagConflictError($Tag, [string]$Where, [string]$Commit) {
    return New-ReleaseDiagnosticError "Tag $($Tag.name) already names $Commit $Where, not the release's source $($Tag.commit); a tag is never moved, so reconcile it by hand."
}

# Finds where the tag stands, given the commit origin's tag of that name names, or $null: 'origin' where origin has it on
# the release's source, 'local' where only this checkout does, or $null where neither has it. A tag of that name on another
# commit is refused wherever it is, including here when origin's is right, since a local version tag on the wrong source
# misleads whatever is branched from it.
function Get-ReleaseSourceTagProgress($Plan, $Remote) {
    $tag=$Plan.sourceTag
    if ($Remote -and $Remote -cne $tag.commit) {throw (New-ReleaseTagConflictError $tag 'on origin' $Remote)}
    $local=Get-ReleaseLocalTagCommit $Plan.repository $tag.name
    if ($local -and $local -cne $tag.commit) {throw (New-ReleaseTagConflictError $tag 'in this checkout' $local)}
    if ($Remote) {return 'origin'}
    if ($local) {return 'local'}
    return $null
}

# Checks, before any store write, that the tag can be made as planned: origin names the planned repository, no tag of that
# name names another commit and Git can name the tagger where the tag is still to be made. A recorded success stands only
# while origin's tag names the release's source; otherwise $Record goes back to pending, so the tag is made again, from this
# checkout's tag where it still has one and needing a tagger where it has none, rather than taken as done. Nothing but
# $Record is written.
function Assert-ReleaseSourceTagDestination($Plan, $Record) {
    $remote=Get-ReleaseRemoteTagCommit $Plan.repository (Get-ReleaseTagPushUrl $Plan) $Plan.sourceTag.name
    if ($Record.status -eq 'succeeded' -and $remote -cne $Plan.sourceTag.commit) {$Record.status='pending'}
    if (Get-ReleaseSourceTagProgress $Plan $remote) {return}
    $identity=Invoke-ReleaseTool 'git' @('--no-optional-locks','-C',$Plan.repository,'var','GIT_COMMITTER_IDENT') $Plan.repository
    if ($identity.exitCode -ne 0) {throw (New-ReleaseDiagnosticError 'Git has no tagger identity; set user.name and user.email for this checkout.')}
}

# Puts the release's tag on origin: an annotated tag on the planned commit, made here unless this checkout already has it,
# then pushed alone and without force. A tag already naming that commit, on origin or here, is kept as it is.
function Publish-ReleaseSourceTag($Plan) {
    $tag=$Plan.sourceTag;$repository=$Plan.repository;$ref="refs/tags/$($tag.name)"
    $url=Get-ReleaseTagPushUrl $Plan
    $progress=Get-ReleaseSourceTagProgress $Plan (Get-ReleaseRemoteTagCommit $repository $url $tag.name)
    if ($progress -eq 'origin') {return}
    if (-not $progress) {
        $made=Invoke-ReleaseTool 'git' @('-C',$repository,'tag','--annotate','--message',$tag.message,$tag.name,$tag.commit) $repository
        if ($made.exitCode -ne 0) {throw (New-ReleaseDiagnosticError "Git could not make the annotated tag $($tag.name); check its tagger identity.")}
    }
    # The explicit refspec pushes this one tag; --no-follow-tags keeps push.followTags from sending any other.
    $push=Invoke-ReleaseTool 'git' @('-C',$repository,'push','--no-follow-tags','origin',"${ref}:${ref}") $repository -Environment @{GIT_TERMINAL_PROMPT='0'}
    if ($push.exitCode -ne 0) {throw (New-ReleaseDiagnosticError "Pushing $($tag.name) to origin failed; check push access to $($tag.repository).")}
    if ((Get-ReleaseRemoteTagCommit $repository $url $tag.name) -cne $tag.commit) {throw (New-ReleaseDiagnosticError "Origin does not show $($tag.name) on the release's source after the push.")}
}
