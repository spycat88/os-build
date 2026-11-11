extends Plugin

## RetroForge: ROM library with one library tab per system (plan Phase 4). Prototype: the PSX tab.
##
## OpenGamepadUI's library menu only fills its own two grids (Installed, All Games); a tab added
## through library_tabs_state gets placed in the TabContainer but its grid is ours to fill. Plugins
## are initialised BEFORE the library menu is ready (PluginManager comes first in card_ui.tscn), so
## tabs are added from library_loaded, which fires after the UI's first reload_library().

const LIBRARY_ID := "retroforge-roms"
## The Steam games, owned and installed (library_steam.gd, no second sign-in), and their tab.
const STEAM_LIBRARY_ID := "retroforge-steam"
const STEAM_TAB := "steam"
## The GOG and Epic games (library_store.gd, .claude/plans/stores.plan.md): store -> its tab's title.
## Each store's library is "retroforge-<store>" and its tab is keyed by the store.
const STORE_TABS := {"gog": "GOG", "epic": "Epic Games"}
## OGUI's own library of .desktop files (core/systems/library/library_desktop.tscn).
const DESKTOP_LIBRARY_ID := "desktop"
const SteamApps := preload("steam_apps.gd")
## Seconds between two looks at ~/roms (rom_watch.gd): a copied ROM shows up 5-10 s after the
## copy ends.
const RESCAN_INTERVAL := 5.0

var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
var input_plumber := load("res://core/systems/input/input_plumber.tres") as InputPlumberInstance
var tabs_state := load("res://core/ui/card_ui/library/library_tabs_state.tres") as TabContainerState
var menu_state_machine := load("res://assets/state/state_machines/menu_state_machine.tres") as StateMachine
var launcher_state := load("res://assets/state/states/game_launcher.tres") as State
var main_menu_state := load("res://assets/state/states/main_menu.tres") as State
var card_scene := load("res://core/ui/components/card.tscn") as PackedScene
var scroller_scene := load("res://core/systems/input/scroller_joystick.tscn") as PackedScene

var roms  # our Library subclass; untyped so roms.SYSTEMS resolves at runtime
var steam  # library_steam.gd
var stores := {}  # store -> its library_store.gd
## system (or STEAM_TAB, or a store) -> {"tab": ScrollContainer, "grid": HFlowContainer}
var _tabs := {}
var _scroll_tween: Tween  # a library tab's scroll to its focused card (_scroll_to_card)
var _emulators_button: Control
var _emulators_screen: Control
var _steam_button: Control  # Main menu > Steam (_add_menu_button)
var _game_settings_page: Control
var _hardware_card: Control
## Input boost (see _input): how long the UI renders every frame after the last input.
const INPUT_BOOST_SECS := 1.5
var _boost_timer: Timer
var _display: RefCounted  # display_settings.gd
var _overlay: RefCounted  # overlay_hiding.gd
var _osk_nav: RefCounted  # osk_navigation.gd
var _touch_keyboard: RefCounted  # touch_keyboard.gd
var _buttons: RefCounted  # button_layout.gd
var _pause: RefCounted  # pause_on_menu.gd
var _scraper: RefCounted  # scraper_settings.gd
var _psn: RefCounted  # psn_settings.gd
var _cheevos: RefCounted  # cheevos_settings.gd
var _tailscale: RefCounted  # tailscale_settings.gd: Settings > Network > VPN
var _art_fetch: RefCounted  # art_fetch.gd: new ROMs' art, fetched when their card asks for it
var _os: Resource  # retroforge_os.gd, installed as OGUI's platform.os
var _tool: RefCounted  # proton_tool.gd
var _keep: RefCounted  # steam_keep.gd
var _direct: RefCounted  # steam_direct.gd
var _stores_page: RefCounted  # steam_settings.gd: Settings > Stores
var _store_rows: RefCounted  # store_settings.gd: GOG and Epic sign-in
var _watch: RefCounted  # rom_watch.gd
var _steam_watch: RefCounted  # steam_watch.gd
var _rescan_timer: Timer
var _rescanning := false
var _steam_rescanning := false


