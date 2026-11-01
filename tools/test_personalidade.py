"""Perfis e integração com relógio virtual; sem rede, modelos ou partidas reais."""
import ast
import asyncio
import importlib.util
import os
from pathlib import Path
import random
import re
import sys
import tempfile
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

player_path = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('lor_personality', player_path.with_name('personality.py'))
personality = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = personality
spec.loader.exec_module(personality)
source = ast.parse(player_path.read_text())
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == 'ChallengeMixin')
names = {'_pace_decision', '_track_decision_clock', '_chat_on', '_say_personality',
         '_handle_chat_restriction', 'teampreview', 'choose_move', '_ladder_pause'}
methods = [n for n in mixin.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
assert len(methods) == len(names)


class TestProfiles(unittest.TestCase):
    def test_conta_normalizada_mantem_perfil_e_avatar(self):
        for account in ('MadMageofMtBaratok', 'Ynokmon', 'Voltbot99', 'the bugcather'):
            first = personality.profile_for(account)
            self.assertEqual(first, personality.profile_for(account.upper() + ' !'))
            self.assertEqual(first, personality.profile_for(account))
        self.assertEqual(len({personality.profile_for(f'Conta{i}').key for i in range(100)}), 5)

    def test_selecao_explicita_classico_e_invalida(self):
        self.assertIsNone(personality.profile_for('Bot', 'classico'))
        for profile in personality.PROFILES:
            self.assertIs(personality.profile_for('Bot', profile.key), profile)
        with self.assertRaisesRegex(ValueError, 'personalidade inválida'):
            personality.profile_for('Bot', 'inexistente')

    def test_saudacoes_identificam_bot_e_nao_repetem(self):
        for profile in personality.PROFILES:
            p = personality.Personality(profile, random.Random(7))
            for event in ('start', 'end'):
                phrases = [p.phrase(event) for _ in range(50)]
                self.assertGreater(len(set(phrases)), 1)
                self.assertTrue(all(a != b for a, b in zip(phrases, phrases[1:])))
                for phrase in phrases:
                    self.assertLess(len(phrase), 120)
                    self.assertNotIn('\n', phrase)
                    self.assertFalse(phrase.startswith('/'))
                    if event == 'start':
                        self.assertIn('bot', phrase.lower())

    def test_intervalos_variaveis_preview_e_trocas_forcadas(self):
        for profile in personality.PROFILES:
            p = personality.Personality(profile, random.Random(42))
            for kwargs, limits in (({}, profile.move), ({'preview': True}, profile.preview),
                                   ({'forced': True}, (4, 10, 6))):
                samples = [p.decision_seconds(**kwargs) for _ in range(100)]
                self.assertTrue(all(limits[0] <= s <= limits[1] for s in samples))
                self.assertGreater(len(set(samples)), 90)
            self.assertTrue(all(60 <= p.pause_seconds() <= 300 for _ in range(100)))

    def test_personalidade_nao_consume_aleatoriedade_da_ia(self):
        state = random.getstate()
        p = personality.Personality(personality.PROFILES[0])
        p.decision_seconds()
        p.pause_seconds()
        p.phrase('start')
        self.assertEqual(random.getstate(), state)


class Engine:
    async def teampreview(self, battle):
        self.clock[0] += self.compute
        return '/team 1234'

    async def choose_move(self, battle):
        self.clock[0] += self.compute
        return self.order


class TestIntegration(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.flag = Path(tmp.name) / 'rapido'
        self.chat_flag = Path(tmp.name) / 'sem-chat'
        env = patch.dict(os.environ, LOR_FAST_DECISIONS_FILE=str(self.flag))
        env.start()
        self.addCleanup(env.stop)
        self.clock = [1000.0]
        self.on_sleep = lambda: None

        async def sleep(seconds):
            self.clock[0] += seconds
            self.on_sleep()
            await asyncio.sleep(0)

        ns = {'Engine': Engine, 'AbstractBattle': object, 'os': os, 're': re,
              'time': types.SimpleNamespace(monotonic=lambda: self.clock[0], time=lambda: self.clock[0]),
              'asyncio': types.SimpleNamespace(sleep=AsyncMock(side_effect=sleep)),
              'random': random, 'to_id_str': lambda s: re.sub(r'[^a-z0-9]', '', s.lower())}
        cls = ast.parse('class Bot(Engine): pass').body[0]
        cls.body = methods
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls], type_ignores=[])), 'player.py', 'exec'), ns)
        self.bot = ns['Bot']()
        self.bot.clock, self.bot.compute = self.clock, 2
        self.bot.username = 'ContaTeste'
        self.bot.order = object()
        self.bot.personality = personality.Personality(personality.profile_for('ContaTeste', 'analitico'), random.Random(9))
        self.bot.chat, self.bot.chat_off, self.bot.timer = True, self.chat_flag, False
        self.bot.stop_after_match = False
        self.bot.ps_client = types.SimpleNamespace(send_message=AsyncMock())
        self.bot.logger = Mock()
        self.bot._placar = Mock()
        self.battle = types.SimpleNamespace(battle_tag='battle-test', teampreview=False,
                                           force_switch=[False, False], finished=False)

    async def test_jogada_e_time_preservados_com_ritmo_do_perfil(self):
        for preview, forced, low, high in ((False, False, 13, 26), (True, False, 23, 40), (False, True, 4, 10)):
            self.battle.teampreview = preview
            self.battle.force_switch = [forced, False]
            start = self.clock[0]
            result = await (self.bot.teampreview(self.battle) if preview else self.bot.choose_move(self.battle))
            self.assertEqual(result, '/team 1234' if preview else self.bot.order)
            self.assertGreaterEqual(self.clock[0] - start, low)
            self.assertLessEqual(self.clock[0] - start, high)

    async def test_instantaneas_interrompem_a_espera(self):
        self.on_sleep = self.flag.touch
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1002.5)
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1004.5)

    async def test_sem_flag_de_configuracao_nao_acrescenta_espera(self):
        os.environ.pop('LOR_FAST_DECISIONS_FILE')
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1002)

    async def test_calculo_mais_longo_que_alvo_nao_espera(self):
        self.bot.compute = 45
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1045)

    async def test_total_menor_que_tempo_do_turno_limita_espera(self):
        self.bot._track_decision_clock('>battle-test\n|inactive|Time left: 45 sec this turn | 9 sec total')
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1004)

    async def test_alerta_durante_preview_limita_espera(self):
        self.battle.teampreview = True
        self.on_sleep = lambda: self.bot._track_decision_clock('>battle-test\n|inactive|ContaTeste has 6 seconds left.')
        await self.bot.teampreview(self.battle)
        self.assertEqual(self.clock[0], 1003.5)

    async def test_reenvio_de_escolha_nao_recebe_espera(self):
        self.bot._decision_retries = {'battle-test'}
        await self.bot.choose_move(self.battle)
        self.assertEqual(self.clock[0], 1002)

    async def test_abertura_so_no_jogo_um_e_uma_vez_por_sala(self):
        self.battle.teampreview = True
        for game in (1, 1, 2, 3):
            self.battle.battle_tag = f'battle-test-{game}'
            self.bot.series_of = {self.battle.battle_tag: ('series-test', game)}
            await self.bot.teampreview(self.battle)
        sent = self.bot.ps_client.send_message.await_args_list
        self.assertEqual(len(sent), 1)
        self.assertIn('bot', sent[0].args[0].lower())
        self.assertEqual(sent[0].args[1], 'battle-test-1')

    async def test_encerramento_e_deduplicado_mas_outro_jogo_pode_falar(self):
        self.assertTrue(await self.bot._say_personality('end', 'battle-1'))
        self.assertFalse(await self.bot._say_personality('end', 'battle-1'))
        self.assertTrue(await self.bot._say_personality('end', 'battle-2'))
        sent = self.bot.ps_client.send_message.await_args_list
        self.assertNotEqual(sent[0].args[0], sent[1].args[0])

    async def test_chat_desligado_ou_restrito_nunca_envia(self):
        self.chat_flag.touch()
        self.assertFalse(await self.bot._say_personality('start', 'battle-1'))
        self.chat_flag.unlink()
        self.bot._handle_chat_restriction(['', 'error', "Due to spam from your internet provider, you can't speak except to staff."])
        self.assertFalse(await self.bot._say_personality('end', 'battle-1'))
        self.bot.ps_client.send_message.assert_not_awaited()

    async def test_historico_de_chat_tem_limite(self):
        for i in range(300):
            await self.bot._say_personality('end', f'battle-{i}')
        self.assertLessEqual(len(self.bot._personality_chat_sent), 128)

    async def test_pausa_de_ladder_respeita_parada(self):
        self.bot.stop_after_match = True
        await self.bot._ladder_pause()
        self.assertEqual(self.clock[0], 1000)
        self.bot.stop_after_match = False
        self.on_sleep = lambda: setattr(self.bot, 'stop_after_match', True)
        await self.bot._ladder_pause()
        self.assertEqual(self.clock[0], 1001)


if __name__ == '__main__':
    unittest.main()
