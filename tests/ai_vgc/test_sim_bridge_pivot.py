"""sim_bridge.js finishes a turn that a pivot (U-turn) interrupts.

Needs the patched Ai-vgc and its simulator, so it is not part of the CI run (and it stays out
of ai-vgc-lor.patch: files the patch creates would be left behind untracked and break the next
`git apply`). Run it from the Ai-vgc checkout:

    cd /opt/lor-bots/ai-vgc
    PYTHONPATH=src .venv/bin/python -m unittest discover -s <this repo>/tests/ai_vgc

Fixture: Ynokmon G3 T2 from the 2026-10-28 ladder (we are p2: Annihilape + Archaludon vs
Sylveon + Charizard). Annihilape's Scarf U-turn moves first and asks for a switch mid-turn;
the opponent's attacks come after it.
"""

import json
import unittest
from pathlib import Path

from ai_vgc.nn.search import Bridge

STATE = json.loads((Path(__file__).parent / "fixtures" / "pivot_state.json").read_text())
SHOWDOWN = "pokemon-showdown-mc"
THEM = "move hypervoice, move heatwave"


class TestPivot(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = Bridge(SHOWDOWN)

    @classmethod
    def tearDownClass(cls):
        cls.bridge.close()

    def play(self, us: str) -> list[dict]:
        return self.bridge.run(STATE, [(us, THEM)], [1, 2, 3])

    def test_uturn_turn_finishes(self):
        for r in self.play("move uturn 1, move protect"):
            self.assertEqual(r["err"], "")
            text = "\n".join(r["lines"])
            self.assertIn("|move|p2a: Annihilape|U-turn|", text)
            self.assertRegex(text, r"\|switch\|p2a: ", "the U-turn switch-in never happened")
            self.assertRegex(text, r"\|move\|p1[ab]: [^|]+\|(Hyper Voice|Heat Wave)\|",
                             "the opponent's attacks never happened")
            # End of turn: residuals ran (a faint then leaves a replacement pending, as before).
            self.assertRegex(text, r"\|upkeep|\|turn\|3|\|win\|", "the turn did not end")

    def test_ordinary_turn_unchanged(self):
        # No pivot: the turn ends as before (sanity check that finishTurn is a no-op here).
        for r in self.play("move closecombat 1, move protect"):
            self.assertEqual(r["err"], "")
            self.assertRegex("\n".join(r["lines"]), r"\|upkeep|\|turn\|3|\|win\|")


if __name__ == "__main__":
    unittest.main()
