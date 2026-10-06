extends Node
## Generates SAMPLE playtest logs: bots play the real game scene, so every line goes through
## the real logging code, but nothing here comes from a real person.
##
##   godot --headless --path star-catcher res://tools/simulate_playtest.tscn -- \
##       --no-telemetry --out=/absolute/path/simulated_playtest.jsonl
##
## Everything between the ASSUMPTIONS markers is invented to produce plausible variety. Any
## number the report prints from this data describes these assumptions, not players. Round
## outcomes (score, length, lives lost) do come from the real game rules, but "skill" below is a
## guess about how a person plays, not a measurement.
const FakeFirebase := preload("res://tests/fake_firebase.gd")
const MainScene := preload("res://scenes/main.tscn")

const DT := 1.0 / 60.0
const DAY := 86400.0

# --- ASSUMPTIONS ----------------------------------------------------------------------------
const PLAYERS := 30
const SEED := 7
const START := 1767607200.0  # 2026-01-05 10:00 UTC, a fictional start date
const INSTALL_SPREAD_DAYS := 7.0
const P_QUIT_AT_CONSENT := 0.08  # leaves without answering
const P_DECLINE := 0.15  # of those who answer
const P_CONFUSED := 0.30  # don't touch the screen for the first CONFUSED_IDLE_S of their first round
const CONFUSED_IDLE_S := 6.0
# skill: reaction delay (s), thumb speed (px/s), aiming error (px)
const SKILLS := [
	{"share": 0.40, "reaction": 0.45, "thumb": 450.0, "noise": 45.0},
	{"share": 0.40, "reaction": 0.28, "thumb": 800.0, "noise": 25.0},
	{"share": 0.20, "reaction": 0.15, "thumb": 1400.0, "noise": 10.0},
]
const P_REPLAY := 0.65  # after a round; +0.15 after a new best, -0.30 after a zero score
const MAX_ROUNDS_PER_SESSION := 12
const MAX_ROUND_SECONDS := 120.0  # then the player puts the phone down mid-round
const P_INTERRUPTED := 0.05  # per round: a call or message ends the session 3-30 s in
# chance of opening the app on each of these days after install (x0.3 if they never scored)
const RETURN_DAYS := {1: 0.35, 3: 0.20, 7: 0.15, 14: 0.08, 30: 0.04}
# --- END ASSUMPTIONS ------------------------------------------------------------------------

var _rng := RandomNumberGenerator.new()
var _now := 0.0
var _aim := 0.0
var _thumb := 0.0


func _ready() -> void:
	var out := "user://simulated_playtest.jsonl"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	_rng.seed = SEED

	var log: Array[String] = []
	Analytics.attach_firebase(FakeFirebase.FakeCore.new(log), FakeFirebase.FakeAnalytics.new(log))
	DirAccess.remove_absolute(out)
	Telemetry.enabled = true
	Telemetry.path = out
	Telemetry.meta_path = "user://sim_meta.cfg"
	Telemetry.clock = func() -> float: return _now
	Save.path = "user://sim_save.cfg"

	for n in PLAYERS:
		_simulate_player(n + 1)

	for f in [Telemetry.meta_path, Save.path]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	print("simulated %d players -> %s (%d lines)" % [PLAYERS, out, Telemetry.event_count()])
	get_tree().quit()


func _simulate_player(n: int) -> void:
	# a fresh "phone": no save file, and a log id marked as simulated
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Save.path))
	Save.load_data()
	var meta := ConfigFile.new()
	meta.set_value("install", "id", "sim-%03d" % n)
	meta.save(Telemetry.meta_path)

	var skill := _pick_skill()
	var confused := _rng.randf() < P_CONFUSED
	var install_time := START + _rng.randf() * INSTALL_SPREAD_DAYS * DAY

	_now = install_time
	_play_session(skill, confused)

	var engaged := 1.0 if Save.best_score > 0 else 0.3
	for day in RETURN_DAYS:
		if _rng.randf() < RETURN_DAYS[day] * engaged:
			_now = install_time + day * DAY + _rng.randf() * 8.0 * 3600.0
			_play_session(skill, false)


