extends GutTest

func test_main_scene_loads_and_shows_the_project_title() -> void:
	var packed := load("res://app/main.tscn") as PackedScene
	assert_not_null(packed)
	if packed == null:
		return
	var main := packed.instantiate()
	add_child_autofree(main)
	var title := main.get_node("Title") as Label
	assert_not_null(title)
	if title != null:
		assert_eq(title.text, ProjectSettings.get_setting("application/config/name"))
