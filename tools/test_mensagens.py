"""Local history: protocol, persistence, isolation and panel transport; no accounts/network."""
import asyncio
from contextlib import redirect_stdout
import importlib.util
import io
import json
import logging
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, patch

path = Path(sys.argv.pop(1)).with_name('messages.py')
spec = importlib.util.spec_from_file_location('messages', path)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class TestHistory(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.history = m.History(self.root, 'Meu_Bot')

    def rows(self):
        return m.recent(self.root, 'Meu Bot')

    def room(self, text):
        self.history.receive('>battle-test\n' + text)

    def test_players_only_bot_opponent_and_exact_body(self):
        self.room('|player|p1|Meu_Bot|1\n|player|p2|Rival|2\n|c| Meu_Bot|gl hf\n|c:|1793556000|@Rival|Olá | tudo bem?\n|c| Visitante|não incluir')
        rows = self.rows()
        self.assertEqual([r['text'] for r in rows], ['gl hf', 'Olá | tudo bem?'])
        self.assertEqual([r['own'] for r in rows], [True, False])
        self.assertEqual(rows[1]['sender'], 'Rival')
        self.assertTrue(rows[1]['time'].endswith('+00:00'))

    def test_private_incoming_only_no_commands_or_other_account(self):
        self.history.receive('|pm|+Amigo| Meu_Bot|Oi | 😊')
        self.history.receive('|pm|Meu_Bot|Amigo|enviada')
        self.history.receive('|pm|Amigo|Outro|outra conta')
        self.history.receive('|pm|Amigo|Meu_Bot|/challenge format')
        self.history.receive('|pm|Meu_Bot|~|/error server reply')
        self.assertEqual([r['text'] for r in self.rows()], ['Oi | 😊'])

    def test_showdown_controls_are_not_conversation(self):
        self.room('|player|p1|Meu_Bot|1\n|player|p2||')
        self.room('|c|~|/uhtml controls,<div>Are you ready for game 2?</div>')
        self.room('|c:|1793556000|~|server notice')
        self.room('|c||empty sender')
        self.room('|player|p2|Rival|2')
        for text in ('/uhtml controls,<div>Ready?</div>', '/uhtmlchange controls,',
                     '/raw <b>notice</b>', '/html <b>notice</b>', '/challenge format',
                     '/UHTML controls,<p>notice</p>', '/uhtml'):
            with self.subTest(text=text):
                self.room('|c|Rival|' + text)
                self.room('|c:|1793556000|Rival|' + text)
                self.history.receive('|pm|Rival|Meu_Bot|' + text)
        self.assertEqual(self.rows(), [])

    def test_literal_text_and_chat_actions_are_preserved(self):
        self.room('|player|p1|Meu_Bot|1\n|player|p2|Rival|2')
        texts = ['Use /uhtml para isso', '<b>texto literal</b> & olá | 😊',
                 '/me acena', '//uhtml exemplo', '/uhtml_exemplo', '/challengecup']
        for text in texts:
            self.room('|c|Rival|' + text)
            self.history.receive('|pm|Rival|Meu_Bot|' + text)
        self.assertEqual([r['text'] for r in self.rows()], [text for text in texts for _ in range(2)])

    def test_legacy_controls_filtered_before_limit_without_rewriting_history(self):
        self.history.append('pm', 'Amigo', 'mensagem preservada')
        with self.history.path.open('a', encoding='utf-8') as out:
            for kind in ('chat', 'pm'):
                for sender, text in (('', '/uhtml controls,<div>Ready?</div>'),
                                     ('~', 'server notice'), ('', 'empty sender'),
                                     ('Rival', '/uhtmlchange controls,'), ('Rival', '/raw <b>notice</b>'),
                                     ('Rival', '/html <b>notice</b>'), ('Rival', '/challenge format'),
                                     ('Rival', None), (None, 'missing sender')):
                    out.write(json.dumps({'kind': kind, 'sender': sender, 'text': text}) + '\n')
        before = self.history.path.read_bytes()
        with patch.object(m, 'LIMIT', 1):
            self.assertEqual([r['text'] for r in self.rows()], ['mensagem preservada'])
        self.assertEqual(self.history.path.read_bytes(), before)

    def test_persistence_rotation_and_partial_line(self):
        with patch.object(m, 'MAX_BYTES', 1):
            self.history.append('pm', 'Rival', 'antes')
            self.history.append('pm', 'Rival', 'depois')
        with self.history.path.open('a') as out:
            out.write('{unfinished')
        self.assertEqual([r['text'] for r in self.rows()], ['antes', 'depois'])
        self.assertEqual(m.recent(self.root, 'Outra'), [])
        self.assertEqual(m.recent(self.root, ''), [])

    def test_permissions_and_no_training_files(self):
        self.history.append('pm', 'Rival', 'segredo')
        self.assertEqual(self.history.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.history.path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(list(self.root.glob('*/games.jsonl')), [])

    def test_long_message_not_truncated(self):
        text = 'texto á | ' * 2000
        self.history.append('pm', 'Rival', text)
        self.assertEqual(self.rows()[0]['text'], text)

    def test_lobby_spectating_and_deinit(self):
        self.history.receive('>lobby\n|c|Rival|oi')
        self.room('|player|p1|Outro|1\n|player|p2|Rival|2\n|c|Rival|oi')
        self.assertEqual(self.rows(), [])
        self.room('|deinit')
        self.assertFalse(self.history.players)

    def test_panel_merge_log_and_messages_no_private_in_technical_log(self):
        self.history.append('pm', 'Amigo', 'segredo', timestamp='2026-11-01T19:00:00+00:00')
        journal = [json.dumps({'MESSAGE': 'win vs Rival in 3 turns', '__REALTIME_TIMESTAMP': '1793556000000000'}),
                   json.dumps({'MESSAGE': 'Received pm: |pm|Amigo|Meu_Bot|segredo antigo', '__REALTIME_TIMESTAMP': '1793556000000000'}), 'broken']
        output = io.StringIO()
        with redirect_stdout(output):
            m.panel(self.root, 'Meu_Bot', 80, journal)
        log, history = output.getvalue().split('---historico---\n')
        self.assertNotIn('segredo', log)
        rows = [json.loads(line) for line in history.splitlines()]
        self.assertEqual({r['kind'] for r in rows}, {'pm', 'log'})
        self.assertEqual([r['time'] for r in rows], sorted(r['time'] for r in rows))

    def test_redacts_client_log_preserves_server_response(self):
        record = logging.LogRecord('test', 30, '', 1, 'Received pm: %s', ('|pm|Amigo|Meu_Bot|segredo',), None)
        m.PrivateMessages().filter(record)
        self.assertNotIn('segredo', record.getMessage())
        server = logging.LogRecord('test', 30, '', 1, 'Received pm: %s', ('|pm|Meu_Bot|~|reply',), None)
        m.PrivateMessages().filter(server)
        self.assertIn('reply', server.getMessage())

    def test_hook_always_forwards_protocol_even_if_disk_full(self):
        client = SimpleNamespace(account_configuration=SimpleNamespace(username='Meu_Bot'),
                                 logger=logging.getLogger('history-test'), _handle_message=AsyncMock())
        original = client._handle_message
        player = SimpleNamespace(ps_client=client, save_dir=self.root / '2026-11-01')
        m.install(player)
        with patch.object(m.History, 'append', side_effect=OSError('disk full')):
            asyncio.run(client._handle_message('|pm|Rival|Meu_Bot|texto'))
        original.assert_awaited_once_with('|pm|Rival|Meu_Bot|texto')

    def test_hook_forwards_bo3_controls_unchanged(self):
        client = SimpleNamespace(account_configuration=SimpleNamespace(username='Meu_Bot'),
                                 logger=logging.getLogger('controls-test'), _handle_message=AsyncMock())
        original = client._handle_message
        m.install(SimpleNamespace(ps_client=client, save_dir=self.root / '2026-11-01'))
        packet = '>game-test\n|player|p1|Meu_Bot|1\n|player|p2||\n|c|~|/uhtml controls,<button>Ready?</button>'
        asyncio.run(client._handle_message(packet))
        original.assert_awaited_once_with(packet)
        self.assertEqual(self.rows(), [])


if __name__ == '__main__':
    unittest.main()
