"""Toggle da fila do time: relógio e coleta simulados, sem bots ou rede reais."""
import ast
import asyncio
import contextlib
import io
import json
import os
import re
import sys
import tempfile
import time
import types
import unittest
from collections import Counter
from pathlib import Path
from unittest.mock import AsyncMock, patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
names = {"_team_wait_enabled", "_wait_turn", "_renew_turn", "_ladder", "_turn", "_known_bots",
         "_accept_turn", "_can_search", "_release_turn"}
GRANT = {"vez": True, "lease": "a" * 32, "expira_em": 120}
methods = [n for n in mixin.body if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name in names]
assert len(methods) == len(names)


class TestTeamWait(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.directory = Path(tmp.name)
        self.flag = self.directory / "bot.sem-espera-colmeia"
        env = patch.dict(os.environ, LOR_SKIP_TEAM_WAIT_FILE=str(self.flag))
        env.start()
        self.addCleanup(env.stop)
        self.elapsed = 0
        self.on_sleep = lambda: None
        async def sleep(seconds):
            self.elapsed += seconds
            self.on_sleep()
            await asyncio.sleep(0)
        async def to_thread(fn):
            return fn()
        self.ns = {"os": os, "json": json, "re": re, "Counter": Counter,
                   "time": types.SimpleNamespace(time=lambda: 1_800_000_000 + self.elapsed,
                                                 monotonic=lambda: self.elapsed,
                                                 strftime=time.strftime, localtime=time.localtime),
                   "asyncio": types.SimpleNamespace(sleep=sleep, to_thread=to_thread, create_task=asyncio.create_task,
                                                    gather=asyncio.gather, wait_for=asyncio.wait_for),
                   "to_id_str": lambda s: re.sub(r"[^a-z0-9]", "", s.lower())}
        for method in methods:
            exec(compile(ast.Module(body=[method], type_ignores=[]), "player.py", "exec"), self.ns)
        cls = type("Bot", (), {n: self.ns[n] for n in names})
        self.bot = cls()
        self.bot.stop_after_match = False
        self.bot._turn = AsyncMock(return_value=GRANT)
        self.bot._turn_required = True
        self.bot._turn_lease, self.bot._turn_deadline = GRANT["lease"], 115
        self.output = io.StringIO()
        stdout = contextlib.redirect_stdout(self.output)
        stdout.__enter__()
        self.addCleanup(stdout.__exit__, None, None, None)

    def actions(self):
        return [c.args[0] for c in self.bot._turn.await_args_list]

    async def test_ligado_espera_a_vez_com_intervalo_de_15_segundos(self):
        self.bot._turn.side_effect = [{"vez": False, "com": "OutroBot"}, GRANT]
        self.assertTrue(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 15)
        self.assertEqual(self.actions(), ["pedir", "pedir"])

    async def test_desligado_nao_espera_outro_bot_e_libera_pedido(self):
        self.flag.touch()
        self.bot._turn.return_value = {"vez": False, "com": "OutroBot"}
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 0)
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_desligado_libera_vez_recebida_sem_renovar(self):
        self.flag.touch()
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_desligar_durante_espera_sai_no_proximo_segundo(self):
        self.bot._turn.return_value = {"vez": False, "com": "OutroBot"}
        self.on_sleep = self.flag.touch
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 1)
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_desligar_com_pedido_em_curso_nao_retem_vez(self):
        async def turn(action, **kw):
            if action == "pedir":
                self.flag.touch()
            return GRANT
        self.bot._turn.side_effect = turn
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_religar_vale_na_proxima_busca(self):
        self.flag.touch()
        self.assertFalse(await self.bot._wait_turn())
        self.flag.unlink()
        self.assertTrue(await self.bot._wait_turn())
        self.assertEqual(self.actions(), ["pedir", "liberar", "pedir"])

    async def test_parada_retira_bot_da_fila_de_espera(self):
        self.bot._turn.return_value = {"vez": False, "com": "OutroBot"}
        self.on_sleep = lambda: setattr(self.bot, "stop_after_match", True)
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 1)
        self.assertEqual(self.actions(), ["pedir", "liberar"])
        self.assertNotIn("wait disabled", self.output.getvalue())

    async def test_coleta_indisponivel_aguarda_sem_autorizar_busca(self):
        self.bot._turn.return_value = None
        self.on_sleep = lambda: setattr(self.bot, "stop_after_match", True)
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 1)
        self.assertFalse(self.bot._can_search())

    async def test_desligar_enquanto_tem_vez_interrompe_renovacao_e_libera(self):
        self.on_sleep = self.flag.touch
        await self.bot._renew_turn()
        self.assertEqual(self.elapsed, 1)
        self.assertEqual(self.actions(), ["liberar"])

    async def test_renovacao_continua_a_cada_30_segundos_enquanto_ligado(self):
        def after_sleep():
            if self.elapsed >= 61:
                self.flag.touch()
        self.on_sleep = after_sleep
        await self.bot._renew_turn()
        self.assertEqual(self.actions(), ["pedir", "pedir", "liberar"])
        self.assertEqual(self.elapsed, 61)

    async def test_ladder_desligado_busca_sem_renovar_e_preserva_espera_adversarios(self):
        self.flag.touch()
        self.bot.ps_client = types.SimpleNamespace(logged_in=types.SimpleNamespace(wait=AsyncMock()))
        self.bot._renew_turn = AsyncMock()
        self.bot._wait_for_busy_bots = AsyncMock()
        self.bot._search_until_match = AsyncMock(return_value=True)
        self.bot._battle_start_condition = asyncio.Condition()
        self.bot._battle_count_queue = types.SimpleNamespace(join=AsyncMock())
        self.bot._battle_semaphore = types.SimpleNamespace(acquire=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = AsyncMock()
        await self.bot._ladder(1)
        self.bot._search_until_match.assert_awaited_once()
        self.bot._renew_turn.assert_not_called()
        self.bot._wait_for_busy_bots.assert_awaited_once()
        self.bot._ladder_pause.assert_awaited_once()
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_desligado_ainda_registra_conta_e_exclui_colmeia_dos_adversarios(self):
        self.flag.touch()
        self.bot._turn = types.MethodType(self.ns["_turn"], self.bot)
        self.bot.username, self.bot._format = "MeuBot", "gen9test"
        self.bot.TURN_URL = "https://coleta.invalid/fila"
        self.bot.ps_client = types.SimpleNamespace(server_configuration=types.SimpleNamespace(websocket_url="wss://server.invalid/ws"))
        calls = []
        def response(request, timeout):
            calls.append(json.loads(request.data)["acao"])
            self.assertEqual(timeout, 10)
            reply = {"vez": False, "com": "OutroBot", "nossos": ["MeuBot", "OutroBot"]}
            return contextlib.closing(io.BytesIO(json.dumps(reply).encode()))
        with patch.dict(os.environ, COLETA_CODIGO="codigo-sintetico"), patch("urllib.request.urlopen", side_effect=response):
            self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(calls, ["pedir", "liberar"])
        self.assertEqual(self.bot._team_bots, {"meubot", "outrobot"})
        day = self.directory / time.strftime("%Y-%m-%d", time.localtime(1_800_000_000))
        day.mkdir()
        self.bot.save_dir = day
        self.bot.KNOWN_BOT_DAYS, self.bot.KNOWN_BOT_GAMES = 7, 6
        rows = [json.dumps({"format": "gen9test", "opponent": name})
                for name in ("OutroBot", "Adversario") for _ in range(6)]
        (day / "games.jsonl").write_text("\n".join(rows))
        self.assertEqual(self.bot._known_bots(), ["adversario"])


if __name__ == "__main__":
    unittest.main()
