extends Node2D
## Star Catcher gameplay: stars and bombs fall, drag the basket to catch stars and dodge
## bombs. Missing a star or catching a bomb costs a life; three lives per round.
##
## Everything is drawn in code, so the project ships no art assets. The simulation lives
## in step() so tests can drive it with a fixed delta.

signal score_changed(score: int)
signal lives_changed(lives: int)
signal life_lost(cause: String)
## Emitted once per round with score, duration, stars_caught, stars_missed and bombs_hit.
signal ended(result: Dictionary)

enum ItemKind { STAR, BOMB }

const FIELD := Vector2(540, 960)
const BASKET_SIZE := Vector2(120, 26)
const BASKET_Y := 860.0
const ITEM_RADIUS := 18.0
const START_LIVES := 3
const BASKET_SPEED := 2400.0
const KEY_SPEED := 650.0
## Longest simulated step; a frame hitch must not let an item tunnel through the basket.
const MAX_STEP := 1.0 / 20.0

var running := false
var score := 0
var lives := START_LIVES
var elapsed := 0.0
var stars_caught := 0
var stars_missed := 0
var bombs_hit := 0
var basket_x := FIELD.x / 2.0
var rng := RandomNumberGenerator.new()

var _items: Array[Item] = []
var _target_x := FIELD.x / 2.0
var _spawn_timer := 0.0
var _backdrop: Array[Vector3] = []  # x, y, radius of the static background stars


class Item:
	var kind: int
	var pos: Vector2

	func _init(item_kind: int, item_pos: Vector2) -> void:
		kind = item_kind
		pos = item_pos


func _ready() -> void:
	rng.randomize()
	for i in 70:
		_backdrop.append(Vector3(rng.randf() * FIELD.x, rng.randf() * FIELD.y, rng.randf_range(0.8, 2.2)))
	queue_redraw()


func start() -> void:
	running = true
	score = 0
	lives = START_LIVES
	elapsed = 0.0
	stars_caught = 0
	stars_missed = 0
	bombs_hit = 0
	basket_x = FIELD.x / 2.0
	_target_x = basket_x
	_spawn_timer = 0.5
	_items.clear()
	score_changed.emit(score)
	lives_changed.emit(lives)
	queue_redraw()


func stop() -> void:
	running = false
	_items.clear()
	queue_redraw()


## Drops an item at the given spot. The spawner and the tests both use this.
func spawn_item(kind: int, x: float, y: float = -ITEM_RADIUS) -> void:
	_items.append(Item.new(kind, Vector2(x, y)))


func item_count() -> int:
	return _items.size()


func fall_speed() -> float:
	return clampf(230.0 + score * 5.0, 230.0, 620.0)


func spawn_interval() -> float:
	return clampf(0.95 - score * 0.012, 0.38, 0.95)


func bomb_chance() -> float:
	return clampf(0.15 + score * 0.004, 0.15, 0.40)


func step(delta: float) -> void:
	if not running:
		return
	delta = minf(delta, MAX_STEP)
	elapsed += delta
	_move_basket(delta)

	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer += spawn_interval()
		var kind := ItemKind.BOMB if rng.randf() < bomb_chance() else ItemKind.STAR
		var margin := ITEM_RADIUS + 8.0
		spawn_item(kind, rng.randf_range(margin, FIELD.x - margin))

	var fall := fall_speed() * delta
	for item in _items.duplicate():
		item.pos.y += fall
		if _is_caught(item):
			_items.erase(item)
			_on_caught(item)
		elif item.pos.y - ITEM_RADIUS > FIELD.y:
			_items.erase(item)
			if item.kind == ItemKind.STAR:
				stars_missed += 1
				_lose_life("missed_star")
		if not running:
			return
	queue_redraw()


func _process(delta: float) -> void:
	step(delta)


func _unhandled_input(event: InputEvent) -> void:
	if not running:
		return
	if event is InputEventScreenTouch or event is InputEventScreenDrag:
		var local := make_input_local(event)
		if event is InputEventScreenDrag or event.pressed:
			_target_x = local.position.x


func _move_basket(delta: float) -> void:
	var keys := Input.get_axis("ui_left", "ui_right")
	if keys != 0.0:
		_target_x += keys * KEY_SPEED * delta
	_target_x = clampf(_target_x, BASKET_SIZE.x / 2.0, FIELD.x - BASKET_SIZE.x / 2.0)
	basket_x = move_toward(basket_x, _target_x, BASKET_SPEED * delta)


## Move the basket the way a touch would. Also used by tests.
func set_target_x(x: float) -> void:
	_target_x = x


func _is_caught(item: Item) -> bool:
	var below_top := item.pos.y + ITEM_RADIUS >= BASKET_Y
	var above_bottom := item.pos.y - ITEM_RADIUS <= BASKET_Y + BASKET_SIZE.y
	var within_width := absf(item.pos.x - basket_x) <= BASKET_SIZE.x / 2.0 + ITEM_RADIUS * 0.5
	return below_top and above_bottom and within_width


func _on_caught(item: Item) -> void:
	if item.kind == ItemKind.STAR:
		stars_caught += 1
		score += 1
		score_changed.emit(score)
	else:
		bombs_hit += 1
		_lose_life("bomb")


func _lose_life(cause: String) -> void:
	lives -= 1
	lives_changed.emit(lives)
	life_lost.emit(cause)
	if lives <= 0:
		running = false
		_items.clear()
		ended.emit({
			"score": score,
			"duration": elapsed,
			"stars_caught": stars_caught,
			"stars_missed": stars_missed,
			"bombs_hit": bombs_hit,
		})
		queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, FIELD), Color("0b1022"))
	draw_rect(Rect2(0, FIELD.y * 0.55, FIELD.x, FIELD.y * 0.45), Color("111a3a"))
	for dot in _backdrop:
		draw_circle(Vector2(dot.x, dot.y), dot.z, Color(1, 1, 1, 0.35))

	for item in _items:
		if item.kind == ItemKind.STAR:
			draw_colored_polygon(_star_points(item.pos, ITEM_RADIUS * 1.15, ITEM_RADIUS * 0.5), Color("ffd34d"))
		else:
			draw_circle(item.pos, ITEM_RADIUS, Color("2b2f45"))
			draw_arc(item.pos, ITEM_RADIUS, 0.0, TAU, 24, Color("ff5470"), 3.0)
			draw_line(item.pos + Vector2(0, -ITEM_RADIUS), item.pos + Vector2(8, -ITEM_RADIUS - 10), Color("ffd34d"), 3.0)

	var half := BASKET_SIZE.x / 2.0
	var top := BASKET_Y
	var basket := PackedVector2Array([
		Vector2(basket_x - half, top),
		Vector2(basket_x + half, top),
		Vector2(basket_x + half - 14.0, top + BASKET_SIZE.y),
		Vector2(basket_x - half + 14.0, top + BASKET_SIZE.y),
	])
	draw_colored_polygon(basket, Color("4dd2ff"))


func _star_points(center: Vector2, outer: float, inner: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	for i in 10:
		var radius := outer if i % 2 == 0 else inner
		var angle := -PI / 2.0 + i * PI / 5.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	return points
