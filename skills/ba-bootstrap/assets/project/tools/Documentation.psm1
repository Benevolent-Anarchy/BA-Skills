#requires -Version 7.2
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# PowerShell ships this parser for its own Markdown commands. No package download.
$parserPath=Join-Path $PSHOME 'Markdig.Signed.dll'
if (-not (Test-Path -LiteralPath $parserPath)) { throw 'PowerShell is missing its bundled Markdown parser (Markdig.Signed.dll). Use a complete PowerShell 7.2+ installation.' }
Add-Type -Path $parserPath
$builder=[Markdig.MarkdownPipelineBuilder]::new()
$builder.PreciseSourceLocation=$true
$script:DocumentationPipeline=$builder.Build()

function Get-DocumentationNodes($Node) {
    ,$Node
    if ($Node -is [Markdig.Syntax.ContainerBlock]) {
        foreach ($child in $Node) { Get-DocumentationNodes $child }
    } elseif ($Node -is [Markdig.Syntax.LeafBlock] -and $null -ne $Node.Inline) {
        Get-DocumentationNodes $Node.Inline
    } elseif ($Node -is [Markdig.Syntax.Inlines.ContainerInline]) {
        $child=$Node.FirstChild
        while ($null -ne $child) { Get-DocumentationNodes $child; $child=$child.NextSibling }
    }
}

function Set-DocumentationMask([bool[]]$Mask,[int]$Start,[int]$End) {
    for ($at=[Math]::Max(0,$Start); $at -le [Math]::Min($Mask.Length-1,$End); $at++) { $Mask[$at]=$true }
}

