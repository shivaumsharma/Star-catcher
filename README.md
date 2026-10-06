# Star Catcher

A tiny 2D Android game built in **Godot 4.7**, with **Firebase Analytics**.
Drag the basket to catch falling stars and dodge the bombs. Missing a star or catching a bomb
costs a life; three lives per round. It speeds up as your score grows.

| Consent | Menu | Playing | Game over |
|---|---|---|---|
| ![](screenshots/consent.png) | ![](screenshots/menu.png) | ![](screenshots/playing.png) | ![](screenshots/game-over.png) |

Everything is drawn in code, so the project has no art or audio assets to manage.

## Status — what is and isn't verified

| | |
|---|---|
| Game logic, UI flow, analytics wrapper | Covered by the headless suite in `tests/`, run under Godot 4.7; every check was also confirmed to fail when the code it guards is broken. |
| Rendering | Screenshots above are real captures of the scenes under Godot 4.7. |
| Firebase plugin integration | Written against the plugin's published source (singleton names, signals, method signatures, accepted parameter types) and tested against fakes with the same interface. |
| **APK build and events reaching Firebase** | **Not done.** It needs the Android SDK and your own Firebase project, neither of which existed where this was written. Follow *Firebase setup* below and confirm in DebugView. |

## Run it on desktop

```sh
godot --path star-catcher              # Godot 4.7; click or drag to move the basket, or use ← →
star-catcher/tests/run.sh              # Godot tests (needs `godot` on PATH, or pass its path); fails on any problem
python3 -m unittest discover -s star-catcher/tools   # tests for the playtest report script
```

On desktop there is no Firebase plugin, so analytics events are printed to the console instead
(after you tap *Allow analytics*), e.g. `[Analytics] game_over { "score": 12, ... }`.

## Firebase setup (Android)

