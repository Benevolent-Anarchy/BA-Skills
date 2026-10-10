## Verify self-test probe: a node left orphaned in before_all(), where GUT
## counts it under no test. tools/verify.ps1 must fail even though the test
## passes.
extends GutTest

## The node before_all() leaves orphaned, kept so it is never freed.
var _kept: Node


## Makes a node, adds it to no tree and never frees it.
func before_all() -> void:
	_kept = Node.new()


## Passes, so that only the orphan left in before_all() can fail the run.
func test_passes() -> void:
	assert_true(true)
