"""reaplicar-patch.sh: o patch do Ai-vgc aplica de novo depois do checkout -f, mesmo quando ele cria arquivos.

Com git de verdade num repositório de mentira: aplicar -> restaurar (checkout -f, como o
instalar.sh) -> reaplicar, e a troca de um patch que cria arquivos por outro que não cria.
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
SCRIPT = RAIZ_REPO / "linux" / "reaplicar-patch.sh"


def git(cwd: Path, *args: str) -> str:
    return subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], cwd=cwd,
                          check=True, capture_output=True, text=True).stdout


@unittest.skipUnless(shutil.which("git"), "precisa de git")
class TestReaplicarPatch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        self.repo = d / "ai-vgc"
        (self.repo / "src").mkdir(parents=True)
        git(self.repo, "init", "-q")
        (self.repo / "src" / "busca.py").write_text("prior = 0.1\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-q", "-m", "base")
        # Patch 1: muda um arquivo do git e cria dois (como o da 2026.10.29.2).
        (self.repo / "src" / "busca.py").write_text("prior = 0.03\n")
        (self.repo / "tests" / "fixtures").mkdir(parents=True)
        (self.repo / "tests" / "fixtures" / "estado.json").write_text("{}\n")
        (self.repo / "tests" / "test_pivo.py").write_text("# teste\n")
        git(self.repo, "add", "-N", ".")
        self.patch1 = d / "patch1"
        self.patch1.write_text(git(self.repo, "diff"))
        # Patch 2: só a mudança no arquivo do git.
        self.patch2 = d / "patch2"
        self.patch2.write_text(git(self.repo, "diff", "--", "src"))
        git(self.repo, "reset", "-q")
        self.restaurar()
        shutil.rmtree(self.repo / "tests")
        # O que não é do git e não é do patch (partidas, modelos, simulador) tem que ficar.
        (self.repo / "data").mkdir()
        (self.repo / "data" / "partidas.json").write_text("[1]\n")
        self.nenhum = d / "nao-existe"

    def tearDown(self):
        self.tmp.cleanup()

    def restaurar(self):
        git(self.repo, "checkout", "-q", "-f", "HEAD")

    def reaplicar(self, anterior: Path, novo: Path) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", str(SCRIPT), str(self.repo), str(anterior), str(novo)],
                              capture_output=True, text=True)

    def test_aplicar_restaurar_reaplicar(self):
        r = self.reaplicar(self.nenhum, self.patch1)  # instalação nova
        self.assertEqual(r.returncode, 0, r.stderr)
        self.restaurar()
        self.assertTrue((self.repo / "tests" / "test_pivo.py").exists())  # o checkout -f não apaga
        # Só o git apply, como era antes, falha:
        falha = subprocess.run(["git", "apply", str(self.patch1)], cwd=self.repo, capture_output=True)
        self.assertNotEqual(falha.returncode, 0)
        r = self.reaplicar(self.patch1, self.patch1)  # mesma versão de novo (instalação interrompida)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.repo / "src" / "busca.py").read_text(), "prior = 0.03\n")
        self.assertEqual((self.repo / "data" / "partidas.json").read_text(), "[1]\n")

    def test_troca_para_um_patch_que_nao_cria_e_volta(self):
        self.assertEqual(self.reaplicar(self.nenhum, self.patch1).returncode, 0)
        self.restaurar()
        r = self.reaplicar(self.patch1, self.patch2)  # atualização: apaga o que o anterior criou
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse((self.repo / "tests" / "test_pivo.py").exists())
        self.restaurar()
        r = self.reaplicar(self.patch2, self.patch1)  # volta (rollback) para a versão anterior
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue((self.repo / "tests" / "test_pivo.py").exists())
        self.assertEqual((self.repo / "data" / "partidas.json").read_text(), "[1]\n")

    def test_nao_apaga_arquivo_do_git(self):
        # Um patch que "cria" um caminho que já é do git falha no apply, sem apagar nada.
        self.assertEqual(self.reaplicar(self.nenhum, self.patch1).returncode, 0)
        git(self.repo, "add", "tests")
        git(self.repo, "commit", "-q", "-m", "testes no git")
        r = self.reaplicar(self.patch1, self.patch1)
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue((self.repo / "tests" / "test_pivo.py").exists())


if __name__ == "__main__":
    unittest.main()
