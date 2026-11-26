extends RefCounted

## Automatic ROM rescan: tells the plugin when ~/roms or an SD card's roms folder changed and the
## change has settled. No OGUI types, so tests/test-plugin.sh runs it in a stock headless Godot.
##
## OGUI only reloads its library at start and from Settings > Library > Refresh Library, so ROMs
## copied over SMB stayed invisible. The plugin polls instead (no inotify tools in the image, and
## OGUI has no IPC a systemd .path unit could poke): every poll lists each system folder with
## name, size and mtime. A directory mtime alone is not enough: Godot reports it in whole seconds,
## so a file created in the same second as the last poll went unseen, and an SMB copy can set the
## final size first and fill the file in afterwards (only its mtime moves while it copies).
##
## A rescan is due when the folders differ from what the library last loaded AND two polls in a
## row agree, so a copy in progress (a file still growing or still being written) waits for the
## copy to end, and a half-written .m3u is never read.
##
## Game FOLDERS (game_dirs.gd: PS3 disc dumps) count by their marker file: a folder copied over SMB
## shows up once the file that makes it a game is there and has stopped changing. The rest of the
## folder is not walked (thousands of files, every 5 s), so a game whose marker arrives before its
## other files may be listed while the copy still runs.
##
## SD cards (rom_roots.gd) are part of every snapshot, so a card inserted or pulled out is a change
## like any other: its ROMs appear or vanish together, two polls agree, and the library reloads
## (hot swap, 5-10 s after the card mounts or goes). Each line names its root, so the same file
## moving between the card and ~/roms is a change too.

const GameDirs := preload("game_dirs.gd")
const RomRoots := preload("rom_roots.gd")

var roms_dir: String
var mounts_dir: String  # where the player's SD cards are mounted ("" = none)
var systems: Array
var dir_markers: Dictionary  # system -> marker files of its game folders (game_dirs.gd)

var _loaded = null  # snapshot the library last loaded from (null: not loaded yet)
var _previous = null  # snapshot of the last poll
var _due = null  # snapshot a due poll reported: what our own reload is about to read


## No _init: tests/test-plugin.sh forbids it in plugin scripts. Returns self: RomWatch.new().setup(..).
func setup(roms_path: String, system_ids: Array, game_dir_markers: Dictionary = {}, sd_mounts: String = "") -> RefCounted:
	roms_dir = roms_path
	mounts_dir = sd_mounts
	systems = system_ids
	dir_markers = game_dir_markers
	return self


## Every file of each system folder of every root, one level deep, as "root/system/name size
## mtime", plus each game folder as "root/system/name/ size mtime" of its marker file, sorted.
func snapshot() -> PackedStringArray:
	var lines := PackedStringArray()
	for root in RomRoots.list(roms_dir, mounts_dir):
		for system in systems:
			if not RomRoots.reads(root, system):
				continue
			var dir_path: String = str(root["path"]).path_join(system)
			var dir := DirAccess.open(dir_path)
			if not dir:
				continue
			for file in dir.get_files():
				var path := dir_path.path_join(file)
				lines.append("%s %d %d" % [path, FileAccess.get_size(path), FileAccess.get_modified_time(path)])
			var markers: Array = dir_markers.get(system, [])
			if markers.is_empty():
				continue
			for sub in dir.get_directories():
				var found := GameDirs.marker(dir_path.path_join(sub), markers)
				if found != "":
					lines.append("%s/ %d %d" % [dir_path.path_join(sub), FileAccess.get_size(found), FileAccess.get_modified_time(found)])
	lines.sort()
	return lines


## The library has just been (re)loaded. After our own reload, the baseline is the snapshot the
## due poll took right before the scan, not what is on disk now: a ROM copied between the scan and
## library_loaded (a frame later) would otherwise count as loaded without ever being scanned. A
## load OGUI started (start, Refresh Library) has no such snapshot: take one now.
func mark_loaded() -> void:
	_loaded = _due if _due != null else snapshot()
	_previous = _loaded
	_due = null


## One poll. True when the plugin should reload the ROM library now; it then calls mark_loaded()
## once the load is done. Call it with busy = true while a game runs: nothing is read and the
## rescan waits until the game has exited.
func poll(busy: bool) -> bool:
	if busy or _loaded == null:
		_previous = null
		return false
	var now := snapshot()
	var settled: bool = now == _previous
	_previous = now
	if settled and now != _loaded:
		_due = now
		return true
	return false
