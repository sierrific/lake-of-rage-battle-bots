"""Testes do linux/enviar-partidas.py contra uma coleta falsa (só biblioteca padrão).

    python3 -m unittest discover -s tests
"""

import importlib.util
import itertools
import json
import re
import tempfile
import threading
import time
import unittest
import unittest.mock
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("enviar", RAIZ_REPO / "linux" / "enviar-partidas.py")
enviar = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enviar)

MB = 1024 * 1024


TAG = re.compile(r"^battle-[a-z0-9-]{1,120}$")  # o da coleta (LOR-SD-Server coleta/coleta.py)
_numero = itertools.count(1)


class Coleta(BaseHTTPRequestHandler):
    """Como a coleta da VPS: recusa (413) envios acima de 4 MB e (400) o envio inteiro se uma linha
    não for um objeto JSON com tag battle-...; `fora` simula a VPS caída."""

    recebidos: list[list[dict]] = []
    fora = False

    def do_POST(self):
        tamanho = int(self.headers["Content-Length"])
        corpo = self.rfile.read(tamanho)
        if Coleta.fora:
            return self._responder(503, {"erro": "fora"})
        if tamanho > enviar.LIMITE:
            return self._responder(413, {"erro": "grande"})
        try:
            linhas = [json.loads(x) for x in corpo.splitlines() if x.strip()]
        except ValueError:
            return self._responder(400, {"erro": "linha que não é JSON"})
        if not all(isinstance(x, dict) and TAG.match(str(x.get("tag", ""))) for x in linhas):
            return self._responder(400, {"erro": "cada linha precisa de um tag battle-..."})
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
    tag = f"battle-gen9vgc2026regmc-{next(_numero)}"
    return json.dumps({"time": hora, "tag": tag, "log": "x" * tamanho}).encode() + b"\n"


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
        enviar.SEM_DISCORD = self.raiz / "sem-discord"  # nunca o /etc/lor-bots do PC dos testes

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

    def test_historico_privado_nunca_vai_para_coleta(self):
        mensagens = self.raiz / '.messages'
        mensagens.mkdir()
        privada = json.dumps({'kind': 'pm', 'sender': 'Amigo', 'text': 'segredo-sintetico'}) + '\n'
        (mensagens / 'conta.jsonl').write_text(privada)
        (mensagens / 'conta.jsonl.1').write_text(privada)
        self.escrever(partida('2026-10-24 13:00:00'))
        self.ciclo()
        self.assertEqual(len(self.todas()), 1)
        self.assertNotIn('segredo-sintetico', json.dumps(self.todas()))
        self.assertNotIn('.messages', json.dumps(self.estado))

    def test_discord_desligado_marca_as_partidas(self):
        self.escrever(partida("2026-10-24 13:00:00"))
        self.ciclo()
        enviar.SEM_DISCORD.touch()  # painel.sh discord nao: vale no ciclo seguinte, sem reiniciar
        self.escrever(partida("2026-10-24 11:00:00"), partida("2026-10-24 13:00:01"))
        self.ciclo()
        enviar.SEM_DISCORD.unlink()
        self.escrever(partida("2026-10-24 13:00:02"))
        self.ciclo()
        self.assertEqual([p.get("discord", True) for p in self.todas()], [True, False, False, True])
        self.assertEqual([p.get("antigo", False) for p in self.todas()], [False, True, False, False])

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

    def test_status_para_o_painel(self):
        enviar.STATUS = self.raiz / ".coleta-status"
        try:
            self.escrever(partida("2026-10-24 13:00:00"))
            Coleta.fora = True
            self.ciclo()
            self.assertEqual(json.loads(enviar.STATUS.read_text())["status"], "fora")
            Coleta.fora = False
            self.ciclo()
            self.assertEqual(json.loads(enviar.STATUS.read_text())["status"], "ok")
        finally:
            enviar.STATUS = None

    def test_linha_invalida_e_pulada(self):
        self.escrever(partida("2026-10-24 13:00:00"), b'{"time": "quebr\n', partida("2026-10-24 13:00:01"))
        self.ciclo()
        self.assertEqual(len(self.todas()), 2)
        self.assertEqual(self.pos(), self.jsonl.stat().st_size)

    def test_linha_sem_formato_de_partida_vai_para_quarentena(self):
        # A coleta recusaria o lote inteiro; antes, [] ou null derrubavam o envio no mesmo ponto.
        ruins = [b"[]\n", b"null\n", b'"texto"\n', b"42\n", b'{"time": "2026-10-24 13:00:00", "log": "x"}\n',
                 b'{"tag": "outra-coisa", "log": "x"}\n']
        self.escrever(partida("2026-10-24 13:00:00"), *ruins, partida("2026-10-24 13:00:01"))
        self.ciclo()
        self.assertEqual([p["time"] for p in self.todas()], ["2026-10-24 13:00:00", "2026-10-24 13:00:01"])
        self.assertEqual(self.pos(), self.jsonl.stat().st_size)
        guardadas = sorted((self.raiz / ".coleta-quarentena").iterdir(), key=lambda g: int(g.name.rsplit("-", 1)[1]))
        self.assertEqual([g.read_bytes() for g in guardadas], ruins)
        self.ciclo()  # e não volta a elas
        self.assertEqual(len(self.todas()), 2)

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


