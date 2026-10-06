"""Tests for playtest_report.py.  Run:  python3 -m unittest discover -s tools -v

The six players below are invented for the tests, and every expected number was worked out
by hand from the story told in each player's comment, not copied from the script's output.
"""
import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

import playtest_report as report

T0 = datetime(2026, 1, 5, 10, 0, tzinfo=timezone.utc).timestamp()
DAY = 86400


def line(player, t, name, **params):
    return {"t": t, "i": player, "s": 1, "e": name, "p": params}


def story():
    ev = []
    # A: plays two rounds on day 0 (leaves during round 2, session 120 s), returns next day (60 s).
    ev += [line("a", T0, "app_open", first_launch=1),
           line("a", T0 + 3, "consent_shown"),
           line("a", T0 + 8, "consent_choice", granted=1),
           line("a", T0 + 10, "round_start", round_number=1, source="menu"),
           line("a", T0 + 13, "round_first_star", round_number=1, seconds_in_round=2.5),
           line("a", T0 + 30, "unlock_milestone", id="catcher_10", round_number=1),
           line("a", T0 + 50, "round_end", round_number=1, stars_caught=12),
           line("a", T0 + 60, "round_start", round_number=2, source="game_over"),
           line("a", T0 + 120, "app_background", in_round=1),
           line("a", T0 + DAY, "app_open", first_launch=0),
           line("a", T0 + DAY + 5, "round_start", round_number=3, source="menu"),
           line("a", T0 + DAY + 60, "round_end", round_number=3, stars_caught=5)]
    # B: sees the consent screen and leaves (5 s).
    ev += [line("b", T0 + 100, "app_open", first_launch=1), line("b", T0 + 105, "consent_shown")]
    # C: declines, plays one round, catches no star (30 s).
    ev += [line("c", T0 + 200, "app_open", first_launch=1), line("c", T0 + 202, "consent_shown"),
           line("c", T0 + 210, "consent_choice", granted=0),
           line("c", T0 + 212, "round_start", round_number=1, source="menu"),
           line("c", T0 + 230, "round_end", round_number=1, stars_caught=0)]
    # D: one round, first star after 4.0 s, does not play again (90 s).
    ev += [line("d", T0 + 300, "app_open", first_launch=1), line("d", T0 + 302, "consent_shown"),
           line("d", T0 + 306, "consent_choice", granted=1),
           line("d", T0 + 308, "round_start", round_number=1, source="menu"),
           line("d", T0 + 312, "round_first_star", round_number=1, seconds_in_round=4.0),
           line("d", T0 + 390, "round_end", round_number=1, stars_caught=3)]
    # E: first star after 3.0 s, starts a second round and leaves (100 s).
    ev += [line("e", T0 + 400, "app_open", first_launch=1), line("e", T0 + 402, "consent_shown"),
           line("e", T0 + 405, "consent_choice", granted=1),
           line("e", T0 + 407, "round_start", round_number=1, source="menu"),
           line("e", T0 + 410, "round_first_star", round_number=1, seconds_in_round=3.0),
           line("e", T0 + 460, "round_end", round_number=1, stars_caught=4),
           line("e", T0 + 470, "round_start", round_number=2, source="game_over"),
           line("e", T0 + 500, "app_background", in_round=1)]
    # F: installs two days later (extends the data so day 1 is judgeable), sees consent, leaves (5 s).
    ev += [line("f", T0 + 2 * DAY, "app_open", first_launch=1), line("f", T0 + 2 * DAY + 5, "consent_shown")]
    return ev


