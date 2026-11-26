extends RefCounted
## Settings > Library > "PSN packages": install what the player dropped into ~/roms/ps3/psn
## (plan psn-pkg Phase 3).
##
## One row under OGUI's Refresh Library button, shown only while the inbox holds something:
## "Install" runs retroforge-launch --psn-install on a worker thread (psn_runner.gd) — one headless
## RPCS3 run installs every .pkg and licence, writes a .psn stub per base game and consumes what
## succeeded; failures stay in the folder, visible and retryable. The row is refused while a game
## runs (two RPCS3s must not write one dev_hdd0), and the ROM library reloads when a run made new
## cards. The count refreshes when the settings menu shows, so a drop over the network share is
## seen without a restart.

const PsnRunner := preload("psn_runner.gd")
const LIBRARY_ID := "retroforge-roms"
const IDLE_TEXT := "Install the PlayStation 3 packages and licences from roms/ps3/psn. Installed files are removed from the folder."

var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene

var logger := Log.get_logger("RetroForgePSN", Log.LEVEL.INFO)
var tree: SceneTree
var runner := PsnRunner.new()
var _nodes: Array[Node] = []
var _menu: Node
var _label: Control
var _button: Control  # card_button_setting


func setup(scene_tree: SceneTree) -> RefCounted:
	runner.finished.connect(_on_finished)
	tree = scene_tree
	return self


func inbox_dir() -> String:
	return OS.get_environment("HOME").path_join("roms/ps3/psn")


## Add the row under Settings > Library's Refresh Library. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("LibrarySettingsMenu", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	if not box:
		return false
	var at: int = box.get_node("RefreshLibraryButton").get_index() + 1 if box.has_node("RefreshLibraryButton") else box.get_child_count()
	_label = section_scene.instantiate()
	_label.text = "PSN Packages"
	_button = button_scene.instantiate()
	_button.text = "Install PSN packages"
	_button.button_text = "Install"
	_button.description = IDLE_TEXT
	_button.pressed.connect(_on_pressed)
	# In the tree FIRST: a component's @onready children only exist once it is ready (OGUI is a
	# release export, where touching such a null child segfaults; scraper_settings.gd's rule).
	# A separator closes the section (shown and hidden with it, as the sections above and below).
	for node in [_label, _button, HSeparator.new()]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	if menu is CanvasItem:
		menu.visibility_changed.connect(_refresh)
		_menu = menu
	_refresh()
	return true


## A running install is deliberately NOT cancelled here: a SIGTERM would kill RPCS3 mid-extract.
## Its finished signal still lands in _on_finished, whose node touches are guarded.
func detach() -> void:
	if is_instance_valid(_menu) and _menu.visibility_changed.is_connected(_refresh):
		_menu.visibility_changed.disconnect(_refresh)
	_menu = null
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	_label = null
	_button = null


## The files waiting in the inbox (the README and other files do not count).
func pending() -> int:
	if not DirAccess.dir_exists_absolute(inbox_dir()):  # tmpfiles makes it; a deleted one is empty
		return 0
	var count := 0
	for file in DirAccess.get_files_at(inbox_dir()):
		var ext := file.get_extension().to_lower()
		if ext in ["pkg", "rap", "edat"]:
			count += 1
	return count


func _refresh() -> void:
	if runner.running:
		return  # _on_finished refreshes; the row stays visible while it works
	var count := pending()
	for node in _nodes:
		if is_instance_valid(node):
			node.visible = count > 0
	if is_instance_valid(_button):
		_button.text = "Install PSN packages (%d)" % count if count > 0 else "Install PSN packages"
		_button.description = IDLE_TEXT
		_button.set("disabled", false)


func _on_pressed() -> void:
	if runner.running:
		return
	if not launch_manager.get_running().is_empty():
		_notify("Close the running game first: installing would disturb it.")
		return
	if runner.start():
		_button.set("disabled", true)
		_button.description = "Installing... a big package takes a few minutes."


func _on_finished(code: int, results: Array, error: String) -> void:
	if code == 0 or not results.is_empty():
		_notify(PsnRunner.results_text(results) if code == 0 else
			PsnRunner.results_text(results) + " " + PsnRunner.failure_text(code, error))
	else:
		_notify(PsnRunner.failure_text(code, error))
	if code != 0:
		logger.warn("retroforge-launch --psn-install exited %d: %s" % [code, error])
	if PsnRunner.any_stub(results):
		library_manager.load_library(LIBRARY_ID)  # the PS3 tab picks up the new cards
	_refresh()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
