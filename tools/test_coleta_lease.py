"""Regressões do contrato da coleta no player.py já com o patch, sem contas/modelos/rede.

python3 tools/test_coleta_lease.py /caminho/ai-vgc/src/ai_vgc/nn/player.py
"""
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
from pathlib import Path
from unittest.mock import AsyncMock, patch
from urllib.error import HTTPError

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
mixin = next(n for n in source.body if isinstance(n, ast.ClassDef) and n.name == "ChallengeMixin")
NAMES = {"_turn", "_accept_turn", "_can_search", "_release_turn", "_team_wait_enabled",
         "_wait_turn", "_renew_turn", "_ladder", "_search_until_match", "_battle_finished_callback"}
TOKEN = "a" * 32
GRANT = {"vez": True, "lease": TOKEN, "expira_em": 120}


class LeaseTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.clock = 0
        self.after_wait = lambda: None
        self.after_sleep = lambda: None
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.flag = Path(self.directory.name) / "skip-team"
        env = patch.dict(os.environ, LOR_SKIP_TEAM_WAIT_FILE=str(self.flag), COLETA_CODIGO="synthetic")
        env.start()
        self.addCleanup(env.stop)
        self.output = io.StringIO()
        out = contextlib.redirect_stdout(self.output)
        out.__enter__()
        self.addCleanup(out.__exit__, None, None, None)

        async def sleep(seconds):
            self.clock += seconds
            self.after_sleep()
            await asyncio.sleep(0)

        async def wait(tasks, *, timeout=None, return_when=asyncio.ALL_COMPLETED):
            result = await asyncio.wait(tasks, timeout=0.002, return_when=return_when)
            self.clock += timeout or 0
            self.after_wait()
            return result

        api = types.SimpleNamespace(**vars(asyncio))
        api.sleep, api.wait = sleep, wait
        ns = {"asyncio": api, "os": os, "json": json, "re": re,
              "time": types.SimpleNamespace(monotonic=lambda: self.clock, time=lambda: self.clock,
                                            strftime=time.strftime),
              "Path": Path, "to_id_str": lambda s: re.sub("[^a-z0-9]", "", s.lower()),
              "_dex_name": lambda m: m.species,
              "Base": type("Base", (), {"_battle_finished_callback": lambda *_: None})}
        methods = [n for n in mixin.body if getattr(n, "name", "") in NAMES]
        self.assertEqual(len(methods), len(NAMES))
        cls = ast.ClassDef(name="Bot", bases=[ast.Name(id="Base", ctx=ast.Load())],
                           keywords=[], body=methods, decorator_list=[])
        code = ast.fix_missing_locations(ast.Module(body=[
            ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0), cls], type_ignores=[]))
        exec(compile(code, "player.py", "exec"), ns)
        self.bot = ns["Bot"]()
        self.bot.stop_after_match = False
        self.bot.username, self.bot._format = "My Bot", "gen9testbo3"
        self.bot.TURN_URL = "https://coleta.invalid/fila"
        self.bot.SEARCH_RETRY = 60
        self.bot._turn_required = True
        self.bot._turn_lease, self.bot._turn_deadline = TOKEN, 115
        self.bot._battle_semaphore = asyncio.Semaphore(0)
        self.bot.next_team = "packed-team"
        self.messages = []
        self.on_search = AsyncMock()
        self.cancel_reply = {"searching": [], "games": None}
        self.on_cancel = AsyncMock()
        self.admit_search = True

        async def send(message, room="", message_2=None):
            self.messages.append(message)
            if message.startswith("/search "):
                if self.admit_search:
                    await self.bot.ps_client._handle_message('|updatesearch|{"searching":["gen9testbo3"],"games":null}')
                await self.on_search()
            elif message == "/cancelsearch":
                await self.on_cancel()
                if self.cancel_reply is not None:
                    await self.bot.ps_client._handle_message("|updatesearch|" + json.dumps(self.cancel_reply))

        async def search(fmt, team):
            await self.bot.ps_client.send_message("/utm " + team)
            await self.bot.ps_client.send_message("/search " + fmt)

        self.bot.ps_client = types.SimpleNamespace(send_message=send, _handle_message=AsyncMock(),
            search_ladder_game=search, logged_in=types.SimpleNamespace(wait=AsyncMock()),
            server_configuration=types.SimpleNamespace(websocket_url="wss://server.invalid/showdown/websocket"))

    def lose(self):
        self.bot._turn_deadline = 0

    async def test_request_uses_protocol_and_exact_lease_and_server(self):
        calls = []
        def reply(req, timeout):
            calls.append(json.loads(req.data))
            return contextlib.closing(io.BytesIO(json.dumps(GRANT).encode()))
        with patch("urllib.request.urlopen", side_effect=reply):
            await self.bot._turn("pedir")
            await self.bot._turn("pedir", lease=TOKEN)
            await self.bot._turn("liberar", lease=TOKEN)
        self.assertNotIn("lease", calls[0])
        for data in calls:
            self.assertEqual(data["protocolo"], 2)
            self.assertEqual(data["servidor"], self.bot.ps_client.server_configuration.websocket_url)
            self.assertEqual(data["conta"], "mybot")
        self.assertEqual([c.get("lease") for c in calls], [None, TOKEN, TOKEN])

    async def test_transport_and_invalid_json_are_not_grants(self):
        for response in (b"null", b"[]", b"false", b"{", b'"text"'):
            with self.subTest(response=response), patch("urllib.request.urlopen", return_value=contextlib.closing(io.BytesIO(response))):
                self.assertIsNone(await self.bot._turn("pedir"))
        for error in (TimeoutError(), *(HTTPError("https://coleta.invalid", code, "synthetic", {}, None)
                                       for code in (400, 429, 500))):
            with patch("urllib.request.urlopen", side_effect=error):
                self.assertIsNone(await self.bot._turn("pedir", lease=TOKEN))

    async def test_malformed_old_and_changed_grants_are_rejected(self):
        bad = [None, [], {"vez": True}, {**GRANT, "vez": 1}, {**GRANT, "lease": "short"},
               {**GRANT, "lease": [TOKEN]}, {**GRANT, "expira_em": True},
               {**GRANT, "expira_em": 121}, {**GRANT, "expira_em": 0},
               {**GRANT, "expira_em": float("nan")}, {**GRANT, "lease": "b" * 32}]
        for value in bad:
            with self.subTest(value=value):
                self.assertFalse(self.bot._accept_turn(value, 0, lease=TOKEN))
        self.assertTrue(self.bot._accept_turn(GRANT, 0, lease=TOKEN))

    async def test_ttl_counts_request_latency_and_reserves_cancellation_margin(self):
        self.clock = 20
        self.assertTrue(self.bot._accept_turn(GRANT, 0))
        self.assertEqual(self.bot._turn_deadline, 115)
        self.clock = 115
        self.assertFalse(self.bot._can_search())
        self.assertFalse(self.bot._accept_turn(GRANT, 0))

    async def test_outage_waits_then_acquires_without_downgrade(self):
        self.bot._turn = AsyncMock(side_effect=[None, {"vez": True}, GRANT])
        self.assertTrue(await self.bot._wait_turn())
        self.assertEqual(self.clock, 30)
        self.assertTrue(self.bot._can_search())
        self.assertEqual(self.bot._turn_lease, TOKEN)

    async def test_failed_renewal_invalidates_lease_immediately(self):
        for reply in (None, {"vez": False}, {"vez": False, "motivo": "lease_invalido"},
                      {"vez": True}, {**GRANT, "lease": "b" * 32}):
            with self.subTest(reply=reply):
                self.clock = 0
                self.bot._turn_deadline = 115
                self.bot._turn = AsyncMock(return_value=reply)
                await self.bot._renew_turn()
                self.assertEqual(self.clock, 30)
                self.assertFalse(self.bot._can_search())
                self.bot._turn.assert_awaited_once_with("pedir", lease=TOKEN)

    async def test_valid_renewal_keeps_same_owner_until_explicit_rejection(self):
        self.bot._turn = AsyncMock(side_effect=[GRANT, {"vez": False}])
        await self.bot._renew_turn()
        self.assertEqual(self.clock, 60)
        self.assertFalse(self.bot._can_search())
        self.assertEqual([c.kwargs["lease"] for c in self.bot._turn.await_args_list], [TOKEN, TOKEN])

    async def test_late_renewal_does_not_revive_expired_search(self):
        async def response(*_, **kw):
            self.clock = 120
            return GRANT
        self.bot._turn = AsyncMock(side_effect=response)
        await self.bot._renew_turn()
        self.assertFalse(self.bot._can_search())

    async def test_release_clears_local_authority_before_network(self):
        async def release(action, lease):
            self.assertEqual((action, lease), ("liberar", TOKEN))
            self.assertFalse(self.bot._can_search())
        self.bot._turn = AsyncMock(side_effect=release)
        await self.bot._release_turn()
        self.assertIsNone(self.bot._turn_lease)

    async def test_lease_loss_cancels_search_and_never_retries(self):
        self.on_search.side_effect = self.lose
        self.assertFalse(await self.bot._search_until_match())
        self.assertEqual(self.messages, ["/utm packed-team", "/search gen9testbo3", "/cancelsearch"])

    async def test_expiry_cancels_search_without_waiting_for_renewal_task(self):
        self.on_search.side_effect = lambda: setattr(self, "clock", 115)
        self.assertFalse(await self.bot._search_until_match())
        self.assertEqual(self.messages.count("/cancelsearch"), 1)

    async def test_lost_lease_after_team_upload_blocks_actual_search(self):
        original = self.bot.ps_client.send_message
        async def delayed_team(message, *args):
            await original(message, *args)
            if message.startswith("/utm "):
                self.lose()
        self.bot.ps_client.send_message = delayed_team
        self.assertFalse(await self.bot._search_until_match())
        self.assertEqual(self.messages, ["/utm packed-team"])

    async def test_loss_while_login_waits_cancels_delayed_task(self):
        gate = asyncio.Event()
        cancelled = asyncio.Event()
        async def login_wait(*args):
            try:
                await gate.wait()
                await self.bot.ps_client.send_message("/search gen9testbo3")
            finally:
                cancelled.set()
        self.bot.ps_client.search_ladder_game = login_wait
        self.after_wait = self.lose
        self.assertFalse(await self.bot._search_until_match())
        gate.set()
        await asyncio.sleep(0)
        self.assertTrue(cancelled.is_set())
        self.assertEqual(self.messages, [])

    async def test_battle_start_wins_race_with_lease_loss(self):
        async def start():
            self.lose()
            self.bot._battle_semaphore.release()
        self.on_search.side_effect = start
        self.assertTrue(await self.bot._search_until_match())
        self.assertNotIn("/cancelsearch", self.messages)
        self.assertTrue(self.bot._battle_semaphore.locked())

    async def test_battle_arriving_during_cancel_is_not_replaced(self):
        self.on_search.side_effect = self.lose
        self.cancel_reply = {"searching": [], "games": {"game-gen9test-1": "series"}}
        self.on_cancel.side_effect = self.bot._battle_semaphore.release
        self.assertTrue(await self.bot._search_until_match())
        self.assertEqual(self.messages.count("/search gen9testbo3"), 1)
        self.assertTrue(self.bot._battle_semaphore.locked())

    async def test_no_cancellation_confirmation_keeps_search_paused(self):
        self.on_search.side_effect = self.lose
        self.cancel_reply = None
        task = asyncio.create_task(self.bot._search_until_match())
        try:
            for _ in range(100):
                if "/cancelsearch" in self.messages:
                    break
                await asyncio.sleep(0.001)
            self.assertIn("/cancelsearch", self.messages)
            await asyncio.sleep(0.01)
            self.assertFalse(task.done())
            self.assertEqual(self.messages.count("/search gen9testbo3"), 1)
            await self.bot.ps_client._handle_message('|updatesearch|{"searching":[],"games":null}')
            self.assertFalse(await asyncio.wait_for(task, 1))
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_empty_cancel_reply_does_not_hide_late_server_validation(self):
        self.admit_search = False  # Showdown is still awaiting prepBattle()/team validation
        self.on_search.side_effect = self.lose
        task = asyncio.create_task(self.bot._search_until_match())
        try:
            for _ in range(100):
                if "/cancelsearch" in self.messages:
                    break
                await asyncio.sleep(0.001)
            await asyncio.sleep(0.01)
            self.assertFalse(task.done(), "empty updatesearch did not cancel pending validation")
            await self.bot.ps_client._handle_message('|updatesearch|{"searching":["gen9testbo3"],"games":null}')
            self.assertFalse(await asyncio.wait_for(task, 1))
            self.assertEqual(self.messages.count("/cancelsearch"), 2)
            self.assertEqual(self.messages.count("/search gen9testbo3"), 1)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_uncertain_retry_stops_renewing_team_reservation(self):
        self.bot.SEARCH_RETRY = 2
        self.cancel_reply = None
        task = asyncio.create_task(self.bot._search_until_match())
        try:
            for _ in range(200):
                if not self.bot._can_search():
                    break
                await asyncio.sleep(0.002)
            self.assertFalse(self.bot._can_search())
            self.assertFalse(task.done())
            self.assertIn("search paused", self.output.getvalue())
            await self.bot.ps_client._handle_message('|updatesearch|{"searching":[],"games":null}')
            self.assertFalse(await asyncio.wait_for(task, 1))
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)

    async def test_graceful_stop_cancels_and_cleans_up_tasks_and_wrappers(self):
        before = self.bot.ps_client.send_message, self.bot.ps_client._handle_message
        self.on_search.side_effect = lambda: setattr(self.bot, "stop_after_match", True)
        self.assertFalse(await self.bot._search_until_match())
        self.assertIn("/cancelsearch", self.messages)
        self.assertEqual((self.bot.ps_client.send_message, self.bot.ps_client._handle_message), before)

    async def test_retry_checks_lease_again_after_delay(self):
        self.bot.SEARCH_RETRY = 2
        self.after_sleep = self.lose
        self.assertFalse(await self.bot._search_until_match())
        self.assertEqual(self.messages.count("/search gen9testbo3"), 1)
        self.assertEqual(self.messages.count("/cancelsearch"), 1)

    async def test_ladder_reacquires_after_loss_without_consuming_match(self):
        self.bot._turn = AsyncMock(return_value=GRANT)
        self.bot._renew_turn = AsyncMock()
        self.bot._wait_for_busy_bots = AsyncMock()
        self.bot._search_until_match = AsyncMock(side_effect=[False, True])
        self.bot._battle_count_queue = types.SimpleNamespace(join=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = AsyncMock()
        await self.bot._ladder(1)
        self.assertEqual(self.bot._search_until_match.await_count, 2)
        self.assertEqual([c.args[0] for c in self.bot._turn.await_args_list], ["pedir", "liberar", "pedir", "liberar"])
        self.bot._battle_count_queue.join.assert_awaited_once()
        self.bot._ladder_pause.assert_awaited_once()

    async def test_ladder_joins_cancelled_renewal_before_release(self):
        started = asyncio.Event()
        events = []
        async def renew():
            try:
                started.set()
                await asyncio.Event().wait()
            finally:
                await asyncio.sleep(0)
                events.append("renewal joined")
        async def search():
            await started.wait()
            return True
        async def turn(action, **kw):
            if action == "liberar":
                self.assertEqual(events, ["renewal joined"])
                events.append("released")
            return GRANT
        self.bot._turn = AsyncMock(side_effect=turn)
        self.bot._renew_turn = renew
        self.bot._wait_for_busy_bots = AsyncMock()
        self.bot._search_until_match = search
        self.bot._battle_count_queue = types.SimpleNamespace(join=AsyncMock())
        self.bot._busy = lambda: False
        self.bot._ladder_pause = AsyncMock()
        await self.bot._ladder(1)
        self.assertEqual(events, ["renewal joined", "released"])

    async def test_lost_lease_during_known_bot_wait_never_searches(self):
        self.bot._turn = AsyncMock(return_value=GRANT)
        self.bot._renew_turn = AsyncMock()
        calls = 0
        async def known_bots():
            nonlocal calls
            calls += 1
            if calls == 1:
                self.lose()
            else:
                self.bot.stop_after_match = True
        self.bot._wait_for_busy_bots = known_bots
        self.bot._search_until_match = AsyncMock()
        self.bot._busy = lambda: False
        await self.bot._ladder(1)
        self.bot._search_until_match.assert_not_called()

    async def test_records_identify_public_private_and_local_servers_without_replays(self):
        bot = self.bot
        bot._placar = lambda *_: None
        bot._cycle = lambda *_: {"cycles": []}
        bot.logs_dir = None
        bot._team = None
        bot.replay_url = None
        bot.save_dir = Path(self.directory.name)
        battle = types.SimpleNamespace(won=True, lost=False, battle_tag="battle-gen9test-1",
            opponent_username="Rival", turn=1, team={}, opponent_team={},
            _build_replay_log=lambda: "|win|My Bot", save_replay=lambda path: path)
        for endpoint in ("wss://sim3.psim.us/showdown/websocket",
                         "wss://showdown.sierverso.com.br/showdown/websocket",
                         "ws://localhost:8000/showdown/websocket"):
            bot.ps_client.server_configuration.websocket_url = endpoint
            bot._battle_finished_callback(battle)
            row = json.loads((bot.save_dir / "games.jsonl").read_text().splitlines()[-1])
            self.assertEqual(row["server_id"], endpoint)
            self.assertIsNone(row["replay_url"])


if __name__ == "__main__":
    unittest.main()
