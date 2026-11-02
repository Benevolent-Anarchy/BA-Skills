## Verify self-test probe: a test whose assertion fails. The gate
## must fail.
extends GutTest


## Asserts that one equals two.
func test_fails() -> void:
	assert_eq(1, 2)
