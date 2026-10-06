extends Node
## Local playtest log (autoloaded as `Telemetry`).
##
## Appends one JSON object per line to a file on the player's own device. Nothing is sent
## anywhere by this script: the menu's "Share playtest log" button copies the file's text to
## the clipboard so a tester can paste it to whoever runs the playtest.
##
## It deliberately ignores the Firebase consent choice. It is the only way to see what players
## do on the consent screen itself, and playtesters are told about it on that screen and in the
## README. For a build that isn't a playtest, set `enabled = false`.
##
## One line looks like:
##   {"e":"round_end","i":"3fa9c1d2","p":{"score":12,...},"s":2,"t":1767607412.512}
## t = unix seconds, i = install id (random, generated on first launch), s = session number
## for that install (counts app launches), e = event name, p = event parameters.

## Run the game with `-- --no-telemetry` (the test suite does) to keep a dev machine's own
## log clean.
const OFF_FLAG := "--no-telemetry"

var enabled := true
var path := "user://playtest_log.jsonl"
var meta_path := "user://playtest_meta.cfg"
## Replaced by tests and the playtest simulator so timestamps are deterministic.
var clock: Callable = func() -> float: return Time.get_unix_time_from_system()

var install_id := ""
var round_number := 0
var _sessions := 0


func _ready() -> void:
	if OFF_FLAG in OS.get_cmdline_user_args():
		enabled = false
		return
	start_session()


## One call per app launch. `_ready` does it; tests and the simulator call it to fake a relaunch.
func start_session() -> void:
	var meta := ConfigFile.new()
	meta.load(meta_path)  # a missing file just leaves the defaults below
	install_id = str(meta.get_value("install", "id", ""))
	_sessions = int(meta.get_value("install", "sessions", 0))
	round_number = int(meta.get_value("install", "rounds_started", 0))
	var first_launch := _sessions == 0
	if install_id == "":
		install_id = Crypto.new().generate_random_bytes(4).hex_encode()
	_sessions += 1
	_save_meta()
	event("app_open", {"first_launch": int(first_launch)})


## Call when a round starts; returns this install's lifetime round number (1 = first ever).
func next_round() -> int:
	round_number += 1
	_save_meta()
	return round_number


## Parameter values should be int, float or String so the log stays plain JSON.
func event(event_name: String, params: Dictionary = {}) -> void:
	if not enabled:
		return
	var line := JSON.stringify({
		"t": snappedf(clock.call(), 0.001),
		"i": install_id,
		"s": _sessions,
		"e": event_name,
		"p": params,
	}, "", true, true)  # sorted keys, full float precision
	var file := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if file == null:
		push_warning("[Telemetry] cannot write %s (error %d)" % [path, FileAccess.get_open_error()])
		return
	file.seek_end()
	file.store_line(line)


## The whole log as text (empty if nothing has been logged).
func export_text() -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func event_count() -> int:
	var text := export_text().strip_edges()
	return 0 if text == "" else text.count("\n") + 1


func _save_meta() -> void:
	var meta := ConfigFile.new()
	meta.set_value("install", "id", install_id)
	meta.set_value("install", "sessions", _sessions)
	meta.set_value("install", "rounds_started", round_number)
	meta.save(meta_path)
