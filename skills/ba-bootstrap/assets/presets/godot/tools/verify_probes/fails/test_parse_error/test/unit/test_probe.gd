## Verify self-test probe: a test script that does not parse. GUT alone would
## skip it and pass, so tools/verify.ps1 must fail at the compile step.
extends GutTest


## Missing the colon after its signature, so the script does not parse.
func test_never_runs() -> void
	assert_true(true)