func _pick_skill() -> Dictionary:
	var roll := _rng.randf()
	var cumulative := 0.0
	for skill in SKILLS:
		cumulative += skill.share
		if roll < cumulative:
			return skill
	return SKILLS[-1]


func _play_session(skill: Dictionary, confused: bool) -> void:
	Telemetry.start_session()
	var main: Node = MainScene.instantiate()
	add_child(main)
	var game: Node2D = main.get_node("Game")
	var last_round := {}
	game.ended.connect(func(result: Dictionary) -> void: last_round.merge(result, true))

	if Save.consent == Save.CONSENT_UNKNOWN:
		_now += _rng.randf_range(2.0, 9.0)  # reading the consent screen
		if _rng.randf() < P_QUIT_AT_CONSENT:
			_end_session(main)
			return
		var answer := "%DeclineButton" if _rng.randf() < P_DECLINE else "%AllowButton"
		main.get_node(answer).pressed.emit()
	_now += _rng.randf_range(0.8, 3.0)  # looking at the menu

	var button := "%PlayButton"
	for round_index in MAX_ROUNDS_PER_SESSION:
		var best_before := Save.best_score
		main.get_node(button).pressed.emit()
		var idle := CONFUSED_IDLE_S if confused and Telemetry.round_number == 1 else 0.0
		if not _play_round(game, skill, idle):
			_end_session(main)  # put the phone down mid-round
			return
		_now += _rng.randf_range(2.0, 6.0)  # looking at the game-over screen
		var chance := P_REPLAY
		chance += 0.15 if last_round.score > best_before else 0.0
		chance -= 0.30 if last_round.score == 0 else 0.0
		if _rng.randf() >= chance:
			break
		button = "%PlayAgainButton"
	_end_session(main)


func _end_session(main: Node) -> void:
	main.notification(NOTIFICATION_APPLICATION_PAUSED)
	main.free()


## Plays one round. Returns false if the player gave up before it ended.
func _play_round(game: Node2D, skill: Dictionary, idle_seconds: float) -> bool:
	game.rng.seed = _rng.randi()
	_thumb = game.basket_x
	_aim = game.basket_x
	var pending: Array = []  # [apply_at, target]: what the player decided, not yet acted on
	var next_look := 0.0
	var t := 0.0
	var give_up_at := MAX_ROUND_SECONDS
	if _rng.randf() < P_INTERRUPTED:
		give_up_at = _rng.randf_range(3.0, 30.0)
	while game.running:
		if t >= give_up_at:
			return false
		if t >= idle_seconds:
			if t >= next_look:
				pending.append([t + skill.reaction, _decide(game, skill)])
				next_look = t + 0.1
			while pending.size() > 0 and pending[0][0] <= t:
				_aim = pending.pop_front()[1]
		_thumb = move_toward(_thumb, _aim, skill.thumb * DT)
		game.set_target_x(_thumb)
		game.step(DT)
		t += DT
		_now += DT
	return true


## Where the player wants the basket: under the next star, or away from the next bomb.
func _decide(game: Node2D, skill: Dictionary) -> float:
	var next = null
	for item in game._items:
		if item.pos.y <= game.BASKET_Y + 10.0 and (next == null or item.pos.y > next.pos.y):
			next = item
	if next == null:
		return _aim
	var target: float = next.pos.x
	if next.kind == game.ItemKind.BOMB:
		var reach: float = game.BASKET_SIZE.x / 2.0 + game.ITEM_RADIUS * 0.5 + 6.0
		target = next.pos.x + reach if next.pos.x < game.FIELD.x / 2.0 else next.pos.x - reach
	return clampf(target + _rng.randfn(0.0, skill.noise), 60.0, game.FIELD.x - 60.0)
