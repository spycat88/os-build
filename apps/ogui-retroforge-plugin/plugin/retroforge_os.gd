extends OSPlatform
## RetroForge's OS platform: Settings > General > Updates drives /usr/bin/retroforge-update (plan
## ota-ui Phase 2), in place of OGUI's own updater, which only knows OGUI's x86 update.zip.
##
## OGUI picks its OS platform from a fixed list of os-release IDs (core/global/platform.gd) that
## has no `retroforge`, and calls ready(root) from card_ui's _ready, before plugins load. So
## plugin.gd installs this as platform.os and calls ready() itself, as Platform.load() would have
## (core/platform/os/nixos.gd is the model).
##
## The section: one button walking Check for updates -> Install <version> (progress in its
## description) -> Restart now, and a Stable / Beta / Nightly dropdown; switching never asks (plan ota-ui D3)
## and checks the new channel straight away. Nothing installs or restarts without a press (D2). An
## update already installed and waiting for a reboot shows Restart now from the start. A background
## check (3 min after start, then every 6 h, never while a game runs) posts one notification per
## version found; it never installs (plan ota-ui Phase 3).
##
## Under it, Remote access: "Allow pairing a computer" starts and stops retroforge-pairingd, the
## unauthenticated socket that accepts an SSH key for `player` (docs/remote-access.md). Off at every
## boot (the unit has no [Install], D5); polkit 50-retroforge-pairing.rules lets the session start
## and stop that one unit. The switch shows the daemon's real state, read again whenever Settings >
## General opens, so it never claims "on" after a crash or "off" while it still listens.
##
## Last, Factory reset: two rows (keep games / erase everything), each confirmed in OGUI's dialog, starting
## retroforge-reset@soft|hard.service, whose own screen takes the pad-sequence consent.
##
## Between them, on a card only, Internal storage: one button that asks release-info what would be
## installed, confirms in OGUI's dialog, and starts retroforge-installer.service, which ends this
## session and takes the panel (polkit 50-retroforge-installer.rules). --no-block because the session
## asking is the one being stopped.

const UpdateStates := preload("update_states.gd")
const InternalInstall := preload("internal_install.gd")
const ScrapeRunner := preload("scrape_runner.gd")
const GeneralBox := preload("general_box.gd")
const TOOL := "/usr/bin/retroforge-update"
const CHECK_TIMEOUT := 60.0  # s: the manifest fetch retries for at most ~30 s
const FIRST_CHECK_DELAY := 180.0  # s after start: the network is up, the player is not mid-menu
const CHECK_INTERVAL := 6 * 3600.0
const IN_GAME_RETRY := 600.0  # s: a check skipped for a running game is tried again this soon
const PAIRING_UNIT := "retroforge-pairingd.service"
const PAIRING_PORT := 32000  # retroforge-pairingd's SERVICE_PORT
const INSTALLER_UNIT := "retroforge-installer.service"
const BOOT_MEDIUM := "/usr/lib/retroforge/install/boot-medium"
const RELEASE_INFO := "/usr/lib/retroforge/install/release-info"
const INSTALL_TEXT := "Install RetroForge beside Android, so the device runs without this card."
## Factory reset (issue #40, .claude/plans/factory-reset.plan.md): the unit of each level, and its rows.
const RESET_UNIT := "retroforge-reset@%s.service"
const RESET_ROWS := {
	"soft": {
		"name": "RetroForgeResetSoft", "text": "Reset settings, keep games", "button": "Reset",
		"description": "Keeps your ROMs, BIOS files, saves and states. Erases settings, Wi-Fi, sign-ins and downloads.",
		"confirm": "Restart and reset this device? Your ROMs, BIOS files, saves and states are kept; everything else is erased. You confirm on the next screen.",
	},
	"hard": {
		"name": "RetroForgeResetHard", "text": "Erase everything", "button": "Erase",
		"description": "Erases everything you put on this device, ROMs and saves included. The RetroForge version stays.",
		"confirm": "Restart and erase everything on this device? ROMs, saves and settings are erased for good. You confirm on the next screen.",
	},
}

var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var general_settings_state := load("res://assets/state/states/settings_general.tres") as State

