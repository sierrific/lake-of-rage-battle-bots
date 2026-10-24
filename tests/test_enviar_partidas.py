"""Testes do linux/enviar-partidas.py contra uma coleta falsa (só biblioteca padrão).

    python3 -m unittest discover -s tests
"""

import importlib.util
import json
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("enviar", RAIZ_REPO / "linux" / "enviar-partidas.py")
enviar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enviar)

MB = 1024 * 1024


class Coleta(BaseHTTPRequestHandler):
    """Como a coleta da VPS: recusa (413) envios acima de 4 MB; `fora` simula a VPS caída."""

    recebidos: list[list[dict]] = []
    fora = False

    def do_POST(self):
        tamanho = int(self.headers["Content-Length"])
        corpo = self.rfile.read(tamanho)
        if Coleta.fora:
            return self._responder(503, {"erro": "fora"})
        if tamanho > enviar.LIMITE:
            return self._responder(413, {"erro": "grande"})
        linhas = [json.loads(x) for x in corpo.splitlines() if x.strip()]
        Coleta.recebidos.append(linhas)
        self._responder(200, {"recebidas": len(linhas), "novas": len(linhas)})

    def _responder(self, codigo, obj):
        r = json.dumps(obj).encode()
        self.send_response(codigo)
        self.send_header("Content-Length", str(len(r)))
        self.end_headers()
        self.wfile.write(r)

    def log_message(self, *_):
        pass


def partida(hora: str, tamanho: int = 100) -> bytes:
    return json.dumps({"time": hora, "log": "x" * tamanho}).encode() + b"\n"


class TestEnvio(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.srv = HTTPServer(("127.0.0.1", 0), Coleta)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        enviar.URL = f"http://127.0.0.1:{cls.srv.server_port}/"

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        Coleta.recebidos, Coleta.fora = [], False
        self.tmp = tempfile.TemporaryDirectory()
        self.raiz = Path(self.tmp.name)
        (self.raiz / "2026-10-24").mkdir()
        self.jsonl = self.raiz / "2026-10-24" / "games.jsonl"
        self.estado_arq = self.raiz / ".coleta-enviado"
        self.estado = {"desde": "2026-10-24 12:00:00", "enviados": {}}

    def tearDown(self):
        self.tmp.cleanup()

    def escrever(self, *linhas: bytes):
        with open(self.jsonl, "ab") as f:
            for linha in linhas:
                f.write(linha)

    def ciclo(self):
        enviar.ciclo("codigo", self.raiz, self.estado_arq, self.estado)

    def pos(self) -> int:
        # O gravado em disco (que é o que vale depois de um reinício), quando houver.
        estado = json.loads(self.estado_arq.read_text()) if self.estado_arq.exists() else self.estado
        return estado["enviados"].get("2026-10-24/games.jsonl", 0)

    def todas(self) -> list[dict]:
        return [p for lote in Coleta.recebidos for p in lote]

    def test_envia_e_marca_antigas(self):
        self.escrever(partida("2026-10-24 11:00:00"), partida("2026-10-24 13:00:00"))
        self.ciclo()
        self.assertEqual([p.get("antigo", False) for p in self.todas()], [True, False])
        self.assertEqual(self.pos(), self.jsonl.stat().st_size)
        self.ciclo()  # nada novo: não reenvia
        self.assertEqual(len(self.todas()), 2)

    def test_lotes_limitados(self):
        self.escrever(*[partida("2026-10-24 13:00:00", 400_000) for _ in range(20)])  # ~8 MB
        self.ciclo()
        self.assertEqual(len(self.todas()), 20)
        self.assertTrue(all(sum(len(json.dumps(p)) for p in lote) <= enviar.LOTE for lote in Coleta.recebidos))

    def test_partida_entre_lote_e_limite_vai_sozinha(self):
        self.escrever(partida("2026-10-24 13:00:00"), partida("2026-10-24 13:00:01", int(3.5 * MB)),
                      partida("2026-10-24 13:00:02"))
        self.ciclo()
        self.assertEqual(len(self.todas()), 3)
        self.assertIn([len(p["log"]) for p in Coleta.recebidos[1]], ([int(3.5 * MB)],))
        self.assertFalse((self.raiz / ".coleta-quarentena").exists())

    def test_partida_acima_do_limite_vai_para_quarentena(self):
        grande = partida("2026-10-24 13:00:01", 5 * MB)
        self.escrever(partida("2026-10-24 13:00:00"), grande, partida("2026-10-24 13:00:02"))
        self.ciclo()
        self.assertEqual([p["time"] for p in self.todas()], ["2026-10-24 13:00:00", "2026-10-24 13:00:02"])
        guardadas = list((self.raiz / ".coleta-quarentena").iterdir())
        self.assertEqual([g.read_bytes() for g in guardadas], [grande])
        self.assertEqual(self.pos(), self.jsonl.stat().st_size)

    def test_espera_partida_incompleta(self):
        for tamanho in (1000, 5 * MB):  # pequena, e maior que o limite
            with self.subTest(tamanho=tamanho):
                self.setUp()
                linha = partida("2026-10-24 13:00:00", tamanho)
                self.escrever(partida("2026-10-24 12:59:59"), linha[:-50])
                self.ciclo()
                self.assertEqual(len(self.todas()), 1)
                antes = self.pos()
                self.ciclo()
                self.assertEqual(self.pos(), antes)  # não pula a partida pela metade
                self.escrever(linha[-50:])
                self.ciclo()
                self.assertEqual(self.pos(), self.jsonl.stat().st_size)
                quarentena = self.raiz / ".coleta-quarentena"
                enviada = len(self.todas()) == 2
                self.assertTrue(enviada or [g.read_bytes() for g in quarentena.iterdir()] == [linha])
                self.tearDown()

    def test_coleta_fora_nao_perde_nada(self):
        self.escrever(partida("2026-10-24 13:00:00"))
        Coleta.fora = True
        self.ciclo()
        self.assertEqual(self.pos(), 0)
        Coleta.fora = False
        self.ciclo()
        self.assertEqual(len(self.todas()), 1)

    def test_linha_invalida_e_pulada(self):
        self.escrever(partida("2026-10-24 13:00:00"), b'{"time": "quebr\n', partida("2026-10-24 13:00:01"))
        self.ciclo()
        self.assertEqual(len(self.todas()), 2)
        self.assertEqual(self.pos(), self.jsonl.stat().st_size)

    def test_registro_corrompido(self):
        self.escrever(partida("2026-10-24 13:00:00"))
        self.estado_arq.write_text('{"desde": "2026-10')
        estado = enviar._ler_estado(self.estado_arq)
        self.assertTrue((self.raiz / ".coleta-enviado.ruim").exists())
        enviar.ciclo("codigo", self.raiz, self.estado_arq, estado)
        self.assertEqual([p.get("antigo") for p in self.todas()], [True])  # o Discord não reposta

    def test_gravacao_atomica(self):
        enviar._gravar(self.estado_arq, self.estado)
        self.assertEqual(json.loads(self.estado_arq.read_text()), self.estado)
        self.assertEqual([p.name for p in self.raiz.iterdir() if p.name.endswith(".tmp")], [])


if __name__ == "__main__":
    unittest.main()
