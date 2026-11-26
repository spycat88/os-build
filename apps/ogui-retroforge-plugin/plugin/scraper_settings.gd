extends RefCounted
## Settings > Library > "ROM art": scrape box art from ScreenScraper (plan scraper Phase 3).
##
## Under OGUI's Refresh Library button: Scrape missing art / Scrape all art again (with progress and
## Cancel), "Scrape new games automatically" (on by default: a card of a ROM the tool never tried
## fetches its art when it is built, art_fetch.gd, as Steam's cards do), the art region, and the
## player's optional ScreenScraper account (a free account scrapes
## with more threads and quota, and keeps working when ScreenScraper closes to non-members). All of
## it goes through /usr/bin/retroforge-scrape (scrape_runner.gd); the password goes to the tool on
## stdin and is kept only in its 0600 conf, never in OGUI's settings. When a run ends the ROM
## library is reloaded, which rebuilds our tabs' cards with their new art.
##
## A build without RetroForge's ScreenScraper developer login (rootfs/lib-assemble-scraper.sh) shows
## the section greyed out with the reason.

const ScrapeRunner := preload("scrape_runner.gd")
const TOOL := "/usr/bin/retroforge-scrape"
const DEVID_FILE := "/usr/share/retroforge/scraper/devid"
const LIBRARY_ID := "retroforge-roms"
## OGUI settings: section, key of "Scrape new games automatically" (default on).
const SECTION := "retroforge"
const AUTO_KEY := "auto_scrape"
## Region choices, in dropdown order: retroforge-scrape's values and what the player reads.
const REGIONS := ["auto", "wor", "us", "eu", "jp"]
const REGION_NAMES := ["Automatic (from the file names)", "World", "USA", "Europe", "Japan"]
const MISSING_TEXT := "Fetch box art from ScreenScraper for the games that have none yet."
const ALL_TEXT := "Fetch every game's art again. Uses more of ScreenScraper's daily quota."

var library_manager := load("res://core/global/library_manager.tres") as LibraryManager
var settings := load("res://core/global/settings_manager.tres") as SettingsManager
var toggle_scene := load("res://core/ui/components/toggle.tscn") as PackedScene
var notification_manager := load("res://core/global/notification_manager.tres")
var section_scene := load("res://core/ui/components/section_label.tscn") as PackedScene
var button_scene := load("res://core/ui/components/card_button_setting.tscn") as PackedScene
var dropdown_scene := load("res://core/ui/components/dropdown.tscn") as PackedScene
var input_scene := load("res://core/ui/components/text_input.tscn") as PackedScene

var logger := Log.get_logger("RetroForgeScraper", Log.LEVEL.INFO)
var tree: SceneTree
var runner := ScrapeRunner.new()
var _login := ScrapeRunner.new()  # a field: a runner must outlive its worker thread
var _nodes: Array[Node] = []
var _missing: Control  # card_button_setting
var _all: Control
var _region: Control  # dropdown
var _user: Control  # text_input
var _password: Control
var _account: Control  # card_button_setting
var _account_info := {}  # `retroforge-scrape account`
var _running_button: Control  # the button whose run is going (it reads Cancel)
var _auto: Control  # toggle: "Scrape new games automatically"


func setup(scene_tree: SceneTree) -> RefCounted:
	tree = scene_tree
	runner.progressed.connect(_on_progress)
	runner.finished.connect(_on_finished)
	_login.finished.connect(_on_login_finished)
	return self


## Add the section under Settings > Library's Refresh Library. False when the layout differs.
func attach() -> bool:
	var menu: Node = tree.root.find_child("LibrarySettingsMenu", true, false)
	var box: Node = menu.get_node_or_null("MarginContainer/VBoxContainer") if menu else null
	if not box:
		return false
	var at: int = box.get_node("RefreshLibraryButton").get_index() + 1 if box.has_node("RefreshLibraryButton") else box.get_child_count()
	var label = section_scene.instantiate()
	label.text = "ROM Art"
	_missing = _button("Scrape missing art", "Scrape", MISSING_TEXT)
	_missing.pressed.connect(_on_scrape.bind(false))
	_all = _button("Scrape all art again", "Scrape all", ALL_TEXT)
	_all.pressed.connect(_on_scrape.bind(true))
	_auto = toggle_scene.instantiate()
	_auto.text = "Scrape new games automatically"
	_auto.description = "Fetch art for a new ROM when its card first shows."
	_region = dropdown_scene.instantiate()
	_region.title = "Art region"
	_region.description = "Which region's box to prefer when a game has several."
	_user = input_scene.instantiate()
	_user.title = "ScreenScraper user name"
	_user.description = "Optional: a free account from screenscraper.fr scrapes faster and keeps working when ScreenScraper is busy."
	_password = input_scene.instantiate()
	_password.title = "ScreenScraper password"
	_password.description = ""
	_password.secret = true
	_account = _button("ScreenScraper account", "Sign in", "")
	_account.pressed.connect(_on_account_pressed)
	# In the tree FIRST: a component's @onready children only exist once it is ready, and OGUI is a
	# release export, where calling a method on such a null child segfaults instead of erroring
	# (dropdown.clear() before add_child crashed OGUI at every start, ACE 2026-10-17).
	# A separator closes the section, like the stock one under the last Library section.
	for node in [label, _missing, _all, _auto, _region, _user, _password, _account, HSeparator.new()]:
		box.add_child(node)
		box.move_child(node, at)
		at += 1
		_nodes.append(node)
	_region.clear()  # dropdown.tscn ships one placeholder item
	for text in REGION_NAMES:
		_region.add_item(text)
	_region.item_selected.connect(_on_region_selected)
	_auto.button_pressed = auto_enabled()
	_auto.toggled.connect(func(on: bool) -> void: settings.set_value(SECTION, AUTO_KEY, on))
	_refresh()
	return true


