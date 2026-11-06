"""Uma série Bo3 por vez: a espera entre jogos cobre um jogo seguinte que demora minutos, e o time gravado
é o da própria batalha. Sem contas, rede ou PyTorch.

Caso real (2026-11-05): o G1 contra um oponente acabou ~00:09 e o G2 só começou 00:15:36. Com a espera
antiga de 2 minutos o bot buscou outra partida, jogou duas séries ao mesmo tempo, chegou a 5 s no
relógio e gravou o time do último sorteio nos jogos da outra série."""
import ast
import re
import sys
import types
import unittest
from pathlib import Path


def to_id_str(s: str) -> str:
    """O mesmo de poke_env.data.to_id_str (a CI roda sem poke_env)."""
    return re.sub(r"[^a-z0-9]", "", s.lower())


source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
pick = [n for n in mixin.body if (isinstance(n, ast.FunctionDef) and n.name in ("_busy", "_team_of"))
        or (isinstance(n, ast.Assign) and any(getattr(t, "id", "") == "SERIES_WAIT" for t in n.targets))]
assert len(pick) == 3, [getattr(n, "name", "SERIES_WAIT") for n in pick]
clock = types.SimpleNamespace(now=0.0)
ns = {"time": types.SimpleNamespace(monotonic=lambda: clock.now), "to_id_str": to_id_str, "AbstractBattle": object}
cls = ast.ClassDef(name="Bot", bases=[], keywords=[], body=pick, decorator_list=[], type_params=[])
exec(compile(ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[])), "player.py", "exec"), ns)
Bot = ns["Bot"]


def packed(*species):
    return "]".join(f"{s}||Leftovers|Ability|Protect||||||50|" for s in species)


MC371 = ("Pelipper", "Archaludon", "Basculegion", "Golisopod", "Salamence", "Sneasler")
MC196 = ("Pelipper", "Incineroar", "Rillaboom", "Archaludon", "Annihilape", "Golisopod")


class TestSerieUnica(unittest.TestCase):
    def setUp(self):
        clock.now = 0.0
        self.bot = Bot()
        self.bot._battles = {}
        self.bot.series_logs = {}

    def fim_de_jogo(self, series, acabou=False):
        # O que _battle_finished_callback faz com a espera.
        waits = self.bot.__dict__.setdefault("_series_wait_until", {})
        if acabou:
            self.bot.series_logs.pop(series, None)
            waits.pop(series, None)
        else:
            self.bot.series_logs.setdefault(series, []).append("log")
            waits[series] = clock.now + self.bot.SERIES_WAIT

    def test_g2_que_demora_seis_minutos_nao_abre_outra_serie(self):
        self.fim_de_jogo("game-bestof3-a")          # G1 acaba ~00:09
        for minutos in (2, 4, 6.5):                 # o G2 só começou 00:15:36
            clock.now = minutos * 60
            self.assertTrue(self.bot._busy(), f"buscou outra partida aos {minutos} min")

    def test_teto_seguro(self):
        self.fim_de_jogo("game-bestof3-a")
        clock.now = self.bot.SERIES_WAIT + 1
        self.assertFalse(self.bot._busy())

    def test_serie_terminada_libera_na_hora(self):
        self.fim_de_jogo("game-bestof3-a")
        clock.now = 30
        self.fim_de_jogo("game-bestof3-a", acabou=True)
        self.assertFalse(self.bot._busy())

    def test_batalha_em_andamento(self):
        self.bot._battles = {"x": types.SimpleNamespace(finished=False)}
        self.assertTrue(self.bot._busy())

    def batalha(self, *species):
        return types.SimpleNamespace(team={f"p1: {s}": types.SimpleNamespace(species=to_id_str(s)) for s in species})

    def pool(self, last):
        return types.SimpleNamespace(_names=["MC371", "MC196"], _teams=[packed(*MC371), packed(*MC196)], last_name=last)

    def test_time_vem_da_batalha_nao_do_ultimo_sorteio(self):
        self.bot._team = self.pool("MC371")
        self.assertEqual(self.bot._team_of(self.batalha(*MC196)), "MC196")
        self.bot._team = self.pool("MC196")
        self.assertEqual(self.bot._team_of(self.batalha(*MC371)), "MC371")

    def test_forma_mega_conta_como_a_base(self):
        self.bot._team = self.pool("MC196")
        mega = ("Pelipper", "Archaludon", "Basculegion", "Golisopod-Mega", "Salamence-Mega", "Sneasler")
        self.assertEqual(self.bot._team_of(self.batalha(*mega)), "MC371")

    def test_sem_correspondencia_usa_o_sorteio(self):
        self.bot._team = self.pool("MC371")
        self.assertEqual(self.bot._team_of(self.batalha("Pikachu", "Eevee", "Ditto", "Mew")), "MC371")
        self.bot._team = types.SimpleNamespace(last_name="LOR-X")
        self.assertEqual(self.bot._team_of(self.batalha(*MC371)), "LOR-X")


if __name__ == "__main__":
    unittest.main()
