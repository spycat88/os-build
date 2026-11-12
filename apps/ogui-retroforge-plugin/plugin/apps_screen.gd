extends Control

## The Apps screen, opened from the main menu's Apps entry (plugin.gd): a full-screen
## menu laid out like OGUI's Settings (settings_menu.tscn) -- every catalog emulator on the left,
## the focused one's page on the right (apps_page.gd) under its name.
##
## A plugin-owned State on OGUI's menu state machine shows it (fade in, focus on the list; Back
## pops it, as Settings). Inside, a plugin-owned StateMachine holds the page's state: A on an
## entry pushes it (focus into the page); Back pops it when it is there (the list takes the focus
## back), else closes the screen. Never a second settings_menu.tscn: it would bring OGUI's own settings pages and their
## global states with it.

var menu_state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var card_button_scene := load("res://core/ui/components/card_button.tscn") as PackedScene
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var focus_group_scene := load("res://core/systems/input/focus_group.tscn") as PackedScene
var input_watcher_scene := load("res://core/systems/input/input_watcher.tscn") as PackedScene
var state_updater_scene := load("res://core/systems/state/state_updater.tscn") as PackedScene
var state_watcher_scene := load("res://core/systems/state/state_watcher.tscn") as PackedScene
var fade_effect_scene := load("res://core/systems/effects/fade_effect.tscn") as PackedScene
var focus_group_setter_script := load("res://core/systems/input/focus_group_setter.gd") as GDScript
var state_machine_watcher_script := load("res://core/systems/state/state_machine_watcher.gd") as GDScript

## The screen's state on the menu state machine; the main menu's Apps entry pushes it.
var state: State
var page: Control  # apps_page.gd
var logger := Log.get_logger("RetroForgeEmulators", Log.LEVEL.INFO)
var _page_machine := StateMachine.new()
var _list: VBoxContainer
var _list_focus: FocusGroup
var _title: Label
var _content: MarginContainer
var _right: Control  # the title and the page: Left in it goes back to the list (_input)


func setup(screen_state: State, page_script: GDScript) -> void:
	state = screen_state
	name = "RetroForgeEmulatorsScreen"
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# StateMachine keeps one state by default: the page's must pop (settings_state_machine.tres has 0).
	_page_machine.minimum_states = 0
	_page_machine.logger_name = "RetroForgeEmulatorsStateMachine"
	var page_state := State.new()
	page_state.name = "retroforge_emulator_page"

	# One Back for the whole screen: it leaves the page when the page is open, else closes the screen.
	var back = input_watcher_scene.instantiate()
	back.stop_propagation = true
	back.action = "ogui_east"
	back.input_released.connect(_on_back)
	add_child(back)

	_build_layout()
	page = page_script.new()
	page.setup(page_state, null)
	_content.add_child(page)

	var watcher = state_watcher_scene.instantiate()
	watcher.state = state
	var fade = fade_effect_scene.instantiate()
	fade.target = self
	fade.on_signal = "state_entered"
	fade.fade_out_signal = "state_exited"
	watcher.add_child(fade)
	for sig in ["state_entered", "state_refreshed"]:
		watcher.add_child(_focus_setter(sig))
	var clear = state_updater_scene.instantiate()
	clear.state_machine = _page_machine
	clear.action = 6  # StateUpdater.ACTION.CLEAR
	clear.on_signal = "state_removed"
	watcher.add_child(clear)
	watcher.state_entered.connect(_fill)
	add_child(watcher)

	# The page popped (Back in it): the list takes the focus back.
	var machine_watcher: Node = state_machine_watcher_script.new()
	machine_watcher.state_machine = _page_machine
	machine_watcher.add_child(_focus_setter("emptied"))
	add_child(machine_watcher)