# No _init override: Plugin._init adds the node to the "plugin" group.
func _ready() -> void:
	logger = Log.get_logger("RetroForge", Log.LEVEL.INFO)
	roms = load(plugin_base.path_join("library_roms.gd")).new()
	add_library(roms)
	steam = load(plugin_base.path_join("library_steam.gd")).new()
	add_library(steam)
	for store in STORE_TABS:
		stores[store] = load(plugin_base.path_join("library_store.gd")).new()
		stores[store].store = store
		add_library(stores[store])
	library_manager.library_launch_item_added.connect(_drop_steam_shortcut)
	for app in library_manager.get_library_items([]):
		var shortcut := app.get_launch_item(DESKTOP_LIBRARY_ID)
		if shortcut:
			_drop_steam_shortcut(shortcut)
	# Before the library loads: the first ROM cards already ask for their art.
	_art_fetch = load(plugin_base.path_join("art_fetch.gd")).new()
	var art = load(plugin_base.path_join("boxart_retroforge.gd")).new()
	art.fetcher = _art_fetch
	add_boxart(art)
	library_manager.library_loaded.connect(_on_library_loaded)
	logger.info("ROM library registered: %s" % library_manager.has_library(LIBRARY_ID))
	_watch = load(plugin_base.path_join("rom_watch.gd")).new().setup(roms.roms_dir(), roms.SYSTEMS.keys(), roms.dir_markers())
	_steam_watch = load(plugin_base.path_join("steam_watch.gd")).new().watch_steam(steam.steam_root())
	_rescan_timer = Timer.new()
	_rescan_timer.wait_time = RESCAN_INTERVAL
	_rescan_timer.timeout.connect(_on_rescan_timer)
	add_child(_rescan_timer)
	_rescan_timer.start()
	# The settings menu is not ready yet when plugins initialise: add our page a frame later.
	await get_tree().process_frame
	_add_emulators_screen()
	_add_game_settings_page()
	_add_hardware_card()
	_apply_render_mode()
	_overlay = load(plugin_base.path_join("overlay_hiding.gd")).new().setup(get_tree())
	_osk_nav = load(plugin_base.path_join("osk_navigation.gd")).new().setup(get_tree())
	_touch_keyboard = load(plugin_base.path_join("touch_keyboard.gd")).new().setup(get_tree())
	_buttons = load(plugin_base.path_join("button_layout.gd")).new().setup(get_tree())
	if not _buttons.attach():
		logger.warn("OGUI controller settings layout not found; no Nintendo layout toggle")
	_pause = load(plugin_base.path_join("pause_on_menu.gd")).new().setup(get_tree())
	if not _pause.attach():
		logger.warn("OGUI general settings layout not found; no pause-in-menus toggle")
	# Every Library section inserts right after Refresh Library, so the later one lands on top:
	# RetroAchievements first (the bottom), then PSN, then ROM art.
	_cheevos = load(plugin_base.path_join("cheevos_settings.gd")).new().setup(get_tree())
	if not _cheevos.attach():
		logger.warn("OGUI library settings layout not found; no RetroAchievements section")
	_psn = load(plugin_base.path_join("psn_settings.gd")).new().setup(get_tree())
	if not _psn.attach():
		logger.warn("OGUI library settings layout not found; no PSN packages row")
	_scraper = load(plugin_base.path_join("scraper_settings.gd")).new().setup(get_tree())
	if not _scraper.attach():
		logger.warn("OGUI library settings layout not found; no ROM art section")
	# Until here no card fetches (allowed unset): the setting lives in the Settings section.
	_art_fetch.other = _scraper.runner
	_art_fetch.allowed = _scraper.can_fetch
	_tailscale = load(plugin_base.path_join("tailscale_settings.gd")).new().setup(get_tree())
	if not _tailscale.attach():
		logger.warn("no tailscale, or OGUI network settings layout not found; no VPN section")
	_install_os_platform()
	_tool = load(plugin_base.path_join("proton_tool.gd")).new().setup(get_tree())
	_keep = load(plugin_base.path_join("steam_keep.gd")).new().setup(get_tree())
	_direct = load(plugin_base.path_join("steam_direct.gd")).new().setup(get_tree())
	if is_instance_valid(_emulators_screen):
		_emulators_screen.page.steam_rows = _add_steam_rows
		_emulators_screen.page.proton_entry = _tool.entry
		_emulators_screen.page.proton_rows = _add_proton_rows
	else:
		logger.warn("no Apps screen; no Steam rows, no Proton")
	_stores_page = load(plugin_base.path_join("steam_settings.gd")).new().setup(get_tree(), "Stores")
	_store_rows = load(plugin_base.path_join("store_settings.gd")).new().setup(get_tree())
	if _stores_page.attach() and _store_rows.attach(_stores_page.box):
		_store_rows.changed.connect(func(store: String) -> void: library_manager.load_library("retroforge-" + store))
	else:
		_stores_page.detach()
		logger.warn("OGUI settings menu layout or the store tool not found; no Settings > Stores")
	_setup_input_boost()