function Test-DocumentationEscape([string]$Text,[int]$At) {
    $slashes=0
    for ($i=$At-1; $i -ge 0 -and $Text[$i] -eq '\'; $i--) { $slashes++ }
    return ($slashes%2 -eq 1)
}

function Get-DocumentationCommentFreeText([string]$Text) {
    $initial=[Markdig.Markdown]::Parse($Text,$script:DocumentationPipeline)
    $codeNodes=@(Get-DocumentationNodes $initial | Where-Object {$_ -is [Markdig.Syntax.CodeBlock] -or $_ -is [Markdig.Syntax.Inlines.CodeInline]})
    $protected=[bool[]]::new($Text.Length)
    foreach ($node in $codeNodes) { Set-DocumentationMask $protected $node.Span.Start $node.Span.End }
    $removed=[bool[]]::new($Text.Length)
    $at=0
    while ($at -lt $Text.Length) {
        $html=$Text.IndexOf('<!--',$at,[StringComparison]::Ordinal)
        $obsidian=$Text.IndexOf('%%',$at,[StringComparison]::Ordinal)
        if ($html -lt 0 -and $obsidian -lt 0) { break }
        $start=if ($html -ge 0 -and ($obsidian -lt 0 -or $html -lt $obsidian)) {$html} else {$obsidian}
        $marker=if ($start -eq $html) {'<!--'} else {'%%'}
        if ($protected[$start] -or (Test-DocumentationEscape $Text $start)) { $at=$start+$marker.Length; continue }
        $terminator=if ($marker -eq '<!--') {'-->'} else {'%%'}
        $close=$Text.IndexOf($terminator,$start+$marker.Length,[StringComparison]::Ordinal)
        $end=if ($close -lt 0) {$Text.Length-1} else {$close+$terminator.Length-1}
        Set-DocumentationMask $removed $start $end
        # Backticks originating inside an Obsidian comment cannot protect later text.
        foreach ($node in $codeNodes) {
            if ($node.Span.Start -ge $start -and $node.Span.Start -le $end) {
                for ($i=$node.Span.Start; $i -le [Math]::Min($Text.Length-1,$node.Span.End); $i++) { $protected[$i]=$false }
            }
        }
        $at=$end+1
    }
    $clean=[Text.StringBuilder]::new()
    for ($i=0; $i -lt $Text.Length; $i++) {
        if (-not $removed[$i] -or $Text[$i] -eq "`n") { [void]$clean.Append($Text[$i]) }
    }
    return $clean.ToString()
}

function Get-DocumentationInlineText($Container) {
    $text=[Text.StringBuilder]::new()
    $child=$Container.FirstChild
    while ($null -ne $child) {
        if ($child -is [Markdig.Syntax.Inlines.LiteralInline]) { [void]$text.Append($child.Content.ToString()) }
        elseif ($child -is [Markdig.Syntax.Inlines.CodeInline]) { [void]$text.Append($child.Content) }
        elseif ($child -is [Markdig.Syntax.Inlines.ContainerInline]) { [void]$text.Append((Get-DocumentationInlineText $child)) }
        elseif ($child -is [Markdig.Syntax.Inlines.LineBreakInline]) { [void]$text.Append(' ') }
        $child=$child.NextSibling
    }
    return $text.ToString()
}

function Get-MarkdownAnchor([string]$Title) {
    return ([regex]::Replace($Title.Trim().ToLowerInvariant(),'[^\p{L}\p{N}\p{M} _-]','')).Replace(' ','-')
}

function Get-DocumentationTokens([AllowEmptyString()][string]$Text,[string]$File) {
    $clean=Get-DocumentationCommentFreeText $Text.Replace("`r`n","`n").Replace("`r","`n")
    $document=[Markdig.Markdown]::Parse($clean,$script:DocumentationPipeline)
    $nodes=@(Get-DocumentationNodes $document)
    $hidden=[bool[]]::new($clean.Length)
    $code=[bool[]]::new($clean.Length)
    foreach ($node in $nodes) {
        if ($node -is [Markdig.Syntax.CodeBlock] -or $node -is [Markdig.Syntax.HtmlBlock]) { Set-DocumentationMask $hidden $node.Span.Start $node.Span.End }
        if ($node -is [Markdig.Syntax.Inlines.CodeInline] -or $node -is [Markdig.Syntax.Inlines.HtmlInline]) { Set-DocumentationMask $code $node.Span.Start $node.Span.End }
    }
    $headings=[Collections.Generic.List[object]]::new()
    $links=[Collections.Generic.List[object]]::new()
    foreach ($node in $nodes) {
        if ($node -is [Markdig.Syntax.HeadingBlock] -and $null -ne $node.Inline) {
            $span=$node.Inline.Span
            $title=$clean.Substring($span.Start,$span.End-$span.Start+1).Trim()
            $headings.Add(@{Level=$node.Level; Title=$title; Anchor=(Get-MarkdownAnchor (Get-DocumentationInlineText $node.Inline)); Line=$node.Line+1})
        }
    }
    $wikiSpans=[Collections.Generic.List[object]]::new()
    foreach ($match in [regex]::Matches($clean,'\[\[([^\]\r\n]+)\]\]')) {
        if ($hidden[$match.Index] -or $code[$match.Index] -or (Test-DocumentationEscape $clean $match.Index)) { continue }
        $parts=$match.Groups[1].Value.Split('|',2)
        $target=$parts[0].Trim()
        $label=if ($parts.Count -gt 1) {$parts[1].Trim()} else {($target -split '#',2)[0]}
        $line=1+[regex]::Matches($clean.Substring(0,$match.Index),"`n").Count
        $links.Add(@{Kind='wiki'; Target=$target; Label=$label; HasAlias=($parts.Count -gt 1); Line=$line; EndColumn=$match.Index+$match.Length-($clean.LastIndexOf("`n",$match.Index)+1)})
        $wikiSpans.Add(@{Start=$match.Index; End=$match.Index+$match.Length-1})
    }
    foreach ($node in $nodes) {
        if ($node -isnot [Markdig.Syntax.Inlines.LinkInline] -or $null -eq $node.Url) { continue }
        $insideWiki=$false
        foreach ($span in $wikiSpans) { if ($node.Span.Start -ge $span.Start -and $node.Span.Start -le $span.End) { $insideWiki=$true; break } }
        if ($insideWiki) { continue }
        $links.Add(@{Kind='markdown'; Target=$node.Url; Label=(Get-DocumentationInlineText $node); HasAlias=$true; Line=$node.Line+1; EndColumn=$node.Span.End+1-($clean.LastIndexOf("`n",$node.Span.Start)+1)})
    }
    $visible=$clean.ToCharArray(); $linkable=$clean.ToCharArray()
    for ($i=0; $i -lt $clean.Length; $i++) {
        if ($clean[$i] -eq "`n") { continue }
        if ($hidden[$i]) { $visible[$i]=' '; $linkable[$i]=' ' }
        elseif ($code[$i]) { $linkable[$i]=' ' }
    }
    return @{Headings=$headings.ToArray(); Links=@($links | Sort-Object Line); VisibleLines=(-join $visible) -split "`n"; LinkableLines=(-join $linkable) -split "`n"}
}
function Test-DocumentationDate([string]$Date) {
    $parsed=[datetime]::MinValue
    return [datetime]::TryParseExact($Date,'yyyy-MM-dd',[cultureinfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$parsed)
}

function Test-ProjectDocumentation([string]$Repository) {
    $root=[IO.Path]::GetFullPath($Repository).TrimEnd('\','/')
    $vault=Join-Path $root 'docs'
    $diagnostics=[Collections.Generic.List[object]]::new()
    $notes=@{}
    function Add-DocDiagnostic($Code,$File,$Line,$Heading,$Message,$Severity='error') {
        $diagnostics.Add(@{Code=$Code;Severity=$Severity;File=$File;Line=$Line;Heading=$Heading;Message=$Message})
    }
    function Get-DocNote([string]$Path) {
        if (-not $notes.ContainsKey($Path)) {
            try {
                $notes[$Path]=Get-DocumentationTokens -Text ([IO.File]::ReadAllText($Path)) -File $Path
            } catch {
                Add-DocDiagnostic 'unreadable-file' ([IO.Path]::GetRelativePath($root,$Path).Replace('\','/')) 1 '' "Cannot read note: $($_.Exception.Message)"
                $notes[$Path]=@{Headings=@();Links=@();VisibleLines=@();LinkableLines=@()}
            }
        }
        return $notes[$Path]
    }
    function Resolve-DocLink($Source,$Link) {
        $target=[string]$Link.Target
        if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $target.StartsWith('//')) { return @{External=$true;Valid=$true} }
        $parts=$target.Split('#',2)
        $file=[uri]::UnescapeDataString($parts[0])
        $fragment=if ($parts.Count -gt 1) {[uri]::UnescapeDataString($parts[1])} else {''}
        $base=if ($Link.Kind -eq 'wiki') {$vault} elseif ($file.StartsWith('/')) {$root} else {Split-Path $Source -Parent}
        if ($file -eq '') {$path=$Source}
        else {
            $path=[IO.Path]::GetFullPath((Join-Path $base $file.TrimStart('/')))
        }
        if (-not $path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { return @{External=$false;Valid=$false;Reason='Target leaves the repository.'} }
        if ($Link.Kind -eq 'wiki' -and $file -ne '' -and [IO.Path]::GetExtension($file) -ne '.md') {
            # Dots can belong to a note's basename. Keep an existing explicit attachment;
            # otherwise resolve the implicit Markdown suffix, including dotted note names.
            if ([IO.Path]::GetExtension($file) -eq '' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {$path+='.md'}
        }
        # Never traverse a linked directory or file while validating repository content.
        $cursor=$path
        while ($cursor -ne $root) {
            if (Test-Path -LiteralPath $cursor) {
                if ((Get-Item -LiteralPath $cursor -Force).LinkType) { return @{External=$false;Valid=$false;Reason='Target traverses a symbolic link or junction.'} }
            }
            $cursor=Split-Path $cursor -Parent
        }
        # Windows existence checks ignore case. Check each repository-relative entry
        # against its actual name so a passing link also works on GitHub and Linux.
        $cursor=$root
        foreach ($segment in [IO.Path]::GetRelativePath($root,$path).Split([IO.Path]::DirectorySeparatorChar) | Where-Object {$_}) {
            if (-not (Test-Path -LiteralPath $cursor -PathType Container)) {return @{External=$false;Valid=$false;Reason='Target file or directory is missing.'}}
            $entries=@(Get-ChildItem -LiteralPath $cursor -Force)
            $exact=@($entries | Where-Object {[string]::Equals($_.Name,$segment,[StringComparison]::Ordinal)})
            if ($exact.Count -ne 1) {
                $differentCase=@($entries | Where-Object {[string]::Equals($_.Name,$segment,[StringComparison]::OrdinalIgnoreCase)})
                $reason=if ($differentCase.Count) {"Target path casing differs: '$segment' should be '$($differentCase[0].Name)'."} else {'Target file or directory is missing.'}
                return @{External=$false;Valid=$false;Reason=$reason}
            }
            $cursor=$exact[0].FullName
        }
        $heading=$null
        if ($fragment) {
            if ([IO.Path]::GetExtension($path) -ne '.md' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{External=$false;Valid=$false;Reason='A heading needs a Markdown file.'} }
            $note=Get-DocNote $path
            $matches=@($note.Headings | Where-Object { if ($Link.Kind -eq 'wiki') {$_.Title -ceq $fragment} else {$_.Anchor -ceq $fragment} })
            if ($matches.Count -ne 1) { return @{External=$false;Valid=$false;Reason="Heading '$fragment' is missing or ambiguous."} }
            $heading=$matches[0]
        }
        return @{External=$false;Valid=$true;Path=$path;Heading=$heading}
    }
    if (-not (Test-Path -LiteralPath $vault -PathType Container)) {
        Add-DocDiagnostic 'required-path' 'docs' 1 '' 'Required documentation vault is missing.'
        return @{Passed=$false;Diagnostics=$diagnostics.ToArray()}
    }
    # Explicit traversal avoids following tooling junctions or the ignored Obsidian tree.
    $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($vault)
    while ($queue.Count) {
        $dir=$queue.Dequeue()
        try { $items=@(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { Add-DocDiagnostic 'unreadable-file' ([IO.Path]::GetRelativePath($root,$dir)) 1 '' $_.Exception.Message; continue }
        foreach ($item in $items) {
            if ($item.Name -eq '.obsidian') {continue}
            if ($dir -eq $vault -and $item.PSIsContainer -and $item.Name -ceq 'Vault Inspector Reports') {continue}
            if ($item.LinkType) { Add-DocDiagnostic 'linked-path' ([IO.Path]::GetRelativePath($root,$item.FullName)) 1 '' 'Documentation must be readable without following a linked path.'; continue }
            if ($item.PSIsContainer) {$queue.Enqueue($item.FullName)}
            elseif ($item.Extension -eq '.md') {Get-DocNote $item.FullName | Out-Null}
        }
    }
    # Root entry points use repository-relative Markdown links, without corpus rules.
    foreach ($item in Get-ChildItem -LiteralPath $root -File -Force -Filter '*.md') {
        if ($item.LinkType) {Add-DocDiagnostic 'linked-path' $item.Name 1 '' 'Root documentation must be readable without following a linked path.';continue}
        Get-DocNote $item.FullName | Out-Null
    }
    foreach ($path in @($notes.Keys)) {
        $relative=[IO.Path]::GetRelativePath($root,$path).Replace('\','/')
        foreach ($link in $notes[$path].Links) {
            if ((Split-Path $path -Parent) -eq $root -and $link.Kind -eq 'wiki') {continue}
            try {$resolved=Resolve-DocLink $path $link} catch {$resolved=@{Valid=$false;Reason=$_.Exception.Message}}
            if (-not $resolved.Valid) { Add-DocDiagnostic 'link-target' $relative $link.Line '' "$($link.Target): $($resolved.Reason)" }
        }
    }
    foreach ($corpus in @('design','decisions','judgements')) {
        $indexPath=Join-Path $vault ($corpus.ToUpperInvariant()+'.md')
        $indexFile='docs/'+$corpus.ToUpperInvariant()+'.md'
        $topicDir=Join-Path $vault $corpus
        $missing=$false
        foreach ($required in @($indexPath,$topicDir)) {
            $kind=if ($required -eq $indexPath) {'Leaf'} else {'Container'}
            if (-not (Test-Path -LiteralPath $required -PathType $kind) -or (Get-Item -LiteralPath $required -Force).LinkType) {
                Add-DocDiagnostic 'required-path' ([IO.Path]::GetRelativePath($root,$required).Replace('\','/')) 1 '' 'Required index or topical directory is missing or linked.'; $missing=$true
            }
        }
        if ($missing) {continue}
        $index=Get-DocNote $indexPath
        $sections=@($index.Headings | Where-Object {$_.Level -eq 2 -and $_.Title -ceq 'Index'})
        if ($sections.Count -ne 1) {Add-DocDiagnostic 'index-section' $indexFile 1 'Index' 'Expected exactly one live ## Index heading.';continue}
        $start=$sections[0].Line
        $end=$index.VisibleLines.Count+1
        $next=@($index.Headings | Where-Object {$_.Line -gt $start -and $_.Level -le 2} | Sort-Object Line)
        if ($next.Count) {$end=$next[0].Line}
        $topics=@($notes.Keys | Where-Object {$_.StartsWith($topicDir+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)})
        $records=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        $keys=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
        foreach ($topic in $topics) {
            $note=$notes[$topic]; $file=[IO.Path]::GetRelativePath($root,$topic).Replace('\','/')
            $titles=@($note.Headings | Where-Object Level -eq 1)
            if ($titles.Count -ne 1) {Add-DocDiagnostic 'topic-title' $file 1 '' 'Each topical note needs exactly one top-level title.'}
            $selected=@($note.Headings | Where-Object {if ($corpus -eq 'design') {$_.Level -ge 2} else {$_.Level -eq 3}})
            foreach ($heading in $selected) {
                $key=$topic.ToLowerInvariant()+'#'+$heading.Title
                if ($records.ContainsKey($key)) {Add-DocDiagnostic 'duplicate-key' $file $heading.Line $heading.Title 'Duplicate heading in this topic.';continue}
                $record=@{File=$file;Path=$topic;Heading=$heading;Count=0;Metadata=$null;Incomplete=$false}
                $records.Add($key,$record)
                if ($corpus -ne 'design') {
                    if ($keys.ContainsKey($heading.Title)) {Add-DocDiagnostic 'duplicate-key' $file $heading.Line $heading.Title 'Citation key is already defined in another record.'} else {$keys.Add($heading.Title,$record)}
                }
                if ($corpus -eq 'decisions') {
                    $groups=@($note.Headings | Where-Object {$_.Line -lt $heading.Line -and $_.Level -le 2} | Sort-Object Line)
                    if (-not $groups.Count -or $groups[-1].Level -ne 2 -or -not (Test-DocumentationDate $groups[-1].Title)) {Add-DocDiagnostic 'decision-date' $file $heading.Line $heading.Title 'Decision must belong to a real ## YYYY-MM-DD date group.'}
                }
                if ($corpus -eq 'judgements') {
                    $recordEnd=$note.VisibleLines.Count+1
                    $after=@($note.Headings | Where-Object {$_.Line -gt $heading.Line -and $_.Level -le 3} | Sort-Object Line)
                    if ($after.Count) {$recordEnd=$after[0].Line}
                    $metadata=@()
                    for ($line=$heading.Line+1; $line -lt $recordEnd; $line++) {
                        if ($note.VisibleLines[$line-1] -match '^\*Judged .+\.\*$') {$metadata+=@{Line=$line;Text=$note.VisibleLines[$line-1].Substring(1,$note.VisibleLines[$line-1].Length-3)}}
                    }
                    if ($metadata.Count -ne 1 -or $metadata[0].Line -ne $heading.Line+1) {Add-DocDiagnostic 'judgement-metadata' $file $heading.Line $heading.Title 'Expected one immediate, single-line *Judged ... .* statement.';continue}
                    $record.Metadata=$metadata[0].Text
                    $first=($record.Metadata -split '\. ',2)[0]
                    $dates=@([regex]::Matches($record.Metadata,'(?<![\p{L}\p{N}_])\d{4}-\d{2}-\d{2}(?![\p{L}\p{N}_])'))
                    $dateValid=@($dates | Where-Object {Test-DocumentationDate $_.Value}).Count -gt 0
                    $impossible=@($dates | Where-Object {-not (Test-DocumentationDate $_.Value)}).Count -gt 0
                    $dateMissing=$record.Metadata -cmatch '\bDate not recorded\b'
                    $hardwareMissing=$record.Metadata -cmatch '\bHardware not recorded\b'
                    $hardwareValid=$record.Metadata -cmatch '\bHardware not applicable\b'
                    $clauses=($first -replace '^Judged ','') -split ', '
                    foreach ($clause in @($clauses | Select-Object -First 2)) {
                        if ($clause.StartsWith('on ',[StringComparison]::Ordinal)) {
                            $name=$clause.Substring(3) -replace '(?<![\p{L}\p{N}_])\d{4}-\d{2}-\d{2}(?![\p{L}\p{N}_])','' -replace '\bDate not recorded\b',''
                            if ($name -match '\p{L}') {$hardwareValid=$true}
                        }
                    }
                    $body=($note.VisibleLines[($heading.Line)..($recordEnd-2)] -join "`n")
                    $record.Incomplete=($dateMissing -or $hardwareMissing) -and $body -cmatch '\bIncomplete historical record\b'
                    if ($impossible -or (-not $dateValid -and -not ($dateMissing -and $record.Incomplete)) -or (-not $hardwareValid -and -not ($hardwareMissing -and $record.Incomplete))) {Add-DocDiagnostic 'judgement-fields' $file ($heading.Line+1) $heading.Title 'Date and applicable hardware must each be independently recorded.'}
                    elseif ($record.Incomplete) {Add-DocDiagnostic 'incomplete-record' $file $heading.Line $heading.Title 'Incomplete historical record; this is not trusted acceptance.' 'warning'}
                }
            }
        }
        $group=$null; $topicCounts=@{}
        $links=@($index.Links | Where-Object {$_.Line -gt $start -and $_.Line -lt $end})
        $lastLine=$start
        foreach ($link in $links) {
            # Any intervening section heading starts a new group, even without a link.
            if (@($index.Headings | Where-Object {$_.Line -gt $lastLine -and $_.Line -le $link.Line}).Count) {$group=$null}
            $lastLine=$link.Line
            $resolved=Resolve-DocLink $indexPath $link
            if (-not $resolved.Valid -or $resolved.External) {continue}
            if ($resolved.Path -notin $topics) {continue}
            if ($null -eq $resolved.Heading) {
                $group=$resolved.Path
                if (-not $topicCounts.ContainsKey($group)) {$topicCounts[$group]=0}; $topicCounts[$group]++
                $titles=@($notes[$group].Headings | Where-Object Level -eq 1)
                if ($titles.Count -eq 1 -and $link.Label -cne $titles[0].Title) {Add-DocDiagnostic 'topic-title' $indexFile $link.Line '' 'Topic link label must match its top-level title.'}
                continue
            }
            $key=$resolved.Path.ToLowerInvariant()+'#'+$resolved.Heading.Title
            if (-not $records.ContainsKey($key)) {Add-DocDiagnostic 'index-entry' $indexFile $link.Line $resolved.Heading.Title 'Target is not a record or indexed design heading.';continue}
            $record=$records[$key]; $record.Count++
            if ($group -ne $resolved.Path) {Add-DocDiagnostic 'index-group' $indexFile $link.Line $resolved.Heading.Title 'Entry must appear under a link to its actual topical file.'}
            if ($link.HasAlias -and $link.Label -cne $resolved.Heading.Title) {Add-DocDiagnostic 'index-entry' $indexFile $link.Line $resolved.Heading.Title 'Indexed title must match the record title.'}
            if ($corpus -eq 'judgements' -and $null -ne $record.Metadata) {
                $tail=$index.VisibleLines[$link.Line-1].Substring($link.EndColumn).Trim()
                $expected='— '+$record.Metadata
                if (-not ($tail -ceq $expected -or $tail.StartsWith($expected+' — ',[StringComparison]::Ordinal)) -or ($record.Incomplete -and $index.VisibleLines[$link.Line-1] -cnotmatch 'Incomplete historical record')) {Add-DocDiagnostic 'judgement-index' $indexFile $link.Line $resolved.Heading.Title 'Index must copy the complete Judged statement, removing only italics and its final full stop.'}
            }
        }
        foreach ($topic in $topics) {
            if (-not $topicCounts.ContainsKey($topic) -or $topicCounts[$topic] -ne 1) {Add-DocDiagnostic 'topic-index' $indexFile $start '' "Expected one topic group for $([IO.Path]::GetRelativePath($vault,$topic))."}
        }
        foreach ($record in $records.Values) {
            if ($record.Count -eq 0) {Add-DocDiagnostic 'not-indexed' $record.File $record.Heading.Line $record.Heading.Title 'Real record or design heading has no index entry.'}
            elseif ($record.Count -gt 1) {Add-DocDiagnostic 'duplicate-index' $indexFile $start $record.Heading.Title 'Record or design heading appears more than once in the index.'}
        }
    }
    return @{Passed=(@($diagnostics | Where-Object Severity -eq 'error').Count -eq 0);Diagnostics=$diagnostics.ToArray()}
}
Export-ModuleMember -Function Get-DocumentationTokens,Test-ProjectDocumentation
