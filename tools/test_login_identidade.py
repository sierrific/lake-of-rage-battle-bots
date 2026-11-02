"""Regressions for Showdown updateuser confirmation, without network or models."""
import ast
import asyncio
import contextlib
from collections import namedtuple
import io
import json
import os
from pathlib import Path
import re
import sys
import types
import unittest
from unittest.mock import AsyncMock, Mock, patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding='utf-8'))
definition = next(n for n in source.body if getattr(n, 'name', '') == '_public_login')


class Client(types.SimpleNamespace):
    @property
    def account_configuration(self):
        return self._account_configuration


class TestLoginIdentity(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.name = 'PaiBrazVGC_Oficial'
        self.original_handler = AsyncMock()
        self.client = Client(
            _account_configuration=namedtuple('AccountConfiguration', 'username password')(self.name, None),
            server_configuration=types.SimpleNamespace(authentication_url='https://example.invalid'),
            _handle_message=self.original_handler, logged_in=asyncio.Event(),
            send_message=AsyncMock(), search_ladder_game=AsyncMock(),
            change_avatar=AsyncMock(), _avatar=90,
        )
        self.clock = Mock()
        self.battle = types.SimpleNamespace(player_username=self.name, finished=False)
        player = types.SimpleNamespace(ps_client=self.client, stop_after_match=False,
                                       _track_decision_clock=self.clock, _battles={'battle-1': self.battle})
        ns = dict(Player=object, os=os, asyncio=asyncio, json=json,
                  to_id_str=lambda value: re.sub('[^a-z0-9]', '', value.lower()))
        exec(compile(ast.Module(body=[definition], type_ignores=[]), 'player.py', 'exec'), ns)
        with patch.dict(sys.modules, requests=types.SimpleNamespace()):
            ns['_public_login'](player, None)

    async def test_case_punctuation_rank_and_status_identify_same_account(self):
        for display in (' paibrazvgc_oficial', ' PaiBrazVGC_Oficial',
                        ' PaiBrazVGCOficial', '+PaiBrazVGC Oficial@!',
                        ' PaiBrazVGC_Oficial@'):
            with self.subTest(display=display):
                self.client.logged_in.clear()
                await self.client._handle_message(f'|updateuser|{display}|1|90|{{}}')
                self.assertTrue(self.client.logged_in.is_set())
                expected = display[1:].split('@', 1)[0]
                self.assertEqual(self.client.account_configuration.username, expected)
                self.assertEqual(self.battle.player_username, expected)
        self.original_handler.assert_not_awaited()

    async def test_wrong_guest_unnamed_and_malformed_updates_do_not_confirm(self):
        for message in ('|updateuser| OtherAccount|1|90|{}',
                        '|updateuser| Guest 123|0|1|{}',
                        '|updateuser| PaiBrazVGC_Oficial|0|90|{}',
                        '|updateuser| PaiBrazVGC_Oficial',
                        '|updateuser||1|90|{}'):
            with self.subTest(message=message):
                self.client.logged_in.set()
                await self.client._handle_message(message)
                self.assertFalse(self.client.logged_in.is_set())
        self.original_handler.assert_not_awaited()

    async def test_battle_and_chat_messages_keep_original_handler_and_clock(self):
        for message in ('>battle-1\n|win|Rival',
                        '|pm|Rival|Bot||updateuser| PaiBrazVGC_Oficial|1|90|{}'):
            await self.client._handle_message(message)
            self.original_handler.assert_awaited_with(message)
            self.clock.assert_called_with(message)
        self.assertFalse(self.client.logged_in.is_set())

    async def test_browser_login_then_preference_then_search_and_reconnect(self):
        sent = []
        trn_sent = asyncio.Event()
        async def send(message):
            sent.append(message)
            if message.startswith('/trn '):
                trn_sent.set()
        self.client.send_message = send
        self.client.wait_for_login = AsyncMock(side_effect=lambda **kw: None)
        async def wait_login(**kw):
            await self.client.logged_in.wait()
        self.client.wait_for_login.side_effect = wait_login
        assertion = 'challenge,paibrazvgcoficial,2,123,server;signature'
        output = io.StringIO()
        with patch.dict(os.environ, {'LOR_BROWSER_LOGIN': 'helper', 'LOR_BROWSER_DIR': 'mailbox'}, clear=True), \
                patch('runpy.run_path', return_value={'request_assertion': lambda *a, **kw: assertion}), \
                contextlib.redirect_stdout(output):
            for _ in range(2):
                trn_sent.clear()
                logging_in = asyncio.create_task(self.client.log_in(['', 'challstr', '4', 'challenge']))
                await asyncio.wait_for(trn_sent.wait(), 1)
                self.assertFalse(self.client.logged_in.is_set(), 'reconnection must discard previous login')
                searching = asyncio.create_task(self.client.search_ladder_game('format', 'team'))
                try:
                    await self.client._handle_message('|updateuser| OtherAccount|1|90|{}')
                    await asyncio.sleep(0)
                    self.assertFalse(logging_in.done())
                    self.assertFalse(searching.done())
                    await self.client._handle_message('|updateuser| paibrazvgc_oficial|1|90|{}')
                    await asyncio.wait_for(logging_in, 1)
                    await asyncio.wait_for(searching, 1)
                finally:
                    logging_in.cancel()
                    searching.cancel()
                    await asyncio.gather(logging_in, searching, return_exceptions=True)
        self.assertEqual(sent, [f'/trn {self.name},0,{assertion}', '/blockbots'] * 2)
        self.assertEqual(output.getvalue().count('login confirmed: ' + self.name), 2)
        self.assertNotIn(assertion, output.getvalue())


if __name__ == '__main__':
    unittest.main()
