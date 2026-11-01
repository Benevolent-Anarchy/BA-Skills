Original PowerShell protocol fixtures

original_protocol.py transcribes the retained Release.psm1 functions
Get-ReleasePlan (ordered identity, complete plan and literal requiredActions),
Get-ReleaseArtifact, Get-ReleaseNotesHash and Invoke-ReleasePublish's approval
hashing. It never invokes the native planner/preparer/serializer. These are
protocol fixtures constructed from the original implementation, not a claim
that PowerShell executed on this host (pwsh is absent).

powershell-identity.json fixes the original ordered source-tag identity contract
with a Windows source-path pin and Unicode title. There is no final newline.
SHA-256: 4f45cb0fcd9fd08ca81932ec0c4ffbee1c8b66340d81c5893760358e784f02f0

PowerShell pipeline cardinality is significant for artifact approval:
zero objects => empty text; one object => JSON object; multiple => JSON array.
Object member order is significant to these hashes; array order is preserved.
The full-plan semantic comparison ignores only object member order, and permits
only the original derived Android useGradle omission after all other fields
compare equal, matching Update-ReleaseDerivedPlanMetadata.
