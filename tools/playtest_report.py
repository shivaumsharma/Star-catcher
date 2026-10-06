#!/usr/bin/env python3
"""Summarise Star Catcher playtest logs.

Reads the JSON Lines files written by scripts/telemetry.gd (one file per player is fine;
pasted-together files and repeated shares are de-duplicated) and prints:

  * the onboarding funnel, with the drop-off at every step
  * session length
  * rounds completed per session
  * day-1 / day-7 / day-30 return rate (only for players old enough to judge)

    python3 tools/playtest_report.py logs/*.jsonl
    python3 tools/playtest_report.py sample_data/            # a folder of .jsonl files

Only the standard library is used.
"""
import argparse
import json
import statistics
import sys
from datetime import datetime, timezone
from pathlib import Path

SESSION_GAP_SECONDS = 30 * 60
SIM_PREFIX = "sim-"

# The funnel is strict: a player counts at a step only if they also passed every earlier step.
# Each entry is (label, predicate over one player's events).
FUNNEL = [
    ("1 first launch",
     lambda ev: any(e["e"] == "app_open" and e["p"].get("first_launch") == 1 for e in ev)),
    ("2 consent screen shown",
     lambda ev: any(e["e"] == "consent_shown" for e in ev)),
    ("3 consent answered",
     lambda ev: any(e["e"] == "consent_choice" for e in ev)),
    ("4 first round started",
     lambda ev: any(e["e"] == "round_start" for e in ev)),
    ("5 first star caught",
     lambda ev: any(e["e"] == "round_first_star" for e in ev)),
    ("6 first round finished",
     lambda ev: any(e["e"] == "round_end" for e in ev)),
    ("7 second round started",
     lambda ev: any(e["e"] == "round_start" and e["p"].get("round_number", 0) >= 2 for e in ev)),
    ("8 reached 10 stars",
     lambda ev: any(e["e"] == "unlock_milestone" and e["p"].get("id") == "catcher_10" for e in ev)),
]


def load_events(paths):
    """Returns (events, malformed_line_count). Identical lines (a log shared twice) count once."""
    events, seen, malformed = [], set(), 0
    files = []
    for path in paths:
        path = Path(path)
        files.extend(sorted(path.glob("*.jsonl")) if path.is_dir() else [path])
    for file in files:
        for line in file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            if line in seen:
                continue
            seen.add(line)
            try:
                event = json.loads(line)
                event.setdefault("p", {})
                if not all(k in event for k in ("t", "i", "e")):
                    raise ValueError("missing field")
            except (ValueError, TypeError):
                malformed += 1
                continue
            events.append(event)
    return events, malformed


def _day(timestamp):
    return datetime.fromtimestamp(timestamp, tz=timezone.utc).date()


def _split_sessions(player_events):
    """A session ends at the next app_open or after a 30-minute gap."""
    sessions, current = [], []
    for event in player_events:
        new_session = current and (
            event["e"] == "app_open" or event["t"] - current[-1]["t"] > SESSION_GAP_SECONDS)
        if new_session:
            sessions.append(current)
            current = []
        current.append(event)
    if current:
        sessions.append(current)
    return sessions


def _summary(values):
    if not values:
        return None
    return {"mean": statistics.mean(values), "median": statistics.median(values),
            "max": max(values), "n": len(values)}


def analyse(events):
    """Turns a list of event dicts into a plain dict of results (what the tests check)."""
    by_player = {}
    for event in sorted(events, key=lambda e: (e["t"], e.get("s", 0))):
        by_player.setdefault(event["i"], []).append(event)

    result = {"players": len(by_player), "events": len(events)}
    ids = list(by_player)
    result["simulated_players"] = sum(1 for i in ids if str(i).startswith(SIM_PREFIX))
    if not events:
        return result
    result["first_event"] = _day(min(e["t"] for e in events)).isoformat()
    result["last_event"] = _day(max(e["t"] for e in events)).isoformat()

    # --- funnel
    remaining = list(by_player.values())
    funnel, previous, start = [], None, None
    for label, passed in FUNNEL:
        remaining = [ev for ev in remaining if passed(ev)]
        count = len(remaining)
        start = count if start is None else start
        funnel.append({
            "step": label, "players": count,
            "of_previous": None if previous is None else (count / previous if previous else 0.0),
            "of_start": count / start if start else 0.0,
            "lost": 0 if previous is None else previous - count,
        })
        previous = count
    result["funnel"] = funnel
    drops = [f for f in funnel[1:] if f["lost"] > 0]
    result["biggest_drop"] = max(drops, key=lambda f: f["lost"])["step"] if drops else None

    answered = [e for ev in by_player.values() for e in ev if e["e"] == "consent_choice"]
    result["consent"] = {"answered": len(answered),
                         "allowed": sum(1 for e in answered if e["p"].get("granted") == 1)}

    # --- first-round diagnostics
    first_round_ends, zero_star, first_star_times = 0, 0, []
    for ev in by_player.values():
        end = next((e for e in ev if e["e"] == "round_end" and e["p"].get("round_number") == 1), None)
        if end:
            first_round_ends += 1
            zero_star += end["p"].get("stars_caught", 0) == 0
        star = next((e for e in ev if e["e"] == "round_first_star" and e["p"].get("round_number") == 1), None)
        if star:
            first_star_times.append(star["p"]["seconds_in_round"])
    result["first_round"] = {"finished": first_round_ends, "zero_star": zero_star,
                             "seconds_to_first_star": _summary(first_star_times)}

    # --- sessions and rounds
    sessions = [s for ev in by_player.values() for s in _split_sessions(ev)]
    lengths = [s[-1]["t"] - s[0]["t"] for s in sessions]
    started = [sum(e["e"] == "round_start" for e in s) for s in sessions]
    completed = [sum(e["e"] == "round_end" for e in s) for s in sessions]
    result["sessions"] = {
        "count": len(sessions),
        "length_seconds": _summary(lengths),
        "without_a_round": sum(1 for n in started if n == 0),
        "rounds_completed": _summary(completed),
        "rounds_started_total": sum(started),
        "rounds_completed_total": sum(completed),
    }

    # --- return rate: share of players seen again on calendar day N (UTC) after their first launch.
    data_end = _day(max(e["t"] for e in events))
    retention = {}
    for n in (1, 7, 30):
        eligible = returned = 0
        for ev in by_player.values():
            opens = [e for e in ev if e["e"] == "app_open"]
            if not opens:
                continue
            first_day = _day(opens[0]["t"])
            if (data_end - first_day).days <= n:  # day N hasn't fully happened in this data
                continue
            eligible += 1
            returned += any((_day(s[0]["t"]) - first_day).days == n for s in _split_sessions(ev))
        retention[n] = {"eligible": eligible, "returned": returned}
    result["retention"] = retention
    return result


