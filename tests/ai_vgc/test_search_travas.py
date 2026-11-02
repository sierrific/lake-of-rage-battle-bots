"""Search sees charged moves, Encore and field changes as they really are (2026-11-01 replay review
of PaiBrazVGC_Oficial: Nico67 G1, Yutok G2/G3, arrdamoin G1 T7, French1 G2).

Needs the patched Ai-vgc and its simulator, so it is not part of the CI run (and it stays out of
ai-vgc-lor.patch, see test_sim_bridge_pivot.py). Run it from the Ai-vgc checkout:

    cd /opt/lor-bots/ai-vgc
    PYTHONPATH=src .venv/bin/python -m unittest discover -s <this repo>/tests/ai_vgc

Fixture: the same position as test_sim_bridge_pivot.py (we are p2: Annihilape + Archaludon vs
Sylveon + Charizard, no weather), with the locks added by each test.
"""

import copy
import json
import unittest
from pathlib import Path

import numpy as np

from ai_vgc.nn.search import (Bridge, _charge_held, _field_choice, _locked_slot, _part,
                              _slot_options, opp_candidates)
from ai_vgc.nn.series import Context

BASE = json.loads((Path(__file__).parent / "fixtures" / "pivot_state.json").read_text())
SHOWDOWN = "pokemon-showdown-mc"
THEM = "move protect, move protect"


def state(**archaludon) -> dict:
    st = copy.deepcopy(BASE)
    st["sides"]["us"]["mons"][1].update(archaludon)
    return st


class TestLocksInBridge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bridge = Bridge(SHOWDOWN)

    @classmethod
    def tearDownClass(cls):
        cls.bridge.close()

    def test_charge_turn_is_held(self):
        # Out of rain Electro Shot only charges: the playout ends locked into firing it next turn.
        for r in self.bridge.run(state(), [("move icepunch 2, move electroshot 2", THEM)], [1, 2], keep=True):
            self.assertIn("|-prepare|p2b: Archaludon|Electro Shot", "\n".join(r["lines"]))
            self.assertTrue(_charge_held(r), r.get("next"))
        # Not a charge line: nothing held.
        r = self.bridge.run(state(), [("move icepunch 2, move dragonpulse 2", THEM)], [1], keep=True)[0]
        self.assertFalse(_charge_held(r))

    def test_charge_held_after_partner_faints(self):
        # Annihilape falls to Hyper Voice + Heat Wave: with fill, its replacement comes in and the
        # charged Archaludon still gets its firing turn scored.
        pair = [("move icepunch 2, move electroshot 2", "move hypervoice, move heatwave")]
        plain = self.bridge.run(state(), pair, [1], keep=True)[0]
        filled = self.bridge.run(state(), pair, [1], keep=True, fill=True)[0]
        self.assertIn("|faint|p2a: Annihilape", "\n".join(plain["lines"]))
        self.assertIsNone(plain.get("next"))
        self.assertTrue(_charge_held(filled), filled.get("next"))

    def test_charged_move_fires(self):
        # Charged last turn: it fires now (no second -prepare, no second +1).
        st = state(charging="electroshot", chargeLoc=2)
        for r in self.bridge.run(st, [("move icepunch 2, move electroshot 2", "move hypervoice, move heatwave")], [1, 2]):
            text = "\n".join(r["lines"])
            self.assertEqual(r["err"], "")
            self.assertNotIn("|-prepare|p2b: Archaludon", text)
            self.assertRegex(text, r"\|move\|p2b: Archaludon\|Electro Shot\|p1b: Charizard")

    def test_without_charge_state_it_charges_again(self):
        # What search did before: the same choice from a rebuilt position charges once more.
        r = self.bridge.run(state(), [("move icepunch 2, move electroshot 2", "move hypervoice, move heatwave")], [1])[0]
        self.assertIn("|-prepare|p2b: Archaludon|Electro Shot", "\n".join(r["lines"]))

    def test_encore_carries_over(self):
        st = state(encore=["flashcannon", 2])
        r = self.bridge.run(st, [("move icepunch 2, move flashcannon 1", THEM)], [1], keep=True)[0]
        self.assertEqual(r["err"], "")
        moves = r["next"]["request"]["active"][1]["moves"]
        usable = [m["id"] for m in moves if not m.get("disabled")]
        self.assertEqual(usable, ["flashcannon"])
        # A switch out is still legal under Encore.
        self.assertFalse(r["next"]["request"]["active"][1].get("trapped"))


class FakeMove:
    def __init__(self, id_):
        self.id = id_


