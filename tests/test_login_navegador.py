"""Contrato da autorização local: sem rede, senha, cookie ou contas reais."""
import importlib.util
import contextlib
import io
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("login_navegador", ROOT / "linux/login-navegador.py")
login = importlib.util.module_from_spec(spec)
spec.loader.exec_module(login)


class TestLoginNavegador(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.req = {"id": "a" * 32, "username": "Conta Teste", "challstr": "4|" + "b" * 256,
                    "expires": time.time() + 300}
        login.write_json(self.dir / "pedido.json", self.req)

    def tearDown(self):
        self.tmp.cleanup()

    def assertion(self, **changes):
        fields = dict(challenge="b" * 256, user="contateste", kind="2", issued=str(int(time.time())),
                      host="sim3.psim.us")
        fields.update(changes)
        return ",".join(fields.values()) + ";" + "c" * 256

    def test_autorizacao_preserva_tipo_e_assinatura(self):
        for kind in ("2", "4", "10"):
            assertion = self.assertion(kind=kind)
            login.respond(self.dir, {"id": self.req["id"], "assertion": assertion})
            self.assertEqual(login.read_json(self.dir / "resposta.json")["assertion"], assertion)

    def test_extensoes_assinadas_do_showdown_sao_preservadas(self):
        # users.ts aceita pelo menos cinco campos e lê s1/s2/s3 depois deles.
        # O endpoint oficial atualmente envia oito, incluindo extensão final vazia.
        for kind in ("2", "4", "10"):
            for extension in (",s1", ",s1,s2,", ",s1,s2,s3,futuro"):
                data, signature = self.assertion(kind=kind).split(";")
                assertion = data + extension + ";" + signature
                login.respond(self.dir, {"id": self.req["id"], "assertion": assertion})
                self.assertEqual(login.read_json(self.dir / "resposta.json")["assertion"], assertion)

    def test_extensoes_nao_dispensam_validacao_da_conta_conexao_ou_prazo(self):
        for changes in ({"user": "outra"}, {"challenge": "d" * 256}, {"issued": "0"}, {"kind": "1"}):
            data, signature = self.assertion(**changes).split(";")
            with self.assertRaises(login.LoginError):
                login.respond(self.dir, {"id": self.req["id"], "assertion": data + ",s1,s2,;" + signature})

    def test_erro_publico_nao_expoe_resposta_remota(self):
        for code in ("assertion-format", "assertion-mismatch", "assertion-expired", "account-unregistered"):
            login.respond(self.dir, {"id": self.req["id"], "error": code})
            self.assertEqual(login.read_json(self.dir / "resposta.json")["error"], code)
        login.respond(self.dir, {"id": self.req["id"], "error": self.assertion()})
        self.assertEqual(login.read_json(self.dir / "resposta.json")["error"], "browser-error")
        output = io.StringIO()
        with patch.object(login, "read_json", side_effect=[self.req, {"id": self.req["id"], "error": "assertion-format"}, self.req]), \
             patch.object(login.secrets, "token_hex", return_value=self.req["id"]), contextlib.redirect_stdout(output):
            with self.assertRaises(login.LoginError):
                login.request_assertion(self.req["username"], self.req["challstr"], self.dir)
        self.assertIn("formato inválido", output.getvalue())
        self.assertNotIn(self.assertion(), output.getvalue())

    def test_cli_sinaliza_so_codigo_seguro(self):
        invalid = self.assertion() + "\nsegredo-sintetico"
        result = subprocess.run([sys.executable, str(ROOT / "linux/login-navegador.py"), "respond", str(self.dir)],
                                input=json.dumps({"id": self.req["id"], "assertion": invalid}),
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr.strip(), "LOGIN_ERROR:assertion-format")
        self.assertEqual(result.stdout, "")

    def test_rejeita_outra_conta_conexao_tempo_e_resposta_invalida(self):
        for assertion in (self.assertion(user="outraconta"), self.assertion(challenge="d" * 256),
                          self.assertion(issued="0"), self.assertion(kind="1"), ";", "<html>",
                          self.assertion() + "\n/command", "a" * 17000, None):
            with self.subTest(assertion_type=type(assertion).__name__), self.assertRaises(ValueError):
                login.respond(self.dir, {"id": self.req["id"], "assertion": assertion})
        self.assertFalse((self.dir / "resposta.json").exists())

    def test_resposta_de_pedido_anterior_nao_serve(self):
        with self.assertRaises(ValueError):
            login.respond(self.dir, {"id": "d" * 32, "assertion": self.assertion()})

    def test_pedido_vencido_nao_e_exposto_nem_aceita_resposta(self):
        self.req["expires"] = time.time() - 1
        login.write_json(self.dir / "pedido.json", self.req)
        self.assertIsNone(login.pending(self.dir))
        with self.assertRaises(ValueError):
            login.respond(self.dir, {"id": self.req["id"], "assertion": self.assertion()})

    def test_pedido_e_consumido_e_apagado(self):
        (self.dir / "pedido.json").unlink()
        results, errors = [], []
        def authorize():
            try:
                results.append(login.request_assertion(self.req["username"], self.req["challstr"], self.dir))
            except Exception as error:
                errors.append(error)
        thread = threading.Thread(target=authorize)
        thread.start()
        try:
            deadline = time.monotonic() + 3
            req = None
            while req is None and time.monotonic() < deadline:
                req = login.pending(self.dir)
                time.sleep(0.01)
            self.assertIsNotNone(req)
            login.respond(self.dir, {"id": req["id"], "assertion": self.assertion()})
        finally:
            thread.join(timeout=3)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors)
        self.assertEqual(len(results), 1)
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_cancelar_limpa_e_nao_tenta_senha(self):
        self.assertIsNone(login.request_assertion(self.req["username"], self.req["challstr"], self.dir,
                                                  stop=lambda: True))
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_timeout_limpa_pedido(self):
        with patch.object(login, "TTL", 0.01), self.assertRaisesRegex(ValueError, "expirou"):
            login.request_assertion(self.req["username"], self.req["challstr"], self.dir)
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_challstr_complementar_e_preservado(self):
        self.req["challstr"] += "|additional-token"
        login.write_json(self.dir / "pedido.json", self.req)
        self.assertEqual(login.pending(self.dir)["challstr"], self.req["challstr"])
        self.assertEqual(login.validate_assertion(self.assertion(), self.req), self.assertion())


if __name__ == "__main__":
    unittest.main()
