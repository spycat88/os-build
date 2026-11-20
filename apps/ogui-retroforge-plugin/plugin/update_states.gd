extends RefCounted
## What Settings > General > Updates shows (retroforge_os.gd), from retroforge-update's answers.
##
## One button walks Steam's steps: Check for updates -> Install <version> -> Restart now. Nothing
## installs or restarts on its own (plan ota-ui D2). No OGUI types: tested on a stock Godot
## (tests/test-plugin.sh).

enum Step { IDLE, CHECKING, AVAILABLE, INSTALLING, STAGED }

## The channels' names as the player reads them; any other (a dev card's pin) shows as it is.
const CHANNEL_NAMES := {"stable": "Stable", "beta": "Beta", "nightly": "Nightly"}
## What the channel dropdown says when `channels` fails: the hosted list could not be fetched.
## retroforge_os.gd fetches it again on the next visit to the page, which the text asks for.
const CHANNELS_UNAVAILABLE := "Could not load the update channels. Check your internet connection and open this page again."
## What the update button says when `check` exits 8: the channel list, which every check needs,
## could not be fetched, so nothing was checked and "No update found" would be untrue.
const CHECK_NO_CHANNELS := "Could not check for updates: the update channels could not be loaded. Check your internet connection and try again."


## `retroforge-update channels`: the offered channels, then `pinned<TAB><source>` when /etc or the
## environment decides the channel. A channel line is `name` or `name<TAB>label<TAB>description`,
## the last two from the hosted channel list, so a channel added there brings its own words.
## {"channels": [...], "pinned": "<source>" or "", "labels": {name: label}, "descriptions": {name: text}}.
static func parse_channels(stdout: String) -> Dictionary:
	var channels: Array[String] = []
	var pinned := ""
	var labels := {}
	var descriptions := {}
	for line in stdout.split("\n", false):
		var text := line.strip_edges()
		if text.begins_with("pinned\t"):
			pinned = text.get_slice("\t", 1)
		elif text != "":
			var name := text.get_slice("\t", 0)
			channels.append(name)
			if text.get_slice_count("\t") > 1 and text.get_slice("\t", 1) != "":
				labels[name] = text.get_slice("\t", 1)
			if text.get_slice_count("\t") > 2 and text.get_slice("\t", 2) != "":
				descriptions[name] = text.get_slice("\t", 2)
	return {"channels": channels, "pinned": pinned, "labels": labels, "descriptions": descriptions}


## `retroforge-update channel`: "<channel><TAB><source>" -> the channel ("" when unreadable).
static func parse_channel(stdout: String) -> String:
	return stdout.strip_edges().get_slice("\t", 0)


## `labels` is parse_channels()'s: a label from the hosted list wins over the built-in names.
static func channel_name(channel: String, labels := {}) -> String:
	return labels.get(channel, CHANNEL_NAMES.get(channel, channel))


## The button for a step: {"button": text, "description": text, "disabled": bool}. `running` is
## the version this image runs, `offered` the one check found (or staged), `percent` the install's.
static func button_for(step: Step, running: String, offered := "", percent := 0) -> Dictionary:
	match step:
		Step.CHECKING:
			return {"button": "Checking...", "description": "Looking for a newer RetroForge.", "disabled": true}
		Step.AVAILABLE:
			return {"button": "Install", "description": "RetroForge %s is available (you have %s)." % [offered, running], "disabled": false}
		Step.INSTALLING:
			return {"button": "Installing...", "description": "Installing RetroForge %s: %d%%. You can keep playing." % [offered, percent], "disabled": true}
		Step.STAGED:
			return {"button": "Restart now", "description": "RetroForge %s is installed. Restart to use it." % offered, "disabled": false}
	return {"button": "Check for updates", "description": "RetroForge %s." % running if running != "" else "", "disabled": false}


## What the channel dropdown says under its title.
## What the channel dropdown says under it: who pinned it, else what the channel in effect means.
## Nightly is built from every day's changes and installed on no device first (plan nightly-channel
## D5/D6), so it says so while it is the one selected.
## `descriptions` is parse_channels()'s: the hosted list's text for the current channel wins.
static func channel_description(pinned: String, current := "", descriptions := {}) -> String:
	if pinned != "":
		return "Set by %s on this device." % pinned
	if descriptions.has(current):
		return descriptions[current]
	if current == "nightly":
		return "Nightly: daily untested builds of the newest changes. You can switch back to Stable at any time."
	return "Beta gets new versions first. You can switch back to Stable at any time."


## Whether the periodic background check may run now: nothing else is going on in the section, and
## no game runs (a check is a network fetch; a notification would land over the game).
static func background_check_wanted(step: Step, in_game: bool) -> bool:
	return step == Step.IDLE and not in_game


## The notification a background check posts when it finds an update.
static func available_text(version: String) -> String:
	return "RetroForge %s is available: Settings > General > Updates" % version
