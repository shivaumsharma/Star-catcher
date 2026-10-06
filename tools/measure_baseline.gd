extends Node
## Measurements quoted in TEARDOWN.md. Two simple bots play the real game.gd:
##   * an IDLE player who never touches the screen
##   * an INSTANT-AIM player who always puts the basket under the next star and away from the
##     next bomb, with no reaction delay and no limit on thumb speed
## Neither is a person. The idle bot is a floor for how fast a round can end; the instant-aim bot
## is a ceiling for how well anyone could play. Real players sit somewhere in between, and where is
## exactly what a playtest is for.
##
##   godot --headless --path star-catcher res://tools/measure_baseline.tscn -- --no-telemetry
const GameScript := preload("res://scripts/game.gd")

const DT := 1.0 / 60.0
const IDLE_SEEDS := 300
const AIM_SEEDS := 40
const AIM_MINUTES := 10
const MARKS := [1, 10, 25, 50, 78, 100]


func _ready() -> void:
	_idle_player()
	_instant_aim_player()
	_difficulty_table()
	_catch_zone()
	get_tree().quit()


func _new_game(seed_value: int) -> Node2D:
	var game: Node2D = GameScript.new()
	add_child(game)
	game.rng.seed = seed_value
	game.start()
	return game


func _idle_player() -> void:
	var round_lengths: Array = []
	var first_life_lost: Array = []
	var scored_at_least_one := 0
	for seed_value in IDLE_SEEDS:
		var game := _new_game(seed_value)
		var lost_at := -1.0
		while game.running:
			game.step(DT)
			if lost_at < 0.0 and game.lives < game.START_LIVES:
				lost_at = game.elapsed
		round_lengths.append(game.elapsed)
		first_life_lost.append(lost_at)
		scored_at_least_one += 1 if game.score >= 1 else 0
		game.free()
	print("IDLE player, %d rounds: a round lasts %s s; first life lost at %s s" % [
		IDLE_SEEDS, _spread(round_lengths), _spread(first_life_lost)])
	print("IDLE player: %d of %d rounds still caught at least one star by luck (basket starts mid-screen)" % [
		scored_at_least_one, IDLE_SEEDS])


func _instant_aim_player() -> void:
	var reached := {}
	for mark in MARKS:
		reached[mark] = []
	var survivors := 0
	var scores: Array = []
	for seed_value in AIM_SEEDS:
		var game := _new_game(1000 + seed_value)
		var next_mark := 0
		while game.running and game.elapsed < AIM_MINUTES * 60.0:
			game.set_target_x(_target(game))
			game.step(DT)
			while next_mark < MARKS.size() and game.score >= MARKS[next_mark]:
				reached[MARKS[next_mark]].append(game.elapsed)
				next_mark += 1
		if game.running:
			survivors += 1
			scores.append(game.score)
		game.free()
	print("INSTANT-AIM player, %d rounds: still alive after %d minutes in %d of %d; score at that point %s" % [
		AIM_SEEDS, AIM_MINUTES, survivors, AIM_SEEDS, _spread(scores)])
	for mark in MARKS:
		print("INSTANT-AIM player reaches score %3d at %s s" % [mark, _spread(reached[mark])])


## Under the next item to arrive if it's a star; clear of it if it's a bomb.
func _target(game: Node2D) -> float:
	var next = null
	for item in game._items:
		if next == null or item.pos.y > next.pos.y:
			next = item
	if next == null:
		return game.basket_x
	if next.kind == game.ItemKind.STAR:
		return next.pos.x
	var reach: float = game.BASKET_SIZE.x / 2.0 + game.ITEM_RADIUS * 0.5 + 6.0
	var away: float = next.pos.x + reach if next.pos.x < game.FIELD.x / 2.0 else next.pos.x - reach
	return clampf(away, 60.0, game.FIELD.x - 60.0)


func _difficulty_table() -> void:
	var game: Node2D = GameScript.new()
	add_child(game)
	for score in [0, 10, 25, 48, 63, 78, 79, 150]:
		game.score = score
		print("score %3d: items fall %.0f px/s, one item every %.2f s, %.0f%% bombs -> %.2f stars/s and %.2f bombs/s" % [
			score, game.fall_speed(), game.spawn_interval(), game.bomb_chance() * 100.0,
			(1.0 - game.bomb_chance()) / game.spawn_interval(), game.bomb_chance() / game.spawn_interval()])
	game.free()


## Does the hit-box match what the player sees? Drops a star at each distance from the basket's centre.
func _catch_zone() -> void:
	var widest := -1
	for distance in range(40, 120):
		var game := _new_game(1)
		game._spawn_timer = INF
		game.spawn_item(game.ItemKind.STAR, game.basket_x + distance, game.BASKET_Y - 5.0)
		game.step(0.001)
		if game.score == 1:
			widest = distance
		game.free()
	var game := _new_game(1)
	var touches: float = game.BASKET_SIZE.x / 2.0 + game.ITEM_RADIUS
	print("CATCH ZONE: a star is caught up to %d px from the basket's centre, but its picture already touches the basket from %.0f px away (basket half-width %.0f + item radius %.0f)" % [
		widest, touches, game.BASKET_SIZE.x / 2.0, game.ITEM_RADIUS])
	game.free()


func _spread(values: Array) -> String:
	if values.is_empty():
		return "n/a"
	var sorted := values.duplicate()
	sorted.sort()
	return "median %.1f (min %.1f, max %.1f)" % [sorted[sorted.size() / 2], sorted[0], sorted[-1]]
