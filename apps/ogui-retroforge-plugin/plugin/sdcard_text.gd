extends RefCounted
## What Settings > Disks > SD card shows (sdcard_settings.gd), from retroforge-sdcard-info's answer.
## No OGUI types: tested on a stock Godot (tests/test-plugin.sh).


## retroforge-sdcard-info's key=value lines. A value may hold `=`.
static func parse_info(stdout: String) -> Dictionary:
	var info := {}
	for line in stdout.split("\n", false):
		var at := line.find("=")
		if at > 0:
			info[line.left(at)] = line.substr(at + 1)
	return info


## "RETROFORGE, /dev/mmcblk0": the label when it has one, and the device.
static func describe_card(info: Dictionary) -> String:
	var label: String = info.get("label", "")
	var disk: String = info.get("disk", "")
	return disk if label == "" else "%s, %s" % [label, disk]


## Bytes for a person: "59.5 GB", "512 MB" (powers of 1024, one decimal under 100); "Unknown" for nothing.
static func size_text(bytes: String) -> String:
	return human(int(bytes)) if bytes.is_valid_int() and int(bytes) > 0 else "Unknown"


static func human(n: int) -> String:
	var units := ["B", "KB", "MB", "GB", "TB"]
	var value := float(n)
	var i := 0
	while value >= 1024.0 and i < units.size() - 1:
		value /= 1024.0
		i += 1
	if i == 0 or value >= 100.0:
		return "%d %s" % [int(round(value)), units[i]]
	return "%.1f %s" % [value, units[i]]


static func fstype_text(fstype: String) -> String:
	match fstype:
		"exfat":
			return "exFAT"
		"vfat":
			return "FAT32"
		"ext4":
			return "ext4"
		"":
			return "None (not formatted)"
	return fstype


## "1.2 GB used, 58.2 GB free".
static func usage_text(info: Dictionary) -> String:
	var used: String = info.get("fsused", "")
	var avail: String = info.get("fsavail", "")
	if not used.is_valid_int() or not avail.is_valid_int():
		return "Unknown"
	return "%s used, %s free" % [human(int(used)), human(int(avail))]
