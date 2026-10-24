"""Testes dos scripts do Linux: parada do bot (rodar-bot.sh) e reinício pendente (painel.sh).

Sem systemd nem Showdown: um bot.sh falso (zsh, como o do Ai-vgc) com um "Python" que joga,
cai ou termina, e um systemctl falso que só anota as chamadas.
"""

import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent

PYTHON_FALSO = r'''
import signal, sys, time
modo, parar = sys.argv[2], []
signal.signal(signal.SIGINT, lambda *_: parar.append(1) or print("py: INT", flush=True))
print("py: start", flush=True)
if modo == "cai":            # a conexão cai logo: o bot.sh reconecta depois de 10 s
    time.sleep(0.5); sys.exit(75)
while not parar:             # "partida": joga até pedirem para parar
    time.sleep(0.1)
time.sleep(1)
if modo == "caiparando":     # cai depois do pedido, no meio da partida
    print("py: caiu", flush=True); sys.exit(75)
print("py: fim da partida", flush=True)
'''

BOT_SH_FALSO = r'''#!/usr/bin/env zsh
set -e
while true; do
  code=0
  python3 {dir}/fake.py ai_vgc.nn.player $(cat {dir}/modo) || code=$?
  (( code == 75 )) || exit $code
  echo "sh: reconectando em 10 s"; sleep 10
done
'''


@unittest.skipUnless(shutil.which("zsh"), "precisa de zsh (o bot.sh do Ai-vgc é zsh)")
class TestRodarBot(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        (d / "ai" / "scripts").mkdir(parents=True)
        (d / "fake.py").write_text(PYTHON_FALSO)
        (d / "ai" / "scripts" / "bot.sh").write_text(BOT_SH_FALSO.format(dir=d))
        script = (RAIZ_REPO / "linux" / "rodar-bot.sh").read_text().replace("/opt/lor-bots/ai-vgc", str(d / "ai"))
        (d / "rodar.sh").write_text(script)
        (d / "rodar.sh").chmod(0o755)
        self.d = d

    def tearDown(self):
        subprocess.run(["pkill", "-f", f"{self.d}/fake[.]py"])
        self.tmp.cleanup()

    def parar_depois(self, modo: str, espera: float) -> tuple[int, float, str]:
        (self.d / "modo").write_text(modo)
        env = {**os.environ, "BOT": "x", "PS_PASSWORD": "y", "MODO": "--ladder"}
        p = subprocess.Popen([str(self.d / "rodar.sh")], env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True)
        time.sleep(espera)
        t0 = time.time()
        p.send_signal(signal.SIGINT)  # o que o systemd manda (KillSignal=SIGINT)
        saida, _ = p.communicate(timeout=30)
        return p.returncode, time.time() - t0, saida

    def sem_python_sobrando(self):
        time.sleep(0.5)
        r = subprocess.run(["pgrep", "-f", f"{self.d}/fake[.]py"], capture_output=True)
        self.assertNotEqual(r.returncode, 0, "sobrou um Python do bot rodando")

    def test_parada_na_espera_de_reconexao(self):
        codigo, demora, saida = self.parar_depois("cai", 2)
        self.assertEqual(codigo, 0, saida)
        self.assertLess(demora, 5, saida)  # não espera os 10 s nem relança
        self.assertEqual(saida.count("py: start"), 1, saida)
        self.sem_python_sobrando()

    def test_parada_termina_a_partida(self):
        codigo, demora, saida = self.parar_depois("partida", 1.5)
        self.assertEqual(codigo, 0, saida)
        self.assertIn("py: fim da partida", saida)
        self.sem_python_sobrando()

    def test_queda_depois_do_pedido_nao_relanca(self):
        codigo, demora, saida = self.parar_depois("caiparando", 1.5)
        self.assertEqual(codigo, 0, saida)
        self.assertEqual(saida.count("py: start"), 1, saida)
        self.sem_python_sobrando()


SYSTEMCTL_FALSO = r'''#!/usr/bin/env bash
echo "systemctl $*" >>"$LOG"
case "$1" in
  list-units) [ -f "$PENDENTE" ] && echo "lor-reinicio-bot-1700000000.service loaded active running x" ;;
  show) echo "${ESTADO:-active}" ;;
  stop) [[ "$2" == lor-reinicio-* ]] && rm -f "$PENDENTE" ;;
esac
exit 0
'''


class TestPainelReinicio(unittest.TestCase):
    """Aplicar agenda parar+ligar numa unit lor-reinicio-*; Desligar tem de cancelar o ligar."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        for nome, corpo in (("systemctl", SYSTEMCTL_FALSO), ("id", "#!/bin/sh\necho 0\n"),
                            ("systemd-run", '#!/bin/sh\necho "systemd-run $*" >>"$LOG"\n')):
            (d / nome).write_text(corpo)
            (d / nome).chmod(0o755)
        self.d = d
        self.env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "LOG": str(d / "log"),
                    "PENDENTE": str(d / "pendente")}

    def tearDown(self):
        self.tmp.cleanup()

    def painel(self, *args, **env) -> str:
        r = subprocess.run(["bash", str(RAIZ_REPO / "linux" / "painel.sh"), *args],
                           env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def chamadas(self) -> list[str]:
        log = self.d / "log"
        return log.read_text().splitlines() if log.exists() else []

    def test_desligar_cancela_reinicio_pendente(self):
        for comando in ("desligar", "agora"):
            with self.subTest(comando=comando):
                (self.d / "pendente").touch()
                (self.d / "log").unlink(missing_ok=True)
                self.painel(comando)
                c = self.chamadas()
                cancelou = c.index("systemctl stop lor-reinicio-bot-1700000000.service")
                parou = next(i for i, x in enumerate(c) if x.startswith("systemctl stop") and "lor-bot@bot" in x)
                self.assertLess(cancelou, parou, c)

    def test_desligar_sem_reinicio_pendente(self):
        self.assertIn("ok=desligando", self.painel("desligar"))
        self.assertFalse(any("lor-reinicio" in x and "stop" in x for x in self.chamadas()))

    def test_aplicar_de_novo_durante_reinicio_ainda_religa(self):
        (self.d / "pendente").touch()
        saida = self.painel("reiniciar", ESTADO="deactivating")  # o 1º Aplicar já está parando o bot
        self.assertIn("ok=reiniciando", saida)
        self.assertTrue(any(x.startswith("systemd-run") for x in self.chamadas()))

    def test_aplicar_com_bot_desligando_por_pedido_nao_religa(self):
        saida = self.painel("reiniciar", ESTADO="deactivating")  # Desligar, sem Aplicar pendente
        self.assertIn("ok=parado", saida)


if __name__ == "__main__":
    unittest.main()
