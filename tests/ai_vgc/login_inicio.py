"""Executa main com conexao imediata: o login remoto deve estar pronto antes de ouvir.

Modelos, rede e navegador sao sinteticos. O cliente reproduz o start_listening=True
do construtor do poke-env; entregar challstr ali detecta a corrida de inicializacao.
"""
import argparse
import ast
import asyncio
import concurrent.futures
import contextlib
import io
import importlib.util
import json
import os
import sys
import time
import types
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, Mock, patch

player_path = Path(sys.argv.pop(1))
source = ast.parse(player_path.read_text(encoding="utf-8"))
spec = importlib.util.spec_from_file_location('ai_vgc.nn.personality', player_path.with_name('personality.py'))
personality_module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = personality_module
spec.loader.exec_module(personality_module)
definitions = [node for node in source.body if isinstance(node, ast.FunctionDef)
               and node.name in {"main", "_public_login"}]
assert len(definitions) == 2


class TestLoginStartup(unittest.TestCase):
    def run_startup(self, *, search=False, remote=True, custom=False, browser=True, mode="ladder", personality='classico'):
        events, clients, players = [], [], []
        assertion = "challenge,contateste,2,123,sim3.psim.us;signature"
        case = self

        async def to_thread(fn, *args, **kwargs):
            return fn(*args, **kwargs)

        def schedule(coro, loop):
            future = concurrent.futures.Future()
            try:
                future.set_result(asyncio.run(coro))
            except BaseException:
                coro.close()
                raise
            return future

        async_api = types.SimpleNamespace(**vars(asyncio))
        async_api.to_thread = to_thread
        async_api.run_coroutine_threadsafe = schedule

        class Client:
            def __init__(self, account_configuration):
                self.account_configuration = account_configuration
                self.server_configuration = types.SimpleNamespace(authentication_url="https://example.invalid")
                self.loop = object()
                self._avatar = None
                self.wait_for_login = AsyncMock()
                self.change_avatar = AsyncMock()
                self.search_ladder_game = AsyncMock(side_effect=lambda *args: events.append("search"))

            async def send_message(self, message):
                events.append(message)

            async def log_in(self, message):
                events.append("default-login")
                if remote:
                    case.fail("challstr chegou ao login padrao antes do login remoto estar instalado")

            async def listen(self):
                events.append("listen")
                await self.log_in(["", "challstr", "4", "challenge"])

        class Player:
            stop_after_match = False
            n_won_battles = n_finished_battles = 0
            searched = search_time = fallbacks = sim_errors = sims = countered = 0

            def __init__(self, *args, account_configuration, start_listening=True, **kwargs):
                self.ps_client = Client(account_configuration)
                self.ps_client._avatar = kwargs.get('avatar')
                clients.append(self.ps_client)
                players.append(self)
                if start_listening:
                    self.ps_client._listening_coroutine = schedule(self.ps_client.listen(), self.ps_client.loop)
                events.append("models-ready")

            async def ladder(self, count):
                await self.ps_client.search_ladder_game("format", "team")

            async def send_challenges(self, *args):
                events.append("challenge")

            async def accept_challenges(self, *args):
                events.append("accept")

        def browser_assertion(*args, **kwargs):
            events.append("browser")
            return assertion

        def direct_login(*args, **kwargs):
            if browser:
                case.fail("login direto usado no modo navegador")
            events.append("password")
            return types.SimpleNamespace(text="]" + json.dumps({"assertion": assertion}))

        ns = {"argparse": argparse, "asyncio": async_api, "os": os, "json": json, "time": time,
              "Path": Path, "Player": object, "torch": types.SimpleNamespace(set_num_threads=Mock()),
              "getpass": types.SimpleNamespace(getpass=lambda *args: case.fail("pediu senha")),
              "AccountConfiguration": lambda name, password: types.SimpleNamespace(username=name, password=password),
              "ServerConfiguration": lambda *args: object(), "ShowdownServerConfiguration": object(),
              "ChallengeNNPlayer": Player, "ChallengeMixin": type("ChallengeMixin", (), {}),
              "to_id_str": lambda s: s.lower(), "__doc__": "test"}
        exec(compile(ast.Module(body=definitions, type_ignores=[]), "player.py", "exec"), ns)
        modules = {
            "ai_vgc.showdown": types.SimpleNamespace(account=Mock(), ensure_server=Mock(return_value=None), wilson=Mock()),
            "ai_vgc.teams": types.SimpleNamespace(TEAMS_DIR=Path("teams"), RandomPoolTeambuilder=Mock()),
            "ai_vgc.nn.search": types.SimpleNamespace(SearchPlayer=Player),
            "ai_vgc.nn.messages": types.SimpleNamespace(install=Mock()),
            "requests": types.SimpleNamespace(request=direct_login),
            "threading": types.SimpleNamespace(Thread=Mock()),
        }
        env = {"LOR_BROWSER_LOGIN": "helper.py", "LOR_BROWSER_DIR": "mailbox"} if browser else {"PS_PASSWORD": "synthetic"}
        env['LOR_PERSONALITY'] = personality
        argv = ["player.py", "--accept", "ContaTeste", "--n", "1", "--no-munchstats"]
        if remote:
            argv += ["--server-url", "wss://example.invalid/ws"] if custom else ["--server", "showdown"]
        if search:
            argv += ["--search"]
        if mode == "ladder":
            argv += ["--ladder"]
        elif mode == "challenge":
            argv += ["--challenge", "Rival"]
        with patch.dict(sys.modules, modules), patch.dict(os.environ, env, clear=True), \
             patch.object(sys, "argv", argv), patch("signal.signal"), \
             patch("runpy.run_path", return_value={"request_assertion": browser_assertion}), \
             contextlib.redirect_stdout(io.StringIO()):
            ns["main"]()
        self.assertEqual(events.count("listen"), 1)
        self.assertTrue(clients[0]._listening_coroutine.done())
        if remote and personality != 'classico':
            profile = personality_module.profile_for('ContaTeste', personality)
            self.assertEqual(players[0].personality.profile, profile)
            clients[0].change_avatar.assert_awaited_once_with(profile.avatar)
        else:
            self.assertIsNone(players[0].personality)
            self.assertIsNone(clients[0]._avatar)
        if remote:
            self.assertLess(events.index("models-ready"), events.index("listen"))
            self.assertNotIn("default-login", events)
            self.assertEqual(events.count("browser" if browser else "password"), 1)
            self.assertIn(f"/trn ContaTeste,0,{assertion}", events)
            self.assertIn("/blockbots", events)
            if mode == "ladder":
                self.assertLess(events.index("/blockbots"), events.index("search"))
        else:
            self.assertIn("default-login", events)
            self.assertNotIn("browser", events)

    def test_navegador_antes_da_conexao_com_modelo_nn(self):
        self.run_startup()

    def test_navegador_antes_da_conexao_com_modelo_de_busca(self):
        self.run_startup(search=True)

    def test_servidor_remoto_personalizado(self):
        self.run_startup(search=True, custom=True)

    def test_desafios_usam_a_mesma_inicializacao(self):
        for mode in ("challenge", "accept"):
            with self.subTest(mode=mode):
                self.run_startup(search=True, mode=mode)

    def test_modo_legado_explicito_tambem_instala_seu_handler_antes(self):
        self.run_startup(browser=False)

    def test_servidor_local_preserva_inicializacao_automatica(self):
        self.run_startup(remote=False)

    def test_perfil_e_avatar_aplicados_em_nn_busca_e_ambos_logins(self):
        for search in (False, True):
            for browser in (False, True):
                with self.subTest(search=search, browser=browser):
                    self.run_startup(search=search, browser=browser, personality='auto')

    def test_perfil_explicito_no_servidor_do_time_e_desafios(self):
        self.run_startup(custom=True, mode='challenge', personality='cordial')

    def test_ambiente_local_de_avaliacao_ignora_personalidade(self):
        self.run_startup(remote=False, personality='auto')


if __name__ == "__main__":
    unittest.main()
