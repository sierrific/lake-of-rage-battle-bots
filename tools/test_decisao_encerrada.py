"""Regressions for late /choose, cancelled search and reuse after a completed battle."""
import ast
import asyncio
import concurrent.futures
import json
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import threading
import time
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

player_path = Path(sys.argv.pop(1))
tree = ast.parse(player_path.read_text())
search_tree = ast.parse(player_path.with_name('search.py').read_text())
future = ast.parse('from __future__ import annotations').body
parts = [n for n in search_tree.body if getattr(n, 'name', '') in ('Bridge', 'SearchStopped', 'check_live')]
ns = dict(threading=threading, subprocess=subprocess, json=json, select=select, time=time)
exec(compile(ast.Module(body=future + parts, type_ignores=[]), 'search.py', 'exec'), ns)


class TestBridge(unittest.TestCase):
    def bridge(self, reply=False):
        bridge = ns['Bridge'].__new__(ns['Bridge'])
        bridge.lock = threading.RLock()
        bridge.timeout = 5
        started = threading.Event()

        def start():
            previous = getattr(bridge, 'proc', None)
            if previous is not None:
                previous.stdin.close()
                previous.stdout.close()
            code = 'import sys,time; sys.stdin.readline(); ' + ('print(\'{"results": [42]}\', flush=True); time.sleep(30)' if reply else 'time.sleep(30)')
            bridge.proc = subprocess.Popen([sys.executable, '-u', '-c', code], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
            started.set()

        bridge._start = start
        start()
        self.addCleanup(bridge.close)
        return bridge, started

    def test_cancel_running_simulator_frees_process_and_lock(self):
        bridge, _ = self.bridge()
        stopped = threading.Event()
        with concurrent.futures.ThreadPoolExecutor() as pool:
            result = pool.submit(bridge.run, {}, [], [], stopped=stopped.is_set)
            time.sleep(0.1)
            start = time.monotonic()
            stopped.set()
            with self.assertRaises(ns['SearchStopped']):
                result.result(timeout=1)
            self.assertLess(time.monotonic() - start, 0.7)
        self.assertIsNotNone(bridge.proc.poll())
        self.assertTrue(bridge.lock.acquire(blocking=False))
        bridge.lock.release()

    def test_waiting_request_cannot_kill_other_battles_simulator(self):
        bridge, _ = self.bridge()
        with bridge.lock, concurrent.futures.ThreadPoolExecutor() as pool:
            result = pool.submit(bridge.run, {}, [], [], stopped=lambda: True)
            with self.assertRaises(ns['SearchStopped']):
                result.result(timeout=1)
            self.assertIsNone(bridge.proc.poll())

    def test_next_battle_restarts_simulator(self):
        bridge, _ = self.bridge(reply=True)
        bridge.proc.kill()
        bridge.proc.wait()
        self.assertEqual(bridge.run({}, [], [], stopped=lambda: False), [42])

    def test_finished_guard_prevents_work(self):
        for battle in (types.SimpleNamespace(finished=True), types.SimpleNamespace(finished=False, _lor_ended=True)):
            with self.assertRaises(ns['SearchStopped']):
                ns['check_live'](battle)
        ns['check_live'](types.SimpleNamespace(finished=False))


class TestDecision(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        mixin = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == 'ChallengeMixin')
        wanted = {'_track_decision_clock', '_handle_battle_request', '_live_battle_request', '_cycle', 'choose_move', '_pace_decision'}
        members = [n for n in mixin.body if getattr(n, 'name', '') in wanted]
        cls = ast.parse('class Bot(Engine): pass').body[0]
        cls.body = members
        class Engine:
            async def choose_move(self, battle):
                self.computed += 1
                return types.SimpleNamespace(message='/choose move 1, move 1')
            async def _handle_battle_request(self, battle, maybe_default_order=False):
                await self.choose_move(battle)
        self.ns = dict(asyncio=asyncio, re=re, time=time, Engine=Engine, os=os,
                       to_id_str=lambda s: re.sub('[^a-z0-9]', '', s.lower()))
        login = next(n for n in tree.body if getattr(n, 'name', '') == '_public_login')
        exec(compile(ast.fix_missing_locations(ast.Module(body=future + [cls, login], type_ignores=[])), 'player.py', 'exec'), self.ns)
        self.bot = self.ns['Bot']()
        self.bot.computed = 0
        self.bot._placar = Mock()
        self.bot.MAX_CYCLES = 300
        self.bot.username = 'Bot'
        self.battle = types.SimpleNamespace(battle_tag='battle-1', finished=False, _wait=False)
        self.bot._battles = {'battle-1': self.battle}

    async def test_terminal_packet_before_room_lock_stops_next_calculation(self):
        for terminal in ('|win|Bot', '|tie', '|deinit'):
            self.battle._lor_ended = False
            self.bot._track_decision_clock('>battle-1\n' + terminal)
            self.assertTrue(self.battle._lor_ended)
            await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.computed, 0)

    async def test_chat_cannot_mark_game_finished(self):
        self.bot._track_decision_clock('>battle-1\n|c|Rival||win|Bot')
        self.assertFalse(getattr(self.battle, '_lor_ended', False))
        await self.bot._handle_battle_request(self.battle)
        self.assertEqual(self.bot.computed, 1)

    async def test_final_send_guard_does_not_block_greetings_or_new_game(self):
        send = AsyncMock()
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username='Bot'),
                                      _handle_message=AsyncMock(), search_ladder_game=AsyncMock(), send_message=send)
        self.bot.ps_client = client
        with patch.dict(sys.modules, requests=types.SimpleNamespace()):
            self.ns['_public_login'](self.bot, None)
        await client._handle_message('>battle-1\n|win|Bot')
        for command in ('/choose move 1', '/team 1234', '/undo'):
            await client.send_message(command, 'battle-1')
        send.assert_not_awaited()
        await client.send_message('gg', 'battle-1')
        await client.send_message('/choose move 1', 'battle-2')
        self.assertEqual(send.await_count, 2)

    async def test_unrelated_cancellation_not_swallowed(self):
        self.bot._live_battle_request = AsyncMock(side_effect=asyncio.CancelledError())
        with self.assertRaises(asyncio.CancelledError):
            await self.bot._handle_battle_request(self.battle)
        self.battle._lor_ended = True
        await self.bot._handle_battle_request(self.battle)


if __name__ == '__main__':
    unittest.main()
