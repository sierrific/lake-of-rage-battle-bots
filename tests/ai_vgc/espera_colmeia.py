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
names = {"_team_wait_enabled", "_wait_turn", "_renew_turn", "_ladder", "_turn", "_known_bots", "_search_until_match"}
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
        self.ns = {"os": os, "json": json, "Counter": Counter,
                   "time": types.SimpleNamespace(time=lambda: 1_800_000_000 + self.elapsed,
                                                 monotonic=lambda: self.elapsed,
                                                 strftime=time.strftime, localtime=time.localtime),
                   "asyncio": types.SimpleNamespace(sleep=sleep, to_thread=to_thread, create_task=asyncio.create_task,
                                                 wait_for=asyncio.wait_for, TimeoutError=asyncio.TimeoutError),
                   "to_id_str": lambda s: re.sub(r"[^a-z0-9]", "", s.lower())}
        for method in methods:
            exec(compile(ast.Module(body=[method], type_ignores=[]), "player.py", "exec"), self.ns)
        cls = type("Bot", (), {**{n: self.ns[n] for n in names}, "TURN_DOWN_WAIT": 120, "TURN_RENEW_FAILS": 3,
                               "SEARCH_RETRY": 600})
        self.bot = cls()
        self.bot.stop_after_match = False
        self.bot._turn = AsyncMock(return_value={"vez": True})
        self.output = io.StringIO()
        stdout = contextlib.redirect_stdout(self.output)
        stdout.__enter__()
        self.addCleanup(stdout.__exit__, None, None, None)

    def actions(self):
        return [c.args[0] for c in self.bot._turn.await_args_list]

    async def test_ligado_espera_a_vez_com_intervalo_de_15_segundos(self):
        self.bot._turn.side_effect = [{"vez": False, "com": "OutroBot"}, {"vez": True}]
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
        async def turn(action):
            if action == "pedir":
                self.flag.touch()
            return {"vez": True}
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

    async def test_sem_codigo_busca_sem_vez_na_hora(self):
        self.bot._turn.return_value = None
        self.assertFalse(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 0)

    async def test_coleta_fora_do_ar_insiste_2_min_antes_de_buscar_sem_vez(self):
        # 06/11: dois bots do time se enfrentaram 5 vezes; buscar na hora quando a VPS não
        # respondia era uma das portas. Agora insiste a cada 15 s e só desiste depois de 2 min.
        self.bot._turn.return_value = {"falha": "URLError"}
        self.assertFalse(await self.bot._wait_turn())
        self.assertGreaterEqual(self.elapsed, 120)
        self.assertLess(self.elapsed, 150)
        self.assertIn("searching without a turn", self.output.getvalue())

    async def test_coleta_volta_e_da_a_vez(self):
        self.bot._turn.side_effect = [{"falha": "TimeoutError"}, {"falha": "TimeoutError"}, {"vez": True}]
        self.assertTrue(await self.bot._wait_turn())
        self.assertEqual(self.elapsed, 30)

    async def test_renovacao_recusada_marca_vez_perdida_e_libera(self):
        # a coleta reiniciou (ou a renovação chegou tarde) e outro bot do time ficou com a vez
        self.bot._turn.side_effect = [{"vez": True}, {"vez": False, "com": "OutroBot", "posicao": 1}, {}]
        self.bot._turn_lost = False
        await self.bot._renew_turn()
        self.assertTrue(self.bot._turn_lost)
        self.assertEqual(self.actions(), ["pedir", "pedir", "liberar"])
        self.assertEqual(self.elapsed, 60)
        self.assertIn("OutroBot has it", self.output.getvalue())

    async def test_renovacao_sem_resposta_3_vezes_marca_vez_perdida(self):
        self.bot._turn.side_effect = [{"falha": "URLError"}, {"vez": True}, {"falha": "URLError"},
                                      {"falha": "URLError"}, {"falha": "URLError"}, {}]
        self.bot._turn_lost = False
        await self.bot._renew_turn()
        self.assertTrue(self.bot._turn_lost)
        self.assertEqual(self.actions(), ["pedir"] * 5 + ["liberar"])

    async def test_busca_cancelada_quando_a_vez_e_perdida(self):
        sent = []
        self.bot.ps_client = types.SimpleNamespace(search_ladder_game=AsyncMock(),
                                                   send_message=AsyncMock(side_effect=lambda m: sent.append(m)))
        self.bot._format, self.bot.next_team = "gen9test", None
        self.bot._battle_start_condition = asyncio.Condition()
        self.bot._turn_lost = True
        async with self.bot._battle_start_condition:
            self.assertIsNone(await self.bot._search_until_match())
        self.assertEqual(sent, ["/cancelsearch"])

    async def test_ladder_pede_a_vez_de_novo_sem_gastar_partida(self):
        self.bot.ps_client = types.SimpleNamespace(logged_in=types.SimpleNamespace(wait=AsyncMock()))
        self.bot._renew_turn = AsyncMock()
        self.bot._wait_for_busy_bots = AsyncMock()
        self.bot._search_until_match = AsyncMock(side_effect=[None, True])
        self.bot._battle_start_condition = asyncio.Condition()
        self.bot._battle_count_queue = types.SimpleNamespace(full=lambda: False)
        self.bot._battle_semaphore = types.SimpleNamespace(acquire=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = AsyncMock()
        await self.bot._ladder(1)
        self.assertEqual(self.bot._search_until_match.await_count, 2)
        self.assertEqual(self.actions().count("pedir"), 2)
        self.bot._ladder_pause.assert_awaited_once()

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
        self.bot._battle_count_queue = types.SimpleNamespace(full=lambda: False)
        self.bot._battle_semaphore = types.SimpleNamespace(acquire=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = AsyncMock()
        await self.bot._ladder(1)
        self.bot._search_until_match.assert_awaited_once()
        self.bot._renew_turn.assert_not_called()
        self.bot._wait_for_busy_bots.assert_awaited_once()
        self.bot._ladder_pause.assert_awaited_once()
        self.assertEqual(self.actions(), ["pedir", "liberar"])

    async def test_ladder_devolve_a_vez_quando_a_partida_comeca_nao_quando_termina(self):
        # A fila do poke-env como ela é: max_concurrent_battles=1 deixa a Queue(1) cheia da
        # criação da batalha até o |win| (na Bo3, até o fim da série). A vez do time tem de
        # voltar para a coleta enquanto a partida ainda está rolando (revisão de 06/11).
        self.bot.ps_client = types.SimpleNamespace(logged_in=types.SimpleNamespace(wait=AsyncMock()))
        self.bot._wait_for_busy_bots = AsyncMock()
        self.bot._ladder_pause = AsyncMock()
        self.bot._battle_start_condition = asyncio.Condition()
        self.bot._battle_end_condition = asyncio.Condition()
        self.bot._battle_count_queue = asyncio.Queue(1)
        self.bot._battle_semaphore = asyncio.Semaphore(0)
        self.bot._busy = lambda: not self.bot._battle_count_queue.empty()
        seen = {}

        async def battle():
            for _ in range(50):  # a partida "dura" 50 passos do loop
                await asyncio.sleep(0)
            seen["liberada_durante_a_partida"] = "liberar" in self.actions()
            await self.bot._battle_count_queue.get()
            self.bot._battle_count_queue.task_done()
            async with self.bot._battle_end_condition:
                self.bot._battle_end_condition.notify_all()

        async def search():
            await self.bot._battle_count_queue.put(None)  # o que o poke-env faz ao criar a batalha
            self.bot._battle_semaphore.release()
            seen["fim"] = asyncio.create_task(battle())
            return True

        self.bot._search_until_match = search
        await asyncio.wait_for(self.bot._ladder(1), 5)
        await seen["fim"]
        self.assertTrue(seen["liberada_durante_a_partida"], self.actions())
        self.assertEqual(self.actions().count("liberar"), 1, self.actions())
        self.assertEqual(self.actions()[0], "pedir")

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
        agora = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(1_800_000_000))
        rows = [json.dumps({"format": "gen9test", "opponent": name, "time": agora})
                for name in ("OutroBot", "Adversario") for _ in range(6)]
        (day / "games.jsonl").write_text("\n".join(rows))
        os.utime(day / "games.jsonl", (1_800_000_000, 1_800_000_000))
        self.assertEqual(self.bot._known_bots(), ["adversario"])

    def test_known_bots_by_game_time_not_folder(self):
        # Bot ligado há 10 dias: tudo cai na pasta do dia em que ligou (save_dir). Os jogos desta
        # semana contam; os da primeira semana, na mesma pasta, não (revisão de código de 05/11).
        self.bot._team_bots, self.bot._format = set(), "gen9test"
        now = 1_800_000_000
        start = self.directory / time.strftime("%Y-%m-%d", time.localtime(now - 10 * 86400))
        start.mkdir()
        self.bot.save_dir = start
        self.bot.KNOWN_BOT_DAYS, self.bot.KNOWN_BOT_GAMES = 7, 6
        when = lambda t: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
        rows = ([{"format": "gen9test", "opponent": "Antigo", "time": when(now - 9 * 86400)}] * 6
                + [{"format": "gen9test", "opponent": "Recente", "time": when(now - 3600)}] * 6
                + [{"format": "outro", "opponent": "OutroFormato", "time": when(now - 3600)}] * 6)
        (start / "games.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n[1]\n")
        os.utime(start / "games.jsonl", (now - 3600, now - 3600))
        self.assertEqual(self.bot._known_bots(), ["recente"])
        # Uma pasta que não mudou na semana nem é lida.
        os.utime(start / "games.jsonl", (now - 8 * 86400, now - 8 * 86400))
        self.assertEqual(self.bot._known_bots(), [])


if __name__ == "__main__":
    unittest.main()