class TestMaskAndOptions(unittest.TestCase):
    def test_locked_slot(self):
        mask = np.zeros((2, 107), bool)
        mask[0, [1, 2]] = True            # switches
        mask[0, [7, 8, 9]] = True         # one move, three targets
        mask[1, [12, 17]] = True          # two moves
        self.assertTrue(_locked_slot(mask, 0))
        self.assertFalse(_locked_slot(mask, 1))
        mask[0, [1, 2]] = False           # trapped (charged move): no way out to look for
        self.assertFalse(_locked_slot(mask, 0))

    def test_field_choice(self):
        st = copy.deepcopy(BASE)
        st["sides"]["them"]["mons"][2]["set"]["ability"] = "snowwarning"
        name = st["sides"]["them"]["mons"][2]["set"]["name"]
        self.assertTrue(_field_choice("move chillyreception", st))
        self.assertTrue(_field_choice(f"switch {name}", st))
        self.assertFalse(_field_choice("move hypervoice 1", st))
        self.assertFalse(_field_choice("switch Incineroar", st))
        self.assertEqual(_part("move heatwave mega, move protect", 0), "move heatwave")


SERIES_LOG = """|player|p1|Rival|
|player|p2|Bot|
|switch|p1a: Sylveon|Sylveon, L50|100/100
|switch|p1b: Charizard|Charizard, L50|100/100
|turn|1
|move|p1a: Sylveon|Yawn|p2a: Annihilape
|move|p1b: Charizard|Protect|p1b: Charizard
|turn|2
|move|p1a: Sylveon|Yawn|p2b: Archaludon
|win|Rival
"""


class FakeMon:
    def __init__(self, name, moves):
        self.name, self.fainted = name, False
        self.moves = {m: FakeMove(m) for m in moves}


class FakeBattle:
    def __init__(self, turn, series):
        self.turn = turn
        self._series = series
        self.opponent_active_pokemon = [FakeMon("Sylveon", ["hypervoice", "moonblast", "yawn", "protect"]),
                                        FakeMon("Charizard", ["heatwave", "weatherball", "ancientpower", "protect"])]


class TestSeriesMemory(unittest.TestCase):
    def probs(self):
        mv = np.array([0.7, 0.2, 0.05, 0.05, 0.0])      # Hyper Voice by far the likeliest
        tg = np.tile([0.5, 0.5, 0.0], (4, 1))
        return mv, tg

    def yawn(self, battle, series):
        opts = dict(_slot_options(battle, BASE, 0, self.probs(), series=series))
        return sum(p for c, p in opts.items() if c.startswith("move yawn"))

    def test_game_two_weights_last_games_moves(self):
        ctx = Context.of([SERIES_LOG], "Bot", "Rival")
        b = FakeBattle(1, ctx)
        self.assertAlmostEqual(self.yawn(b, 0.0), 0.05, places=3)
        self.assertGreater(self.yawn(b, 0.3), 0.3)

    def test_game_one_unchanged(self):
        b = FakeBattle(1, None)
        self.assertAlmostEqual(self.yawn(b, 0.3), 0.05, places=3)

    def test_encored_opponent_repeats(self):
        st = copy.deepcopy(BASE)
        st["sides"]["them"]["mons"][0]["encore"] = ["moonblast", 2]
        opts = dict(_slot_options(FakeBattle(3, None), st, 0, self.probs()))
        self.assertTrue(all(c.startswith("move moonblast") or c.startswith("switch") for c in opts), opts)

    def test_charging_opponent_fires(self):
        st = copy.deepcopy(BASE)
        st["sides"]["them"]["mons"][1].update(charging="weatherball", chargeLoc=2)
        self.assertEqual(_slot_options(FakeBattle(3, None), st, 1, self.probs()), [("move weatherball 2", 1.0)])


class TestFieldCandidates(unittest.TestCase):
    def test_weather_switch_always_played(self):
        st = copy.deepcopy(BASE)
        st["sides"]["them"]["mons"][3]["set"]["ability"] = "snowwarning"  # second in the back
        name = st["sides"]["them"]["mons"][3]["set"]["name"]
        b = FakeBattle(3, None)
        b.opponent_active_pokemon[0].moves = {m: FakeMove(m) for m in ["hypervoice", "moonblast", "yawn", "protect"]}
        b.opponent_active_pokemon[1].moves = {m: FakeMove(m) for m in ["heatwave", "weatherball", "ancientpower", "protect"]}

        def opp(field):
            import ai_vgc.nn.search as s
            orig = s._slot_options
            mv = np.array([0.6, 0.2, 0.05, 0.05, 0.1])
            tg = np.tile([0.5, 0.5, 0.0], (4, 1))
            s._slot_options = lambda battle, state, slot, probs, *a: orig(battle, state, slot, (mv, tg), *a)
            try:
                b.opponent_active_pokemon[0].species = b.opponent_active_pokemon[1].species = "x"
                st["sides"]["them"]["megaUsed"] = True
                return opp_candidates(None, b, {}, st, 6, field)
            finally:
                s._slot_options = orig
        self.assertFalse(any(f"switch {name}" in c for c, _ in opp(False)))
        self.assertTrue(any(f"switch {name}" in c for c, _ in opp(True)))


if __name__ == "__main__":
    unittest.main()