class AnalyseTests(unittest.TestCase):
    def setUp(self):
        self.r = report.analyse(story())

    def test_funnel_counts_and_losses(self):
        counts = [f["players"] for f in self.r["funnel"]]
        self.assertEqual(counts, [6, 6, 4, 4, 3, 3, 2, 1])
        self.assertEqual([f["lost"] for f in self.r["funnel"]], [0, 0, 2, 0, 1, 0, 1, 1])
        self.assertAlmostEqual(self.r["funnel"][2]["of_previous"], 4 / 6)
        self.assertAlmostEqual(self.r["funnel"][7]["of_start"], 1 / 6)
        self.assertEqual(self.r["biggest_drop"], "3 consent answered")

    def test_funnel_is_strict(self):
        # C finished a round but never caught a star, so C is not counted at step 6 even though
        # C has a round_end event.
        self.assertEqual(self.r["funnel"][5]["players"], 3)

    def test_consent(self):
        self.assertEqual(self.r["consent"], {"answered": 4, "allowed": 3})

    def test_first_round(self):
        fr = self.r["first_round"]
        self.assertEqual((fr["finished"], fr["zero_star"]), (4, 1))
        s = fr["seconds_to_first_star"]
        self.assertEqual((s["n"], s["median"], s["max"]), (3, 3.0, 4.0))
        self.assertAlmostEqual(s["mean"], (2.5 + 4.0 + 3.0) / 3)

    def test_sessions(self):
        s = self.r["sessions"]
        self.assertEqual(s["count"], 7)
        # lengths 120, 60, 5, 30, 90, 100, 5
        self.assertAlmostEqual(s["length_seconds"]["mean"], 410 / 7)
        self.assertEqual(s["length_seconds"]["median"], 60)
        self.assertEqual(s["length_seconds"]["max"], 120)
        self.assertEqual(s["without_a_round"], 2)  # B and F

    def test_rounds_per_session(self):
        s = self.r["sessions"]
        self.assertAlmostEqual(s["rounds_completed"]["mean"], 5 / 7)
        self.assertEqual(s["rounds_completed"]["median"], 1)
        self.assertEqual((s["rounds_started_total"], s["rounds_completed_total"]), (7, 5))

    def test_return_rate(self):
        r = self.r["retention"]
        self.assertEqual(r[1], {"eligible": 5, "returned": 1})  # A..E are old enough; only A came back
        self.assertEqual(r[7]["eligible"], 0)
        self.assertEqual(r[30]["eligible"], 0)

    def test_a_long_gap_starts_a_new_session(self):
        ev = [line("g", T0, "app_open", first_launch=1),
              line("g", T0 + 60, "round_start", round_number=1),
              line("g", T0 + 60 + 31 * 60, "round_start", round_number=2)]  # 31 minutes later
        self.assertEqual(report.analyse(ev)["sessions"]["count"], 2)

    def test_a_short_pause_does_not_split_a_session(self):
        ev = [line("g", T0, "app_open", first_launch=1),
              line("g", T0 + 60, "round_start", round_number=1),
              line("g", T0 + 60 + 20 * 60, "round_end", round_number=1, stars_caught=1)]  # 20 minutes later
        sessions = report.analyse(ev)["sessions"]
        self.assertEqual(sessions["count"], 1)
        self.assertEqual(sessions["length_seconds"]["max"], 60 + 20 * 60)

    def test_day_n_only_counts_once_it_is_over(self):
        # The data ends during day 1, so we can't yet say who will come back on day 1.
        ev = [line("g", T0, "app_open", first_launch=1),
              line("g", T0 + DAY + 600, "app_open", first_launch=0)]
        self.assertEqual(report.analyse(ev)["retention"][1], {"eligible": 0, "returned": 0})
        # One more day of data and the same player counts as having returned.
        ev.append(line("h", T0 + 2 * DAY, "app_open", first_launch=1))
        self.assertEqual(report.analyse(ev)["retention"][1], {"eligible": 1, "returned": 1})

    def test_empty_input(self):
        r = report.analyse([])
        self.assertEqual(r["players"], 0)
        self.assertIn("No events found", report.format_report(r))


class LoadTests(unittest.TestCase):
    def write(self, folder, name, lines, raw=None):
        path = Path(folder) / name
        path.write_text("\n".join(raw if raw is not None else [json.dumps(e) for e in lines]) + "\n")
        return path

    def test_repeated_shares_count_once(self):
        with tempfile.TemporaryDirectory() as d:
            self.write(d, "friend.jsonl", story())
            self.write(d, "friend_again.jsonl", story())  # the same log pasted a second time
            events, bad = report.load_events([d])
            self.assertEqual((len(events), bad), (len(story()), 0))

    def test_unreadable_lines_are_counted_not_hidden(self):
        with tempfile.TemporaryDirectory() as d:
            good = json.dumps(line("a", T0, "app_open", first_launch=1))
            self.write(d, "x.jsonl", None, raw=[good, "not json", '{"t": 1}', ""])
            events, bad = report.load_events([d])
            self.assertEqual((len(events), bad), (1, 2))
            self.assertIn("2 line(s) could not be read", report.format_report(report.analyse(events), bad))


class BannerTests(unittest.TestCase):
    def test_simulated_logs_are_labelled(self):
        ev = [line("sim-001", T0, "app_open", first_launch=1)]
        text = report.format_report(report.analyse(ev))
        self.assertIn("SAMPLE DATA - SIMULATED PLAYERS", text)

    def test_mixing_is_flagged(self):
        ev = [line("sim-001", T0, "app_open", first_launch=1), line("3fa9c1d2", T0, "app_open", first_launch=1)]
        text = report.format_report(report.analyse(ev))
        self.assertIn("1 of 2 players are simulated", text)
        self.assertNotIn("SAMPLE DATA - SIMULATED PLAYERS", text)

    def test_real_logs_carry_no_banner(self):
        text = report.format_report(report.analyse(story()))
        self.assertNotIn("SAMPLE", text)
        self.assertIn("Biggest single drop: 3 consent answered", text)


if __name__ == "__main__":
    unittest.main()
