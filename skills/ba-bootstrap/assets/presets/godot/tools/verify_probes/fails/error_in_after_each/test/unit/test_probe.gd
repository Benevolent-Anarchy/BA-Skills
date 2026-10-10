## Verify self-test probe: an engine error in after_each(), where GUT tracks it
## under no test. tools/verify.ps1 must fail even though the test passes.
extends GutTest


## Reads past the end of an empty array, which Godot reports as an error.
func after_each() -> void:
	var empty: Array = []
	print(empty[0])


## Passes, so that only the error in after_each() can fail the run.
func test_passes() -> void:
	assert_true(true)