Firebase has no official Godot SDK. This project uses the community plugin
[godot-x/firebase](https://github.com/godot-x/firebase) (MIT, prebuilt, built for Godot 4.7).
Only `scripts/analytics.gd` talks to it, so swapping plugins touches one file.

1. **Create the Firebase app.** In the [Firebase console](https://console.firebase.google.com/)
   add an Android app. Pick a package name (e.g. `com.yourname.starcatcher`) — it must match the
   export preset's *Package → Unique Name* in step 6 exactly.
2. **Download `google-services.json`** and put it in this folder (`star-catcher/`). It is git-ignored.
3. **Install the plugin.** Godot → *AssetLib* → search "Godotx Firebase" (or download the zip from the
   [releases](https://github.com/godot-x/firebase/releases)) and copy its `addons/` and `android/`
   folders into this project. Enable it in *Project → Project Settings → Plugins*.
4. **Install the Android build template:** *Project → Install Android Build Template*. Then edit
   `android/build/build.gradle`:
   ```gradle
   // very first lines of the file
   buildscript {
       dependencies {
           classpath 'com.google.gms:google-services:4.4.4'
       }
   }
   // ...and at the very end of the file
   apply plugin: 'com.google.gms.google-services'
   ```
5. **Set up Godot's Android export** — Android SDK, a JDK and a debug keystore, configured under
   *Editor → Editor Settings → Export → Android*. The versions Godot needs are in its
   [Exporting for Android](https://docs.godotengine.org/en/stable/tutorials/export/exporting_for_android.html) guide.
6. **Add an Android export preset** (*Project → Export*):
   - **Use Gradle Build**: on (required by the plugin)
   - *Package → Unique Name*: the package name from step 1
   - *Firebase → Android Config File*: `res://google-services.json` (the default)
   - *Firebase → Enable Core*: on (default)
   - ***Firebase → Enable Analytics*: on — it is off by default, and without it nothing is sent**
   - *Firebase → Privacy Safe Defaults*: leave on (see below)
   - *Resources → Filters to exclude*: `android/*,addons/godotx_firebase/*,build/*,tests/*,tools/*`
7. **Export / run on a device.** Use *One-click deploy*, or export an APK and `adb install` it.

### Checking that events arrive

Enable debug reporting for your package, then open *Firebase console → Analytics → DebugView*:

```sh
adb shell setprop debug.firebase.analytics.app com.yourname.starcatcher
```

Events show up in DebugView within seconds (and in the normal reports after up to ~24 h).
Tap *Allow analytics* on first launch — nothing is collected before that.

## What gets logged

Firebase's standard events are used where one fits; the rest are custom.

| Event | When | Parameters |
|---|---|---|
| `screen_view` | menu, game, game-over screens | `screen_name`, `screen_class` |
| `game_start` | a round begins | `best_score` |
| `life_lost` | missed star / bomb caught | `cause` (`missed_star` \| `bomb`), `score` |
| `unlock_achievement` | first time reaching 10 / 25 / 50 stars | `achievement_id` (`catcher_10` …) |
| `game_over` | a round ends | `score`, `duration_s`, `stars_caught`, `stars_missed`, `bombs_hit`, `new_best` (0/1) |
| `post_score` | a round ends | `score` |

Firebase also records `first_open`, `session_start` and friends on its own. To use the custom
parameters in Firebase reports, register them under *Analytics → Custom definitions*.

## Consent

The plugin's *Privacy Safe Defaults* export option ships the app with collection **off** and all
Consent Mode signals denied. The game asks on first launch; *Allow* calls `set_consent(granted)` and
`set_analytics_collection_enabled(true)`, *No thanks* keeps everything off. The choice is saved and
can be flipped from the menu (*Analytics: On/Off*). If you have no consent requirement you can switch
the export option off and drop the prompt.

## Playtest build: local log, share button, report

The product analysis that goes with this build is in [`TEARDOWN.md`](../TEARDOWN.md) at the repo root.

This branch is meant for putting the game in front of friends and learning from it.

- **`scripts/telemetry.gd`** appends one JSON line per event to a file on the phone: app launches,
  the consent screen, button taps that start or end screens, and how each round goes. It runs
  **whatever the player chose on the Firebase consent screen** — that is the only way to see what
  people do on that screen — so the consent screen and the menu both say so, and you should tell
  testers too. It never sends anything itself.
- **Menu → *Share playtest log*** copies the whole log to the clipboard. The tester pastes it into a
  message to you; save each friend's text as its own `.jsonl` file.
- **`tools/playtest_report.py`** reads those files (or a folder of them) and prints the onboarding
  funnel, session length, rounds per session and day-1/7/30 return rate:

  ```sh
  python3 tools/playtest_report.py friends_logs/
  ```
- **`sample_data/simulated_playtest.jsonl`** is a **simulation**: 30 bots (ids `sim-…`) playing the real
  game. It exists to show what the report looks like; the report stamps it as sample data. Regenerate
  with `godot --headless --path . res://tools/simulate_playtest.tscn -- --no-telemetry --out=$PWD/sample_data/simulated_playtest.jsonl`.
  The assumptions behind it are the constants at the top of `tools/simulate_playtest.gd`.

Logged events (`t` = unix seconds, `i` = random install id, `s` = launch number):

| Event | Parameters |
|---|---|
| `app_open` | `first_launch` (1/0) |
| `consent_shown`, `consent_choice` | `granted` (1/0) |
| `menu_shown` | |
| `round_start` | `round_number` (per install), `source` (`menu`/`game_over`), `best_score` |
| `round_first_star` | `round_number`, `seconds_in_round` |
| `life_lost` | `round_number`, `cause`, `score`, `lives_left`, `seconds_in_round` |
| `unlock_milestone` | `id`, `round_number` |
| `round_end` | `round_number`, `score`, `seconds_in_round`, `stars_caught`, `stars_missed`, `bombs_hit`, `new_best` |
| `analytics_toggle` | `granted` |
| `share_log` | `lines` |
| `app_background`, `app_foreground` | `in_round` (1/0) on background |

To keep your own desktop log clean, run the game or tests with `-- --no-telemetry`
(`tests/run.sh` does). For a non-playtest build set `enabled = false` in `scripts/telemetry.gd`.
Not verified on a phone: that the clipboard copy and app-background events behave on Android.

## Project layout

```
scripts/analytics.gd   Firebase facade (autoload): init order, event queue, consent
scripts/save.gd        best score, unlocked achievements, consent (autoload, ConfigFile)
scripts/telemetry.gd   local playtest log (autoload)
scripts/game.gd        gameplay simulation + drawing
scripts/main.gd        screens, and where gameplay turns into analytics events
scenes/main.tscn       the whole game
theme.tres             button styling
tests/                 headless suite (run.sh) + fake Firebase singletons
tools/                 playtest_report.py, simulate_playtest.gd, measure_baseline.gd, sample_size.py (+ tests)
sample_data/           simulated playtest log (not real players)
```

How `analytics.gd` deals with the plugin: Firebase Core must be initialised before Analytics, and the
plugin silently drops events until Analytics is ready, so events logged earlier are queued (max 50)
and flushed in order once it is. Events are only logged, or queued, while consent is granted.
