"""Executa _public_login do patch, sem carregar PyTorch ou conectar ao Showdown."""
import ast
import asyncio
import contextlib
import io
import json
import os
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

source = ast.parse(Path(sys.argv.pop(1)).read_text(encoding="utf-8"))
definition = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == "_public_login")


class TestBrowserLogin(unittest.IsolatedAsyncioTestCase):
    async def test_browser_nao_chama_login_por_senha_e_preserva_tipo(self):
        for kind in ("2", "10"):
            sent = []
            async def send(msg): sent.append(msg)
            async def avatar(_): pass
            client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"),
                                           send_message=send, change_avatar=avatar, _avatar=1)
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
            self.assertEqual(sent, [f"/trn ContaTeste,0,{assertion}"])
            self.assertEqual(calls, [("ContaTeste", "4|" + "b" * 256 + "|extra", "mailbox")])
            self.assertNotIn(assertion, output.getvalue())
            self.assertEqual("registered on Showdown as a bot" in output.getvalue(), kind == "10")

    async def test_falha_nao_faz_fallback_nem_reconexao_automatica(self):
        client = types.SimpleNamespace(account_configuration=types.SimpleNamespace(username="ContaTeste"))
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

    def test_modo_navegador_nao_pede_senha_no_main(self):
        main = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == "main")
        gate = next(n for n in ast.walk(main) if isinstance(n, ast.If) and
                    isinstance(n.test, ast.BoolOp) and "LOR_BROWSER_LOGIN" in ast.unparse(n.test))
        namespace = {"public": True, "os": os, "getpass": types.SimpleNamespace(
            getpass=lambda *_: self.fail("pediu senha")), "password": None}
        with patch.dict(os.environ, LOR_BROWSER_LOGIN="helper.py"):
            exec(compile(ast.Module(body=[gate], type_ignores=[]), "player.py", "exec"), namespace)
        self.assertIsNone(namespace["password"])


if __name__ == "__main__":
    unittest.main()
