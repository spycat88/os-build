extends RefCounted
## Settings > Controller > "Nintendo button layout": swaps A with B and X with Y, so the bottom
## face button goes back and the right one confirms, as on a Switch. The swap applies everywhere
## the pad goes, the OGUI menus and games alike.
##
## OpenGamepadUI (patch 0024) loads a profile into InputPlumber itself: ogui_focus.json while it
## has focus (every input -> its DBus UI action), and in game the game's profile: OGUI's per-game
## or global one (a "<profile>_<target>[_guide].json" copy), or the YAML one the launcher declared
## (emulator.json "gamepad_profile", read-only under /usr/share). The swap is composed onto
## whatever it loaded, after the profile's own mapping:
##   - a base mapping whose one target is a face button gets the partner button, and one whose one
##     target is a face UI action (ui_accept/ui_back, ui_action/ui_context) gets the partner
##     action; that is the focus profile, i.e. the menus. Chords (several targets) stay.
##   - a face button the base mapping leaves alone is mapped to its partner.
##   - inside layers (Guide held) the face-button *sources* swap, so OGUI's Guide combos (Guide+A
##     quick bar, Guide+X keyboard) sit on the same physical buttons in game as in the menus.
## JSON is edited as a dictionary (not through InputPlumberProfile, which drops `layers` and with
## them the Guide layer); YAML line by line, for the shape our emulator profiles have (a YAML one
## that sends a face button or face action out is left alone, with a warning).
## The result is written to user://data/gamepad/profiles/nintendo/ and loaded in its place, its
## name carrying NAME_SUFFIX: that is how a later check knows the device already has the swap.
## The profiles OGUI and the emulators own stay untouched; turning the layout off asks OGUI to
## load its own profile again.
##
## OGUI gives no signal when it loads a profile, so the device is checked shortly after each
## launch, switch and stop, after Settings > Gamepad closes, and every POLL_SECS besides (OGUI
## also loads one on its own, e.g. on every focus change). The check is the device's profile
## name: an in-process property read; busctl runs only when the profile has to change.
## Stored in OGUI's settings, section "retroforge", key "nintendo_layout".
##
## A profile is never swapped while a button is held. InputPlumber drops a release it never saw
## pressed, so a button held across the swap (the A press on the toggle itself) had its release
## come out as its partner's: A stayed down for games and menus. Held buttons are tracked from
## the InputPlumber D-Bus target (what the menus receive); the swap waits for them, MAX_WAIT at
## most.

const SECTION := "retroforge"
const KEY := "nintendo_layout"
const OUT_DIR := "user://data/gamepad/profiles/nintendo"
const NAME_SUFFIX := " (Nintendo)"
const POLL_SECS := 2.0
const SWAP := {"South": "East", "East": "South", "West": "North", "North": "West"}
const DBUS_SWAP := {
	"ui_accept": "ui_back", "ui_back": "ui_accept", "ui_action": "ui_context", "ui_context": "ui_action",
}
const IP_BUS := "org.shadowblip.InputPlumber"
const IP_IFACE := "org.shadowblip.Input.CompositeDevice"

var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var _unswappable := {}  # profile names that cannot be swapped: not retried every poll
var input_plumber := load("res://core/systems/input/input_plumber.tres") as InputPlumberInstance
var gamepad_settings_state := load("res://assets/state/states/gamepad_settings.tres") as State
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var logger := Log.get_logger("RetroForgeButtons", Log.LEVEL.INFO)
var tree: SceneTree
var _toggle: Control  # OGUI Toggle
var _timer: Timer
var _poll: Timer
var _held := {}  # InputPlumber D-Bus event names currently pressed
var _waited := 0.0
const POLL := 0.1
const MAX_WAIT := 3.0


