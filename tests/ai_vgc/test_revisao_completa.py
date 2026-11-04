"""Cases from the 2026-11-04 review of the lost series (S0231 G2 T8):
binding moves reaching the simulator.

Run it like test_casos_replays.py, from the Ai-vgc checkout (it needs the patched search.py).
"""

import unittest

from poke_env.battle.effect import Effect

from ai_vgc.nn.search import position
from test_casos_replays import at_turn

ID = "2709194980"  # S1 G3: Electric Terrain up on turn 5, gone on turn 6; Toxapex and Charizard on the field
TEAMS = "data/teams/reg_mc"
FMT = "gen9championsvgc2026regmcbo3"



class TestBinding(unittest.TestCase):
    def test_infestation_reaches_the_simulator(self):
        b = at_turn(ID, "p2", 5)
        mon = next(m for m in b.active_pokemon if m is not None)
        mon.effects[Effect.INFESTATION] = 1
        mons = position(b, FMT, TEAMS)["sides"]["us"]["mons"]
        self.assertTrue(any("partiallytrapped" in m["volatiles"] for m in mons))

    def test_no_binding_no_volatile(self):
        b = at_turn(ID, "p2", 5)
        mons = position(b, FMT, TEAMS)["sides"]["us"]["mons"]
        self.assertFalse(any("partiallytrapped" in m["volatiles"] for m in mons))


if __name__ == "__main__":
    unittest.main()