def _pct(x):
    return "   —  " if x is None else f"{x * 100:5.1f}%"


def _fmt(summary, unit=""):
    if summary is None:
        return "n/a"
    return (f"mean {summary['mean']:.1f}{unit}, median {summary['median']:.1f}{unit}, "
            f"max {summary['max']:.1f}{unit} (n={summary['n']})")


def format_report(r, malformed=0):
    out = []
    sim, total = r.get("simulated_players", 0), r["players"]
    if total and sim == total:
        out += ["=" * 74,
                "  SAMPLE DATA - SIMULATED PLAYERS, NOT REAL PEOPLE",
                "  Made by tools/simulate_playtest.gd. These numbers describe the simulator's",
                "  assumptions only. Do not quote them as findings about players.",
                "=" * 74, ""]
    elif sim:
        out += [f"WARNING: {sim} of {total} players are simulated (ids starting '{SIM_PREFIX}'). "
                "Do not mix simulated and real logs.", ""]
    if malformed:
        out += [f"WARNING: {malformed} line(s) could not be read and were skipped.", ""]
    if not total:
        return "\n".join(out + ["No events found."])

    out.append(f"Players: {total}   Events: {r['events']}   Period: {r['first_event']} to {r['last_event']}")
    out += ["", "ONBOARDING FUNNEL  (strict: a player counts only if they passed every earlier step)",
            f"  {'step':<26}{'players':>8}{'of previous':>13}{'of first launches':>19}{'lost here':>11}"]
    for f in r["funnel"]:
        out.append(f"  {f['step']:<26}{f['players']:>8}{_pct(f['of_previous']):>13}"
                   f"{_pct(f['of_start']):>19}{f['lost']:>11}")
    out.append(f"  Biggest single drop: {r['biggest_drop'] or 'none'}")
    c = r["consent"]
    out.append(f"  Consent answered: {c['answered']}, allowed Firebase analytics: {c['allowed']}"
               + (f" ({c['allowed'] / c['answered'] * 100:.0f}%)" if c["answered"] else ""))

    fr = r["first_round"]
    out += ["", "FIRST ROUND",
            f"  players who finished their first round: {fr['finished']}, "
            f"of those with zero stars caught: {fr['zero_star']}",
            f"  seconds until the first star was caught: {_fmt(fr['seconds_to_first_star'], ' s')}"]

    s = r["sessions"]
    out += ["", "SESSIONS",
            f"  sessions: {s['count']}   with no round started: {s['without_a_round']}",
            f"  session length: {_fmt(s['length_seconds'], ' s')}",
            f"  rounds completed per session: {_fmt(s['rounds_completed'])}",
            f"  rounds started {s['rounds_started_total']}, finished {s['rounds_completed_total']}"
            f" (left unfinished: {s['rounds_started_total'] - s['rounds_completed_total']})"]

    out += ["", "RETURN RATE  (players seen again on calendar day N after first launch, UTC)"]
    for n, d in r["retention"].items():
        if d["eligible"]:
            out.append(f"  day {n:<2}: {d['returned']}/{d['eligible']} = {d['returned'] / d['eligible'] * 100:.0f}%")
        else:
            out.append(f"  day {n:<2}: n/a (no player is old enough in this data)")
    return "\n".join(out)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="+", help=".jsonl files or folders of them")
    args = parser.parse_args(argv)
    events, malformed = load_events(args.paths)
    print(format_report(analyse(events), malformed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
