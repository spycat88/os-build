extends RefCounted
## Settings > Network > VPN: "Enable Tailscale" puts the device on the player's tailnet
## (packages/tailscale), so it can be reached from their other devices wherever both are.
##
## The section goes at the bottom of OGUI's Network page, laid out like its "Connection Details":
## a section title, a line, then the switch.
##
## OFF BY DEFAULT. tailscaled has no preset and no enable link: nothing runs until the player turns
## the switch on. The choice is kept in OGUI's settings (section "retroforge", key "tailscale",
## default off), and while it is on the daemon is started again at each session start (setup()).
## The shell starts and stops the unit through polkit 50-retroforge-tailscale.rules, and drives the
## Tailscale CLI as the session user, which tailscaled accepts because the session user is its
## operator (the tailscaled.service.d drop-in sets that at every daemon start):
##
##   on    `systemctl start tailscaled`, then `tailscale up --json`. Signed in already: it connects
##         and exits. Signed out (first use, or the node key expired): tailscaled asks the control
##         server for a sign-in URL, which the CLI prints as JSON with a QR code of it (a PNG data
##         URL). That opens the sign-in window: the QR code to scan with a phone, the address to
##         type on another device, and Cancel. The CLI exits once the sign-in is done (the window
##         closes, the switch says the address) or after SIGN_IN_TIMEOUT. A cancelled or failed sign-in turns Tailscale back off.
##   off   `systemctl stop tailscaled`: disconnected and no daemon running, still signed in (the
##         login is in /var/lib/tailscale), so the next on needs no window.
##
## The switch shows the daemon's real state, read again (`systemctl is-active`, then `tailscale
## status --json`) each time the page opens. The section is left out when the image has no
## tailscale.
##
## A tailnet that approves new devices by hand (NeedsMachineAuth) gets no window: the run stops with
## Tailscale left on, the switch says it waits for an admin, and it connects once approved.
##
## netfilter is left off (--netfilter-mode=off): the kernel builds no nftables expressions and no
## iptables filter/nat tables, and a client node needs none of it (it is for subnet routers and
## exit nodes). `tailscale up` refuses a run that does not repeat every non-default setting, so every
## run passes it.
##
## The CLI streams JSON as it goes, so it runs through OS.execute_with_pipe on a thread of its own
## (as scrape_runner.gd), not OGUI's Command, which hands stdout over only once the process ends.

const TOOL := "/usr/bin/tailscale"
const UNIT := "tailscaled.service"
const SECTION := "retroforge"
const KEY := "tailscale"
const UP_FLAGS := ["--netfilter-mode=off"]
## Seconds the sign-in window waits for the player before giving up (`tailscale up --timeout`).
const SIGN_IN_TIMEOUT := 600
const OFF_TEXT := "Reach this device from your other devices with Tailscale, from any network."
const QR_SIZE := 256  # px on screen; the CLI's PNG is 128 px, scaled with nearest filtering

var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var dialog_scene := load("res://core/ui/components/dialog.tscn") as PackedScene
var network_state := load("res://assets/state/states/settings_network.tres") as State
var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var notification_manager := load("res://core/global/notification_manager.tres") as NotificationManager
var logger := Log.get_logger("RetroForgeTailscale", Log.LEVEL.INFO)

## Test seams.
var tool := TOOL
var systemctl := "systemctl"
var tree: SceneTree

var _toggle: Control  # OGUI Toggle
var _dialog: Control  # our own instance of OGUI's dialog.tscn, with the QR code in it
var _dialog_label: Label
var _qr: TextureRect
var _nodes: Array[Node] = []
var _thread: Thread
var _pid := -1
var _up_running := false
var _cancelled := false
## The run stopped on purpose with Tailscale left on: the device waits for an admin's approval.
var _leave_up := false
var _dialog_open := false
var _syncing := false
var _menu: ScrollContainer
var _follow_focus_was := false


## Starts tailscaled when the player left Tailscale on (it reconnects by itself: tailscaled keeps
## that it should run). Not awaited: the session does not wait for the daemon.
func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	if enabled() and FileAccess.file_exists(tool):
		_start_daemon_at_session_start()
	return self


func enabled() -> bool:
	return settings.get_value(SECTION, KEY, false) as bool


func _start_daemon_at_session_start() -> void:
	if not await _systemctl("start"):
		_notify("Could not start Tailscale")
	sync()