func detach() -> void:
	runner.cancel()
	for node in _nodes:
		if is_instance_valid(node):
			node.queue_free()
	_nodes.clear()


func _button(text: String, button_text: String, description: String) -> Control:
	var button = button_scene.instantiate()
	button.text = text
	button.button_text = button_text
	button.description = description
	return button


## Read the account and quota (no network), and set every row from it.
func _refresh() -> void:
	var available := FileAccess.file_exists(DEVID_FILE)
	var out := []
	_account_info = {}
	if available and OS.execute(TOOL, ["account"], out) == 0 and not out.is_empty():
		var data = JSON.parse_string(str(out[0]))
		_account_info = data if data is Dictionary else {}
	var signed_in := bool(_account_info.get("configured", false))
	for row in [_missing, _all, _auto, _region, _account, _user, _password]:
		row.set("disabled", not available)
	_user.editable = available
	_password.editable = available
	_region.select(maxi(0, REGIONS.find(str(_account_info.get("region", "auto")))))
	_user.visible = not signed_in
	_password.visible = not signed_in
	_account.button_text = "Sign out" if signed_in else "Sign in"
	_account.description = "Signed in as %s." % _account_info.get("user") if signed_in else \
		"Not signed in: ScreenScraper's anonymous limits apply."
	# Progress is shown in the running button's description: both are rewritten once nothing runs
	# ("Scrape all" kept "Scraping... 100%" after its run, ACE 2026-10-17).
	if not available:
		_missing.description = ScrapeRunner.failure_text(9, "")
		_all.description = ALL_TEXT
	elif not runner.running:
		_missing.description = MISSING_TEXT + _quota_text()
		_all.description = ALL_TEXT


func auto_enabled() -> bool:
	return settings.get_value(SECTION, AUTO_KEY, true) as bool


## Whether a card may fetch its art (art_fetch.gd): the setting is on, the build can scrape, and no
## sign-in is being checked (the tool's conf is being rewritten).
func can_fetch() -> bool:
	return auto_enabled() and FileAccess.file_exists(DEVID_FILE) and not _login.running


func _quota_text() -> String:
	var today = _account_info.get("requests_today")
	var most = _account_info.get("max_requests_per_day")
	if today == null or most == null:
		return ""
	return " Requests today: %d of %d." % [int(today), int(most)]


func _on_scrape(every: bool) -> void:
	if runner.running:
		if _running_button == (_all if every else _missing):
			runner.cancel()
		return
	_running_button = _all if every else _missing
	if runner.start(["run", "--all"] if every else ["run"]):
		_running_button.button_text = "Cancel"
		_running_button.description = "Starting..."


func _on_progress(percent: int) -> void:
	if is_instance_valid(_running_button):
		_running_button.description = "Scraping... %d%%" % percent


func _on_finished(code: int, summary: Dictionary, error: String) -> void:
	if code == 0 or not summary.is_empty():
		_notify(ScrapeRunner.summary_text(summary) if code == 0 else
			ScrapeRunner.failure_text(code, error) + " " + ScrapeRunner.summary_text(summary))
	else:
		_notify(ScrapeRunner.failure_text(code, error))
	if code != 0:
		logger.warn("retroforge-scrape exited %d: %s" % [code, error])
	if is_instance_valid(_running_button):
		_running_button.button_text = "Scrape all" if _running_button == _all else "Scrape"
	_running_button = null
	if int(summary.get("scraped", 0)) > 0:
		library_manager.load_library(LIBRARY_ID)  # our tabs rebuild their cards, with the new art
	_refresh()


func _on_region_selected(index: int) -> void:
	if index >= 0 and index < REGIONS.size():
		OS.execute(TOOL, ["region", REGIONS[index]])


func _on_account_pressed() -> void:
	if runner.running or _login.running:
		return
	if bool(_account_info.get("configured", false)):
		OS.execute(TOOL, ["logout"])
		_refresh()
		return
	var user: String = _user.text.strip_edges()
	var password: String = _password.text
	if user == "" or password == "":
		_notify("Enter your ScreenScraper user name and password first.")
		return
	_account.description = "Checking with ScreenScraper..."
	_login.start(["login", user], password)


func _on_login_finished(code: int, _summary: Dictionary, error: String) -> void:
	_password.text = ""
	_notify("Signed in to ScreenScraper as %s." % _user.text.strip_edges() if code == 0 else ScrapeRunner.failure_text(code, error))
	_refresh()


func _notify(text: String) -> void:
	notification_manager.show(Notification.new(text))
