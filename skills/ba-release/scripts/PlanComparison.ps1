# Compares every plan field while ignoring JSON object member order and preserving array order.

# Writes JSON objects in ordinal key order without changing primitive values or ordered arrays.
function Write-ReleaseSortedJsonElement([System.Text.Json.JsonElement]$Element, [System.Text.Json.Utf8JsonWriter]$Writer) {
    switch ($Element.ValueKind) {
        'Object' {
            $Writer.WriteStartObject()
            $names=[string[]]@($Element.EnumerateObject() | ForEach-Object {$_.Name})
            [Array]::Sort($names,[StringComparer]::Ordinal)
            foreach ($name in $names) {$Writer.WritePropertyName($name);Write-ReleaseSortedJsonElement ($Element.GetProperty($name)) $Writer}
            $Writer.WriteEndObject()
        }
        'Array' {
            $Writer.WriteStartArray()
            foreach ($item in $Element.EnumerateArray()) {Write-ReleaseSortedJsonElement $item $Writer}
            $Writer.WriteEndArray()
        }
        default {$Element.WriteTo($Writer)}
    }
}

# Produces a comparable JSON representation; it does not replace the saved plan identity or approval.
function Get-ReleaseComparablePlanJson([string]$Json) {
    $document=[System.Text.Json.JsonDocument]::Parse($Json)
    $stream=[IO.MemoryStream]::new()
    $writer=[System.Text.Json.Utf8JsonWriter]::new($stream)
    try {
        Write-ReleaseSortedJsonElement $document.RootElement $writer
        $writer.Flush()
        return [Text.Encoding]::UTF8.GetString($stream.ToArray())
    } finally {$writer.Dispose();$stream.Dispose();$document.Dispose()}
}
