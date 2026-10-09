## Verify self-test probe: a test that takes a node out of the tree and frees
## it with queue_free(), as the application puts things away, and lets the
## frame end in after_each() before GUT counts orphans. tools/verify.ps1 must
## pass: the node is gone by then.
extends GutTest


## Lets the frame end, so the node freed with queue_free() is gone.
func after_each() -> void:
	await wait_process_frames(1)


## Adds a node, then takes it out of the tree and queues it to be freed.
func test_puts_a_node_away() -> void:
	var node := Node.new()
	add_child(node)
	remove_child(node)
	node.queue_free()
	assert_true(node.is_queued_for_deletion())