## Test seams (tests/test-plugin.sh runs this against OGUI's own settings scene and a fake client).
var tool := TOOL
var reboot_command: Array[String] = ["systemctl", "reboot"]
var systemctl := "systemctl"
var boot_medium := BOOT_MEDIUM
var release_info := RELEASE_INFO
var first_check_delay := FIRST_CHECK_DELAY
var in_game := _game_running

var _apply := ScrapeRunner.new()  # runs the install: `N%` lines on a worker thread
var _step := UpdateStates.Step.IDLE
var _running := ""  # this image's version
var _offered := ""  # the version check found, or the one staged
var _switching := false  # set-channel is running: the button and the background check wait
var _channels: Array[String] = []
## The hosted channel list's labels and descriptions, by channel (UpdateStates.parse_channels).
var _channel_labels := {}
var _channel_descriptions := {}
## A _fill_channels() is awaiting retroforge-update; a page visit does not start a second one.
var _filling_channels := false
var _button: Control  # card_button_setting
var _channel: Control  # dropdown
var _pairing: Control  # toggle
var _install_row: Control  # card_button_setting, only on a card
var _timer: Timer  # background checks
var _notified := ""  # the last version a background check announced
var _nodes: Array[Node] = []
var _hidden: Array[Node] = []  # OGUI's own nodes hidden here, shown again on detach


## Called by plugin.gd once the settings menus exist. (No _init override: tests/test-plugin.sh
## forbids one in every plugin script.)
func ready(root: Window) -> void:
	logger = Log.get_logger("PlatformRetroForge", Log.LEVEL.INFO)
	name = "RetroForge"
	_apply.tool = tool
	_apply.progressed.connect(_on_install_progress)
	_apply.finished.connect(_on_install_finished)
	var menu: Node = root.find_child("GeneralSettings", true, false)
	var box: Node = GeneralBox.find(menu)
	if not box:
		logger.warn("OGUI general settings layout not found; no Updates section")
		return
	_remove_ogui_updater(menu, box)
	if FileAccess.file_exists(tool):
		_add_updater(box)
		_start_background_checks(menu)
	_add_remote_access(box)
	_add_separator_under(box, "Appearance")
	_add_internal_install(box)
	_add_factory_reset(box)


func detach() -> void:
	if general_settings_state.state_entered.is_connected(_on_general_entered):
		general_settings_state.state_entered.disconnect(_on_general_entered)
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	for node in _hidden:
		if is_instance_valid(node):
			node.visible = true
	_hidden.clear()


## A line under one of OGUI's own section titles, like the ones under ours.
func _add_separator_under(box: Node, title: String) -> void:
	var label := box.get_node_or_null(title)
	if not label:
		return
	var separator := HSeparator.new()
	box.add_child(separator)
	box.move_child(separator, label.get_index() + 1)
	_nodes.append(separator)


## OGUI's updater fetches OGUI's x86 update.zip (the session runs it with --skip-update-pack): its
## auto-update toggle, buttons, timer and SoftwareUpdater go, as nixos.gd removes them. The menu's
## script keeps references to them, so those are cleared too.
func _remove_ogui_updater(menu: Node, box: Node) -> void:
	for path in ["SoftwareUpdater", "UpdateTimer"]:
		var node := menu.get_node_or_null(path)
		if node:
			node.queue_free()
	for path in ["AutoUpdateToggle", "CheckUpdateButton", "UpdateButton"]:
		var node := box.get_node_or_null(path)
		if node:
			node.queue_free()
	for property in ["updater", "update_timer", "auto_update_toggle", "check_update_button", "update_button"]:
		if property in menu:
			menu.set(property, null)


func _add_updater(box: Node) -> void:
	var label: Node = box.get_node_or_null("UpdatesLabel")
	if not label:
		label = section_scene.instantiate()
		label.text = "Updates"
		box.add_child(label)
		box.move_child(label, 0)
		_nodes.append(label)
	_button = button_scene.instantiate()
	_button.name = "RetroForgeUpdateButton"
	_button.text = "System update"
	_button.button_up.connect(_on_button)
	_channel = dropdown_scene.instantiate()
	_channel.name = "RetroForgeUpdateChannel"
	_channel.title = "Update channel"
	# In the tree FIRST: a component's @onready children only exist once it is ready, and OGUI is a
	# release export, where calling a method on such a null child segfaults instead of erroring
	# (see scraper_settings.gd).
	var at := label.get_index() + 1
	for node in [HSeparator.new(), _button, _channel]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	var focus_group = box.get_node_or_null("FocusGroup")
	if focus_group:
		focus_group.current_focus = _button  # was OGUI's auto-update toggle, now freed
	_channel.item_selected.connect(_on_channel_selected)
	_load_state()


