extends Node
## Tiny persistent store (autoloaded as `Save`): best score, achievements already
## unlocked, and the player's analytics-consent choice.

const CONSENT_UNKNOWN := "unknown"
const CONSENT_GRANTED := "granted"
const CONSENT_DENIED := "denied"

## Tests point this at a throwaway file.
var path := "user://save.cfg"

var best_score := 0
var achievements: Array[String] = []
var consent := CONSENT_UNKNOWN


func _ready() -> void:
	load_data()


func load_data() -> void:
	best_score = 0
	achievements.clear()
	consent = CONSENT_UNKNOWN
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	best_score = int(cfg.get_value("player", "best_score", 0))
	achievements.assign(cfg.get_value("player", "achievements", []))
	consent = str(cfg.get_value("privacy", "consent", CONSENT_UNKNOWN))


func save_data() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "best_score", best_score)
	cfg.set_value("player", "achievements", achievements)
	cfg.set_value("privacy", "consent", consent)
	var err := cfg.save(path)
	if err != OK:
		push_warning("Could not save %s (error %d)" % [path, err])