## Settings' layout: margins, the list panel, then the title and the content panel (2.75x wider).
func _build_layout() -> void:
	var outer := MarginContainer.new()
	outer.set_anchors_preset(Control.PRESET_FULL_RECT)
	var margins := {"left": 20, "top": 10, "right": 20, "bottom": 30}
	for side in margins:
		outer.add_theme_constant_override("margin_" + side, margins[side])
	add_child(outer)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	outer.add_child(columns)

	var list_panel := _panel()
	list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	columns.add_child(list_panel)
	var list_margin := _margin(50, 20)
	list_panel.add_child(list_margin)
	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	list_margin.add_child(scroll)
	var inner := _margin(5, 5)
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(inner)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 10)
	inner.add_child(_list)
	_list_focus = focus_group_scene.instantiate() as FocusGroup
	_list.add_child(_list_focus)

	var right := MarginContainer.new()
	_right = right
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 2.75
	columns.add_child(right)
	var right_rows := VBoxContainer.new()
	right_rows.add_theme_constant_override("separation", 20)
	right.add_child(right_rows)
	var title_panel := _panel()
	title_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	right_rows.add_child(title_panel)
	var title_margin := _margin(20, 5)
	title_panel.add_child(title_margin)
	_title = section_scene.instantiate()
	_title.uppercase = true
	_title.text = "Apps"
	title_margin.add_child(_title)
	var content_panel := _panel()
	content_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_rows.add_child(content_panel)
	_content = _margin(20, 5)
	content_panel.add_child(_content)


func _panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"SettingsMenu"
	return panel


func _margin(horizontal: int, vertical: int) -> MarginContainer:
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, horizontal)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, vertical)
	return margin


## The D-pad moves between the list and the page, as in OGUI's Settings (its patch 0051): Right on
## an entry opens its page, as A does, and Left on the page goes back to the list, as Back does,
## wherever Left has nothing to do on the page (FocusGroup.leaves_by_left: not on a slider, a text
## field or a row with a left neighbour, nor in a dialog).
func _input(event: InputEvent) -> void:
	if not is_visible_in_tree():
		return
	var right := event.is_action_pressed("ui_right")
	var left := event.is_action_pressed("ui_left")
	if not right and not left:
		return
	if Input.is_action_pressed("ogui_guide"):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if not focus:
		return

	if right and focus is CardButton and _list.is_ancestor_of(focus):
		get_viewport().set_input_as_handled()
		var entry := focus as CardButton
		entry.pressed.emit()
		entry.button_up.emit()
		return

	if left and _right.is_ancestor_of(focus) and _page_machine.current_state():
		if not FocusGroup.leaves_by_left(focus, _right):
			return
		get_viewport().set_input_as_handled()
		_page_machine.pop_state()


func _on_back() -> void:
	if _page_machine.current_state():
		_page_machine.pop_state()
	else:
		menu_state_machine.pop_state()


func _focus_setter(on_signal: String) -> Node:
	var setter: Node = focus_group_setter_script.new()
	setter.target = _list_focus
	setter.on_signal = on_signal
	return setter


## Read the catalog and (re)build the list at each visit: one entry per emulator, by name. The
## entry shown last time keeps the focus.
func _fill() -> void:
	page.load_catalog()
	var keep: String = page.emulator_id
	for child in _list.get_children():
		if child != _list_focus:
			_list.remove_child(child)
			child.queue_free()
	var ids: Array = page.catalog.keys()
	ids.sort_custom(func(a, b): return _name(a).naturalnocasecmp_to(_name(b)) < 0)
	var focus: Control = null
	for id in ids:
		var entry := _entry(id)
		_list.add_child(entry)
		if id == keep or focus == null:
			focus = entry
	_list_focus.current_focus = focus
	_list_focus.recalculate_focus()
	page.emulator_id = ""  # rebuild the page from the catalog just read
	_show(focus.get_meta("emulator") if focus else "")
	logger.info("Apps screen: %d app(s)" % ids.size())


func _name(id: String) -> String:
	return str(page.catalog.get(id, {}).get("name", id))


## A list entry: focusing it shows its emulator, A moves the focus into the page.
func _entry(id: String) -> Control:
	var entry = card_button_scene.instantiate()
	entry.name = "Emulator_" + id
	entry.text = _name(id)
	entry.set_meta("emulator", id)
	var push = state_updater_scene.instantiate()
	push.state_machine = _page_machine
	push.state = page.state
	push.action = 3  # StateUpdater.ACTION.REPLACE, as Settings' buttons
	push.on_signal = "button_up"
	entry.add_child(push)
	entry.focus_entered.connect(_show.bind(id))
	return entry


func _show(id: String) -> void:
	_title.text = _name(id) if id != "" else "Apps"
	if id != page.emulator_id:
		page.show_emulator(id)
