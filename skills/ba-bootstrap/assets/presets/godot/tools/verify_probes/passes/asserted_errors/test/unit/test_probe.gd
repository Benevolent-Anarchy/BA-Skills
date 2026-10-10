## Verify self-test probe: errors raised on purpose and asserted with GUT's
## error assertions, once in a hook and once in a test. Asserting an error
## marks it handled, so tools/verify.ps1 must pass.
extends GutTest


## Pushes an error outside any test, then asserts it.
func before_each() -> void:
	push_error("probe: expected in before_each")
	assert_push_error("probe: expected in before_each")


## Raises an engine error in a helper, then asserts it. The helper is needed
## because a runtime error ends the function it happens in.
func test_asserted_engine_error() -> void:
	_read_past_end()
	assert_engine_error("Out of bounds")


## Reads past the end of an empty array, which Godot reports as an error.
func _read_past_end() -> void:
	var empty: Array = []
	print(empty[0])
