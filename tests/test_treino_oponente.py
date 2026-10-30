"""Testes da leitura do backup e do contexto das séries no linux/treino-oponente.py (sem o Ai-vgc).

    python3 -m unittest discover -s tests
"""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent

try:
    import numpy  # noqa: F401  (o script importa no topo; o resto do Ai-vgc só dentro das funções)
except ImportError:
    treino = None
else:
    spec = importlib.util.spec_from_file_location("treino", RAIZ_REPO / "linux" / "treino-oponente.py")
    treino = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(treino)


@unittest.skipIf(treino is None, "precisa de numpy")
class TestTreinoOponente(unittest.TestCase):
    JOGOS = {t: {"log": f"log {t}"} for t in ("a", "b", "c")}

    def test_serie_completa_leva_os_jogos_anteriores(self):
        self.assertEqual(treino._contexto([(2, "b"), (1, "a"), (3, "c")], self.JOGOS),
                         [("a", []), ("b", ["log a"]), ("c", ["log a", "log b"])])

    def test_serie_incompleta_vai_sem_contexto(self):
        # Backup com só o jogo 2, ou com o 1 e o 3: antes dava KeyError e parava a geração inteira.
        self.assertEqual(treino._contexto([(2, "b")], self.JOGOS), [("b", [])])
        self.assertEqual(treino._contexto([(1, "a"), (3, "c")], self.JOGOS), [("a", []), ("c", [])])

    def test_backup_ignora_linhas_que_nao_sao_partidas(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "Sier").mkdir()
            boa = {"log": "x", "tag": "battle-gen9-1", "user": "u", "format": "f", "time": "1"}
            linhas = [json.dumps(boa), "[]", "null", "42", "{quebrada", json.dumps({**boa, "tag": None}),
                      json.dumps({"log": "x", "tag": "battle-gen9-2"}), json.dumps(boa)]
            (Path(tmp) / "Sier" / "games.jsonl").write_text("\n".join(linhas) + "\n")
            self.assertEqual(list(treino._ler_backup(Path(tmp))), ["gen9-1"])

    def test_tira_jogos_entre_os_nossos_bots(self):
        def jogo(user, p1, p2):
            return {"user": user, "log": f"|j|x\n|player|p1|{p1}|1|\n|player|p2|{p2}|2|1300\n|turn|1"}
        jogos = {"a": jogo("MadMageofMtBaratok", "MadMageofMtBaratok", "Humano"),
                 "b": jogo("MadMageofMtBaratok", "Ynokmon", "MadMage of MtBaratok"),
                 "c": jogo("Ynokmon", "Ynokmon", "Outro Humano"),
                 "d": jogo("Ynokmon", "HeySidet", "Ynokmon")}
        fica, fora = treino._sem_nossos_bots(jogos, ["Hey Sidet"])
        self.assertEqual((sorted(fica), fora), (["a", "c"], 2))

    def test_lado_do_bot_que_jogou_sem_login(self):
        nomes = {"p1": "Guest 3506156", "p2": "Humano X"}
        self.assertEqual(treino._papel(nomes, "the bugcather", "Humano X"), "p1")
        self.assertEqual(treino._papel({"p1": "the bugcather", "p2": "H"}, "The Bugcather", "H"), "p1")
        self.assertIsNone(treino._papel(nomes, "the bugcather", ""))
        self.assertIsNone(treino._papel(nomes, "the bugcather", "Outro"))

    def test_saida_com_geracao_anterior_e_recusada_ou_limpa(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            treino._preparar_saida(out, False)  # vazia: segue
            (out / "treino").mkdir()
            (out / "teste").mkdir()
            (out / "treino" / "gen9vgc2026regmc.npz").write_bytes(b"x")
            (out / "teste" / "formato-que-sumiu.npz").write_bytes(b"x")
            (out / "manifesto.json").write_text("{}")
            with self.assertRaises(SystemExit):
                treino._preparar_saida(out, False)
            self.assertTrue((out / "teste" / "formato-que-sumiu.npz").exists())
            treino._preparar_saida(out, True)
            self.assertEqual(list(out.rglob("*.npz")), [])
            self.assertFalse((out / "manifesto.json").exists())

    def test_particao_vazia_para_antes_de_treinar(self):
        treino._conferir_particoes(500, 60, 50)
        for tr, va in ((500, 0), (0, 60), (500, 10)):
            with self.subTest(tr=tr, va=va), self.assertRaises(SystemExit):
                treino._conferir_particoes(tr, va, 50)


if __name__ == "__main__":
    unittest.main()
