extends Node
## Firebase Analytics facade (autoloaded as `Analytics`).
##
## The rest of the game only calls `Analytics.log_event()` / `Analytics.screen_view()`.
## On Android with the godot-x Firebase plugin (https://github.com/godot-x/firebase)
## those go to Firebase; everywhere else (editor, desktop, tests) no plugin exists and
## events are only printed.
##
## Two rules from the plugin shape this file:
##  * Firebase Core must be initialised before Analytics, and the plugin drops
##    log_event() calls until Analytics reports ready, so early events are queued.
##  * With the export option "Privacy-safe defaults" collection is off until we switch
##    it on, so nothing is sent (or queued) until the player has consented.

## Emitted whenever an event is handed to Firebase (or printed when there is no plugin).
signal event_logged(event_name: String, params: Dictionary)

const MAX_QUEUED := 50

var firebase_ready := false

var _core: Object
var _firebase: Object
var _queue: Array[Dictionary] = []
var _warned_queue_full := false


func _ready() -> void:
	if Engine.has_singleton("GodotxFirebaseCore") and Engine.has_singleton("GodotxFirebaseAnalytics"):
		attach_firebase(
			Engine.get_singleton("GodotxFirebaseCore"),
			Engine.get_singleton("GodotxFirebaseAnalytics"))
	else:
		print("[Analytics] Firebase plugin not found - events will only be printed")


func has_consent() -> bool:
	return Save.consent == Save.CONSENT_GRANTED


## Wires up the plugin singletons and starts initialisation. Public so tests can pass fakes.
func attach_firebase(core: Object, firebase: Object) -> void:
	_core = core
	_firebase = firebase
	firebase_ready = false
	_core.core_initialized.connect(_on_core_initialized)
	_firebase.analytics_initialized.connect(_on_analytics_initialized)
	_firebase.analytics_error.connect(_on_analytics_error)
	_core.initialize()


## Records the player's choice, persists it and applies it to Firebase.
func set_consent(granted: bool) -> void:
	Save.consent = Save.CONSENT_GRANTED if granted else Save.CONSENT_DENIED
	Save.save_data()
	if not granted:
		_queue.clear()
	_apply_consent()
	_flush()


## Parameter values must be int, float, bool or String (the plugin ignores anything else).
func log_event(event_name: String, params: Dictionary = {}) -> void:
	if not has_consent():
		return
	if _firebase == null or firebase_ready:
		_send(event_name, params)
	elif _queue.size() < MAX_QUEUED:
		_queue.append({"name": event_name, "params": params})
	elif not _warned_queue_full:
		_warned_queue_full = true
		push_warning("[Analytics] Firebase still not ready after %d events - dropping the rest" % MAX_QUEUED)


## Firebase doesn't track screens inside a single-activity game on its own.
func screen_view(screen_name: String) -> void:
	log_event("screen_view", {"screen_name": screen_name, "screen_class": "Main"})


func _on_core_initialized(success: bool) -> void:
	if success:
		_firebase.initialize()
	else:
		push_warning("[Analytics] Firebase Core failed to initialise - analytics disabled")


func _on_analytics_initialized(success: bool) -> void:
	if not success:
		push_warning("[Analytics] Firebase Analytics failed to initialise")
		return
	firebase_ready = true
	_apply_consent()
	_flush()


func _on_analytics_error(message: String) -> void:
	push_warning("[Analytics] %s" % message)


## Pushes the saved choice into Firebase. "Unknown" is left as the manifest default (denied).
func _apply_consent() -> void:
	if not firebase_ready or Save.consent == Save.CONSENT_UNKNOWN:
		return
	var granted := has_consent()
	var state := "granted" if granted else "denied"
	_firebase.set_consent({
		"analytics_storage": state,
		"ad_storage": state,
		"ad_user_data": state,
		"ad_personalization": state,
	})
	_firebase.set_analytics_collection_enabled(granted)


## The queue only ever holds events logged with consent (set_consent(false) empties it).
func _flush() -> void:
	if _firebase != null and not firebase_ready:
		return
	for queued in _queue:
		_send(queued.name, queued.params)
	_queue.clear()
	_warned_queue_full = false


func _send(event_name: String, params: Dictionary) -> void:
	if _firebase != null:
		_firebase.log_event(event_name, params)
	else:
		print("[Analytics] %s %s" % [event_name, params])
	event_logged.emit(event_name, params)