func unload() -> void:
	if library_manager.library_launch_item_added.is_connected(_drop_steam_shortcut):
		library_manager.library_launch_item_added.disconnect(_drop_steam_shortcut)
	if is_instance_valid(_rescan_timer):
		_rescan_timer.stop()
	for system in _tabs.keys():
		tabs_state.remove_tab(_tab_text(system))
	_tabs.clear()
	if main_menu_state.state_entered.is_connected(_show_app_buttons):
		main_menu_state.state_entered.disconnect(_show_app_buttons)
	for node in [_emulators_button, _emulators_screen, _steam_button]:
		if is_instance_valid(node):
			node.queue_free()
	if is_instance_valid(_game_settings_page):
		_game_settings_page.detach()
	if _display:
		_display.detach()
	if _overlay:
		_overlay.detach()
	if _touch_keyboard:
		_touch_keyboard.detach()
	if _buttons:
		_buttons.detach()
	if _pause:
		_pause.detach()
	if _scraper:
		_scraper.detach()
	if _psn:
		_psn.detach()
	if _cheevos:
		_cheevos.detach()
	if _tailscale:
		_tailscale.detach()
	if _art_fetch:
		_art_fetch.allowed = Callable()
		_art_fetch.runner.cancel()
	if _os:
		_os.detach()
	if _tool:
		_tool.detach()
	if _keep:
		_keep.detach()
	if _direct:
		_direct.detach()
	if _store_rows:
		_store_rows.detach()
	if _stores_page:
		_stores_page.detach()
	if is_instance_valid(_hardware_card):
		var qb_card: Node = _hardware_card.find_parent("QuickBarCard*")
		(qb_card if qb_card else _hardware_card).queue_free()


## OGUI knows no `retroforge` OS (core/global/platform.gd's fixed list), so platform.os is null and
## nothing would call an OS platform's ready(): install ours and call it, as Platform.load() does.
## Never over an OS platform OGUI detected itself.
func _install_os_platform() -> void:
	var platform := load("res://core/global/platform.tres") as Platform
	if platform.os or not platform.os_info or platform.os_info.id != "retroforge":
		logger.info("OS platform left to OGUI")
		return
	_os = load(plugin_base.path_join("retroforge_os.gd")).new()
	platform.os = _os
	_os.ready(get_tree().root)
	logger.info("RetroForge OS platform installed")


## Game settings > RetroForge (the gear on a ROM's launch menu): per-game options.
func _add_game_settings_page() -> void:
	var menu: Node = get_tree().root.find_child("GameSettingsMenu", true, false)
	var page = load(plugin_base.path_join("game_settings_page.gd")).new()
	if not menu or not page.attach(menu, roms):
		page.free()
		logger.warn("OGUI game settings layout not found; no per-game RetroForge options")
		return
	_game_settings_page = page
	logger.info("Game settings > RetroForge added")