## The version and the channels, read once the rows are up and not awaited by _add_updater: each run
## of retroforge-update starts Python, ~0.5 s on the Air X, and the three of them held OGUI's first
## frames back by 1.3 s at boot (2026-11-01).
func _load_state() -> void:
	_running = (await _run_async(["version"])).strip_edges()
	if not _alive():
		return
	if _running == "":
		logger.warn("retroforge-update version printed nothing")
	await _fill_channels()
	if not _alive():
		return
	_show()
	_restore_staged()


## A Timer beside OGUI's own (the menu held its UpdateTimer the same way).
func _start_background_checks(host: Node) -> void:
	_timer = Timer.new()
	_timer.name = "RetroForgeUpdateTimer"
	_timer.one_shot = true
	_timer.timeout.connect(_on_background_check)
	host.add_child(_timer)
	_nodes.append(_timer)
	_timer.start(first_check_delay)


func _on_background_check() -> void:
	if _switching or not UpdateStates.background_check_wanted(_step, in_game.call()):
		_timer.start(IN_GAME_RETRY if _step == UpdateStates.Step.IDLE else CHECK_INTERVAL)
		return
	_timer.start(CHECK_INTERVAL)
	if await check() and _step == UpdateStates.Step.AVAILABLE and _offered != _notified:
		_notified = _offered
		_notify(UpdateStates.available_text(_offered))


## Whether a game runs. Behind the `in_game` seam, so tests/test-plugin.sh need not load LaunchManager
## (it brings InputPlumber, which a test host lacks).
func _game_running() -> bool:
	var launch_manager := load("res://core/global/launch_manager.tres") as LaunchManager
	return launch_manager.get_current_app() != null


## Remote access, after the Updates rows (or at the top when there is no update client).
func _add_remote_access(box: Node) -> void:
	var label = section_scene.instantiate()
	label.text = "Remote access"
	_pairing = toggle_scene.instantiate()
	_pairing.name = "RetroForgePairing"
	_pairing.text = "Allow pairing a computer"
	_pairing.separator_visible = false  # read in _ready, so before add_child
	# Nor OGUI's line between the Updates rows and Appearance, which now falls under this one.
	var separator := box.get_node_or_null("HSeparator2")
	if separator:
		separator.visible = false
		_hidden.append(separator)
	var at: int = _channel.get_index() + 1 if is_instance_valid(_channel) else 0
	for node in [label, HSeparator.new(), _pairing]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	_pairing.toggled.connect(_on_pairing_toggled)
	general_settings_state.state_entered.connect(_on_general_entered)
	_sync_pairing()


## Internal storage, between Updates and Remote access, when this system runs from a card. Added once
## boot-medium has answered, not awaited by ready(), like _load_state.
func _add_internal_install(box: Node) -> void:
	var medium := Command.create(boot_medium, [])
	if medium.execute() != OK or (await medium.finished) != 0 or medium.stdout.strip_edges() != "card":
		return
	if not is_instance_valid(box):  # detached while it ran
		return
	var label = section_scene.instantiate()
	label.text = "Internal storage"
	_install_row = button_scene.instantiate()
	_install_row.name = "RetroForgeInternalInstall"
	_install_row.text = "Install to internal storage"
	var at: int = _channel.get_index() + 1 if is_instance_valid(_channel) else 0
	# In the tree first, for the reason _add_updater gives.
	for node in [label, HSeparator.new(), _install_row]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	_install_row.button_text = "Install"
	_install_row.description = INSTALL_TEXT
	_install_row.button_up.connect(_on_install_pressed)


