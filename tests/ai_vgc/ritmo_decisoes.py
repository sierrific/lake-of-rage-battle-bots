"""Ritmo de decisões do patch, com relógio virtual, sem contas nem conexão ao Showdown."""
import ast
import asyncio
import json
import os
import re
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
names = {"_cycle", "_handle_battle_request", "_track_decision_clock", "_pace_decision",
         "_chat_on", "_say_personality", "teampreview", "choose_move"}
members = [n for n in mixin.body if (
    isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names
) or (isinstance(n, ast.Assign) and isinstance(n.targets[0], ast.Name) and n.targets[0].id == "MAX_CYCLES")]
assert len(members) == len(names) + 1
login = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == "_public_login")


class Engine:
    async def choose_move(self, battle):
        self.clock[0] += self.compute_seconds
        return self.order

    async def teampreview(self, battle):
        self.clock[0] += self.compute_seconds
        return "/team 1234"

    async def _handle_battle_request(self, battle, maybe_default_order=False):
        if battle._wait:
            return
        choice = await self.teampreview(battle) if battle.teampreview else await self.choose_move(battle)
        self.sent.append((self.clock[0], choice))


class TestDecisionPacing(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.flag = Path(tmp.name) / "bot.decisoes-rapidas"
        env = patch.dict(os.environ, LOR_FAST_DECISIONS_FILE=str(self.flag))
        env.start()
        self.addCleanup(env.stop)
        self.clock = [1000.0]
        self.on_sleep = lambda: None

        async def sleep(seconds):
            self.clock[0] += seconds
            self.on_sleep()
            await asyncio.sleep(0)

        self.sleep = AsyncMock(side_effect=sleep)
        self.uniform = Mock(return_value=15.0)
        self.ns = {"os": os, "re": re, "json": json, "Player": object,
                   "time": types.SimpleNamespace(monotonic=lambda: self.clock[0]),
                   "random": types.SimpleNamespace(uniform=self.uniform),
                   "asyncio": types.SimpleNamespace(sleep=self.sleep),
                   "AbstractBattle": object, "Engine": Engine,
                   "to_id_str": lambda s: re.sub(r"[^a-z0-9]", "", s.lower())}
        cls = ast.parse("class Bot(Engine): pass").body[0]
        cls.body = members
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls, login], type_ignores=[])),
                     "player.py", "exec"), self.ns)
        self.bot = self.ns["Bot"]()
        self.bot.clock = self.clock
        self.bot.compute_seconds = 2
        self.bot.username = "ContaTeste"
        self.bot.order = types.SimpleNamespace(message="/choose move 1, move 2")
        self.bot.sent = []
        self.bot.chat = self.bot.timer = False
        self.bot._placar = Mock()
        self.battle = types.SimpleNamespace(battle_tag="battle-test-1", finished=False,
                                           teampreview=False, _wait=False)

    async def test_nao_completa_total_de_10_a_20_segundos_sem_mudar_escolha(self):
        for preview in (True, False):
            for target in (10.0, 15.0, 20.0):
                self.battle.teampreview = preview
                self.uniform.return_value = target
                started = self.clock[0]
                await self.bot._handle_battle_request(self.battle)
                self.assertEqual(self.bot.sent[-1][0] - started, target)
                self.assertEqual(self.bot.sent[-1][1], "/team 1234" if preview else self.bot.order)
        self.uniform.assert_called_with(10, 20)

    async def test_sim_envia_assim_que_calcula(self):
        self.flag.touch()
        for preview in (True, False):
            self.battle.teampreview = preview
            started = self.clock[0]
            await self.bot._handle_battle_request(self.battle)
            self.assertEqual(self.bot.sent[-1][0] - started, 2)
        self.sleep.assert_not_awaited()

    async def test_sim_durante_espera_envia_em_ate_meio_segundo(self):
        self.on_sleep = self.flag.touch
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1002.5)

    async def test_voltar_a_nao_passa_a_valer_na_proxima_escolha(self):
        self.flag.touch()
        await self.bot._handle_battle_request(self.battle)
        self.flag.unlink()
        started = self.clock[0]
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0] - started, 15)

    async def test_calculo_lento_nao_recebe_mais_espera(self):
        self.bot.compute_seconds = 23
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1023)
        self.sleep.assert_not_awaited()

    async def test_preview_em_cada_jogo_do_bo3_tem_intervalo_proprio(self):
        self.battle.teampreview = True
        for game in range(1, 4):
            self.battle.battle_tag = f"battle-series-{game}"
            started = self.clock[0]
            await self.bot._handle_battle_request(self.battle)
            self.assertEqual(self.bot.sent[-1][0] - started, 15)

    async def test_correcao_de_jogada_nao_repete_espera(self):
        await self.bot._handle_battle_request(self.battle)
        started = self.clock[0]
        await self.bot._handle_battle_request(self.battle, maybe_default_order=True)
        self.assertEqual(self.bot.sent[-1][0] - started, 2)
        self.assertFalse(self.bot._decision_retries)
        started = self.clock[0]
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0] - started, 15)

    async def test_wait_nao_calcula_nem_espera(self):
        self.battle._wait = True
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent, [])
        self.sleep.assert_not_awaited()

    async def test_tempos_registrados_incluem_espera(self):
        await self.bot._handle_battle_request(self.battle)
        self.clock[0] += 3  # adversário termina três segundos depois
        await self.bot._handle_battle_request(self.battle)
        cycle = self.bot._tempos[self.battle.battle_tag]
        self.assertEqual(cycle["cycles"], [[18.0, 15.0]])

    async def test_relogio_privado_limita_espera_com_margem(self):
        self.bot._track_decision_clock(">battle-test-1\n|inactive|Time left: 12 sec this turn | 75 sec total")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1007)

    async def test_pouco_tempo_envia_sem_espera_adicional(self):
        self.bot._track_decision_clock(">battle-test-1\n|inactive|Conta Teste has 5 seconds left.")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1002)
        self.sleep.assert_not_awaited()

    async def test_aviso_de_relogio_durante_espera_e_lido(self):
        self.on_sleep = lambda: self.bot._track_decision_clock(
            ">battle-test-1\n|inactive|ContaTeste has 6 seconds left this turn.")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1003.5)

    async def test_relogio_do_adversario_chat_e_outra_sala_nao_limitam(self):
        for message in (
            ">battle-test-1\n|tier|[Gen 9] VGC",
            ">battle-test-1\n|inactive|Rival has 5 seconds left.",
            ">battle-test-1\n|c|Rival|Time left: 5 sec this turn | 5 sec total",
            ">battle-other\n|inactive|Time left: 5 sec this turn | 5 sec total",
        ):
            self.bot._track_decision_clock(message)
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1015)

    async def test_fim_da_partida_durante_espera_nao_aguarda_o_intervalo(self):
        self.on_sleep = lambda: self.bot._track_decision_clock(">battle-test-1\n|tie")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1002.5)

    async def test_novo_pedido_limpa_relogio_anterior(self):
        self.bot._track_decision_clock(">battle-test-1\n|inactive|ContaTeste has 5 seconds left.")
        self.bot._track_decision_clock('>battle-test-1\n|request|{"active":[]}')
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1015)

    async def test_timer_desligado_limpa_prazo(self):
        self.bot._track_decision_clock(">battle-test-1\n|inactive|ContaTeste has 5 seconds left.")
        self.bot._track_decision_clock(">battle-test-1\n|inactiveoff|Battle timer is now OFF.")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1015)

    async def test_sem_configuracao_mantem_ferramentas_de_avaliacao_rapidas(self):
        os.environ.pop("LOR_FAST_DECISIONS_FILE")
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.sent[-1][0], 1002)
        self.sleep.assert_not_awaited()

    async def test_relogio_chega_antes_da_trava_da_sala_no_cliente(self):
        lock, entered, release = asyncio.Lock(), asyncio.Event(), asyncio.Event()
        forwarded = []
        async def receive(message):
            async with lock:
                entered.set()
                await release.wait()
                forwarded.append(message)
        client = types.SimpleNamespace(_handle_message=receive, search_ladder_game=AsyncMock(),
                                       account_configuration=types.SimpleNamespace(username="ContaTeste"))
        self.bot.ps_client = client
        self.ns["asyncio"] = asyncio
        with patch.dict(sys.modules, requests=types.SimpleNamespace()):
            self.ns["_public_login"](self.bot, None)
        request = '>battle-test-1\n|request|{"active":[]}'
        warning = ">battle-test-1\n|inactive|Time left: 6 sec this turn | 6 sec total"
        first = asyncio.create_task(client._handle_message(request))
        await entered.wait()
        second = asyncio.create_task(client._handle_message(warning))
        await asyncio.sleep(0)
        self.assertFalse(first.done())
        self.assertFalse(second.done())
        self.assertEqual(self.bot._decision_clocks["battle-test-1"], 1006)
        release.set()
        await asyncio.gather(first, second)
        self.assertEqual(forwarded, [request, warning])


if __name__ == "__main__":
    unittest.main()
