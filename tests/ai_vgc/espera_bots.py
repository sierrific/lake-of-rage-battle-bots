"""Exercita a espera e o fluxo de ladder do patch sem contas, rede ou PyTorch."""
import ast
import asyncio
import contextlib
import io
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
methods = [n for n in mixin.body if isinstance(n, ast.AsyncFunctionDef)
           and n.name in ("_wait_for_busy_bots", "_ladder")]
assert len(methods) == 2


class TestKnownBotWait(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.flag = Path(tmp.name) / "bot.sem-espera-bots"
        env = patch.dict(os.environ, LOR_SKIP_BOT_WAIT_FILE=str(self.flag))
        env.start()
        self.addCleanup(env.stop)
        self.elapsed = 0
        self.on_sleep = lambda: None

        async def sleep(seconds):
            self.elapsed += seconds
            self.on_sleep()

        self.sleep = AsyncMock(side_effect=sleep)
        ns = {"os": os, "time": types.SimpleNamespace(time=lambda: self.elapsed),
              "asyncio": types.SimpleNamespace(sleep=self.sleep, create_task=asyncio.create_task,
                                               gather=asyncio.gather)}
        for method in methods:
            exec(compile(ast.Module(body=[method], type_ignores=[]), "player.py", "exec"), ns)
        bot_class = type("Bot", (), {m.name: ns[m.name] for m in methods})
        self.bot = bot_class()
        self.bot.stop_after_match = False
        self.bot._can_search = lambda: not self.bot.stop_after_match
        self.bot.BOT_WAIT = 60
        self.bot._known_bots = Mock(return_value=["rival"])
        self.bot._idle_bots = AsyncMock(return_value=["rival"])
        self.output = io.StringIO()
        stdout = contextlib.redirect_stdout(self.output)
        stdout.__enter__()
        self.addCleanup(stdout.__exit__, None, None, None)

    async def test_padrao_espera_adversario_entrar_em_partida(self):
        self.bot._idle_bots.side_effect = [["rival"], []]
        await self.bot._wait_for_busy_bots()
        self.assertEqual(self.elapsed, 30)
        self.assertEqual(self.bot._idle_bots.await_count, 2)

    async def test_desligado_pula_consultas_e_espera(self):
        self.flag.touch()
        await self.bot._wait_for_busy_bots()
        self.bot._known_bots.assert_not_called()
        self.bot._idle_bots.assert_not_awaited()
        self.sleep.assert_not_awaited()

    async def test_desligar_durante_espera_libera_em_um_segundo(self):
        self.on_sleep = self.flag.touch
        await self.bot._wait_for_busy_bots()
        self.assertEqual(self.elapsed, 1)
        self.bot._idle_bots.assert_awaited_once()
        self.assertIn("known bots wait disabled: searching now", self.output.getvalue())

    async def test_desligar_durante_consulta_nao_entra_na_espera(self):
        async def query(_):
            self.flag.touch()
            return ["rival"]
        self.bot._idle_bots.side_effect = query
        await self.bot._wait_for_busy_bots()
        self.sleep.assert_not_awaited()
        self.assertIn("known bots wait disabled", self.output.getvalue())

    async def test_religar_vale_na_proxima_busca(self):
        self.flag.touch()
        await self.bot._wait_for_busy_bots()
        self.flag.unlink()
        self.bot._idle_bots.side_effect = [["rival"], []]
        await self.bot._wait_for_busy_bots()
        self.assertEqual(self.elapsed, 30)

    async def test_limite_de_espera_preservado(self):
        await self.bot._wait_for_busy_bots()
        self.assertEqual(self.elapsed, self.bot.BOT_WAIT)
        self.assertIn("searching anyway", self.output.getvalue())

    async def test_pedido_de_parada_interrompe_a_espera(self):
        self.on_sleep = lambda: setattr(self.bot, "stop_after_match", True)
        await self.bot._wait_for_busy_bots()
        self.assertEqual(self.elapsed, 1)
        self.assertNotIn("searching now", self.output.getvalue())

    async def test_desligado_preserva_fila_do_time_e_pausa_entre_partidas(self):
        self.flag.touch()
        events = []
        async def turn():
            events.append("team-turn")
            return True
        async def search():
            events.append("search")
            return True
        async def release():
            events.append("release")
        async def pause():
            events.append("pause")
        self.bot.ps_client = types.SimpleNamespace(logged_in=types.SimpleNamespace(wait=AsyncMock()))
        self.bot._wait_turn = turn
        self.bot._renew_turn = AsyncMock()
        self.bot._release_turn = release
        self.bot._search_until_match = search
        self.bot._battle_start_condition = asyncio.Condition()
        self.bot._battle_count_queue = types.SimpleNamespace(join=AsyncMock())
        self.bot._battle_semaphore = types.SimpleNamespace(acquire=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = pause
        await self.bot._ladder(1)
        self.assertEqual(events, ["team-turn", "search", "release", "pause"])
        self.bot._idle_bots.assert_not_awaited()


if __name__ == "__main__":
    unittest.main()
