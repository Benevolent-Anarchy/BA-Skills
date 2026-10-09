$documentationModule=Join-Path $assetRoot 'tools/Documentation.psm1'
if (Test-Path -LiteralPath $documentationModule) { Import-Module $documentationModule -Force }
Test 'scanner keeps code in heading titles and complete real link targets' {
    $text=@'
# Topic
## Behaviour of `Size`
`[[missing#Target]]`
<!-- [[also-missing]] -->
[[design/topic#Behaviour of `Size`|Size]]
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'docs/design/topic.md'
    Assert ($tokens.Headings[1].Title -ceq 'Behaviour of `Size`') 'Heading code disappeared.'
    Assert ($tokens.Links.Count -eq 1) 'Code/comment example counted.'
    Assert ($tokens.Links[0].Target -ceq 'design/topic#Behaviour of `Size`') 'Real target was masked.'
    Assert ($tokens.Links[0].Line -eq 5) 'Wrong line number.'
    Assert ($tokens.Headings[1].Anchor -ceq 'behaviour-of-size') 'Wrong Markdown anchor.'
}
Test 'scanner respects unequal fence closers and indented code' {
    $text=@'
````markdown
## Hidden
```
[[hidden]]
```` trailing text
## Still hidden
````
## Visible
    ## Indented example
    [[also-hidden]]
~~~
## Tilde hidden
```
~~~
## After tilde
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'fixture.md'
    Assert (($tokens.Headings.Title -join '|') -ceq 'Visible|After tilde') 'Fence/code boundaries were misread.'
    Assert ($tokens.Links.Count -eq 0) 'Fenced link counted.'
}
Test 'scanner ignores comments but preserves literal comment text inside code spans' {
    $text=@'
# Topic
<!-- comment ` --> ## After HTML
%% comment ` %% ## After Obsidian
<!--
## Hidden HTML
` -->
## Live
%%
## Hidden Obsidian
` %%
## Also live
Text `literal <!-- across
lines` [[design/live|Live]].
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'fixture.md'
    Assert ($tokens.Headings.Title -contains 'Live') 'HTML terminator inside ticks failed.'
    Assert ($tokens.Headings.Title -contains 'Also live') 'Obsidian terminator inside ticks failed.'
    Assert (-not ($tokens.Headings.Title -contains 'Hidden HTML')) 'Hidden HTML heading counted.'
    Assert (-not ($tokens.Headings.Title -contains 'Hidden Obsidian')) 'Hidden Obsidian heading counted.'
    Assert ($tokens.Links.Count -eq 1 -and $tokens.Links[0].Target -ceq 'design/live') 'Multiline code span hid later link.'
}
Test 'scanner confines unmatched spans to their Markdown block' {
    $text=@'
## Heading with stray `
<!-- comment `
## Hidden
-->
## Live
An unmatched ` stays literal.

[[design/live]]
``[[hidden]]``
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'fixture.md'
    Assert (($tokens.Headings.Title -join '|') -ceq 'Heading with stray `|Live') 'Span crossed a heading or comment block.'
    Assert ($tokens.Links.Count -eq 1) 'Double-backtick span counted as a link.'
}
Test 'scanner parses Markdown references attachments aliases and encoded paths' {
    $text=@'
# Topic
[ordinary](<some file.md#some-heading>)
[reference][record]
![image](images/picture.png)
[[#Heading|Alias]]
\[[escaped]]

[record]: decisions/input.md#keyboard-navigation
[external](https://example.invalid/no-network)
[balanced](notes/a(b).md)
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'fixture.md'
    Assert ($tokens.Links.Count -eq 6) 'Reference/image/escaped syntax was misread.'
    Assert (@($tokens.Links | Where-Object Target -ceq 'decisions/input.md#keyboard-navigation').Count -eq 1) 'Reference target missing.'
    Assert (@($tokens.Links | Where-Object Target -ceq 'notes/a(b).md').Count -eq 1) 'Balanced destination missing.'
    Assert (@($tokens.Links | Where-Object {$_.Kind -eq 'wiki' -and $_.Target -ceq '#Heading' -and $_.Label -ceq 'Alias'}).Count -eq 1) 'Alias became target.'
    $windows=Get-DocumentationTokens -Text $text.Replace("`n","`r`n") -File 'fixture.md'
    Assert (($windows.Links.Target -join '|') -ceq ($tokens.Links.Target -join '|')) 'CRLF changed links.'
}
Test 'scanner cannot find an index inside a fenced example' {
    $tokens=Get-DocumentationTokens -Text "``````markdown`n## Index`n[[missing]]`n``````" -File 'fixture.md'
    Assert ($tokens.Headings.Count -eq 0 -and $tokens.Links.Count -eq 0) 'Fenced-only index was live.'
}
Test 'scanner distinguishes invalid fence info and headings differing in code' {
    $text=@'
```not `valid fence info
## Behaviour of `Size`
## Behaviour of `Colour`
~~~
## Hidden
    ~~~
## Still hidden
~~~
## Visible
\\[[live]]
'@
    $tokens=Get-DocumentationTokens -Text $text -File 'fixture.md'
    Assert (($tokens.Headings.Title -join '|') -ceq 'Behaviour of `Size`|Behaviour of `Colour`|Visible') 'Invalid/indented fence changed headings.'
    Assert ($tokens.Links.Count -eq 1 -and $tokens.Links[0].Target -ceq 'live') 'Even escape count hid a real link.'
}