func _on_install_pressed() -> void:
	_install_row.disabled = true
	_install_row.description = "Looking for the latest RetroForge..."
	var cmd := Command.create(release_info, [])
	var out := ""
	if cmd.execute() == OK and (await cmd.finished) == 0:
		out = cmd.stdout
	if not is_instance_valid(_install_row):  # detached while it ran
		return
	_install_row.disabled = false
	var release := InternalInstall.parse_release(out)
	if not InternalInstall.can_install(release):
		_install_row.description = InternalInstall.refusal(release)
		return
	_install_row.description = INSTALL_TEXT
	var dialog = (Engine.get_main_loop() as SceneTree).get_first_node_in_group("dialog")
	if not dialog:  # never start it unconfirmed
		logger.warn("no OGUI dialog to confirm the installer with")
		return
	dialog.open(_install_row, InternalInstall.confirmation(release), "Install", "Cancel")
	if not await dialog.choice_selected:
		return
	var start := Command.create(systemctl, ["--no-block", "start", INSTALLER_UNIT])
	var code := -1
	if start.execute() == OK:
		code = await start.finished as int
	if code != 0:
		logger.warn("systemctl start %s exited %d: %s" % [INSTALLER_UNIT, code, start.stderr])
		_notify("Could not start the installer")


## Factory reset, the last of our sections, just above OGUI's Appearance (appended, it would land
## between OGUI's Theme title and its theme buttons, which sit in the next container): one row per level. Each confirms in OGUI's dialog and starts
## retroforge-reset@<level>.service, which ends this session and takes the consent on the panel before
## anything is written (polkit 50-retroforge-reset.rules); --no-block because the session asking is the
## one being stopped. On a card and on an internal install alike.
func _add_factory_reset(box: Node) -> void:
	var label = section_scene.instantiate()
	label.text = "Factory reset"
	var rows: Array[Node] = []
	for level in ["soft", "hard"]:
		var row = button_scene.instantiate()
		row.name = RESET_ROWS[level]["name"]
		row.text = RESET_ROWS[level]["text"]
		rows.append(row)
	var appearance := box.get_node_or_null("Appearance")
	var at: int = appearance.get_index() if appearance else box.get_child_count()
	# In the tree first, for the reason _add_updater gives.
	for node in [label, HSeparator.new()] + rows:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	for i in rows.size():
		var level: String = ["soft", "hard"][i]
		rows[i].button_text = RESET_ROWS[level]["button"]
		rows[i].description = RESET_ROWS[level]["description"]
		rows[i].button_up.connect(_on_reset_pressed.bind(level, rows[i]))


func _on_reset_pressed(level: String, row: Control) -> void:
	var dialog = (Engine.get_main_loop() as SceneTree).get_first_node_in_group("dialog")
	if not dialog:  # never start it unconfirmed
		logger.warn("no OGUI dialog to confirm the factory reset with")
		return
	dialog.open(row, RESET_ROWS[level]["confirm"], RESET_ROWS[level]["button"], "Cancel")
	if not await dialog.choice_selected:
		return
	var unit := RESET_UNIT % level
	var start := Command.create(systemctl, ["--no-block", "start", unit])
	var code := -1
	if start.execute() == OK:
		code = await start.finished as int
	if code != 0:
		logger.warn("systemctl start %s exited %d: %s" % [unit, code, start.stderr])
		_notify("Could not start the factory reset")


func _on_general_entered(_from: State) -> void:
	_sync_pairing()
	# The channel list is fetched online only, and the first fetch runs at shell start, often before
	# the network is up. Every visit to the page tries again until a list arrives.
	if _channels.is_empty() and _alive() and not _filling_channels:
		await _fill_channels()
		_show()


## Set the switch to whether the daemon runs, without acting on it (OGUI's Toggle emits toggled
## only from its own input handling, never from the setter).
func _sync_pairing() -> void:
	if not is_instance_valid(_pairing):
		return
	var on := OS.execute(systemctl, ["is-active", "--quiet", PAIRING_UNIT]) == 0
	_pairing.button_pressed = on
	_pairing.description = pairing_text(on, _address())


func _on_pairing_toggled(on: bool) -> void:
	_pairing.disabled = true
	var cmd := Command.create(systemctl, ["start" if on else "stop", PAIRING_UNIT])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if not is_instance_valid(_pairing):  # detached while systemctl ran
		return
	_pairing.disabled = false
	if code != 0:
		logger.warn("systemctl %s %s exited %d: %s" % ["start" if on else "stop", PAIRING_UNIT, code, cmd.stderr])
		_notify("Could not turn pairing %s" % ("on" if on else "off"))
	else:
		logger.info("pairing " + ("on" if on else "off"))
	_sync_pairing()


