"""Testes da leitura do backup e do contexto das séries no linux/treino-oponente.py (sem o Ai-vgc).

    python3 -m unittest discover -s tests
"""

import importlib.util
import json
import tempfile
import sys
import types
import unittest
from pathlib import Path
from unittest.mock import patch

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

    def test_formatos_hostis_nao_ocupam_tag_nem_chegam_ao_arquivo(self):
        ruins = ["../teste/probe", "../../probe", "/tmp/probe", r"..\teste\probe",
                 r"C:\probe", "C:probe", r"\\server\share\probe", "f:stream", "f\n", "ｆ", "a/b"]
        with tempfile.TemporaryDirectory() as tmp:
            raiz = Path(tmp)
            (raiz / "membro").mkdir()
            boa = {"tag": "battle-boa", "log": "log", "user": "u", "format": "gen9championsvgc2026regmcbo3"}
            linhas = [{**boa, "format": fmt} for fmt in ruins] + [boa]
            (raiz / "membro" / "games.jsonl").write_text("\n".join(map(json.dumps, linhas)), encoding="utf-8")
            self.assertEqual(treino._ler_backup(raiz), {"boa": boa})
            for fmt in ruins:
                with self.subTest(fmt=fmt), self.assertRaises(ValueError):
                    treino._arquivo_dataset(raiz, "teste", fmt)
            for fmt in ("f", "gen9championsvgc2026regmc", boa["format"]):
                self.assertEqual(treino._arquivo_dataset(raiz, "treino", fmt), raiz / "treino" / f"{fmt}.npz")

    def test_dados_nao_contamina_particoes_nem_escreve_fora(self):
        import numpy as np
        class Pool:
            def __init__(self, *args, **kwargs): pass
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def map(self, func, lotes):
                for lote in lotes:
                    yield {"opp": np.zeros((len(lote), 2, 2), dtype=np.int8),
                           "game": np.array([int(item[0]) for item in lote])}
        with tempfile.TemporaryDirectory() as tmp:
            raiz = Path(tmp)
            backup, out = raiz / "backup", raiz / "out"
            (backup / "membro").mkdir(parents=True)
            boa = {"log": "log", "user": "u", "format": "gen9championsvgc2026regmc"}
            rows = [{**boa, "tag": str(i), "time": str(i)} for i in (1, 2)]
            rows += [{**boa, "tag": str(i + 3), "time": "9", "format": fmt}
                     for i, fmt in enumerate(("../treino/poison", str(raiz / "fora"), r"..\teste\poison"))]
            (backup / "membro" / "games.jsonl").write_text("\n".join(map(json.dumps, rows)), encoding="utf-8")
            modules = {"ai_vgc.nn.encode": types.SimpleNamespace(vocab=lambda: None),
                       "ai_vgc.nn.series": types.SimpleNamespace(series_key=lambda _: None)}
            args = types.SimpleNamespace(out=out, backup=backup, substituir=False, com_nossos_bots=True,
                                         teste=0.5, workers=1, excluir=[])
            with patch.dict(sys.modules, modules), patch.object(treino, "ProcessPoolExecutor", Pool):
                treino.dados(args)
            self.assertEqual(sorted(p.relative_to(out).as_posix() for p in raiz.rglob("*.npz")),
                             [f"teste/{boa['format']}.npz", f"treino/{boa['format']}.npz"])
            for nome, jogo in (("treino", 1), ("teste", 2)):
                with np.load(out / nome / f"{boa['format']}.npz") as data:
                    self.assertEqual(data["game"].tolist(), [jogo])
            manifesto = json.loads((out / "manifesto.json").read_text())
            self.assertEqual(manifesto["series"], {"treino": 1, "teste": 1})

    def test_symlink_de_particao_nao_e_usado_nem_limpo(self):
        with tempfile.TemporaryDirectory() as tmp:
            raiz = Path(tmp)
            out, fora = raiz / "out", raiz / "fora"
            out.mkdir(); fora.mkdir()
            protegido = fora / "f.npz"
            protegido.write_bytes(b"preservar")
            try:
                (out / "treino").symlink_to(fora, target_is_directory=True)
            except OSError as exc:
                self.skipTest(f"symlinks indisponíveis: {exc}")
            with self.assertRaises(ValueError): treino._preparar_saida(out, True)
            with self.assertRaises(ValueError): treino._arquivo_dataset(out, "treino", "f")
            self.assertEqual(protegido.read_bytes(), b"preservar")

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
