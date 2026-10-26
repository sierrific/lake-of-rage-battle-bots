"""Testes do linux/backup-coleta.py contra uma coleta falsa (/coleta/backup).

    python3 -m unittest discover -s tests
"""

import importlib.util
import json
import tempfile
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("backup", RAIZ_REPO / "linux" / "backup-coleta.py")
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class Coleta(BaseHTTPRequestHandler):
    """Como a coleta da VPS: a lista dos arquivos e cada um a partir de um byte."""

    arquivos: dict[str, bytes] = {}
    pedidos: list[str] = []

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer tokentoken":
            return self._enviar(401, b"{}")
        Coleta.pedidos.append(self.path)
        partes = urllib.parse.urlsplit(self.path)
        nome = partes.path.strip("/")
        if not nome:
            return self._enviar(200, json.dumps({"arquivos": {n: len(d) for n, d in Coleta.arquivos.items()}}).encode())
        desde = int(urllib.parse.parse_qs(partes.query)["desde"][0])
        self._enviar(200, Coleta.arquivos[nome][desde:])

    def _enviar(self, codigo, corpo):
        self.send_response(codigo)
        self.send_header("Content-Length", str(len(corpo)))
        self.end_headers()
        self.wfile.write(corpo)

    def log_message(self, *_):
        pass


class TestBackup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), Coleta)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        backup.URL = f"http://127.0.0.1:{cls.srv.server_port}"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.destino = Path(self.tmp.name)
        Coleta.arquivos, Coleta.pedidos = {"sier": b'{"a": 1}\n{"a": 2}\n', "joao": b'{"b": 1}\n'}, []

    def tearDown(self):
        self.tmp.cleanup()

    def rodar(self):
        for nome, tamanho in json.loads(backup.pedir("", "tokentoken").read())["arquivos"].items():
            backup.copiar("tokentoken", self.destino, nome, tamanho)

    def test_copia_e_depois_so_o_que_cresceu(self):
        self.rodar()
        self.assertEqual((self.destino / "sier" / "games.jsonl").read_bytes(), Coleta.arquivos["sier"])
        Coleta.arquivos["sier"] += b'{"a": 3}\n'
        Coleta.pedidos.clear()
        self.rodar()
        self.assertEqual((self.destino / "sier" / "games.jsonl").read_bytes(), Coleta.arquivos["sier"])
        self.assertIn("/sier?desde=18", Coleta.pedidos)
        self.assertFalse(any(p.startswith("/joao?") for p in Coleta.pedidos))  # não mudou: nem pede

    def test_linha_pela_metade_fica_para_a_proxima(self):
        Coleta.arquivos["sier"] += b'{"a": 3'  # a coleta ainda gravava esta
        self.rodar()
        self.assertEqual((self.destino / "sier" / "games.jsonl").read_bytes(), b'{"a": 1}\n{"a": 2}\n')
        Coleta.arquivos["sier"] += b'}\n'
        self.rodar()
        self.assertEqual((self.destino / "sier" / "games.jsonl").read_bytes(), Coleta.arquivos["sier"])

    def test_arquivo_menor_na_coleta_guarda_a_copia_velha(self):
        self.rodar()
        Coleta.arquivos["sier"] = b'{"c": 1}\n'
        self.rodar()
        self.assertEqual((self.destino / "sier" / "games.jsonl").read_bytes(), b'{"c": 1}\n')
        self.assertEqual(len(list((self.destino / "sier").glob("games.jsonl.*.antigo"))), 1)


if __name__ == "__main__":
    unittest.main()
