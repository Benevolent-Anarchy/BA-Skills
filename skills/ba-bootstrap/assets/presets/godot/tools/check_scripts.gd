## Compiles every GDScript file in the project outside res://addons and quits
## non-zero if any fails, so tools/verify.ps1 catches parse errors and
## warnings configured as errors even in scripts no test loads. GUT cannot be
## relied on for this: it skips a test script that fails to compile, with only
## a warning, and still exits zero.
extends SceneTree

## Third-party plugins, which Godot's default warning rules already exclude.
const ADDONS_DIRECTORY := "res://addons"


## Runs the whole check, then quits with the result as the process exit code.
## It runs here rather than in _init() because Godot adds the project's
## autoload singletons after constructing this script and before calling
## _initialize(); from _init(), any script naming an autoload would fail to
## compile with "Identifier not found".
func _initialize() -> void:
	var scripts := _scripts_under("res://")
	var failures: PackedStringArray = []
	for path in scripts:
		if not _compiles(path):
			failures.append(path)

	if failures.is_empty():
		print("check_scripts: every script compiles (%d checked)." % scripts.size())
		quit(0)
		return
	for failure in failures:
		printerr("check_scripts: does not compile: ", failure)
	printerr("check_scripts: %d of %d scripts do not compile." % [failures.size(), scripts.size()])
	quit(1)


## Returns every .gd file below [param directory], skipping directories as
## Godot's editor file system does: names beginning with a dot, such as
## .godot, and any directory holding a .gdignore file or a nested project's
## project.godot. tools/verify.ps1 applies the same rules when it reads
## import results. res://addons is skipped as well.
func _scripts_under(directory: String) -> PackedStringArray:
	var found: PackedStringArray = []
	for file_name in DirAccess.get_files_at(directory):
		if file_name.get_extension() == "gd":
			found.append(directory.path_join(file_name))
	for subdirectory in DirAccess.get_directories_at(directory):
		var path := directory.path_join(subdirectory)
		if subdirectory.begins_with(".") or path == ADDONS_DIRECTORY:
			continue
		if FileAccess.file_exists(path.path_join(".gdignore")) \
				or FileAccess.file_exists(path.path_join("project.godot")):
			continue
		found.append_array(_scripts_under(path))
	return found


## Returns whether the script at [param path] compiled. load() compiles it,
## printing Godot's own error if that fails, or returns the copy compiled
## already, as this script and the autoloads are before the check starts. A script that failed to compile still loads, but cannot be
## instantiated. Recompiling with reload() is avoided because Godot refuses
## to reload a script with live instances, such as an autoload singleton.
## Note that an @abstract script still counts as instantiable in Godot 4.7.2.
func _compiles(path: String) -> bool:
	var loaded := load(path) as Script
	return loaded != null and loaded.can_instantiate()
