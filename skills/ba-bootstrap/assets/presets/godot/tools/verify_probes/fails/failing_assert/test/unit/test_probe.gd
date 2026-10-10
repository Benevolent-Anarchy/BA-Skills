## Verify self-test probe: a test whose assertion fails. tools/verify.ps1
## must fail.
extends GutTest


## Asserts that one equals two.
func test_fails() -> void:
	assert_eq(1, 2)
