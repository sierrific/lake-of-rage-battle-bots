"""Cases from the 2026-11-04 review of the lost series (S0001-S0322): moves a terrain makes useless.

Run it like test_casos_replays.py, from the Ai-vgc checkout (it needs the patched rules.py).
"""

import unittest

from poke_env.battle import Field, Move

from ai_vgc.nn.rules import _status_fails
from test_casos_replays import at_turn

ID = "2709194980"  # S1 G3: Electric Terrain up on turn 5, gone on turn 6; Toxapex and Charizard on the field


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


if __name__ == "__main__":
    unittest.main()