## What the switch says: how to pair while it is on.
static func pairing_text(on: bool, address: String) -> String:
	if not on:
		return "Turn on to send your computer's SSH key to this device. Turns off when the device restarts."
	return "From a computer on this network: curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://%s:%d/register" % [address, PAIRING_PORT]


## The device's first global IPv4 address, or its mDNS name when it has none.
func _address() -> String:
	var out := []
	if OS.execute("ip", ["-4", "-o", "addr", "show", "scope", "global"], out) == 0 and not out.is_empty():
		for line in str(out[0]).split("\n", false):
			var fields := line.split(" ", false)
			var at := fields.find("inet")
			if at >= 0 and at + 1 < fields.size():
				return fields[at + 1].get_slice("/", 0)
	return "retroforge.local"


## Run a local subcommand synchronously (no network); its stdout, "" on failure.
func _run(args: Array) -> String:
	var out := []
	return str(out[0]) if OS.execute(tool, args, out) == 0 and not out.is_empty() else ""


## _run, off the main thread.
func _run_async(args: Array) -> String:
	var cmd := Command.create(tool, args)
	if cmd.execute() != OK or (await cmd.finished) != 0:
		return ""
	return cmd.stdout


func _fill_channels() -> void:
	_filling_channels = true
	var listed := UpdateStates.parse_channels(await _run_async(["channels"]))
	var current := UpdateStates.parse_channel(await _run_async(["channel"]))
	_filling_channels = false
	if not _alive():
		return
	_channels = listed["channels"]
	_channel_labels = listed["labels"]
	_channel_descriptions = listed["descriptions"]
	_channel.clear()  # dropdown.tscn ships one placeholder item
	if _channels.is_empty():
		# The list is fetched from GitHub every time, with no fallback (retroforge-update channels exits
		# non-zero). Show the channel in effect, locked, and say why, instead of an empty dropdown.
		if current != "":
			_channel.add_item(UpdateStates.channel_name(current))
			_channel.select(0)
		_channel.description = UpdateStates.CHANNELS_UNAVAILABLE
		_channel.set_meta("pinned", true)  # locked as a pin is: there is nothing to pick from
		return
	for i in _channels.size():
		_channel.add_item(UpdateStates.channel_name(_channels[i], _channel_labels))
		if _channels[i] == current:
			_channel.select(i)
	_channel.description = UpdateStates.channel_description(listed["pinned"], current, _channel_descriptions)
	_channel.set_meta("pinned", listed["pinned"] != "")


## Whether the section's nodes still exist: every await below may end after detach() freed them, and
## touching a freed node in OGUI's release export can crash it.
func _alive() -> bool:
	return is_instance_valid(_button) and is_instance_valid(_channel)


func _show(percent := 0) -> void:
	if not _alive():
		return
	var shown := UpdateStates.button_for(_step, _running, _offered, percent)
	_button.button_text = shown["button"]
	_button.description = shown["description"]
	_button.disabled = shown["disabled"] or _switching
	var busy := _switching or _step in [UpdateStates.Step.CHECKING, UpdateStates.Step.INSTALLING]
	_channel.disabled = busy or bool(_channel.get_meta("pinned", false))


## A session restarted after an install (OGUI crash, logout) still has the update waiting.
func _restore_staged() -> void:
	var cmd := Command.create(tool, ["staged"])
	if cmd.execute() != OK or (await cmd.finished) != 0 or not _alive():
		return
	if _step == UpdateStates.Step.IDLE and not _switching:
		_offered = cmd.stdout.strip_edges()
		_step = UpdateStates.Step.STAGED
		_show()


func _on_button() -> void:
	if _switching:
		return
	match _step:
		UpdateStates.Step.IDLE:
			check()
		UpdateStates.Step.AVAILABLE:
			_install()
		UpdateStates.Step.STAGED:
			_restart()


