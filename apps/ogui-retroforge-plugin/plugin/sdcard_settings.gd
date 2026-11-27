extends RefCounted
## Settings > Disks > "SD card": what is in the slot, and a Format button that makes it a ROM card.
##
## Above OGUI's own drive cards: the card's total size, its filesystem, where it is mounted, and
## how much of it is used and free (`retroforge-sdcard-info`, read whenever the page is shown and
## whenever udisks2's devices change, so a card inserted or pulled out while the page is open shows
## at once). Format asks in OGUI's dialog, then runs `retroforge-format-sdcard --exfat`: the
## privileged formatter (polkit: the seat session only) takes the [sdcard] share down, unmounts the
## card, deletes every partition, writes one exFAT partition over the whole card and mounts it again
## through automount.sh, which makes roms/ and the system folders. The rows are read again when it
## ends, and the ROM library notices the card on its own (rom_watch.gd).
##
## OGUI's Disks page is a MarginContainer holding its "no drives" label and the drive cards' box on
## top of each other; both are moved into a VBox below this section, so neither overlaps it. The
## page's focus setter is pointed at this section's FocusGroup, chained to the drive cards below.

const SDCardText := preload("sdcard_text.gd")
const INFO_TOOL := "/usr/bin/retroforge-sdcard-info"
const FORMAT_TOOL := "/usr/bin/retroforge-format-sdcard"
## The label the formatter gives the card (exFAT allows 11 characters).
const CARD_LABEL := "RETROFORGE"
const FORMAT_TEXT := "Erase the card and make it an exFAT ROM card, with a roms folder for every system."
const STATE_TEXT := {
	"none": "No card inserted",
	"system": "RetroForge runs from this card",
	"several": "More than one SD card",
}

var udisks2 := load("res://core/systems/disks/disk_manager.tres")
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var text_scene := load("res://core/ui/components/text.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene

var logger := Log.get_logger("RetroForgeSDCard", Log.LEVEL.INFO)
var tree: SceneTree
var _menu: Control
var _box: VBoxContainer  # this section
var _outer: VBoxContainer  # this section, then OGUI's label and drive cards
var _focus: Node  # this section's FocusGroup
var _rows := {}  # key -> text.tscn row
var _format: Control  # card_button_setting
var _formatting := false
var _info := {}


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	return self


## Add the section at the top of Settings > Disks. False when the layout differs.
func attach() -> bool:
	_menu = tree.root.find_child("DisksMenu", true, false) as Control
	var margin: Node = _menu.get_node_or_null("MarginContainer") if _menu else null
	var no_drives: Node = margin.get_node_or_null("NoDisksLabel") if margin else null
	var cards: Node = margin.get_node_or_null("DriveCardContainer") if margin else null
	if not no_drives or not cards:
		return false
	_outer = VBoxContainer.new()
	_outer.name = "RetroForgeDisksBox"
	_outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_outer)
	_box = VBoxContainer.new()
	_box.name = "RetroForgeSDCard"
	_outer.add_child(_box)
	# In the tree FIRST, then filled: a component's @onready children only exist once it is ready
	# (OGUI is a release export: a call on a null child segfaults, scraper_settings.gd).
	_focus = focus_group_scene.instantiate()
	_box.add_child(_focus)
	var label = section_scene.instantiate()
	label.text = "SD Card"
	_box.add_child(label)
	for key in ["card", "size", "fstype", "mountpoint", "usage"]:
		var row = text_scene.instantiate()
		_box.add_child(row)
		_rows[key] = row
	_rows["card"].title = "SD card"
	_rows["size"].title = "Total size"
	_rows["fstype"].title = "Filesystem"
	_rows["mountpoint"].title = "Mount point"
	_rows["usage"].title = "Used / free"
	for row in _rows.values():
		row.description = ""
	_format = button_scene.instantiate()
	_box.add_child(_format)
	_format.text = "Format SD card"
	_format.button_text = "Format"
	_format.description = FORMAT_TEXT
	_format.pressed.connect(_on_format)
	_outer.add_child(HSeparator.new())
	no_drives.reparent(_outer, false)
	cards.reparent(_outer, false)
	# The page's focus starts here, and moves down into OGUI's drive cards and back up.
	var setter: Node = _menu.get_node_or_null("StateWatcher/FocusGroupSetter")
	var cards_focus: Node = cards.get_node_or_null("FocusGroup")
	if setter and "target" in setter:
		setter.target = _focus
	if cards_focus:
		_focus.focus_neighbor_bottom = cards_focus
		cards_focus.focus_neighbor_top = _focus
	_menu.visibility_changed.connect(_refresh)
	if udisks2 and udisks2.has_signal("unprotected_devices_updated"):
		udisks2.unprotected_devices_updated.connect(func(_devices) -> void: _refresh.call_deferred())
	_refresh()
	return true


func detach() -> void:
	if is_instance_valid(_box):
		_box.queue_free()


## Read the slot again and set every row from it. Only while the page is shown (and not mid-format).
func _refresh() -> void:
	if _formatting or not is_instance_valid(_menu) or not _menu.is_visible_in_tree():
		return
	var out := []
	_info = {}
	if OS.execute(INFO_TOOL, [], out) == 0 and not out.is_empty():
		_info = SDCardText.parse_info(str(out[0]))
	var state: String = _info.get("state", "none")
	var has_card := state == "card"
	_rows["card"].text = SDCardText.describe_card(_info) if has_card else STATE_TEXT.get(state, STATE_TEXT["none"])
	for key in ["size", "fstype", "mountpoint", "usage"]:
		_rows[key].visible = has_card
	_format.visible = has_card
	if not has_card:
		return
	_rows["size"].text = SDCardText.size_text(_info.get("size", ""))
	_rows["fstype"].text = SDCardText.fstype_text(_info.get("fstype", ""))
	_rows["mountpoint"].text = _info.get("mountpoint", "") if _info.get("mountpoint", "") != "" else "Not mounted"
	_rows["usage"].text = SDCardText.usage_text(_info)
	_rows["usage"].visible = _info.get("mountpoint", "") != ""


func _on_format() -> void:
	if _formatting:
		return
	var dialog = tree.get_first_node_in_group("dialog")
	if not dialog:  # never erase a card unconfirmed
		logger.warn("no OGUI dialog to confirm the format with")
		return
	dialog.open(_format, "Format the SD card (%s)?\nEverything on it is erased. This cannot be undone." \
			% SDCardText.describe_card(_info), "Format", "Cancel")
	if not await dialog.choice_selected:
		return
	_formatting = true
	_format.disabled = true
	_format.button_text = "Formatting..."
	_rows["card"].text = "Formatting..."
	_notify("Formatting the SD card")
	var cmd := Command.create(FORMAT_TOOL, ["--exfat", "--skip-validation", "--label", CARD_LABEL])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_formatting = false
	_format.disabled = false
	_format.button_text = "Format"
	if code == 0:
		logger.info("SD card formatted")
		_notify("SD card formatted")
	else:
		logger.warn("%s exited %d: %s" % [FORMAT_TOOL, code, cmd.stderr])
		_notify("The SD card could not be formatted")
	_refresh()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))

