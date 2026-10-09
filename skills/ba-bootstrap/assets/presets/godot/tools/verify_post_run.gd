## GUT post-run hook that tools/verify.ps1 installs, with tools/verify_pre_run.gd
## before the run. It fails the run on two things GUT reports but fails
## nothing for, so that the run would otherwise still exit zero:
## - An unexpected error raised outside any test. GUT fails a test for an
##   unexpected error raised inside it, but files one raised anywhere else,
##   such as in before_all(), before_each(), after_each() or after_all(), under
##   no test at all. An error already asserted with GUT's error assertions is
##   marked handled, so it still passes.
## - Orphaned nodes: those verify_pre_run.gd noted as GUT counted them, after
##   each test and each script, and any node still orphaned now, at the end of
##   the run, which no count caught: one a script left while skipping itself,
##   which GUT counts but signals nothing for, or one the last script left as
##   GUT took it out of the tree, after its count. GUT's own final count of
##   orphans comes only after this hook.
##
## It also writes GUT's own totals for the run where the environment variable
## BA_VERIFY_TOTALS says, for verify.ps1's closing summary: GUT's JUnit
## report holds only tests, and leaves out asserts made in before_all() and
## after_all(), which GUT's Run Summary counts.
extends GutHookScript

## The environment variable naming the file to write the run's totals to.
const TOTALS_FILE := "BA_VERIFY_TOTALS"


## Called by GUT after the last test script finishes. An exit code set here
## replaces the one GUT would have used, so it is only ever set to failure:
## a run that already failed stays failed.
func run() -> void:
	var failed := false
	var tracker: GutErrorTracker = gut.error_tracker
	if tracker.should_test_fail_from_errors(GutUtils.NO_TEST):
		printerr("verify: unexpected errors outside any test, as in before_all(), before_each(), ",
				"after_each() or after_all():\n", tracker.get_fail_text_for_errors(GutUtils.NO_TEST))
		failed = true
	var collector = gut.get_pre_run_script_instance()
	var reported: Dictionary = collector.reported_ids if collector != null else {}
	if collector != null and not collector.reports.is_empty():
		printerr("verify: tests left orphaned nodes, out of the tree and not freed when GUT ",
				"counted them. A node freed with queue_free() is still there until the frame ends, ",
				"so a test that ends on such an action lets the frame end in after_each():\n",
				"\n".join(collector.reports))
		failed = true
	var lasting := _lasting_orphans(reported)
	if not lasting.is_empty():
		printerr("verify: nodes still orphaned at the end of the run, which no test's or script's ",
				"count caught, as one left while a script skips itself or as GUT takes the last ",
				"script out of the tree:\n", "\n".join(lasting))
		failed = true
	_write_totals(failed)
	if failed:
		set_exit_code(1)


## Returns a description of each node still orphaned now, out of the tree,
## alive and not queued to be freed, that is not among [param reported], the
## ids of those already reported.
func _lasting_orphans(reported: Dictionary) -> PackedStringArray:
	var described: PackedStringArray = []
	for id in Node.get_orphan_node_ids():
		var node := instance_from_id(id) as Node
		if node == null or reported.has(id) or node.get_parent() != null \
				or node.is_queued_for_deletion():
			continue
		var node_script := node.get_script() as Script
		described.append("* [%s]%s" % [node,
				"" if node_script == null else " " + node_script.resource_path])
	return described


## Writes GUT's totals for the run, as its Run Summary gives them, to the file
## the environment names, if it names one: how many scripts ran tests, how
## many tests ran, how many asserts were made, setup and teardown included, and
## how many seconds GUT took.
func _write_totals(failed: bool) -> void:
	var path := OS.get_environment(TOTALS_FILE)
	if path.is_empty():
		return
	var totals: Dictionary = gut.get_summary().get_totals()
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		printerr("verify: could not write the run's totals to ", path)
		return
	file.store_string(JSON.stringify({
		"hookComplete": true,
		"failed": failed,
		"scripts": totals.scripts,
		"tests": totals.tests,
		"asserts": totals.passing + totals.failing,
		"seconds": gut.get_elapsed_time(),
	}))
