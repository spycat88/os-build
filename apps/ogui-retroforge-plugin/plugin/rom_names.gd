extends RefCounted

## Card names for ROMs, and which of the library's cards a rescan must drop. Plain functions with
## no OGUI types, so tests/test-plugin.sh can run them in a stock headless Godot.
##
## OGUI keys its whole library by item NAME, across every provider: a second launch item with a
## name the library already holds is merged into the first item, and if both come from the same
## library the second one is silently dropped. So every ROM needs a name no other ROM has.


## A name per ROM, in the same order. roms: [{"system": id, "path": file, "dir": bool, "sd": bool}]
## ("dir": a game folder, game_dirs.gd; its whole name is kept and it counts as the "FOLDER" type;
## "sd": on an SD card, rom_roots.gd), system_names: id -> label. A ROM keeps its file name (without
## extension) unless another ROM has the same one: then the system is added when the other ROM is
## from another system ("Tetris (PlayStation)"), " (SD card)" to the card's copy when the other one
## is on internal storage, and the extension when both are from the same system and medium
## ("Tetris (CUE)"). Compared without case, as OGUI keeps per-game settings under the lower-cased
## name. Pass internal ROMs first: a name still taken after all that is numbered, and the later one
## gets the number, so an internal game keeps its name (and its OGUI settings) when a card goes in.
static func names_for(roms: Array, system_names: Dictionary) -> PackedStringArray:
	var bases := PackedStringArray()
	var systems_of := {}  # lower-cased base -> {system: true}
	for rom in roms:
		var base: String = str(rom["path"]).get_file()
		if not rom.get("dir", false):
			base = base.get_basename()
		bases.append(base)
		systems_of.get_or_add(base.to_lower(), {})[rom["system"]] = true

	var names := PackedStringArray()
	for i in roms.size():
		var name := bases[i]
		if systems_of[name.to_lower()].size() > 1:
			var system: String = roms[i]["system"]
			name += " (%s)" % system_names.get(system, system)
		names.append(name)

	var media_of := {}  # lower-cased name -> {sd: true}
	for i in names.size():
		media_of.get_or_add(names[i].to_lower(), {})[roms[i].get("sd", false)] = true
	for i in names.size():
		if roms[i].get("sd", false) and media_of[names[i].to_lower()].size() > 1:
			names[i] += " (SD card)"

	var count := {}
	for name in names:
		count[name.to_lower()] = count.get(name.to_lower(), 0) + 1
	for i in names.size():
		if count[names[i].to_lower()] > 1:
			var kind := "FOLDER" if roms[i].get("dir", false) else str(roms[i]["path"]).get_extension().to_upper()
			names[i] += " (%s)" % kind

	# Still taken (A.chd and a.chd, or a file really named "Tetris (CUE)"): number the later ones.
	var taken := {}
	for i in names.size():
		var name := names[i]
		var n := 2
		while name.to_lower() in taken:
			name = "%s (%d)" % [names[i], n]
			n += 1
		taken[name.to_lower()] = true
		names[i] = name
	return names


## Names of the cards to remove before a rescan's items are added. current / wanted: name -> ROM
## path, as the library holds them now and as the rescan found them. A card goes when its ROM is
## gone, or when its name now belongs to another file (OGUI would keep the old launch item).
static func stale(current: Dictionary, wanted: Dictionary) -> PackedStringArray:
	var result := PackedStringArray()
	for name in current:
		if wanted.get(name, "") != current[name]:
			result.append(name)
	return result