## Start watching OGUI's profile loads and apply the stored choice.
func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.wait_time = 0.5
	_timer.timeout.connect(_on_timer)
	tree.root.add_child(_timer)
	_poll = Timer.new()
	_poll.wait_time = POLL_SECS
	_poll.autostart = true
	_poll.timeout.connect(_check)
	tree.root.add_child(_poll)
	for device in input_plumber.get_composite_devices():
		_watch(device)
	input_plumber.composite_device_added.connect(_watch)
	launch_manager.app_launched.connect(_recheck.unbind(1))
	launch_manager.app_stopped.connect(_recheck.unbind(1))
	launch_manager.app_switched.connect(_recheck.unbind(2))
	launch_manager.all_apps_stopped.connect(_recheck)
	gamepad_settings_state.state_exited.connect(_recheck.unbind(1))
	_recheck()
	return self


## Add the toggle under Settings > Controller's Gamepad Settings button. False when the menu
## is not laid out as expected.
func attach() -> bool:
	var menu: Node = tree.root.find_child("GeneralControllerSettings", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	if not box:
		return false
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeNintendoLayout"
	_toggle.text = "Nintendo button layout"
	_toggle.description = "Swap A with B and X with Y: the bottom button goes back, the right one confirms. Applies to games and these menus."
	box.add_child(_toggle)
	_toggle.button_pressed = enabled()
	_toggle.toggled.connect(func(on: bool):
		settings.set_value(SECTION, KEY, on)
		_recheck())
	return true


func detach() -> void:
	if is_instance_valid(_toggle):
		_toggle.queue_free()
	for t in [_timer, _poll]:
		if is_instance_valid(t):
			t.queue_free()


func enabled() -> bool:
	return settings.get_value(SECTION, KEY, false) as bool


func _recheck() -> void:
	if is_instance_valid(_timer):
		_waited = 0.0
		_timer.start(0.5)


## Cheap: does every gamepad's profile match the setting? If not, the full apply (after release).
func _check() -> void:
	if not _timer.is_stopped():
		return
	var on := enabled()
	for device in input_plumber.get_composite_devices():
		if _unswappable.has(device.profile_name):
			continue
		if device.profile_name.ends_with(NAME_SUFFIX) != on:
			_recheck()
			return


func _on_timer() -> void:
	if not _held.is_empty() and _waited < MAX_WAIT:
		_waited += POLL
		_timer.start(POLL)
		return
	apply()


func _watch(device) -> void:
	for target in device.dbus_devices:
		if not target.input_event.is_connected(_on_input_event):
			target.input_event.connect(_on_input_event)


func _on_input_event(event: String, value: float) -> void:
	if value > 0.5:
		_held[event] = true
	else:
		_held.erase(event)


## Bring every gamepad's loaded profile in line with the setting.
func apply() -> void:
	var on := enabled()
	var restore := false
	for device in input_plumber.get_composite_devices():
		var loaded := _profile_path(device.dbus_path)
		var ext := loaded.get_extension()
		if ext != "json" and ext != "yaml" and ext != "yml":
			logger.info("Nintendo layout: no profile file to swap on " + device.name + " (" + loaded + ")")
			continue
		var swapped := loaded.get_basename().ends_with("_nintendo")
		if on and not swapped:
			var out := _swapped_path(loaded)
			if _write_swapped(loaded, out):
				device.load_profile_path(out)
				logger.info("Nintendo layout on: " + out)
			else:
				_unswappable[device.profile_name] = true
		elif swapped and not on:
			restore = true
	if restore:
		# OGUI loads whatever it would have loaded: the focus profile or the game's
		logger.info("Nintendo layout off: reloading OpenGamepadUI's profile")
		launch_manager.refresh_gamepad_profile()


func _profile_path(dbus_path: String) -> String:
	var out := []
	var args := ["--system", "get-property", IP_BUS, dbus_path, IP_IFACE, "ProfilePath"]
	if OS.execute("busctl", args, out, true) != 0 or out.is_empty():
		return ""
	# 's "/home/player/.../global_default_xbox-elite.json"'
	var line := (out[0] as String).strip_edges()
	return line.trim_prefix("s ").trim_prefix("\"").trim_suffix("\"")


## Where the swapped copy of a profile goes: one directory OGUI can write, whatever owns the
## source (the emulators' YAML is read-only), named so two sources never share a copy.
func _swapped_path(src: String) -> String:
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	var name := "%s_%s_nintendo.%s" % [src.get_file().get_basename(), src.md5_text().left(8), src.get_extension()]
	return dir.path_join(name)


func _write_swapped(src: String, dst: String) -> bool:
	var text := FileAccess.get_file_as_string(src)
	if text.is_empty():
		logger.warn("could not read gamepad profile " + src)
		return false
	var out := ""
	if src.get_extension() == "json":
		var profile = JSON.parse_string(text)
		if not profile is Dictionary:
			logger.warn("could not parse gamepad profile " + src)
			return false
		swap_profile(profile)
		out = JSON.stringify(_whole_numbers_as_ints(profile), "\t")
	else:
		out = swap_yaml(text)
		if out.is_empty():
			logger.warn("Nintendo layout: " + src + " sends a face button out itself; left as it is")
			return false
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var file := FileAccess.open(dst, FileAccess.WRITE)
	if not file:
		logger.warn("could not write " + dst)
		return false
	file.store_string(out)
	return true


## Swap A/B and X/Y after the profile's own mapping, in place (a profile as parsed from JSON).
static func swap_profile(profile: Dictionary) -> void:
	if not profile.get("mapping") is Array:
		profile["mapping"] = []
	var mapped := {}
	for m in profile["mapping"]:
		if not m is Dictionary:
			continue
		var button := _button_of(m.get("source_event"))
		if not button.is_empty():
			mapped[button] = true
		var targets = m.get("target_events")
		# One target only: a chord is a shortcut, not a face-button press, and stays as it is.
		if not targets is Array or targets.size() != 1 or not targets[0] is Dictionary:
			continue
		var target: Dictionary = targets[0]
		var out := _button_of(target)
		if SWAP.has(out):
			target["gamepad"]["button"] = SWAP[out]
		elif target.get("dbus") is String and DBUS_SWAP.has(target["dbus"]):
			target["dbus"] = DBUS_SWAP[target["dbus"]]
	for button in SWAP:
		if not mapped.has(button):
			profile["mapping"].append(_fill_in(button))
	# Layers: the face buttons that hold OGUI's Guide combos follow the swap (see the header)
	if profile.get("layers") is Array:
		for layer in profile["layers"]:
			if not layer is Dictionary or not layer.get("mapping") is Array:
				continue
			for m in layer["mapping"]:
				if not m is Dictionary:
					continue
				var button := _button_of(m.get("source_event"))
				if SWAP.has(button):
					m["source_event"]["gamepad"]["button"] = SWAP[button]
	var name := str(profile.get("name", ""))
	if not name.ends_with(NAME_SUFFIX):
		profile["name"] = name + NAME_SUFFIX


## The same swap on a YAML profile, line by line, or "" when it cannot be done safely: when the
## profile sends a face button or face UI action out (only JSON gets those rewritten) or has no
## block-style `mapping:`. Sources are found by the indentation of `source_event:` /
## `target_events:`; our emulator profiles (rootfs .../emulators/*/guide-hotkeys.yaml) qualify.
static func swap_yaml(text: String) -> String:
	var lines := text.split("\n")
	var face_value := RegEx.create_from_string("^(\\s*(?:- )?(?:button|dbus):\\s*)([A-Za-z_]+)\\s*(#.*)?$")
	var section := ""
	var ctx := ""
	var ctx_indent := -1
	var mapped := {}
	var mapping_line := -1
	var name_done := false
	for i in lines.size():
		var line: String = lines[i]
		var stripped := line.strip_edges(true, false)
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		var indent := line.length() - stripped.length()
		if indent == 0:
			section = stripped.get_slice(":", 0).strip_edges()
			ctx = ""
			if section == "mapping":
				if stripped.get_slice(":", 1).get_slice("#", 0).strip_edges() != "":
					return ""  # flow style, e.g. `mapping: []`
				mapping_line = i
			elif section == "name" and not name_done:
				name_done = true
				lines[i] = _yaml_with_suffix(line)
			continue
		if ctx != "" and indent <= ctx_indent:
			ctx = ""
		var key := stripped.trim_prefix("- ")
		var key_indent := indent + stripped.length() - key.length()
		if key.begins_with("source_event:"):
			ctx = "source"
			ctx_indent = key_indent
			continue
		if key.begins_with("target_events:"):
			ctx = "target"
			ctx_indent = key_indent
			continue
		var m := face_value.search(line)
		if not m:
			continue
		var value := m.get_string(2)
		if not SWAP.has(value) and not DBUS_SWAP.has(value):
			continue
		if ctx == "target" and section in ["mapping", "layers"]:
			return ""
		if ctx == "source" and SWAP.has(value):
			if section == "mapping":
				mapped[value] = true
			elif section == "layers":
				lines[i] = m.get_string(1) + SWAP[value] + ((" " + m.get_string(3)) if not m.get_string(3).is_empty() else "")
	if mapping_line < 0:
		return ""
	# Fill-in rows at the indentation of the mapping's first item
	var item := "  "
	for i in range(mapping_line + 1, lines.size()):
		var stripped := lines[i].strip_edges(true, false)
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		if stripped.begins_with("- "):
			item = lines[i].left(lines[i].length() - stripped.length())
		break
	var rows := PackedStringArray()
	for button in SWAP:
		if mapped.has(button):
			continue
		rows.append_array([
			item + "- name: Nintendo layout " + button + " to " + SWAP[button],
			item + "  source_event:",
			item + "    gamepad:",
			item + "      button: " + button,
			item + "  target_events:",
			item + "    - gamepad:",
			item + "        button: " + SWAP[button],
		])
	var out := Array(lines)
	for j in rows.size():
		out.insert(mapping_line + 1 + j, rows[j])
	if not name_done:
		out.insert(0, "name:" + NAME_SUFFIX)
	return "\n".join(PackedStringArray(out))


static func _yaml_with_suffix(line: String) -> String:
	var value := line.get_slice(":", 1).strip_edges()
	if value.ends_with(NAME_SUFFIX) or value.ends_with(NAME_SUFFIX + "\"") or value.ends_with(NAME_SUFFIX + "'"):
		return line
	if value.length() >= 2 and (value.ends_with("\"") or value.ends_with("'")):
		return "name: " + value.left(value.length() - 1) + NAME_SUFFIX + value.right(1)
	return "name: " + value + NAME_SUFFIX


## The gamepad button an event names ("South"), or "".
static func _button_of(event) -> String:
	if event is Dictionary and event.get("gamepad") is Dictionary:
		var button = event["gamepad"].get("button")
		if button is String:
			return button
	return ""


static func _fill_in(button: String) -> Dictionary:
	return {
		"name": "Nintendo layout " + button + " to " + SWAP[button],
		"source_event": {"gamepad": {"button": button}},
		"target_events": [{"gamepad": {"button": SWAP[button]}}],
	}


## JSON.parse_string reads every number as a float, and InputPlumber refuses a profile whose
## integer fields (`version`) come back as 1.0 (see OGUI patch 0024).
static func _whole_numbers_as_ints(value: Variant) -> Variant:
	if value is float and is_finite(value) and value == floorf(value):
		return int(value)
	if value is Array:
		var items := []
		for item in value:
			items.append(_whole_numbers_as_ints(item))
		return items
	if value is Dictionary:
		var ints := {}
		for key in value:
			ints[key] = _whole_numbers_as_ints(value[key])
		return ints
	return value
