extends Library

## RetroForge ROM library: one launch item per ROM under ~/roms/<system>/, and under
## <card>/roms/<system>/ of an SD card while one is in (rom_roots.gd), each started by
## retroforge-launch in the emulator /etc/retroforge/launch.conf maps the system to.

const LAUNCHER := "/usr/bin/retroforge-launch"

# Relative to this script, so it resolves under res://plugins/retroforge/ once the zip is loaded.
const RomNames := preload("rom_names.gd")
const LaunchArgs := preload("launch_args.gd")
const GameDirs := preload("game_dirs.gd")
const RomRoots := preload("rom_roots.gd")

## Systems the image can launch, in tab order (by maker, then by age). Tab label, and the file
## extensions that are a game. An .m3u playlist wins over the disc images it lists, so a multi-disc
## game is one card. "dirs": the files that make a subfolder a game (game_dirs.gd): a PS3 disc dump
## is a folder, and the folder is what RPCS3 boots. Ports are PortMaster's: each port it installs is
## a launch script, <Name>.sh, in ~/roms/ports (PortMaster's own folder sits beside them; its
## PortMaster.sh is one level down, so it is never a card).
const SYSTEMS := {
	"gb": {"name": "Game Boy", "exts": ["gb", "zip", "7z"]},
	"gbc": {"name": "Game Boy Color", "exts": ["gbc", "gb", "zip", "7z"]},
	"gba": {"name": "Game Boy Advance", "exts": ["gba", "zip", "7z"]},
	"snes": {"name": "Super Nintendo", "exts": ["sfc", "smc", "zip"]},
	"n64": {"name": "Nintendo 64", "exts": ["z64", "n64", "v64", "zip", "7z"]},
	"nds": {"name": "Nintendo DS", "exts": ["nds", "zip", "7z"]},
	"3ds": {"name": "Nintendo 3DS", "exts": ["3ds", "cci", "cxi", "3dsx", "zcci", "zcxi", "z3dsx"]},
	"gc": {"name": "GameCube", "exts": ["iso", "gcm", "gcz", "rvz", "ciso", "wia"]},
	"wii": {"name": "Wii", "exts": ["iso", "wbfs", "rvz", "gcz", "ciso", "wia"]},
	"wiiu": {"name": "Wii U", "exts": ["wua", "wud", "wux", "rpx"]},
	"psx": {"name": "PlayStation", "exts": ["chd", "cue", "pbp", "m3u", "iso"]},
	"ps2": {"name": "PlayStation 2", "exts": ["chd", "iso", "cso", "zso", "gz", "cue"]},
	"psp": {"name": "PSP", "exts": ["iso", "cso", "chd", "pbp"]},
	"ps3": {"name": "PlayStation 3", "exts": ["iso", "psn"], "dirs": ["PS3_GAME/USRDIR/EBOOT.BIN", "USRDIR/EBOOT.BIN"]},
	"md": {"name": "Mega Drive", "exts": ["md", "gen", "bin", "zip"]},
	"segacd": {"name": "Mega CD", "exts": ["chd", "cue"]},
	"dc": {"name": "Dreamcast", "exts": ["chd", "gdi", "cdi", "cue"]},
	"xbox": {"name": "Xbox", "exts": ["iso", "xiso", "chd"]},
	"ports": {"name": "Ports", "exts": ["sh"]},
}


# Set in _ready, not _init: overriding _init skips Library._init, which is what registers the
# library with the LibraryManager (on ready). Ready handlers run before ready is emitted.
func _ready() -> void:
	library_id = "retroforge-roms"
	store_id = "retroforge"
	supports_uninstall = false
	logger = Log.get_logger("RetroForgeRoms", Log.LEVEL.INFO)


## When a ROM's launch fails because its emulator is not installed (or its AppImage did not
## mount), tell the player. OGUI never sees retroforge-launch's exit code (games run through its
## reaper), so retroforge-launch leaves the reason in a status file this EXIT hook reads. The launch
## itself is never held back: downloads happen in Main menu > Apps, not on a card.
func get_app_lifecycle_hooks() -> Array[AppLifecycleHook]:
	var hooks: Array[AppLifecycleHook] = [LaunchFailure.new()]
	return hooks


## system -> the files that make a subfolder of ~/roms/<system> a game (SYSTEMS "dirs").
func dir_markers() -> Dictionary:
	var markers := {}
	for system in SYSTEMS:
		if SYSTEMS[system].has("dirs"):
			markers[system] = SYSTEMS[system]["dirs"]
	return markers


