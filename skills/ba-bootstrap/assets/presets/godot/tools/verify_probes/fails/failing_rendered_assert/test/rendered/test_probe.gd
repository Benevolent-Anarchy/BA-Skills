## Verify self-test probe: a rendered test whose assertion fails. It skips
## itself in the headless run, as every rendered test does, so only the
## windowed step can catch it. tools/verify.ps1 must fail there.
extends GutTest


## Skips the script in a headless run. Untyped, as GUT's own declaration is.
func should_skip_script():
	return DisplayServer.get_name() == "headless"


## Asserts that one equals two.
func test_fails() -> void:
	assert_eq(1, 2)