## Main menu > Apps: an entry after Library, wired like OGUI's own (main_menu.tscn): it pushes
## the screen's state on the menu state machine and the menu state on the global one, and clears
## the popup machine, which closes the main menu. The screen (apps_screen.gd) sits beside
## Settings in card_ui.tscn's AboveContextBarMargin.
func _add_emulators_screen() -> void:
	var main_menu: Node = get_tree().root.find_child("MainMenu", true, false)
	var buttons: Node = main_menu.find_child("ButtonContainer", true, false) if main_menu else null
	var settings: Node = get_tree().get_first_node_in_group("settings_menu")
	var holder: Node = settings.get_parent() if settings else null
	if not (buttons and holder):
		logger.warn("OGUI main menu layout not found; no Apps screen")
		return

	var screen_state := State.new()
	screen_state.name = "retroforge_emulators"
	_emulators_screen = load(plugin_base.path_join("apps_screen.gd")).new()
	_emulators_screen.setup(screen_state, load(plugin_base.path_join("apps_page.gd")))
	holder.add_child(_emulators_screen)

	_emulators_button = load("res://core/ui/components/card_button.tscn").instantiate()
	_emulators_button.name = "RetroForgeEmulatorsButton"
	_emulators_button.text = "Apps"
	_emulators_button.click_focuses = false
	for step in [
		[menu_state_machine, screen_state, 0],  # PUSH
		[load("res://assets/state/state_machines/global_state_machine.tres"), load("res://assets/state/states/menu.tres"), 0],
		[load("res://assets/state/state_machines/popup_state_machine.tres"), null, 6],  # CLEAR
	]:
		var updater = load("res://core/systems/state/state_updater.tscn").instantiate()
		updater.state_machine = step[0]
		updater.state = step[1]
		updater.action = step[2]
		updater.on_signal = "button_up"
		_emulators_button.add_child(updater)

	var library_button := buttons.find_child("LibraryButton", false, false)
	buttons.add_child(_emulators_button)
	if library_button:
		buttons.move_child(_emulators_button, library_button.get_index() + 1)
	_steam_button = _add_menu_button(buttons, "RetroForgeSteamButton", "Steam", _emulators_button, _open_steam)
	main_menu_state.state_entered.connect(_show_app_buttons)
	_show_app_buttons(null)
	var focus_group := buttons.find_child("FocusGroup", false, false)
	if focus_group:
		focus_group.recalculate_focus()
	logger.info("Main menu > Apps added")


## Apps > Steam Client's page ends with these, under its own rows (apps_page.gd builds the page
## again at each visit, so this runs each time): keep Steam running, start without Steam. A row whose
## command is missing is left out.
func _add_steam_rows(box: Node) -> void:
	for row in [_keep, _direct]:
		row.attach(box)


## Apps > Proton's page, built at each visit: the tool with its Download / Update, which Steam, GOG
## and Epic games share.
func _add_proton_rows(box: Node) -> void:
	_tool.attach(box)


## Main menu > Steam, under Apps while Steam Client is installed (looked at each time the main
## menu opens): what Apps > Steam Client's Open starts. The launch's in-game state closes the main
## menu; the popup machine is cleared as OGUI's own buttons do.
func _add_menu_button(buttons: Node, node_name: String, text: String, after: Control, on_press: Callable) -> Control:
	var button: Control = load("res://core/ui/components/card_button.tscn").instantiate()
	button.name = node_name
	button.text = text
	button.click_focuses = false
	var updater = load("res://core/systems/state/state_updater.tscn").instantiate()
	updater.state_machine = load("res://assets/state/state_machines/popup_state_machine.tres")
	updater.action = 6  # CLEAR
	updater.on_signal = "button_up"
	button.add_child(updater)
	button.button_up.connect(on_press)
	buttons.add_child(button)
	buttons.move_child(button, after.get_index() + 1)
	return button


func _show_app_buttons(_from: State) -> void:
	_steam_button.visible = SteamApps.client_installed(SteamApps.steam_root())