## `systemctl start|stop tailscaled`, off the main thread. True when it worked.
func _systemctl(verb: String) -> bool:
	var cmd := Command.create(systemctl, [verb, UNIT])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	if code != 0:
		logger.warn("systemctl %s %s exited %d: %s" % [verb, UNIT, code, cmd.stderr.strip_edges()])
	return code == 0


## Add the VPN section at the bottom of Settings > Network. False when there is no tailscale or the
## layout differs.
func attach() -> bool:
	if not FileAccess.file_exists(tool):
		return false
	var settings: Node = tree.get_first_node_in_group("settings_menu")
	var menu: Node = settings.find_child("NetworkSettings", true, false) if settings else null
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	var holder: Node = tree.get_first_node_in_group("dialog")
	holder = holder.get_parent() if holder else null
	if not (box and holder):
		return false
	# OGUI's Network page is the one settings page without follow_focus: the D-pad reached the switch
	# at the bottom but the page stayed where it was, and only dragging the scrollbar showed it.
	_menu = menu as ScrollContainer
	if _menu:
		_follow_focus_was = _menu.follow_focus
		_menu.follow_focus = true
	# As OGUI's own sections on this page: a gap, the title, a line, the rows.
	var spacer := Control.new()
	spacer.name = "RetroForgeVpnSpacer"
	spacer.custom_minimum_size = Vector2(0, 20)
	var label = section_scene.instantiate()
	label.name = "RetroForgeVpnLabel"
	label.text = "VPN"
	var separator := HSeparator.new()
	separator.name = "RetroForgeVpnSeparator"
	_toggle = toggle_scene.instantiate()
	_toggle.name = "RetroForgeTailscale"
	_toggle.text = "Enable Tailscale"  # read in _ready, so before add_child
	_toggle.separator_visible = false
	_toggle.description = OFF_TEXT
	for node in [spacer, label, separator, _toggle]:
		box.add_child(node)
		_nodes.append(node)
	_toggle.toggled.connect(_on_toggled)
	_add_dialog(holder)
	network_state.state_entered.connect(_on_network_entered)
	network_state.state_exited.connect(_on_network_exited)
	sync()
	return true


func detach() -> void:
	for sig in [network_state.state_entered, network_state.state_exited]:
		for c in sig.get_connections():
			if c["callable"].get_object() == self:
				sig.disconnect(c["callable"])
	if _up_running and _pid > 0:
		_cancelled = true
		OS.execute("kill", ["-TERM", str(_pid)])
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()
	if is_instance_valid(_menu):
		_menu.follow_focus = _follow_focus_was


## A copy of OGUI's dialog beside its own (it lays itself out centred on the screen), with the QR
## code between its text and its button. One button, Cancel: the window closes by itself once the
## sign-in is done.
func _add_dialog(holder: Node) -> void:
	_dialog = dialog_scene.instantiate()
	_dialog.name = "RetroForgeTailscaleSignIn"
	_dialog.visible = false
	_dialog.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_dialog.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	holder.add_child(_dialog)  # in the tree first: its @onready children exist only then
	_nodes.append(_dialog)
	# OGUI finds ITS dialog as the first of group "dialog" (drive_card.gd, retroforge_os.gd): ours is
	# a later sibling so it would not win, but it has no business in that group at all.
	for group in ["dialog", "popup"]:
		if _dialog.is_in_group(group):
			_dialog.remove_from_group(group)
	_dialog.cancel_visible = false
	_dialog.confirm_text = "Cancel"
	_dialog_label = _dialog.label
	_qr = TextureRect.new()
	_qr.name = "QRCode"
	_qr.custom_minimum_size = Vector2(QR_SIZE, QR_SIZE)
	_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_qr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var column := _dialog_label.get_parent()
	column.add_child(_qr)
	column.move_child(_qr, _dialog_label.get_index() + 1)
	# Cancel (the dialog closes itself, close_on_selected).
	_dialog.choice_selected.connect(func(_accepted: bool) -> void:
		_dialog_open = false
		_cancel_sign_in())


func _on_network_entered(_from: State) -> void:
	sync()


## Leaving the page with the window up cancels the sign-in: the window would otherwise stay over
## whatever page comes next.
func _on_network_exited(_to: State) -> void:
	if _dialog_open:
		_close_dialog()
		_cancel_sign_in()