func roms_dir() -> String:
	return RomRoots.home_roms()


## Where the player's SD cards are mounted (rom_roots.gd).
func sd_mounts_dir() -> String:
	return RomRoots.mounts_dir()


func get_library_launch_items() -> Array[LibraryLaunchItem]:
	var started := Time.get_ticks_msec()
	var roms: Array[Dictionary] = []
	var system_names := {}
	var roots := RomRoots.list(roms_dir(), sd_mounts_dir())
	for system in SYSTEMS:
		system_names[system] = SYSTEMS[system]["name"]
	for root in roots:
		var sd: bool = root["sd"]
		for system in SYSTEMS:
			if not RomRoots.reads(root, system):
				continue
			var dir_path := str(root["path"]).path_join(system)
			for path in _scan_system(dir_path, system):
				roms.append({"system": system, "path": path, "sd": sd})
			for path in GameDirs.scan(dir_path, SYSTEMS[system].get("dirs", [])):
				roms.append({"system": system, "path": path, "dir": true, "sd": sd})
	var names := RomNames.names_for(roms, system_names)
	var items: Array[LibraryLaunchItem] = []
	for i in roms.size():
		items.append(_launch_item(names[i], roms[i]["system"], roms[i]["path"], roms[i]["sd"]))
	_drop_stale(items)
	var on_card := roms.filter(func(r): return r["sd"]).size()
	logger.info("Found %d ROM(s), %d on SD card (%d card root(s)), in %d ms" % [items.size(), on_card, roots.size() - 1, Time.get_ticks_msec() - started])
	return items


## OGUI's load_library only ever adds: remove our cards whose ROM is gone, or whose name now
## stands for another file, before LibraryManager adds this scan's items (deferred).
func _drop_stale(items: Array[LibraryLaunchItem]) -> void:
	var wanted := {}
	for item in items:
		wanted[item.name] = item.metadata["rom"]
	var current := {}
	for app in library_manager.get_library_items([]):
		var launch := app.get_launch_item(library_id)
		if launch:
			current[app.name] = launch.metadata.get("rom", "")
	for name in RomNames.stale(current, wanted):
		logger.info("ROM gone or renamed: " + name)
		library_manager.remove_library_launch_item(library_id, name)


## ROM files of one system folder, one level deep, minus the members of any .m3u playlist.
func _scan_system(dir_path: String, system: String) -> PackedStringArray:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return PackedStringArray()
	var exts: Array = SYSTEMS[system]["exts"]
	var roms := PackedStringArray()
	var in_playlist := {}
	for file in dir.get_files():
		var ext := file.get_extension().to_lower()
		if not ext in exts:
			continue
		roms.append(dir_path.path_join(file))
		if ext == "m3u":
			for member in _m3u_members(dir_path.path_join(file)):
				in_playlist[member] = true
	var result := PackedStringArray()
	for rom in roms:
		if not rom.get_file() in in_playlist:
			result.append(rom)
	return result


## File names an .m3u lists (comments and blank lines skipped).
func _m3u_members(path: String) -> PackedStringArray:
	var members := PackedStringArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return members
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			members.append(line.get_file())
	return members


func _launch_item(name: String, system: String, path: String, sd: bool) -> LibraryLaunchItem:
	var item := LibraryLaunchItem.new()
	item.name = name
	item.provider_app_id = LaunchArgs.rom_id(system, path)
	item.command = LAUNCHER
	item.args = LaunchArgs.for_rom(system, path)
	item.tags = PackedStringArray(["retroforge", system])
	item.categories = PackedStringArray(["game"])
	item.installed = true
	item.metadata = {"system": system, "rom": path, "sd": sd}
	return item


## A game's fast-cores override: "" (the emulator's default), "big" or "all".
func get_cpus(item: LibraryLaunchItem) -> String:
	return LaunchArgs.game_cpus(item.metadata["system"], item.metadata["rom"])


## The emulator this game runs in ("" when launch.conf maps its system to none).
func emulator_of(item: LibraryLaunchItem) -> String:
	return LaunchArgs.emulator_for(item.metadata["system"], LaunchArgs.read_text(LaunchArgs.LAUNCH_CONF))


## Whether the emulator this game runs in defaults to the fast cores (Main menu > Apps).
func emulator_fast_cores(item: LibraryLaunchItem) -> bool:
	var emulator := emulator_of(item)
	return emulator != "" and LaunchArgs.emulator_fast_cores(emulator)


