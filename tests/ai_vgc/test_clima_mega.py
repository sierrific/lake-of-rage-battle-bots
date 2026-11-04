"""Cases from the 2026-11-04 review of the bots' lost series (S1-S10): how many turns of weather the
search simulates and which opposing Mega Evolutions it expects.

Run it like test_casos_replays.py, from the Ai-vgc checkout (it needs the patched search.py):

    cd /opt/lor-bots/ai-vgc
    PYTHONPATH=src .venv/bin/python -m unittest discover -s <this repo>/tests/ai_vgc
"""

import unittest
from types import SimpleNamespace

from poke_env.battle import Weather

from ai_vgc.nn.search import opp_candidates, position, weather_left
from test_casos_replays import at_turn

ID = "2709194980"  # S1 G3 (the bugcather, p2): Pelipper with Damp Rock brings rain on turn 2
TEAMS = "data/teams/reg_mc"
FMT = "gen9championsvgc2026regmcbo3"


def mon(item):
    return SimpleNamespace(item=item)


def battle(turn, lines, us=None, them=None):
    return SimpleNamespace(turn=turn, player_role="p1", team=us or {}, opponent_team=them or {},
                           _replay_data=[["", *ln.split("|")] for ln in lines])


class TestWeatherLeft(unittest.TestCase):
    def test_rock_from_the_log(self):
        # Damp Rock on the setter: 8 turns from turn 2, when it came in, whatever the upkeep lines say.
        b = at_turn(ID, "p2", 5)
        self.assertEqual(weather_left(b, Weather.RAINDANCE), 5)

    def test_five_turns_without_rock(self):
        b = battle(3, ["-weather|RainDance|[from] ability: Drizzle|[of] p2a: Pelipper", "turn|1",
                       "-weather|RainDance|[upkeep]", "turn|2", "-weather|RainDance|[upkeep]", "turn|3"],
                   them={"p2: Pelipper": mon("sitrusberry")})
        self.assertEqual(weather_left(b, Weather.RAINDANCE), 3)

    def test_coming_back_does_not_renew(self):
        # S4 G3 T8: rain since before turn 1 with Damp Rock; a switch-in on turn 8 sets nothing.
        lines = ["-weather|RainDance|[from] ability: Drizzle|[of] p1a: Pelipper", "turn|1"]
        for t in range(2, 9):
            lines += ["-weather|RainDance|[upkeep]", f"turn|{t}"]
        b = battle(8, lines, us={"p1: Pelipper": mon("damprock")})
        self.assertEqual(weather_left(b, Weather.RAINDANCE), 1)

    def test_new_rain_after_it_ended(self):
        # The control: entering after the rain ended sets a new one, 8 turns from then.
        lines = ["-weather|RainDance|[from] ability: Drizzle|[of] p1a: Pelipper", "turn|1", "-weather|none", "turn|9",
                 "-weather|RainDance|[from] ability: Drizzle|[of] p1a: Pelipper", "turn|10"]
        b = battle(10, lines, us={"p1: Pelipper": mon("damprock")})
        self.assertEqual(weather_left(b, Weather.RAINDANCE), 7)

    def test_move_set_weather_uses_the_mover(self):
        b = battle(2, ["move|p1a: Pelipper|Rain Dance|p1a: Pelipper", "-weather|RainDance", "turn|2"],
                   us={"p1: Pelipper": mon("damprock")})
        # Set during turn 1, which counts: 7 left at the start of turn 2.
        self.assertEqual(weather_left(b, Weather.RAINDANCE), 7)


class TestOpposingMega(unittest.TestCase):
    def choices(self, turn):
        b = at_turn(ID, "p2", turn)
        return opp_candidates(None, b, {}, position(b, FMT, TEAMS), 200)

    def test_stone_whose_name_does_not_end_in_ite(self):
        # S1 G3 T5: Charizard holds Charizardite Y, whose Mega brings the sun.
        self.assertTrue(any(" mega" in c for c, _ in self.choices(5)))

    def test_no_mega_once_used(self):
        # T6: it already Mega Evolved (the sun is up).
        self.assertFalse(any(" mega" in c for c, _ in self.choices(6)))


if __name__ == "__main__":
    unittest.main()