func _open_steam() -> void:
	var item := LibraryLaunchItem.new()
	item.name = "Steam"
	item.command = "steam"
	item.args = SteamApps.ui_args("steam://open/bigpicture")
	item.installed = true
	launch_manager.launch(item)


## Automatic rescan: reload our library once ~/roms changed and settled (rom_watch.gd), and the
## Steam games once the client's app manifests did (steam_watch.gd). Never while a game runs (Steam's
## own UI counts), nor while our own reload of that library is still going.
func _on_rescan_timer() -> void:
	var running := not launch_manager.get_running().is_empty()
	if _watch.poll(_rescanning or running):
		logger.info("ROM folders changed: rescanning")
		_rescanning = true
		library_manager.load_library(LIBRARY_ID)
	if _steam_watch.poll(_steam_rescanning or running):
		logger.info("Installed Steam games changed: rescanning")
		_steam_rescanning = true
		library_manager.load_library(STEAM_LIBRARY_ID)


func _on_library_loaded(library_id: String) -> void:
	# Any load counts (start, Refresh Library, ours): it read what is on disk now.
	if library_id == STEAM_LIBRARY_ID:
		_steam_watch.mark_loaded()
		_steam_rescanning = false
		_refresh_system(STEAM_TAB)
		return
	for store in STORE_TABS:
		if library_id == "retroforge-" + store:
			_refresh_system(store)
			return
	if library_id != LIBRARY_ID:
		return
	_watch.mark_loaded()
	_rescanning = false
	for system in roms.SYSTEMS:
		_refresh_system(system)


## Steam writes a desktop shortcut for each game it installs (~/.local/share/applications/<Game>.desktop,
## `steam steam://rungameid/<appid>`), and OGUI's desktop library lists it beside our Steam library's
## entry for the same game, on the same card. The card then launched through the shortcut: Steam came
## up in its desktop mode over the game, with a "Launching..." dialog the controller could not reach
## (patch 0021 gives such shortcuts the gamepad flags), and Hades showed on Home twice, once without
## its cover (HW, KONKR Pocket FIT, 2026-10-21). Our library lists every Steam game, so the shortcut's
## entry is dropped as it arrives: one entry per Steam game, ours. Deferred: this runs inside
## LibraryManager's own signal.
func _drop_steam_shortcut(item: LibraryLaunchItem) -> void:
	if item._provider_id == DESKTOP_LIBRARY_ID and item.command == "steam" and SteamApps.appid_of(item.args) > 0:
		library_manager.remove_library_launch_item.call_deferred(DESKTOP_LIBRARY_ID, item.name)


## Library items of one tab, sorted by name: the ROMs whose retroforge-roms launch item is tagged
## with the system, or for STEAM_TAB the Steam games, or for a store its games.
func _items_for(system: String) -> Array[LibraryItem]:
	var library := STEAM_LIBRARY_ID if system == STEAM_TAB else ("retroforge-" + system if system in STORE_TABS else LIBRARY_ID)
	var items: Array[LibraryItem] = []
	for item in library_manager.get_library_items():
		var launch := item.get_launch_item(library)
		if launch and system in launch.tags:
			items.append(item)
	return items


func _refresh_system(system: String) -> void:
	var items := _items_for(system)
	if items.is_empty():
		if system in _tabs:
			tabs_state.remove_tab(_tab_text(system))
			_tabs.erase(system)
		return
	if not system in _tabs:
		_tabs[system] = _make_tab()
		tabs_state.add_tab(_tab_text(system), _tabs[system]["tab"])
	var started := Time.get_ticks_msec()
	var grid: HFlowContainer = _tabs[system]["grid"]
	for child in grid.get_children():
		child.queue_free()
	for item in items:
		grid.add_child(_build_card(item, _tabs[system]["tab"]))
	logger.info("%s tab: %d game(s), cards built in %d ms" % [_tab_text(system), items.size(), Time.get_ticks_msec() - started])


func _tab_text(system: String) -> String:
	if system == STEAM_TAB:
		return "Steam"
	return STORE_TABS[system] if system in STORE_TABS else roms.SYSTEMS[system]["name"]


