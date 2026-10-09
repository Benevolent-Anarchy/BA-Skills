## Verify self-test probe: a test that leaves a node out of the tree and never
## frees it, which GUT counts as an orphan but fails nothing for.
## tools/verify.ps1 must fail even though the test passes.
extends GutTest

## The node the test leaves orphaned, kept so it is never freed.
var _kept: Node


## Makes a node, adds it to no tree and never frees it.
func test_leaves_an_orphan() -> void:
	_kept = Node.new()
	assert_not_null(_kept)
