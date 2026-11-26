extends RefCounted

## Where ROMs are: ~/roms always, plus the roms folder of an SD card. No OGUI types, so
## tests/test-plugin.sh runs it in a stock headless Godot.
##
## A card counts when udisks mounted it for the player (usr/lib/retroforge/storage/automount.sh:
## /run/media/<player>/<label or uuid>) and it holds a `roms` folder at its root, laid out like
## ~/roms: roms/<system>/<game>. A card without one is left alone (it may be a card for something
## else entirely). The automounter refuses the disk RetroForge runs from, so a card only ever shows
## up here on an internal install, where the slot is free: no "am I on internal storage" test needed.
##
## Read every time, never cached: a card comes and goes (hot swap), and the rescan (rom_watch.gd)
## notices it by the ROMs that appear or vanish with it. retroforge-scrape has the same rule
## (rom_roots there); keep the two in step.

## The folder on a card that holds its systems.
const CARD_ROMS := "roms"
## Systems never read from a card. Ports: a PortMaster port's launch script finds PortMaster and its
## own files through /roms/ports (the image's symlink to ~/roms/ports), so a port on a card would
## start the internal copy or nothing.
const CARD_SKIP := ["ports"]


## ~/roms.
static func home_roms() -> String:
	return OS.get_environment("HOME").path_join("roms")


## Where udisks mounts the player's cards. RETROFORGE_SD_MOUNTS overrides it (tests).
static func mounts_dir() -> String:
	var dir := OS.get_environment("RETROFORGE_SD_MOUNTS")
	if dir != "":
		return dir
	var user := OS.get_environment("USER")
	if user == "":
		user = OS.get_environment("HOME").get_file()
	return "/run/media".path_join(user)


## Every ROM root, internal first: [{"path": ".../roms", "sd": bool}]. Cards sorted by mount name,
## hidden mounts skipped. mounts "" lists none.
static func list(home: String, mounts: String) -> Array:
	var roots := [{"path": home, "sd": false}]
	if mounts == "" or not DirAccess.dir_exists_absolute(mounts):
		return roots
	var names := Array(DirAccess.get_directories_at(mounts))
	names.sort()
	for name in names:
		if str(name).begins_with("."):
			continue
		var path := mounts.path_join(name).path_join(CARD_ROMS)
		if DirAccess.dir_exists_absolute(path):
			roots.append({"path": path, "sd": true})
	return roots


## The roots of this device as it is now.
static func current() -> Array:
	return list(home_roms(), mounts_dir())


## Whether a system's folder under this root holds games.
static func reads(root: Dictionary, system: String) -> bool:
	return not (root.get("sd", false) and system in CARD_SKIP)