## Same node layout as the library menu's AllGamesTab: library_menu.gd focuses the first card of a
## tab through get_child(1).get_child(0), so ScrollerJoystick first, then MarginContainer > grid.
func _make_tab() -> Dictionary:
	var tab := ScrollContainer.new()
	tab.visible = false
	tab.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tab.add_child(scroller_scene.instantiate())
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 15)
	margin.add_theme_constant_override("margin_top", 100)
	margin.add_theme_constant_override("margin_right", 15)
	tab.add_child(margin)
	var grid := HFlowContainer.new()
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 26)
	grid.add_theme_constant_override("v_separation", 16)
	grid.alignment = FlowContainer.ALIGNMENT_CENTER
	margin.add_child(grid)
	return {"tab": tab, "grid": grid}


## As library_menu.gd's _build_card: pressing the card opens OGUI's game launch menu. Its art is
## not awaited: the card goes in the grid at once and its texture lands when ready, so cards whose
## card image must be composed (boxart_retroforge.gd, on worker threads) build in parallel instead
## of one after another (300 new cards: 15.9 s one by one on the ACE, 2026-10-17).
## A focused card scrolls its tab to it, as library_menu.gd does for its own tabs: without that the
## Steam tab left the focused card below the screen's edge.
func _build_card(item: LibraryItem, tab: ScrollContainer) -> Control:
	var card = card_scene.instantiate()
	card.set_library_item(item)
	var on_button_up := func():
		launcher_state.data = {"item": item}
		menu_state_machine.push_state(launcher_state)
	card.button_up.connect(on_button_up)
	card.focus_entered.connect(_scroll_to_card.bind(card, tab))
	return card


## library_menu.gd's _on_focus_updated: a smooth scroll that puts the card a third of its height
## from the top, except while touch or the mouse is in use.
## Within 500 ms of a touch only (OGUI patch 0038's InputManager.pointer_recent): the touch count
## stayed above zero after a release it never saw, and the tab stopped following the D-pad for good.
func _scroll_to_card(card: Control, tab: ScrollContainer) -> void:
	var input_manager := get_tree().get_first_node_in_group("input_manager")
	if input_manager and input_manager.has_method("pointer_recent"):
		if input_manager.pointer_recent():
			return
	elif input_manager and ((input_manager as InputManager).current_touches > 0 or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)):
		return
	if _scroll_tween:
		_scroll_tween.kill()
	_scroll_tween = get_tree().create_tween()
	_scroll_tween.tween_property(tab, "scroll_vertical", card.position.y - card.size.y / 3, 0.25)


## Quick bar > Hardware: the board's battery, temperatures, fan, clocks, backlight and LED
## groups, read from the standard tree /run/retroforge/hw that /usr/lib/retroforge/hw-map resolves from
## the board profile -- the one path every board exposes them at, so this card has no per-board
## code. Rows the map did not resolve stay hidden.
func _add_hardware_card() -> void:
	var card = load(plugin_base.path_join("hardware_card.gd")).new()
	card.setup(plugin_base)
	var icon := load("res://assets/ui/icons/battery-full.svg") as Texture2D
	# Straight to the quick bar with an explicit title, NOT Plugin.add_to_quick_bar: that passes no
	# title, so add_child_menu falls back to find_child("SectionLabel") and frees what it finds,
	# which on a code-built card either throws on null or frees a live node (OGUI SIGSEGV, Air X).
	var qb := get_tree().get_first_node_in_group("quick-bar")
	if not qb:
		card.free()
		logger.warn("OGUI quick bar not found; no Hardware card")
		return
	qb.add_child_menu(card, icon, null, "Hardware")
	_hardware_card = card
	logger.info("Quick bar > Hardware added")


## Settings > Display: Game resolution and Reduced UI resolution (display_settings.gd). The stored
## choices (or the board profile's defaults) are applied at startup whether or not the menu exists.
func _apply_render_mode() -> void:
	_display = load(plugin_base.path_join("display_settings.gd")).new()
	_display.apply_all(get_tree())
	if _display.attach():
		logger.info("Settings > Display: game resolution added")
	else:
		logger.warn("OGUI display settings layout not found; resolution settings not shown")


