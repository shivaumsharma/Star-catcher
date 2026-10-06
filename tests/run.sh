#!/usr/bin/env sh
# Runs the headless test suite. Fails on a script error, or unless it prints "N checks, 0 failed".
# Godot's own exit code isn't trusted: a parse error makes it hang and a runtime error in one test
# still ends the run normally.
#   usage: tests/run.sh [path-to-godot]      (default: godot on PATH)
GODOT="${1:-godot}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
out="$(timeout 180 "$GODOT" --headless --path "$PROJECT" res://tests/test_runner.tscn -- --no-telemetry 2>&1)"
code=$?
printf '%s\n' "$out"
# A runtime error aborts just that one test and the runner carries on, so look for it explicitly.
if printf '%s' "$out" | grep -qE 'SCRIPT ERROR|Parse Error'; then
	echo "FAILED: a script error occurred (see above)" >&2
	exit 1
fi
if printf '%s' "$out" | grep -q ' checks, 0 failed'; then
	exit 0
fi
echo "FAILED: the suite did not finish with '0 failed' (exit code $code)" >&2
exit 1
