"""Cases from the 2026-11-02 replay review (Sierra's "Análise de replays para treino dos bots",
41 annotated cases over PaiBrazVGC_Oficial, PatriotaFujao and malucodetilambuco): the P0 ones
that are mechanical, i.e. a move that does nothing in that position whatever the opponent does.

Each test replays a public log (fixtures/replays, chat lines removed) from the player's side up to
the start of the turn the case is about, and asks rules.move_fails about the move that was used.
The counter-examples (Wide Guard that did block a spread move) must stay allowed: the rule is
"no possible spread move", not "never Wide Guard".

Needs the patched Ai-vgc (rules.py comes from ai-vgc-lor.patch), so it is not part of the CI run.
Run it from the Ai-vgc checkout:

    cd /opt/lor-bots/ai-vgc
    PYTHONPATH=src .venv/bin/python -m unittest discover -s <this repo>/tests/ai_vgc
"""

import copy
import unittest
from pathlib import Path

from poke_env.battle import Move

from ai_vgc.nn.replay import replay
from ai_vgc.nn.rules import move_fails

LOGS = Path(__file__).parent / "fixtures" / "replays"
TAG = "gen9championsvgc2026regmcbo3"


def at_turn(replay_id: str, role: str, turn: int):
    """The battle from `role`'s side at the start of `turn` (before anyone moves)."""
    seen = {}

    def grab(battle, action, teampreview, opp):
        if not teampreview and battle.turn == turn and "b" not in seen:
            logger, battle.logger = battle.logger, None
            seen["b"] = copy.deepcopy(battle)
            battle.logger = logger

    replay(f"{TAG}-{replay_id}", (LOGS / f"{replay_id}.log").read_text(), role, grab)
    assert "b" in seen, f"turn {turn} not reached in {replay_id}"
    return seen["b"]


def why(battle, species: str, move: str) -> str | None:
    """rules.move_fails for our active `species` using `move` (no target)."""
    pos = next(i for i, m in enumerate(battle.active_pokemon)
               if m is not None and not m.fainted and m.species.startswith(species))
    return move_fails(battle, pos, Move(move, gen=9), 0)


class TestCasosReplays(unittest.TestCase):
    def test_coaching_without_ally(self):
        # maluco-2704048851-t6: Sneasler is the last one standing and used Coaching ([notarget]).
        b = at_turn("2704048851", "p2", 6)
        self.assertEqual(why(b, "sneasler", "coaching"), "ally-only move with no ally")

    def test_coaching_without_ally_again(self):
        # 2704023418 T5: the same situation in another game.
        b = at_turn("2704023418", "p2", 5)
        self.assertEqual(why(b, "sneasler", "coaching"), "ally-only move with no ally")

    def test_wide_guard_with_no_spread_move(self):
        # PB01: fc5809 G2 T6. Raichu-Mega-Y and Garchomp are left; their sheets have only
        # single-target attacks and Protect, so Wide Guard blocks nothing (Zap Cannon + Power Gem KO).
        b = at_turn("2707939328", "p1", 6)
        self.assertEqual(why(b, "pelipper", "wideguard"), "Wide Guard with no spread move to block")
        # Nothing on that field has priority either.
        self.assertEqual(why(b, "pelipper", "quickguard"), "Quick Guard with no priority move to block")

    def test_wide_guard_with_real_coverage(self):
        # PB15: French1 G1 T8. Salamence has Hyper Voice: Wide Guard blocked it for both.
        b = at_turn("2707765031", "p2", 8)
        self.assertIsNone(why(b, "pelipper", "wideguard"))

    def test_wide_guard_at_1hp_still_counts(self):
        # maluco-2707868940-t5: Pelipper at 1% put up Wide Guard against Charizard's Heat Wave.
        b = at_turn("2707868940", "p2", 5)
        self.assertIsNone(why(b, "pelipper", "wideguard"))


if __name__ == "__main__":
    unittest.main()