## Save a game's override in its conf, which retroforge-launch reads at the next start.
func set_cpus(item: LibraryLaunchItem, cpus: String) -> void:
	if not LaunchArgs.set_game_cpus(item.metadata["system"], item.metadata["rom"], cpus):
		logger.warn("could not write " + LaunchArgs.game_conf_path(item.metadata["system"], item.metadata["rom"]))
		return
	logger.info("%s: fast cores %s" % [item.name, {"big": "on", "all": "off"}.get(cpus, "emulator default")])


class LaunchFailure extends AppLifecycleHook:
	const EMU_TOOL := "/usr/bin/retroforge-emu"
	var logger := Log.get_logger("RetroForgeRoms", Log.LEVEL.INFO)

	func _init() -> void:
		super(AppLifecycleHook.TYPE.EXIT)

	func get_name() -> String:
		return "RetroForgeLaunchFailure"

	## Same default as retroforge-launch: $XDG_RUNTIME_DIR/retroforge-launch.status.
	static func status_path() -> String:
		var run := OS.get_environment("XDG_RUNTIME_DIR")
		return (run if run != "" else "/tmp").path_join("retroforge-launch.status")

	func execute(item: LibraryLaunchItem) -> void:
		var path := status_path()
		if not FileAccess.file_exists(path):
			return
		var words := FileAccess.get_file_as_string(path).strip_edges().split(" ")
		DirAccess.remove_absolute(path)
		if words.size() < 2:
			return
		var name := _emulator_name(words[1])
		var msg: String
		match words[0]:
			"not-installed":
				msg = "%s is not installed.\nDownload it from Apps in the main menu first." % name
			"mount-failed":
				msg = "%s could not be started.\nDelete it and download it again from Apps in the main menu." % name
			"missing-file":
				# retroforge-launch: `missing-file <emulator> <path under the player's home>...`; several
				# paths are choices, one is enough (system_requires "any": the Mega CD BIOS of any region).
				if words.size() < 3:
					return
				var files := PackedStringArray()
				for file_path in words.slice(2):
					files.append(file_path.get_file())
				var what := files[0] if files.size() == 1 else "one of " + ", ".join(files)
				msg = "%s needs %s.\nCopy it to the %s folder (network share), then start the game again." \
						% [name, what, words[2].get_base_dir()]
			"install-failed":
				msg = "%s could not install its firmware or system files.\nCheck the file in the bios folder, then try again." % name
			"bad-stub":
				# retroforge-launch: a .psn card whose file does not hold a game id any more.
				msg = "This game's .psn file in roms/ps3 is damaged.\nPut the game's .pkg in roms/ps3/psn and install it again (Settings > Library)."
			"card-missing":
				# retroforge-launch: the ROM was on an SD card (rom_roots.gd) that is not in now. The
				# card goes from the library by itself once the rescan sees the card gone.
				msg = "This game is on an SD card that is not in the device.\nInsert the card, wait a few seconds, then start the game again."
			"psn-installing":
				# retroforge-launch: the PSN installer holds the one-RPCS3 lock right now.
				msg = "PSN packages are installing.\nWait for the install to finish, then launch the game again."
			_:
				return
		logger.info("%s: %s %s" % [item.name, words[0], words[1]])
		var dialog := Engine.get_main_loop().get_first_node_in_group("dialog") as Dialog
		if not dialog:
			logger.warn("no OGUI dialog to show: " + msg)
			return
		var cancel_was_visible := dialog.cancel_visible
		dialog.cancel_visible = false
		dialog.open(null, msg, "OK")
		await dialog.choice_selected
		# The dialog is shared: put its Cancel button back, but only once it has faded out, or
		# the button reappears on screen while it closes.
		if dialog.visible:
			await dialog.visibility_changed
		dialog.cancel_visible = cancel_was_visible

	## The catalog's display name for an emulator id (retroforge-emu list), or the id itself.
	func _emulator_name(emu_id: String) -> String:
		var output: Array = []
		if OS.execute(EMU_TOOL, ["list"], output) == 0 and not output.is_empty():
			var parsed = JSON.parse_string(str(output[0]))
			if parsed is Dictionary and emu_id in parsed.get("emulators", {}):
				return str(parsed["emulators"][emu_id].get("name", emu_id))
		return emu_id
