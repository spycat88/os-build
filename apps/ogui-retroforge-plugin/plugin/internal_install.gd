extends RefCounted
## What Settings > General > Internal storage shows (retroforge_os.gd), from release-info's answer.
##
## The row asks what would be installed BEFORE it offers to leave the session: once the installer
## has taken over there is no Wi-Fi screen to go back to. No OGUI types: tested on a stock Godot
## (tests/test-plugin.sh).


## release-info's key=value lines. A value may hold `=`.
static func parse_release(stdout: String) -> Dictionary:
	var release := {}
	for line in stdout.split("\n", false):
		var at := line.find("=")
		if at > 0:
			release[line.left(at)] = line.substr(at + 1)
	return release


static func can_install(release: Dictionary) -> bool:
	return release.get("STATE", "") == "ok"


## The dialog. It only agrees to leave the session: the installer shows the real disk and figures
## and takes the real consent.
static func confirmation(release: Dictionary) -> String:
	# A dev image installs itself (release-info's SOURCE=running), so say so: "dev" alone would not
	# tell two dev builds apart, and the build stamp does.
	if release.get("SOURCE", "") == "running":
		var build: String = release.get("BUILD", "")
		return ("Install this running RetroForge %s image%s on internal storage?\n" % [
				release.get("VERSION", ""), (" (build %s)" % build) if build != "" else ""]
			+ "This closes RetroForge and starts the installer. Nothing is erased until you confirm there.")
	return ("Install RetroForge %s on internal storage?\n" % release.get("VERSION", "")
		+ "This closes RetroForge and starts the installer. Nothing is erased until you confirm there.")


static func refusal(release: Dictionary) -> String:
	match release.get("STATE", ""):
		"no-release":
			return "There is nothing to install yet: the %s channel has no release." % release.get("CHANNEL", "")
		"unreachable":
			return "Could not reach the update server. Check your Wi-Fi connection."
	return "Could not find out what to install. Try again in a moment."
