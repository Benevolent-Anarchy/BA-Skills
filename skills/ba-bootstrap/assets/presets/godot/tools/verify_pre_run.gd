## GUT pre-run hook that tools/verify.ps1 installs, so that verification fails
## on orphaned nodes, as it does on errors. GUT counts the nodes left out of
## the tree after each test, and after each script's before_all() and
## after_all(), and prints them, but fails nothing for them. This notes every
## such count as GUT makes it, for tools/verify_post_run.gd to fail the run on;
## that hook also sweeps up, at the end of the run, any node still orphaned
## that no count here caught.
##
## A node taken out of the tree and freed with queue_free() is counted too
## until the frame ends, when Godot frees it, so a test that ends on such an
## action lets the frame end in after_each().
extends GutHookScript

## Each count of orphans, naming the script and the test, or none, that left
## them, and what they are.
var reports: PackedStringArray = []
## The ids of the orphans the reports name, so the closing sweep leaves them
## out.
var reported_ids := {}
## The script GUT is running now, by the two names GUT files its counts under:
## its file name for its tests and after_all(), and its full path for
## before_all().
var _script_name := ""
var _script_path := ""
## The test running now, and the orphans GUT has counted for it so far, each
## described as GUT describes it when it counted it. GUT counts a parameterized
## test after each of its runs but signals its end only after the last, and
## cleans away between runs an orphan a later run freed, so the counts are
## gathered as each run starts, as well as at the end.
var _test_name := ""
var _test_orphans := {}


## Called by GUT before the first test script: listens for the start of each
## script and each run of a test, and the end of each test and each script,
## where GUT has just counted orphans.
func run() -> void:
	gut.start_script.connect(_on_script_started)
	gut.start_test.connect(_on_test_started)
	gut.end_test.connect(_on_test_ended)
	gut.end_script.connect(_on_script_ended)


## Notes the script [param collected_script] about to run, by the names GUT
## counts its orphans under.
func _on_script_started(collected_script) -> void:
	_script_name = collected_script.get_filename_and_inner()
	_script_path = collected_script.get_full_name()


## Starts gathering the orphans of test [param test_name], or, for a later run
## of the same parameterized test, gathers what GUT counted after the run
## before it.
func _on_test_started(test_name: String) -> void:
	if test_name == _test_name:
		_gather()
		return
	_test_name = test_name
	_test_orphans = {}


## Notes every orphan GUT counted for the test that just ended, over all its
## runs: a node freed with queue_free() is counted too until the frame ends.
func _on_test_ended() -> void:
	_gather()
	_note(_test_name, _test_orphans)
	_test_name = ""
	_test_orphans = {}


## Adds what GUT has counted so far for the running test to its orphans,
## described while each is still there to describe.
func _gather() -> void:
	var counter = gut.get_orphan_counter()
	for id in counter.orphanage.get_orphan_ids(_script_name, _test_name):
		if not _test_orphans.has(id):
			_test_orphans[id] = counter.get_orphan_list_text([id])


## Notes the orphans the script left outside its tests, which GUT has counted:
## in before_all(), under its full path, and in after_all(), under its file
## name. Only those that last are noted: GUT also counts there its own
## leftovers, the previous script's test node, which it has already queued to
## be freed, and which a script whose tests never wait runs its whole course
## before Godot frees. A node a script leaked is still there, and not queued.
## Both are looked up in GUT's orphanage, where null names only those outside
## the tests; the counter's own lookup would return the whole script's for
## null, repeating every test's.
func _on_script_ended() -> void:
	var counter = gut.get_orphan_counter()
	var orphanage = counter.orphanage
	var ids: Array = orphanage.get_orphan_ids(_script_path, null).duplicate()
	ids.append_array(orphanage.get_orphan_ids(_script_name, null))
	var lasting := {}
	for id in ids:
		var node = orphanage.orphan_ids[id].instance
		if is_instance_valid(node) and node.get_parent() == null \
				and not node.is_queued_for_deletion():
			lasting[id] = counter.get_orphan_list_text([id])
	_note(null, lasting)


## Notes [param orphans], ids with their descriptions, counted for test
## [param test_name] of the running script, or, for null, outside any test, if
## there are any.
func _note(test_name: Variant, orphans: Dictionary) -> void:
	if orphans.is_empty():
		return
	var where := "outside any test" if test_name == null else str(test_name)
	var described := PackedStringArray(orphans.values().filter(
			func(text: String) -> bool: return not text.is_empty()))
	reports.append("%s, %s: %d orphans\n%s" % [_script_name, where, orphans.size(),
			"\n".join(described)])
	reported_ids.merge(orphans)
