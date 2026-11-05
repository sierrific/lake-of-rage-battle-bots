"""A spread move with only one foe left is masked when the same Pokemon has a single-target move
of the same type that is at least as strong and more accurate (Heat Wave next to Weather Ball in
sun): with one target the spread move gets no spread penalty, it only adds the chance to miss.

The fixture is a made-up game (fixtures/sinteticos), not a real one: Charizard-Mega-Y and
Incineroar against Metagross-Mega, alone after Whimsicott fainted, sun up.

Needs the patched Ai-vgc (rules.py comes from ai-vgc-lor.patch), so it is not part of the CI run.
Run it from the Ai-vgc checkout:

    cd /opt/lor-bots/ai-vgc
    PYTHONPATH=src .venv/bin/python -m unittest discover -s <this repo>/tests/ai_vgc
"""

import copy
import unittest
from pathlib import Path

import numpy as np
from poke_env.battle import Move, Weather

from ai_vgc.nn.encode import legal_mask
from ai_vgc.nn.replay import replay
from ai_vgc.nn.rules import apply_rules, move_dominated

LOG = Path(__file__).parent / "fixtures" / "sinteticos" / "um_alvo_sol.log"
HEAT_WAVE, WEATHER_BALL = Move("heatwave", gen=9), Move("weatherball", gen=9)


def turn_2():
    seen = {}

    def grab(battle, action, teampreview, opp):
        if not teampreview and battle.turn == 2 and "b" not in seen:
            logger, battle.logger = battle.logger, None
            seen["b"] = copy.deepcopy(battle)
            battle.logger = logger

    replay("gen9championsvgc2026regmcbo3-1", LOG.read_text(), "p1", grab)
    return seen["b"]


class TestGolpeDominado(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.battle = turn_2()

    def with_weather(self, weather):
        b = copy.deepcopy(self.battle)
        b._weather = {weather: 1} if weather else {}
        return b

    def test_heat_wave_masked_in_sun(self):
        b = self.battle
        self.assertTrue(move_dominated(b, 0, HEAT_WAVE, WEATHER_BALL))
        mask = legal_mask(b)
        out = apply_rules(b, mask)
        heat_wave = 7 + 0 * 5 + 2  # move 1, no target
        self.assertTrue(mask[0, heat_wave])
        self.assertFalse(out[0, heat_wave])
        self.assertTrue(out[0, 7 + 1 * 5:7 + 2 * 5].any())  # Weather Ball still there

    def test_heat_wave_kept_without_sun(self):
        # No weather: Weather Ball is a 50 BP Normal move. Rain: a Water move.
        self.assertFalse(move_dominated(self.with_weather(None), 0, HEAT_WAVE, WEATHER_BALL))
        self.assertFalse(move_dominated(self.with_weather(Weather.RAINDANCE), 0, HEAT_WAVE, WEATHER_BALL))

    def test_umbrella_cancels_sun(self):
        b = copy.deepcopy(self.battle)
        b.active_pokemon[0]._item = "utilityumbrella"
        self.assertFalse(move_dominated(b, 0, HEAT_WAVE, WEATHER_BALL))

    def test_foe_could_change_weather(self):
        b = copy.deepcopy(self.battle)
        b.opponent_active_pokemon[0]._moves["raindance"] = Move("raindance", gen=9)
        self.assertFalse(move_dominated(b, 0, HEAT_WAVE, WEATHER_BALL))

    def test_only_clean_pairs(self):
        b = self.battle
        self.assertTrue(move_dominated(b, 0, Move("dazzlinggleam", gen=9), Move("moonblast", gen=9)))
        # Overheat drops SpA, Flamethrower is weaker, Snarl's SpA drop is the point of it.
        self.assertFalse(move_dominated(b, 0, HEAT_WAVE, Move("overheat", gen=9)))
        self.assertFalse(move_dominated(b, 0, HEAT_WAVE, Move("flamethrower", gen=9)))
        self.assertFalse(move_dominated(b, 0, Move("snarl", gen=9), Move("darkpulse", gen=9)))


if __name__ == "__main__":
    unittest.main()
