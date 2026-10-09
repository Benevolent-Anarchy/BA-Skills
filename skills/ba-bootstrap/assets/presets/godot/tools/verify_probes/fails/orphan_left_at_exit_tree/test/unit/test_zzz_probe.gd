## Verify self-test probe: a script that leaves a node orphaned as GUT takes
## it out of the tree, after GUT has counted the script's orphans. Named to run
## last, so no later script's count can catch it. tools/verify.ps1 must fail
## although its test passes.
extends GutTest

## The node left orphaned, kept so it is never freed.
var _kept: Node


## Makes a node, adds it to no tree and never frees it, as GUT removes the
## script.
func _exit_tree() -> void:
	_kept = Node.new()


## Passes, so that only the orphan left at _exit_tree() can fail the run.
func test_passes() -> void:
	assert_true(true)
