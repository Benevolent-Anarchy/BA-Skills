## Verify self-test probe: a script that leaves a node orphaned while deciding
## to skip itself. GUT counts it, but runs no test and no before_all() or
## after_all() there. tools/verify.ps1 must fail although nothing else does.
extends GutTest

## The node left orphaned, kept so it is never freed.
var _kept: Node


## Makes a node, adds it to no tree and never frees it, and skips the script.
## It is untyped because GUT's own declaration is, and an override must match
## it.
func should_skip_script():
	_kept = Node.new()
	return "skipped, leaving a node orphaned"


## Never runs: the script skips itself.
func test_never_runs() -> void:
	assert_true(true)
