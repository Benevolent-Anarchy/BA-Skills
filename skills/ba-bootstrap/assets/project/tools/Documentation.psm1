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
        $links.Add(@{Kind='wiki'; Target=$target; Label=$label; Line=$line})
        $wikiSpans.Add(@{Start=$match.Index; End=$match.Index+$match.Length-1})
    }
    foreach ($node in $nodes) {
        if ($node -isnot [Markdig.Syntax.Inlines.LinkInline] -or $null -eq $node.Url) { continue }
        $insideWiki=$false
        foreach ($span in $wikiSpans) { if ($node.Span.Start -ge $span.Start -and $node.Span.Start -le $span.End) { $insideWiki=$true; break } }
        if ($insideWiki) { continue }
        $links.Add(@{Kind='markdown'; Target=$node.Url; Label=(Get-DocumentationInlineText $node); Line=$node.Line+1})
    }
    $visible=$clean.ToCharArray(); $linkable=$clean.ToCharArray()
    for ($i=0; $i -lt $clean.Length; $i++) {
        if ($clean[$i] -eq "`n") { continue }
        if ($hidden[$i]) { $visible[$i]=' '; $linkable[$i]=' ' }
        elseif ($code[$i]) { $linkable[$i]=' ' }
    }
    return @{Headings=$headings.ToArray(); Links=@($links | Sort-Object Line); VisibleLines=(-join $visible) -split "`n"; LinkableLines=(-join $linkable) -split "`n"}
}
Export-ModuleMember -Function Get-DocumentationTokens
