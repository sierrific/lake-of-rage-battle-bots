"""Executa _public_login do patch, sem carregar PyTorch ou conectar ao Showdown."""
import ast
import asyncio
import contextlib
import io
import json
import os
import sys
import types
from time import perf_counter
import unittest
from pathlib import Path
from unittest.mock import patch
from unittest.mock import AsyncMock

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
definition = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == "_public_login")


# Contrato real de poke-env 379a046, ps_client.py:337-343 (sem importar a biblioteca inteira).
async def wait_for_login(self, checking_interval=0.001, wait_for=5):
    start = perf_counter()
    while perf_counter() - start < wait_for:
        await asyncio.sleep(checking_interval)
        if self.logged_in.is_set():
            return
    assert self.logged_in.is_set(), f"Expected {self.username} to be logged in."


class TestBrowserLogin(unittest.IsolatedAsyncioTestCase):
    async def test_browser_nao_chama_login_por_senha_e_preserva_tipo(self):
        for kind in ("2", "10"):
            sent = []
            async def send(msg): sent.append(msg)
            async def avatar(_): pass
            client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                           send_message=send, change_avatar=avatar, _avatar=1,
                                           wait_for_login=AsyncMock(), search_ladder_game=AsyncMock())
            player = types.SimpleNamespace(ps_client=client, stop_after_match=False)
            namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
            exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
            assertion = "b" * 256 + f",contateste,{kind},123,sim3.psim.us;" + "c" * 256
            calls = []
            def request(name, challstr, directory, stop):
                calls.append((name, challstr, directory))
                return assertion
            fake_requests = types.SimpleNamespace(request=lambda *a, **k: self.fail("tentou login direto"))
            output = io.StringIO()
            with patch.dict(sys.modules, requests=fake_requests), patch.dict(os.environ, {
                "LOR_BROWSER_LOGIN": "helper.py", "LOR_BROWSER_DIR": "mailbox"}), \
                patch("runpy.run_path", return_value={"request_assertion": request}), contextlib.redirect_stdout(output):
                namespace["_public_login"](player, "senha-que-nao-deve-ser-usada")
                await client.log_in(["", "challstr", "4", "b" * 256, "extra"])
            self.assertEqual(sent, [f"/trn ContaTeste,0,{assertion}", "/blockbots"])
            client.wait_for_login.assert_awaited_once()
            self.assertEqual(calls, [("ContaTeste", "4|" + "b" * 256 + "|extra", "mailbox")])
            self.assertNotIn(assertion, output.getvalue())
            self.assertEqual("registered on Showdown as a bot" in output.getvalue(), kind == "10")

    async def test_falha_nao_faz_fallback_nem_reconexao_automatica(self):
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                       search_ladder_game=AsyncMock(), send_message=AsyncMock())
        namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
        exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
        def request(*a, **k): raise ValueError("falha")
        with patch.dict(sys.modules, requests=types.SimpleNamespace()), patch.dict(os.environ, {
            "LOR_BROWSER_LOGIN": "helper.py", "LOR_BROWSER_DIR": "mailbox"}), \
            patch("runpy.run_path", return_value={"request_assertion": request}), \
            patch("os._exit", side_effect=SystemExit) as exit_mock:
            namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha")
            with self.assertRaises(SystemExit):
                await client.log_in(["", "challstr", "4", "b" * 256])
            exit_mock.assert_called_once_with(78)
        client.send_message.assert_not_awaited()

    async def test_blockbots_aguarda_login_e_precede_busca_concorrente(self):
        # Uma busca ja agendada nao pode ultrapassar o envio, mesmo que o socket demore.
        named, trn_sent, block_started, release_block = (asyncio.Event() for _ in range(4))
        sent = []
        async def send(message):
            if message == "/blockbots":
                block_started.set()
                await release_block.wait()
            sent.append(message)
            if message.startswith("/trn "): trn_sent.set()
        async def search(fmt, team):
            sent.append("/search " + fmt)
            return team
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                       server_configuration=types.SimpleNamespace(authentication_url="https://example.test"),
                                       send_message=send, change_avatar=AsyncMock(), _avatar=None,
                                       wait_for_login=lambda **kw: named.wait(), search_ladder_game=search)
        namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
        exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
        assertion = "b" * 256 + ",contateste,2,123,sim3.psim.us;" + "c" * 256
        fake_requests = types.SimpleNamespace(request=lambda *a, **k: types.SimpleNamespace(
            text="]" + json.dumps({"assertion": assertion})))
        with patch.dict(sys.modules, requests=fake_requests), patch.dict(os.environ, {}, clear=True):
            namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha-sintetica")
            searching = asyncio.create_task(client.search_ladder_game("formato", "time"))
            logging_in = asyncio.create_task(client.log_in(["", "challstr", "4", "b" * 256]))
            try:
                await asyncio.wait_for(trn_sent.wait(), 1)
                self.assertEqual(sent, [f"/trn ContaTeste,0,{assertion}"])
                self.assertFalse(searching.done())
                named.set()
                await asyncio.wait_for(block_started.wait(), 1)
                self.assertFalse(searching.done())
                release_block.set()
                await asyncio.wait_for(logging_in, 1)
                self.assertEqual(await asyncio.wait_for(searching, 1), "time")
            finally:
                logging_in.cancel(); searching.cancel()
                await asyncio.gather(logging_in, searching, return_exceptions=True)
        self.assertEqual(sent, [f"/trn ContaTeste,0,{assertion}", "/blockbots", "/search formato"])

    async def test_reenvia_blockbots_em_cada_login(self):
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                       server_configuration=types.SimpleNamespace(authentication_url="https://example.test"),
                                       send_message=AsyncMock(), change_avatar=AsyncMock(), _avatar=None,
                                       wait_for_login=AsyncMock(), search_ladder_game=AsyncMock())
        namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
        exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
        fake_requests = types.SimpleNamespace(request=lambda *a, **k: types.SimpleNamespace(
            text=']{"assertion":"challenge,contateste,2,123,server;signature"}'))
        with patch.dict(sys.modules, requests=fake_requests), patch.dict(os.environ, {}, clear=True):
            namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha-sintetica")
            for _ in range(2):
                await client.log_in(["", "challstr", "4", "b" * 256])
        commands = [args.args[0] for args in client.send_message.await_args_list]
        self.assertEqual(commands[1::2], ["/blockbots", "/blockbots"])
        self.assertEqual(client.wait_for_login.await_count, 2)

    async def test_toggle_rele_preferencia_antes_da_busca_e_no_login(self):
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                       server_configuration=types.SimpleNamespace(authentication_url="https://example.test"),
                                       send_message=AsyncMock(), change_avatar=AsyncMock(), _avatar=None,
                                       wait_for_login=AsyncMock(), search_ladder_game=AsyncMock())
        namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
        exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
        fake_requests = types.SimpleNamespace(request=lambda *a, **k: types.SimpleNamespace(
            text=']{"assertion":"challenge,contateste,2,123,server;signature"}'))
        with patch.dict(sys.modules, requests=fake_requests), \
             patch.dict(os.environ, {"LOR_ALLOW_BOTS_FILE": "preferencia"}, clear=True), \
             patch("os.path.exists", return_value=True) as exists:
            namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha-sintetica")
            await client.log_in(["", "challstr", "4", "b" * 256])
            await client.search_ladder_game("formato", "time")
            exists.return_value = False
            await client.search_ladder_game("formato", "time")
            await client.search_ladder_game("formato", "time")
            exists.return_value = True
            await client.search_ladder_game("formato", "time")
            await client.log_in(["", "challstr", "4", "c" * 256])
        commands = [args.args[0] for args in client.send_message.await_args_list if not args.args[0].startswith("/trn")]
        self.assertEqual(commands, ["/allowbots", "/blockbots", "/allowbots", "/allowbots"])
        self.assertEqual(client.wait_for_login.await_count, 2)

    def test_modo_navegador_nao_pede_senha_no_main(self):
        main = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == "main")
        gate = next(n for n in ast.walk(main) if isinstance(n, ast.If) and
                    isinstance(n.test, ast.BoolOp) and "LOR_BROWSER_LOGIN" in ast.unparse(n.test))
        namespace = {"public": True, "os": os, "getpass": types.SimpleNamespace(
            getpass=lambda *_: self.fail("pediu senha")), "password": None}
        with patch.dict(os.environ, LOR_BROWSER_LOGIN="helper.py"):
            exec(compile(ast.Module(body=[gate], type_ignores=[]), "player.py", "exec"), namespace)
        self.assertIsNone(namespace["password"])

    async def test_confirmacao_depois_de_cinco_segundos(self):
        named = asyncio.Event()
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
            username="ContaTeste", logged_in=named, server_configuration=types.SimpleNamespace(authentication_url="x"),
            send_message=AsyncMock(), change_avatar=AsyncMock(), _avatar=None, search_ladder_game=AsyncMock())
        client.wait_for_login = types.MethodType(wait_for_login, client)
        namespace = {"Player": object, "os": os, "asyncio": asyncio, "json": json}
        exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
        fake = types.SimpleNamespace(request=lambda *a, **k: types.SimpleNamespace(text=']{"assertion":"a,u,2;sig"}'))
        with patch.dict(sys.modules, requests=fake), patch.dict(os.environ, {}, clear=True):
            namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha")
            handle = asyncio.get_running_loop().call_later(5.2, named.set)
            try:
                await asyncio.wait_for(client.log_in(["", "challstr", "4", "a"]), 8)
                await asyncio.wait_for(client.search_ladder_game("fmt", "time"), 1)
            finally:
                handle.cancel()
        client.send_message.assert_any_await("/blockbots")

    async def test_falhas_de_confirmacao_encerram_sem_busca(self):
        class FatalLogin(Exception): pass
        for caso in ("ausente", "preferencia-falhou", "preferencia-travou", "trn-falhou"):
            with self.subTest(caso=caso):
                named = asyncio.Event()
                if caso != "ausente": named.set()
                async def send(message):
                    if caso == "trn-falhou" or (message == "/blockbots" and caso == "preferencia-falhou"):
                        raise OSError("falha sintetica")
                    if message == "/blockbots" and caso == "preferencia-travou":
                        await asyncio.Event().wait()
                client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                    username="ContaTeste", logged_in=named, server_configuration=types.SimpleNamespace(authentication_url="x"),
                    send_message=send, change_avatar=AsyncMock(), _avatar=None, search_ladder_game=AsyncMock())
                original_search = client.search_ladder_game
                client.wait_for_login = types.MethodType(wait_for_login, client)
                deadlines = []
                async def prazo_curto(awaitable, timeout):
                    deadlines.append(timeout)
                    return await asyncio.wait_for(awaitable, 0.05)
                async_api = types.SimpleNamespace(**vars(asyncio))
                async_api.wait_for = prazo_curto
                namespace = {"Player": object, "os": os, "asyncio": async_api, "json": json}
                exec(compile(ast.Module(body=[definition], type_ignores=[]), "player.py", "exec"), namespace)
                fake = types.SimpleNamespace(request=lambda *a, **k: types.SimpleNamespace(text=']{"assertion":"a,u,2;sig"}'))
                with patch.dict(sys.modules, requests=fake), patch.dict(os.environ, {}, clear=True), \
                     patch("os._exit", side_effect=FatalLogin) as sair:
                    namespace["_public_login"](types.SimpleNamespace(ps_client=client), "senha")
                    busca = asyncio.create_task(client.search_ladder_game("fmt", "time"))
                    try:
                        with self.assertRaises(FatalLogin):
                            await client.log_in(["", "challstr", "4", "a"])
                        named.set()  # updateuser tardio nunca libera uma sessao que falhou.
                        await asyncio.sleep(0)
                        self.assertFalse(busca.done())
                        sair.assert_called_once_with(78)
                        original_search.assert_not_awaited()
                        self.assertEqual(deadlines, [30])
                    finally:
                        busca.cancel()
                        await asyncio.gather(busca, return_exceptions=True)


if __name__ == "__main__":
    unittest.main()
