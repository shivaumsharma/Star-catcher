#!/usr/bin/env python3
"""Sample-size and small-group arithmetic for the experiment write-up in TEARDOWN.md.

    python3 tools/sample_size.py

Prints (1) how many players per group a real A/B test of a yes/no metric would need under
stated assumptions, and (2) how little a 5-versus-5 friends comparison can prove.
Every baseline rate below is an ASSUMPTION used to show the arithmetic; none is measured.
Standard library only.
"""
import math
from statistics import NormalDist

ALPHA = 0.05  # two-sided
POWER = 0.80


def players_per_group(p_control, p_variant, alpha=ALPHA, power=POWER):
    """Two-proportion z-test, two-sided, equal groups (the usual textbook formula)."""
    z_alpha = NormalDist().inv_cdf(1 - alpha / 2)
    z_beta = NormalDist().inv_cdf(power)
    p_bar = (p_control + p_variant) / 2
    spread = (z_alpha * math.sqrt(2 * p_bar * (1 - p_bar))
              + z_beta * math.sqrt(p_control * (1 - p_control) + p_variant * (1 - p_variant)))
    return math.ceil(spread ** 2 / (p_control - p_variant) ** 2)


def fisher_two_sided(successes_a, n_a, successes_b, n_b):
    """Exact two-sided p-value for 'the groups differ' with small counts (Fisher's exact test)."""
    total, successes = n_a + n_b, successes_a + successes_b

    def probability(k):  # chance that group A holds exactly k of the successes
        return math.comb(successes, k) * math.comb(total - successes, n_a - k) / math.comb(total, n_a)

    observed = probability(successes_a)
    low, high = max(0, successes - n_b), min(n_a, successes)
    return sum(probability(k) for k in range(low, high + 1) if probability(k) <= observed * (1 + 1e-9))


def main():
    print("A. HYPOTHETICAL LAUNCH - players needed per group (two-sided alpha 0.05, power 80%)")
    print("   Baselines are assumed, not measured. Measure the real baseline first.\n")
    lifts = (0.03, 0.05, 0.10)
    print(f"   {'assumed baseline':>17} | " + " | ".join(f"+{int(l * 100)} pts" .rjust(9) for l in lifts))
    for baseline in (0.30, 0.50, 0.70):
        cells = [f"{players_per_group(baseline, baseline + l):>9,}" for l in lifts]
        print(f"   {int(baseline * 100):>16}% | " + " | ".join(cells))
    print("\n   Days to fill both groups = 2 x players-per-group / new players per day, then rounded up")
    print("   to whole weeks so weekday and weekend behaviour are both covered (minimum 7 days):\n")
    per_group = players_per_group(0.50, 0.55)
    print(f"   Example: 50% -> 55% needs {per_group:,} per group = {2 * per_group:,} new players in total.")
    for daily in (200, 1000, 5000):
        days = max(7, math.ceil(2 * per_group / daily / 7) * 7)
        print(f"   at {daily:>5,} new players/day -> {days} days")
    print("   (add one day if the metric is next-day return, to let the last players come back)\n")

    print("B. FRIENDS-SIZED COMPARISON - 5 players who saw the old build vs 5 who saw the new one")
    print("   Exact two-sided p-value for 'the rates differ' if x of 5 succeed in each group:\n")
    print(f"   {'old build':>10} | {'new build':>10} | p-value")
    for old, new in ((2, 3), (2, 4), (1, 4), (0, 4), (0, 5)):
        print(f"   {old:>7}/5 | {new:>7}/5 | {fisher_two_sided(old, 5, new, 5):.3f}")
    print("\n   Reading: only a near-total swing (0/5 vs 4/5 or 5/5) clears the usual p < 0.05 bar;")
    print("   every smaller difference is indistinguishable from chance with five per group.")


if __name__ == "__main__":
    main()
