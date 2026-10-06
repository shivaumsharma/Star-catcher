extends RefCounted
## Stand-ins for the godot-x Firebase plugin singletons: same method and signal names,
## plus a shared call log so tests can assert ordering.

class FakeCore extends RefCounted:
	signal core_initialized(success: bool)

	var log: Array[String]
	var succeed := true

	func _init(call_log: Array[String]) -> void:
		log = call_log

	func initialize() -> void:
		log.append("core.initialize")
		core_initialized.emit(succeed)


class FakeAnalytics extends RefCounted:
	signal analytics_initialized(success: bool)
	signal analytics_error(message: String)

	var log: Array[String]
	## false = the test finishes initialisation itself via analytics_initialized.emit(true).
	var auto_complete := true
	var events: Array[Dictionary] = []
	var consent_calls: Array[Dictionary] = []
	var collection_enabled: Variant = null

	func _init(call_log: Array[String]) -> void:
		log = call_log

	func initialize() -> void:
		log.append("analytics.initialize")
		if auto_complete:
			analytics_initialized.emit(true)

	func log_event(event_name: String, params: Dictionary) -> void:
		log.append("log:" + event_name)
		events.append({"name": event_name, "params": params})

	func set_consent(consent: Dictionary) -> void:
		log.append("set_consent")
		consent_calls.append(consent)

	func set_analytics_collection_enabled(enabled: bool) -> void:
		log.append("collection:%s" % enabled)
		collection_enabled = enabled

	func names() -> Array[String]:
		var result: Array[String] = []
		for e in events:
			result.append(e.name)
		return result
