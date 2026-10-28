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


if __name__ == "__main__":
    unittest.main()