## Set the switch to the daemon's state, without acting on it (OGUI's Toggle emits toggled only from
## its own input handling, never from the setter). Not while `up` runs: that run owns the switch.
func sync() -> void:
	if _syncing or _up_running or not is_instance_valid(_toggle):
		return
	_syncing = true
	# Not running is the switch being off, not an error (the default, and after a stop).
	if OS.execute(systemctl, ["is-active", "--quiet", UNIT]) != 0:
		_syncing = false
		_toggle.disabled = false
		_toggle.button_pressed = false
		_toggle.description = OFF_TEXT
		return
	var cmd := Command.create(tool, ["status", "--json"])
	var code := -1
	if cmd.execute() == OK:
		code = await cmd.finished as int
	_syncing = false
	if _up_running or not is_instance_valid(_toggle):
		return
	var status = JSON.parse_string(cmd.stdout) if cmd.stdout.strip_edges().begins_with("{") else null
	if not status is Dictionary:
		logger.warn("tailscale status exited %d: %s" % [code, cmd.stderr.strip_edges()])
		_toggle.button_pressed = true
		_toggle.description = "Tailscale is not answering. Turn it off and on again."
		_toggle.disabled = false
		return
	_toggle.disabled = false
	var shown := describe(status)
	_toggle.button_pressed = shown["on"]
	_toggle.description = shown["text"]


## What the switch shows for a `tailscale status --json` reply: {"on": bool, "text": String}.
static func describe(status: Dictionary) -> Dictionary:
	var state := str(status.get("BackendState", ""))
	match state:
		"Running":
			var self_node: Dictionary = status.get("Self", {}) if status.get("Self") is Dictionary else {}
			var name := str(self_node.get("DNSName", "")).trim_suffix(".")
			if name == "":
				name = str(self_node.get("HostName", ""))
			var ips: Array = self_node.get("TailscaleIPs", []) if self_node.get("TailscaleIPs") is Array else []
			var address := str(ips[0]) if not ips.is_empty() else ""
			var text := "Connected"
			if name != "":
				text += " as " + name
			if address != "":
				text += " (%s)" % address
			return {"on": true, "text": text + "."}
		"Starting":
			return {"on": true, "text": "Connecting..."}
		"NeedsMachineAuth":
			return {"on": true, "text": "Waiting for an admin of your tailnet to approve this device."}
		"NeedsLogin":
			return {"on": false, "text": "Signed out. Turn on to sign in to Tailscale."}
	return {"on": false, "text": OFF_TEXT}


func _on_toggled(on: bool) -> void:
	if on:
		_turn_on()
	else:
		_turn_off()


func _turn_on() -> void:
	if _up_running:
		return
	settings.set_value(SECTION, KEY, true)
	_toggle.disabled = true
	_toggle.description = "Starting Tailscale..."
	if not await _systemctl("start"):
		settings.set_value(SECTION, KEY, false)
		_notify("Could not start Tailscale")
		if is_instance_valid(_toggle):
			_toggle.disabled = false
		sync()
		return
	if is_instance_valid(_toggle):
		_sign_in()


func _turn_off() -> void:
	settings.set_value(SECTION, KEY, false)
	if is_instance_valid(_toggle):
		_toggle.disabled = true
		_toggle.description = "Turning off..."
	if await _systemctl("stop"):
		logger.info("tailscale off")
	else:
		_notify("Could not turn Tailscale off")
	if is_instance_valid(_toggle):
		_toggle.disabled = false
	sync()


## `tailscale up`, streamed: each JSON object it prints goes to _on_up_event, its exit to
## _on_up_finished.
func _sign_in() -> void:
	if _up_running:
		return
	_up_running = true
	_cancelled = false
	_leave_up = false
	_pid = -1
	_toggle.disabled = true
	_toggle.description = "Connecting..."
	var args := PackedStringArray(["up", "--json", "--timeout=%ds" % SIGN_IN_TIMEOUT])
	args.append_array(PackedStringArray(UP_FLAGS))
	_thread = Thread.new()
	_thread.start(_run_up.bind(args))