class TestSinal(unittest.TestCase):
    """O sinal de vida: as contas deste PC e o estado de cada uma, para a página de admin."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.etc = Path(self.tmp.name)
        enviar.ETC = self.etc
        (self.etc / "bot.env").write_text('BOT=MadMage\nSERVIDOR=oficial\nMODO="--ladder --model data/models/mc-bo3-rnad-v6.pt --search-prior 0.03"\n')
        (self.etc / "treino.env").write_text("BOT=LoR Sierra\nSERVIDOR=lor\n")
        (self.etc / "coleta.env").write_text("COLETA_CODIGO=segredo\n")
        (self.etc / "vazio.env").write_text("SERVIDOR=lor\n")
        (self.etc / "exemplo.env").write_text("BOT=LoRBot1\nSERVIDOR=oficial\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_partida_atual(self):
        log = "watch: https://play.pokemonshowdown.com/battle-a-1\nwin vs X\nwatch: https://play.pokemonshowdown.com/battle-a-2\n"
        self.assertEqual(enviar.partida_atual(log), "https://play.pokemonshowdown.com/battle-a-2")
        self.assertEqual(enviar.partida_atual(log + "loss vs Y\n"), "")
        self.assertEqual(enviar.partida_atual(""), "")
        # Bo3: o jogo 2 abre antes de o bot escrever o resultado do jogo 1.
        bo3 = ("watch: https://x/battle-g-111\nwatch: https://x/battle-g-222\n"
               "win vs X in 5 turns (/opt/ai/data/live_games/2026-11-05/battle-g-111.html)\n")
        self.assertEqual(enviar.partida_atual(bo3), "https://x/battle-g-222")
        self.assertEqual(enviar.partida_atual(bo3 + "loss vs X in 9 turns (/opt/battle-g-222.html)\n"), "")

    def test_bots_deste_pc(self):
        def rodar(cmd):
            if cmd[0] == "journalctl":
                return "watch: https://play.pokemonshowdown.com/battle-x-9\n" if "lor-bot@bot" in cmd else ""
            return {"lor-bot@bot": "active\n", "lor-bot@treino": "inactive\n",
                    "lor-desafio-bot": "inactive\n", "lor-desafio-treino": "inactive\n"}[cmd[-1]]
        raiz = self.etc / "live_games"
        raiz.mkdir()
        (raiz / "placar-madmage.json").write_text(json.dumps({
            "time": time.time() - 5, "tag": "battle-x-9", "format": "gen9x", "opponent": "Rival", "turn": 4,
            "nossos": 3, "deles": 4, "bo3": True, "jogo": 2, "serie": ["loss"], "resultado": None}))
        (raiz / "placar-lorsierra.json").write_text(json.dumps({"time": time.time(), "tag": "battle-y-1"}))
        bots = enviar.bots_deste_pc(rodar, raiz)
        self.assertEqual(bots, [
            {"conta": "MadMage", "estado": "active", "partida": "https://play.pokemonshowdown.com/battle-x-9",
             "servidor": "oficial", "modelo": "mc-bo3-rnad-v6", "desafio": False,
             "placar": {"oponente": "Rival", "formato": "gen9x", "bo3": True, "jogo": 2, "vitorias": 0,
                        "derrotas": 1, "turno": 4, "nossos": 3, "deles": 4, "idade": 5}},
            {"conta": "LoR Sierra", "estado": "inactive", "partida": "", "servidor": "lor", "modelo": "",
             "desafio": False, "placar": None},
        ])  # sem coleta.env (o código nunca vai no sinal), exemplo.env nem .env sem conta

    def test_modelo_do_modo(self):
        self.assertEqual(enviar.modelo_do_modo("--ladder --model data/models/mc-bo3-rnad-v5.pt --bo1"),
                         "mc-bo3-rnad-v5")
        self.assertEqual(enviar.modelo_do_modo("--model=x/y/meu-modelo.pt"), "meu-modelo")
        self.assertEqual(enviar.modelo_do_modo("--ladder --use MC371"), "")
        self.assertEqual(enviar.modelo_do_modo(""), "")

    def test_placar_de_outra_partida_ou_velho(self):
        raiz = self.etc
        url = "https://play.pokemonshowdown.com/battle-x-9"
        (raiz / "placar-madmage.json").write_text(json.dumps({"time": 1000.0, "tag": "battle-x-9"}))
        self.assertIsNotNone(enviar.placar(raiz, "MadMage", url, agora=1010.0))
        self.assertIsNone(enviar.placar(raiz, "MadMage", url, agora=1000.0 + enviar.PLACAR_VALIDO))
        self.assertIsNone(enviar.placar(raiz, "MadMage", url.replace("x-9", "x-10"), agora=1010.0))
        self.assertIsNone(enviar.placar(raiz, "MadMage", "", agora=1010.0))
        (raiz / "placar-madmage.json").write_text("{quebrado")
        self.assertIsNone(enviar.placar(raiz, "MadMage", url, agora=1010.0))

    def test_sinal_nunca_derruba_o_envio(self):
        url, bots = enviar.URL, enviar.bots_deste_pc
        enviar.URL = "http://127.0.0.1:9/partidas"  # ninguém ouvindo
        enviar.bots_deste_pc = lambda rodar=None, raiz=None: []
        try:
            self.assertFalse(enviar.sinal("codigo"))
        finally:
            enviar.URL, enviar.bots_deste_pc = url, bots


    def test_sinal_nao_espera_o_envio_de_um_acumulo(self):
        # Um acúmulo de partidas com a coleta lenta prende o ciclo de envio por minutos; o sinal de
        # vida segue no próprio ritmo (revisão de código de 06/11).
        chamadas, envio_preso, parar = [], threading.Event(), threading.Event()
        sinal, ciclo, a_cada = enviar.sinal, enviar.ciclo, enviar.SINAL_A_CADA

        def sinal_falso(codigo, raiz=None):
            chamadas.append(time.monotonic())
            return False

        def ciclo_preso(*args):
            envio_preso.wait(10)  # "a coleta demora": o envio fica parado aqui
            parar.set()
            raise SystemExit

        enviar.sinal, enviar.ciclo, enviar.SINAL_A_CADA = sinal_falso, ciclo_preso, 0.05
        try:
            with tempfile.TemporaryDirectory() as d, \
                    unittest.mock.patch.dict("os.environ", COLETA_CODIGO="codigo-teste"), \
                    unittest.mock.patch.object(enviar, "testar", lambda codigo: None), \
                    unittest.mock.patch("sys.argv", ["enviar-partidas.py", d]):
                principal = threading.Thread(target=lambda: self.assertRaises(SystemExit, enviar.main))
                principal.start()
                prazo = time.monotonic() + 5
                while len(chamadas) < 3 and time.monotonic() < prazo:
                    time.sleep(0.01)
                envio_preso.set()
                principal.join(5)
            self.assertGreaterEqual(len(chamadas), 3, "o sinal esperou o envio terminar")
        finally:
            envio_preso.set()
            enviar.sinal, enviar.ciclo, enviar.SINAL_A_CADA = sinal, ciclo, a_cada

    def test_sinal_continuo_sobrevive_a_um_erro(self):
        sinal, a_cada = enviar.sinal, enviar.SINAL_A_CADA
        parar, chamadas = threading.Event(), []

        def sinal_falso(codigo, raiz=None):
            chamadas.append(1)
            if len(chamadas) == 1:
                raise RuntimeError("journal quebrado")
            parar.set()
            return False

        enviar.sinal, enviar.SINAL_A_CADA = sinal_falso, 0.01
        try:
            enviar.sinal_continuo("codigo", Path("."), parar)
        finally:
            enviar.sinal, enviar.SINAL_A_CADA = sinal, a_cada
        self.assertEqual(len(chamadas), 2)


if __name__ == "__main__":
    unittest.main()