## OpenGamepadUI runs in Godot's low-processor mode, which draws only when something changed --
## the reason the idle shell costs nothing. It also paces animations: menu and card transitions
## reached the screen at ~35 fps on the Air X however cheap each frame was, and at 60+ with the
## mode off. So for INPUT_BOOST_SECS after every input event the mode is off (transitions run at
## the display rate), then back on (the idle shell draws nothing again).
func _setup_input_boost() -> void:
	_boost_timer = Timer.new()
	_boost_timer.one_shot = true
	_boost_timer.wait_time = INPUT_BOOST_SECS
	_boost_timer.timeout.connect(func(): OS.low_processor_usage_mode = true)
	add_child(_boost_timer)
	# Idle main-loop pacing. In low-processor mode Godot still wakes every
	# low_processor_usage_mode_sleep_usec (6.9 ms by default, ~145 times a second) and runs every
	# node's _process -- OGUI's main thread cost ~13% of a core on the Air X doing nothing. 16.7 ms
	# in the menus keeps a 60 Hz input response; 50 ms while a game covers the shell, where the
	# shell only has to notice the Guide button. Input still switches to full rate (above).
	var in_game_state := load("res://assets/state/states/in_game.tres") as State
	in_game_state.state_entered.connect(func(_from): _set_in_game(true))
	in_game_state.state_exited.connect(func(_to): _set_in_game(false))
	_set_idle_pacing(false)
	# The gamepad reaches OGUI as InputPlumber D-Bus signals, which OGUI turns into a chain of
	# Godot input events, one main-loop pass per hop (Guide -> ogui_guide -> ogui_menu -> state).
	# OGUI marks those events handled, so _input below never sees them and every hop slept the
	# full idle pace -- the in-game menu took ~200 ms of sleeping to open (Air Y, 2026-10-11).
	# Boost from the signal itself: the pass that receives it no longer sleeps.
	for device in input_plumber.get_composite_devices():
		_watch_input_plumber(device)
	input_plumber.composite_device_added.connect(_watch_input_plumber)


func _watch_input_plumber(device) -> void:
	for target in device.dbus_devices:
		if not target.input_event.is_connected(_on_input_plumber_event):
			target.input_event.connect(_on_input_plumber_event)


## Runs inside InputPlumberInstance.process(), which is bound while it emits: nothing here may
## reach code that calls back into it. The pointer park injects an input event (every _input
## handler runs), so it goes after process() returns.
func _on_input_plumber_event(event: String, value: float) -> void:
	_boost()
	if _touch_keyboard:
		_touch_keyboard.pointer_left.call_deferred()
	if event == "ui_guide" and value == 1.0 and _overlay:
		_overlay.expect_ui()


## The in-game state is current only while the game has the foreground: opening the quick bar
## or the in-game menu over it pushes another state (state_exited), closing it re-enters.
func _set_in_game(in_game: bool) -> void:
	_set_idle_pacing(in_game)
	if _display:
		_display.set_backgrounded(in_game)
	if _overlay:
		_overlay.set_in_game(in_game)


const IDLE_SLEEP_MENU_USEC := 16666
const IDLE_SLEEP_IN_GAME_USEC := 50000

func _set_idle_pacing(in_game: bool) -> void:
	OS.low_processor_usage_mode_sleep_usec = IDLE_SLEEP_IN_GAME_USEC if in_game else IDLE_SLEEP_MENU_USEC


func _input(event: InputEvent) -> void:
	if _touch_keyboard:
		_touch_keyboard.note_input(event)
	if _boost_timer == null:
		return
	if event is InputEventMouseMotion and (event as InputEventMouseMotion).relative.length() < 1.0:
		return
	if event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) < 0.2:
		return
	_boost()


func _boost() -> void:
	if _boost_timer == null:
		return
	OS.low_processor_usage_mode = false
	_boost_timer.start()