# Its own thread.
func _run_up(args: PackedStringArray) -> void:
	var pipe := OS.execute_with_pipe(tool, args, true)
	if pipe.is_empty():
		_on_up_finished.call_deferred(-1, "could not start " + tool)
		return
	_pid = pipe["pid"]
	var io: FileAccess = pipe["stdio"]
	# stderr on a thread of its own at the same time, so a full pipe can never stall the CLI.
	var errors: Array[String] = []
	var err_thread := Thread.new()
	err_thread.start(_drain.bind(pipe["stderr"], errors))
	var buffer := ""
	while true:
		var line := io.get_line()
		if line == "" and io.get_error() != OK:
			break
		# An object starts on a line of its own opening brace. Anything before it is not JSON: the CLI
		# prints its warnings to stdout too, and --netfilter-mode=off always warns first ("Warning:
		# netfilter=off; configure iptables yourself."), which kept in the buffer made the sign-in
		# object unparsable (HW, 2026-11-11).
		if line == "{":
			buffer = ""
		buffer += line + "\n"
		# MarshalIndent: an object ends on a line of its own closing brace.
		if line == "}":
			var event = JSON.parse_string(buffer)
			if event is Dictionary:
				_on_up_event.call_deferred(event)
			else:
				_log.call_deferred("tailscale up: unparsable output: " + buffer.left(200))
			buffer = ""
	err_thread.wait_to_finish()
	while OS.is_process_running(_pid):
		OS.delay_msec(10)
	var code := OS.get_process_exit_code(_pid)
	_on_up_finished.call_deferred(code, "" if errors.is_empty() else errors[-1])


static func _drain(err: FileAccess, lines: Array[String]) -> void:
	while true:
		var line := err.get_line()
		if line == "" and err.get_error() != OK:
			return
		if line.strip_edges() != "":
			lines.append(line.strip_edges())


func _log(text: String) -> void:
	logger.warn(text)


func _on_up_event(event: Dictionary) -> void:
	var state := str(event.get("BackendState", ""))
	var url := str(event.get("AuthURL", ""))
	if event.has("Error"):
		logger.warn("tailscale up: " + str(event["Error"]))
	if url != "" and not _cancelled:
		_open_dialog(url, str(event.get("QR", "")))
	elif state == "Running":
		_close_dialog()
	elif state == "NeedsMachineAuth" and not _cancelled:
		# Signed in, but the tailnet approves new devices by hand. Nothing for the player to do here:
		# stop waiting with Tailscale left on; it connects by itself once approved (sync() says so).
		_close_dialog()
		_leave_up = true
		if _pid > 0:
			OS.execute("kill", ["-TERM", str(_pid)])


func _on_up_finished(code: int, error: String) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	_pid = -1
	_up_running = false
	_close_dialog()
	if not is_instance_valid(_toggle):
		return
	_toggle.disabled = false
	if code == 0 or _leave_up:
		logger.info("tailscale up: " + ("connected" if code == 0 else "waiting for approval"))
		_leave_up = false
		sync()
		return
	if not _cancelled:
		logger.warn("tailscale up exited %d: %s" % [code, error])
		# EOF: tailscaled dropped the CLI's connection, i.e. the daemon stopped or restarted under it.
		if error == "EOF":
			_notify("Tailscale stopped while connecting")
		else:
			_notify("Tailscale did not connect" if error == "" else "Tailscale: " + error)
	# Signed out, cancelled or failed: back off, so the switch, the setting and the daemon agree.
	_turn_off()


func _cancel_sign_in() -> void:
	if not _up_running or _cancelled:
		return
	_cancelled = true
	logger.info("tailscale sign-in cancelled")
	if _pid > 0:
		OS.execute("kill", ["-TERM", str(_pid)])


func _open_dialog(url: String, qr: String) -> void:
	if not is_instance_valid(_dialog):
		return
	var texture: Texture2D = null
	if qr.begins_with("data:image/png;base64,"):
		var image := Image.new()
		if image.load_png_from_buffer(Marshalls.base64_to_raw(qr.trim_prefix("data:image/png;base64,"))) == OK:
			texture = ImageTexture.create_from_image(image)
	_qr.texture = texture
	_qr.visible = texture != null
	_dialog.text = "Sign in to Tailscale\n\nScan the code with your phone, or open this address on another device:\n" + url
	if _dialog_open:
		return  # a new URL for the window already up: only its contents change
	_dialog_open = true
	_dialog.open(_toggle)
	_toggle.description = "Waiting for the sign-in..."


func _close_dialog() -> void:
	if _dialog_open and is_instance_valid(_dialog):
		_dialog_open = false
		_dialog.closed.emit()
		if is_instance_valid(_toggle):
			_toggle.grab_focus.call_deferred()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
