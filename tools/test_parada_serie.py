"""Parada entre jogos/séries, com callbacks reais do patch e relógio virtual."""
import ast
import asyncio
from collections import Counter
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import AsyncMock, Mock

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding='utf-8'))
nn = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == 'NNPlayer')
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == 'ChallengeMixin')
nn_callback = next(n for n in nn.body if isinstance(n, ast.FunctionDef) and n.name == '_battle_finished_callback')
names = {'_busy', '_ladder', '_battle_finished_callback', '_cycle'}
methods = [n for n in mixin.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
assert len(methods) == len(names)


class TestSeriesStop(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.clock = [1000.0]
        self.on_sleep = lambda: None

        async def sleep(seconds):
            self.clock[0] += seconds
            self.on_sleep()
            await asyncio.sleep(0)

        ns = {'Counter': Counter, 'AbstractBattle': object,
              'time': types.SimpleNamespace(time=lambda: self.clock[0], monotonic=lambda: self.clock[0]),
              'asyncio': types.SimpleNamespace(sleep=AsyncMock(side_effect=sleep)),
              'summarize': lambda log: types.SimpleNamespace(winner=log.removeprefix('|win|'))}
        engine = ast.parse('class Engine: pass').body[0]
        engine.body = [nn_callback]
        cls = ast.parse('class Bot(Engine): pass').body[0]
        cls.body = methods
        exec(compile(ast.fix_missing_locations(ast.Module(body=[engine, cls], type_ignores=[])),
                     'player.py', 'exec'), ns)
        self.bot = ns['Bot']()
        self.bot.MAX_CYCLES = 300
        self.bot._battles = {}
        self.bot.series_of, self.bot.series_logs = {}, {}
        self.bot.leads, self.bot.steps, self.bot.games = {}, {}, []
        self.bot.record, self.bot.save_dir = False, None
        self.bot._placar = Mock()
        self.bot.stop_after_match = True
        self.bot.ps_client = types.SimpleNamespace(logged_in=types.SimpleNamespace(wait=AsyncMock()))

    def finish(self, tag, series=None, game=1, winner='Bot'):
        battle = types.SimpleNamespace(battle_tag=tag, finished=True, won=winner == 'Bot',
                                       lost=winner == 'Rival', opponent_team={},
                                       _build_replay_log=lambda: '|win|' + winner)
        self.bot._battles[tag] = battle
        if series:
            self.bot.series_of[tag] = (series, game)
        self.bot._battle_finished_callback(battle)

    def abandoned_then_two_zero(self):
        self.finish('battle-old-1', 'game-bestof3-old')
        self.clock[0] += 130
        self.finish('battle-new-1', 'game-bestof3-new')
        self.clock[0] += 60
        self.finish('battle-new-2', 'game-bestof3-new', 2)

    def test_serie_antiga_nao_renova_espera_depois_de_dois_a_zero(self):
        self.abandoned_then_two_zero()
        self.assertFalse(self.bot._busy(), 'um 2:0 novo reativou a espera da série antiga')

    async def test_ladder_para_apos_dois_a_zero_sem_dois_minutos_extras(self):
        self.abandoned_then_two_zero()
        start = self.clock[0]
        await self.bot._ladder(10)
        self.assertEqual(self.clock[0] - start, 0)

    def test_bo1_nao_renova_espera_de_serie_antiga(self):
        self.finish('battle-old-1', 'game-bestof3-old')
        self.clock[0] += 130
        self.finish('battle-bo1')
        self.assertFalse(self.bot._busy())

    def test_jogo_um_e_placar_um_a_um_continuam_ocupados(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.assertTrue(self.bot._busy())
        self.clock[0] += 90
        self.finish('battle-new-2', 'game-bestof3-new', 2, 'Rival')
        self.clock[0] += 90
        self.assertTrue(self.bot._busy())

    def test_dois_a_um_e_derrota_encerram_sem_espera(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.finish('battle-new-2', 'game-bestof3-new', 2, 'Rival')
        self.finish('battle-new-3', 'game-bestof3-new', 3, 'Rival')
        self.assertFalse(self.bot._busy())

    def test_serie_abandonada_ainda_tem_prazo_para_proximo_jogo(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.clock[0] += 119
        self.assertTrue(self.bot._busy())
        self.clock[0] += 1
        self.assertFalse(self.bot._busy())
        self.assertIn('game-bestof3-new', self.bot.series_logs)  # preserva contexto para retomada tardia

    def test_retomada_tardia_renova_so_o_prazo_da_propria_serie(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.clock[0] += 130
        self.assertFalse(self.bot._busy())
        self.finish('battle-new-2', 'game-bestof3-new', 2, 'Rival')
        self.assertTrue(self.bot._busy())
        self.assertEqual(len(self.bot.series_logs['game-bestof3-new']), 2)
        self.finish('battle-new-3', 'game-bestof3-new', 3)
        self.assertFalse(self.bot._busy())

    def test_finalizar_uma_serie_nao_apaga_espera_valida_de_outra(self):
        self.finish('battle-a-1', 'game-bestof3-a')
        self.clock[0] += 10
        self.finish('battle-b-1', 'game-bestof3-b')
        self.finish('battle-b-2', 'game-bestof3-b', 2)
        self.assertTrue(self.bot._busy())
        self.clock[0] = 1120
        self.assertFalse(self.bot._busy())

    def test_partida_ativa_nao_e_interrompida_pelo_prazo_entre_jogos(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.bot._battles['battle-new-2'] = types.SimpleNamespace(finished=False)
        self.clock[0] += 600
        self.assertTrue(self.bot._busy())

    async def test_pedido_de_parada_entre_jogos_termina_a_serie(self):
        self.finish('battle-new-1', 'game-bestof3-new')
        self.on_sleep = lambda: self.finish('battle-new-2', 'game-bestof3-new', 2)
        await self.bot._ladder(10)
        self.assertEqual(self.clock[0], 1001)
        self.assertEqual(len(self.bot.games), 2)


if __name__ == '__main__':
    unittest.main()