## Ask the channel's server for a newer version. True when one is available (or already staged).
func check() -> bool:
	if _step in [UpdateStates.Step.CHECKING, UpdateStates.Step.INSTALLING]:
		return false
	if _step == UpdateStates.Step.STAGED:
		return true
	_step = UpdateStates.Step.CHECKING
	_show()
	var cmd := Command.create(tool, ["check"])
	cmd.timeout = CHECK_TIMEOUT
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	var offered := cmd.stdout.strip_edges()
	if code == 0 and offered != "":
		_offered = offered
		# check reprints an update that is already installed: Restart, not Install again.
		_step = UpdateStates.Step.STAGED if await _is_staged() else UpdateStates.Step.AVAILABLE
	else:
		# Exit 7 is also how most failures end (no network, a bad manifest): the client fails closed.
		# Exit 8 is the one it tells apart: the channel list on GitHub could not be fetched, so
		# nothing was checked and "No update found" would be untrue.
		_step = UpdateStates.Step.IDLE
		if code != 7:
			logger.warn("retroforge-update check exited %d: %s" % [code, cmd.stderr])
	if not _alive():
		return false
	_show()
	if _step == UpdateStates.Step.IDLE:
		if code == 8:
			_button.description = UpdateStates.CHECK_NO_CHANNELS
		else:
			_button.description = "No update found on the %s channel." % UpdateStates.channel_name(_current_channel(), _channel_labels)
	return _step != UpdateStates.Step.IDLE


## `staged` answers 0 (with the version) when an update waits for a reboot; updates _offered.
func _is_staged() -> bool:
	var cmd := Command.create(tool, ["staged"])
	if cmd.execute() != OK or (await cmd.finished) != 0:
		return false
	_offered = cmd.stdout.strip_edges()
	return true


func _install() -> void:
	if not _apply.start([]):
		logger.warn("an install is already running")
		return
	_step = UpdateStates.Step.INSTALLING
	_show()


func _on_install_progress(percent: int) -> void:
	if _step == UpdateStates.Step.INSTALLING:
		_show(percent)


func _on_install_finished(code: int, _summary: Dictionary, error: String) -> void:
	# Exit 0 is also "already running the newest, nothing installed": Restart now only for an update
	# that really waits for a reboot.
	if code == 0 and await _is_staged():
		_step = UpdateStates.Step.STAGED
		_show()
		_notify("RetroForge %s is installed. Restart to use it." % _offered)
		return
	_step = UpdateStates.Step.IDLE
	_show()
	if not _alive():
		return
	if code == 0:
		_button.description = "Nothing to install: RetroForge is up to date."
		return
	logger.warn("retroforge-update exited %d: %s" % [code, error])
	_button.description = "The update could not be installed. Check the network and try again."
	_notify("The RetroForge update could not be installed")


func _on_channel_selected(index: int) -> void:
	if index < 0 or index >= _channels.size() or _switching:
		return
	# The dropdown is disabled while a check or an install runs, and _switching holds the button and
	# the background check until the new channel is written and checked.
	_switching = true
	_show()
	var cmd := Command.create(tool, ["set-channel", _channels[index]])
	var ok: bool = cmd.execute() == OK and (await cmd.finished) == 0
	_switching = false
	if not _alive():
		return
	if not ok:
		logger.warn("retroforge-update set-channel %s failed: %s" % [_channels[index], cmd.stderr])
		_notify("Could not change the update channel")
		await _fill_channels()
		_show()
		return
	logger.info("update channel: " + _channels[index])
	_channel.description = UpdateStates.channel_description("", _channels[index], _channel_descriptions)  # set-channel succeeded, so nothing pins it
	if _step == UpdateStates.Step.AVAILABLE:
		_step = UpdateStates.Step.IDLE  # that offer was the other channel's
	check()


## As OGUI's power menu reboots (power_menu.gd): systemctl as the session user.
func _restart() -> void:
	logger.info("restarting into RetroForge " + _offered)
	var output := []
	if OS.execute(reboot_command[0], PackedStringArray(reboot_command.slice(1)), output, true) != OK:
		logger.warn("%s failed: %s" % [" ".join(reboot_command), output])
		_notify("Could not restart. Use the power menu to restart.")


func _current_channel() -> String:
	return UpdateStates.parse_channel(_run(["channel"]))


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
