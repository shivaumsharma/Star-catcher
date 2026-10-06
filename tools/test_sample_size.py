"""Checks sample_size.py against well-known published values and a hand-checkable case.

Run:  python3 -m unittest discover -s tools -v
"""
import unittest

import sample_size as ss


class PlayersPerGroupTests(unittest.TestCase):
    def test_matches_textbook_values(self):
        # Widely published two-proportion figures at alpha 0.05 two-sided, power 80%.
        self.assertIn(ss.players_per_group(0.10, 0.15), range(683, 690))   # about 686
        self.assertIn(ss.players_per_group(0.50, 0.60), range(385, 391))   # about 388

    def test_bigger_effects_need_fewer_players(self):
        self.assertLess(ss.players_per_group(0.5, 0.6), ss.players_per_group(0.5, 0.55))

    def test_symmetric_in_direction(self):
        self.assertEqual(ss.players_per_group(0.5, 0.6), ss.players_per_group(0.6, 0.5))

    def test_more_power_needs_more_players(self):
        self.assertGreater(ss.players_per_group(0.5, 0.6, power=0.9), ss.players_per_group(0.5, 0.6))


class FisherTests(unittest.TestCase):
    def test_matches_known_values(self):
        # The classic "lady tasting tea" table (3 of 4 right vs 1 of 4): two-sided p = 0.4857
        self.assertAlmostEqual(ss.fisher_two_sided(3, 4, 1, 4), 0.4857143, places=6)
        # 5/5 vs 0/5: each tail is 1 / C(10,5) = 1/252, so two-sided p = 2/252, checked by hand
        self.assertAlmostEqual(ss.fisher_two_sided(5, 5, 0, 5), 2 / 252, places=9)

    def test_identical_groups_are_not_different(self):
        self.assertAlmostEqual(ss.fisher_two_sided(2, 5, 2, 5), 1.0)


if __name__ == "__main__":
    unittest.main()
