"""Cases from the 2026-11-04 review of the lost series (S0001-S0522): moves a terrain makes useless
(rules.py) and binding moves reaching the simulator (S0231 G2 T8, search.py).

Run it like test_casos_replays.py, from the Ai-vgc checkout (it needs the patched rules.py and search.py).
"""

import unittest

from poke_env.battle import Field, Move
from poke_env.battle.effect import Effect

from ai_vgc.nn.rules import _status_fails
from ai_vgc.nn.search import position
from test_casos_replays import at_turn

ID = "2709194980"  # S1 G3: Electric Terrain up on turn 5, gone on turn 6; Toxapex and Charizard on the field
TEAMS = "data/teams/reg_mc"
FMT = "gen9championsvgc2026regmcbo3"


def foe(b, species):
    return next(m for m in b.opponent_active_pokemon if m is not None and m.species.startswith(species))


class TestTerrain(unittest.TestCase):
    def test_sleep_on_grounded_target_in_electric_terrain(self):
        b = at_turn(ID, "p2", 5)
        self.assertIn(Field.ELECTRIC_TERRAIN, b.fields)
        self.assertTrue(_status_fails(None, foe(b, "toxapex"), Move("sleeppowder", gen=9), b))
        self.assertTrue(_status_fails(None, foe(b, "toxapex"), Move("yawn", gen=9), b))

    def test_flying_target_is_not_grounded(self):
        # The control: Charizard is above the terrain, so nothing stops sleep from it.
        b = at_turn(ID, "p2", 5)
        self.assertFalse(_status_fails(None, foe(b, "charizard"), Move("spore", gen=9), b))

    def test_electric_terrain_only_stops_sleep(self):
        b = at_turn(ID, "p2", 5)
        self.assertFalse(_status_fails(None, foe(b, "toxapex"), Move("willowisp", gen=9), b))

    def test_no_terrain_no_block(self):
        b = at_turn(ID, "p2", 6)
        self.assertNotIn(Field.ELECTRIC_TERRAIN, b.fields)
        self.assertFalse(_status_fails(None, foe(b, "toxapex"), Move("spore", gen=9), b))


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
