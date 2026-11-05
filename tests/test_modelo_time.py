"""modelo-time.sh: baixa o modelo do time da coleta, confere o sha256 e volta ao original se falhar."""
import hashlib
import http.server
import os
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parents[1]
SCRIPT = RAIZ / "linux" / "modelo-time.sh"


class Servidor(http.server.BaseHTTPRequestHandler):
    corpo = b""
    pedidos = []

    def do_GET(self):
        type(self).pedidos.append((self.path, self.headers.get("Authorization")))
        if self.headers.get("Authorization") != "Bearer abc":
            self.send_response(401); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Length", str(len(self.corpo)))
        self.end_headers()
        self.wfile.write(self.corpo)

    def log_message(self, *a):
        pass


class ModeloTimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.aivgc, self.etc = d / "ai", d / "etc"
        (self.aivgc / "data/models").mkdir(parents=True)
        self.etc.mkdir()
        (self.etc / "coleta.env").write_text("COLETA_CODIGO=abc\n")
        self.dados = os.urandom(4096)
        texto = SCRIPT.read_text()
        sha_real = texto.split("mc-bo3-rnad-v6.pt ")[1].split()[0]
        self.script = d / "modelo-time.sh"
        self.script.write_text(texto.replace(sha_real, hashlib.sha256(self.dados).hexdigest()))
        self.script.chmod(0o755)
        Servidor.corpo, Servidor.pedidos = self.dados, []
        self.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Servidor)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close(); self.tmp.cleanup()

    def rodar(self, modelo="data/models/mc-bo3-rnad-v6.pt", url=None):
        env = dict(os.environ, LOR_AIVGC=str(self.aivgc), LOR_ETC=str(self.etc),
                   LOR_COLETA_MODELO=url or f"http://127.0.0.1:{self.srv.server_port}/coleta/modelo")
        r = subprocess.run([str(self.script), modelo], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.strip()

    def test_baixa_confere_e_usa(self):
        self.assertEqual(self.rodar(), "data/models/mc-bo3-rnad-v6.pt")
        self.assertEqual((self.aivgc / "data/models/mc-bo3-rnad-v6.pt").read_bytes(), self.dados)
        self.assertEqual(Servidor.pedidos, [("/coleta/modelo/mc-bo3-rnad-v6.pt", "Bearer abc")])
        self.rodar()  # já está: não baixa de novo
        self.assertEqual(len(Servidor.pedidos), 1)

    def test_arquivo_diferente_volta_ao_original(self):
        Servidor.corpo = b"outro"
        self.assertEqual(self.rodar(), "data/models/mc-bo3-rnad-v5.pt")
        self.assertFalse(list((self.aivgc / "data/models").iterdir()))

    def test_coleta_fora_do_ar_ou_codigo_recusado(self):
        self.assertEqual(self.rodar(url="http://127.0.0.1:9/coleta/modelo"), "data/models/mc-bo3-rnad-v5.pt")
        (self.etc / "coleta.env").write_text("COLETA_CODIGO=errado\n")
        self.assertEqual(self.rodar(), "data/models/mc-bo3-rnad-v5.pt")

    def test_controle_e_modelo_do_aivgc(self):
        (self.etc / "sem-modelo-time").touch()
        self.assertEqual(self.rodar(), "data/models/mc-bo3-rnad-v5.pt")
        self.assertEqual(Servidor.pedidos, [])
        self.assertEqual(self.rodar("data/models/mc-cts-rnad-v7-MC301.pt"), "data/models/mc-cts-rnad-v7-MC301.pt")


if __name__ == "__main__":
    unittest.main()
