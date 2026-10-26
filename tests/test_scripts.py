"""Testes dos scripts do Linux: parada do bot (rodar-bot.sh) e reinício pendente (painel.sh).

Sem systemd nem Showdown: um bot.sh falso (zsh, como o do Ai-vgc) com um "Python" que joga,
cai ou termina, e um systemctl falso que só anota as chamadas.
"""

import json
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
  show) [[ "$*" == *lor-desafio-* ]] && echo "${ESTADO_DESAFIO:-inactive}" || echo "${ESTADO:-active}" ;;
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


# O bot "joga" enquanto $D/jogos > 0: cada "show" do lor-bot@bot gasta um; stop/start mudam o estado.
SYSTEMCTL_DESAFIO = r'''#!/usr/bin/env bash
echo "systemctl $*" >>"$D/log"
case "$1" in
  show)
    if [[ "$*" == *lor-desafio-* ]]; then echo "${ESTADO_DESAFIO:-inactive}"; exit 0; fi
    estado=$(cat "$D/estado")
    if [ "$estado" = active ] && [ -f "$D/jogos" ]; then
      j=$(cat "$D/jogos"); echo $((j - 1)) >"$D/jogos"; ((j > 0)) || estado=inactive
    fi
    echo "$estado" ;;
  start) echo active >"$D/estado"; cp "$D/bot.env" "$D/env-no-start-$(date +%s%N)" ;;
  stop) [[ "$*" == *lor-bot@* ]] && echo inactive >"$D/estado" ;;
esac
exit 0
'''


class TestPainelDesafio(unittest.TestCase):
    """Desafiar: valida, lança a unit lor-desafio-*, e o corpo dela troca o bot e volta ao ladder."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        d = Path(self.tmp.name)
        falsos = {"systemctl": SYSTEMCTL_DESAFIO, "id": "#!/bin/sh\necho 0\n", "chown": "#!/bin/sh\n",
                  "sleep": "#!/bin/sh\n", "journalctl": '#!/bin/sh\n[ -f "$D/aceito" ] && echo "watch: x"\nexit 0\n',
                  "systemd-run": '#!/bin/sh\necho "systemd-run $*" >>"$D/log"\n'}
        for nome, corpo in falsos.items():
            (d / nome).write_text(corpo)
            (d / nome).chmod(0o755)
        (d / "bot.conf").write_text("conta=LoR Bot1\nformato=bo3\n")
        (d / "bot.senha").write_text("x")
        (d / "estado").write_text("active")
        self.d = d
        self.env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "D": str(d),
                    "LOR_ETC": str(d), "LOR_RUN": str(d), "LOR_ELO_API": (d / "sem-api").as_uri() + "/"}
        self.dir = d / "lor-desafio-bot"

    def tearDown(self):
        self.tmp.cleanup()

    def painel(self, *args, entrada="", ok=True, **env) -> str:
        r = subprocess.run(["bash", str(RAIZ_REPO / "linux" / "painel.sh"), *args], input=entrada,
                           env={**self.env, **env}, capture_output=True, text=True)
        if ok:
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout

    def chamadas(self) -> list[str]:
        log = self.d / "log"
        return log.read_text().splitlines() if log.exists() else []

    def test_desafiar_valida_e_lanca(self):
        self.assertIn("erro=", self.painel("desafiar", entrada="\n", ok=False))
        self.assertIn("erro=partidas", self.painel("desafiar", "11", entrada="fulano\n", ok=False))
        self.assertIn("próprio bot", self.painel("desafiar", entrada="lorbot1\n", ok=False))
        self.assertIn("erro=já tem", self.painel("desafiar", entrada="fulano\n", ok=False, ESTADO_DESAFIO="active"))
        self.assertIn("ok=desafiando", self.painel("desafiar", "3", entrada="Sier VGC\r\n"))
        self.assertEqual((self.dir / "alvo").read_text().strip(), "siervgc")
        self.assertEqual((self.dir / "partidas").read_text().strip(), "3")
        self.assertEqual((self.dir / "voltar").read_text().strip(), "1")  # o ladder estava ligado
        self.assertTrue(any(x.startswith("systemd-run") and "lor-desafio-bot" in x and "_desafio" in x
                            for x in self.chamadas()))

    def test_durante_o_desafio(self):
        self.painel("desafiar", entrada="fulano\n")
        self.assertIn("ok=depois-do-desafio", self.painel("reiniciar", ESTADO_DESAFIO="active"))
        self.assertFalse(any(x.startswith("systemd-run") and "lor-reinicio" in x for x in self.chamadas()))
        estado = self.painel("estado", ESTADO_DESAFIO="active")
        self.assertIn("desafio=fulano", estado)
        self.assertIn("desafio_fase=esperando", estado)
        self.painel("desligar", ESTADO_DESAFIO="active")
        self.assertEqual((self.dir / "voltar").read_text().strip(), "0")
        self.assertTrue((self.dir / "cancelado").exists())

    def test_corpo_desafia_e_volta_ao_ladder(self):
        self.painel("desafiar", "2", entrada="fulano\n")
        (self.d / "aceito").touch()
        (self.d / "jogos").write_text("3")
        saida = self.painel("_desafio")
        c = self.chamadas()
        parou = c.index("systemctl stop lor-bot@bot")  # esperou a partida do ladder
        starts = [i for i, x in enumerate(c) if x == "systemctl start lor-bot@bot"]
        self.assertEqual(len(starts), 2, c)  # o desafio, e a volta ao ladder
        self.assertLess(parou, starts[0])
        envs = sorted(self.d.glob("env-no-start-*"))
        self.assertIn("--challenge fulano 2 --challenge-wait 300", envs[0].read_text())
        self.assertIn("--ladder", envs[1].read_text())
        self.assertIn("--ladder", (self.d / "bot.env").read_text())
        self.assertFalse(self.dir.exists())
        self.assertIn("Voltando ao ladder", saida)

    def test_corpo_cancelado_antes_de_comecar(self):
        self.painel("desafiar", entrada="fulano\n")
        (self.dir / "cancelado").write_text("1")
        (self.dir / "voltar").write_text("0")  # o que o "desligar" deixa
        self.painel("_desafio")
        self.assertNotIn("systemctl start lor-bot@bot", self.chamadas())
        self.assertIn("--ladder", (self.d / "bot.env").read_text())


class TestPainelPlacar(TestPainelDesafio):
    """estado: o placar que o bot grava em data/live_games/placar-<conta>.json."""

    def setUp(self):
        super().setUp()
        self.env["LOR_AIVGC"] = str(self.d / "ai")
        (self.d / "ai" / "data" / "live_games").mkdir(parents=True)
        self.arq = self.d / "ai" / "data" / "live_games" / "placar-lorbot1.json"  # conta "LoR Bot1"

    def gravar(self, idade: float = 0, **campos):
        import json
        dados = {"time": time.time() - idade, "opponent": "Rival", "bo3": True, "jogo": 2,
                 "serie": ["win"], "turn": 7, "nossos": 3, "deles": 1, "resultado": None, **campos}
        self.arq.write_text(json.dumps(dados))

    def placar(self) -> dict[str, str]:
        linhas = [x.split("=", 1) for x in self.painel("estado").splitlines() if x.startswith("placar_")]
        return dict(linhas)

    def test_mostra_o_placar_da_serie(self):
        self.gravar()
        self.assertEqual(self.placar(), {
            "placar_oponente": "Rival", "placar_bo3": "sim", "placar_jogo": "2", "placar_vitorias": "1",
            "placar_derrotas": "0", "placar_turno": "7", "placar_nossos": "3", "placar_deles": "1",
            "placar_resultado": ""})

    def test_sem_placar_com_bot_desligado(self):
        self.gravar()
        (self.d / "estado").write_text("inactive")
        self.assertEqual(self.placar(), {"placar_oponente": ""})

    def test_placar_velho_some_sem_partida(self):
        self.gravar(idade=3600)
        self.assertEqual(self.placar(), {"placar_oponente": ""})
        (self.d / "aceito").touch()  # agora há uma partida em andamento no log
        self.assertEqual(self.placar()["placar_oponente"], "Rival")

    def test_sem_arquivo_ou_arquivo_quebrado(self):
        self.assertEqual(self.placar(), {"placar_oponente": ""})
        self.arq.write_text("{quebrado")
        self.assertEqual(self.placar(), {"placar_oponente": ""})


class TestPainelTimer(TestPainelDesafio):
    """timer sim|nao: o bot liga (ou não) o timer em cada partida."""

    def test_timer_liga_por_padrao_e_desliga(self):
        self.assertIn("timer=sim", self.painel("estado").splitlines())
        self.painel("formato", "bo3")
        self.assertNotIn("--no-timer", (self.d / "bot.env").read_text())
        self.assertIn("ok=timer", self.painel("timer", "nao"))
        self.assertIn("timer=nao", self.painel("estado").splitlines())
        self.assertIn("--no-timer", (self.d / "bot.env").read_text())
        self.painel("timer", "sim")
        self.assertNotIn("--no-timer", (self.d / "bot.env").read_text())
        self.assertIn("erro=", self.painel("timer", "talvez", ok=False))



class TestPainelElo(TestPainelDesafio):
    """estado: o Elo da conta no ladder oficial, lido de um cache que se atualiza em segundo plano."""

    def setUp(self):
        super().setUp()
        api = self.d / "api"
        api.mkdir()
        (api / "lorbot1.json").write_text(json.dumps({"ratings": {
            "gen9championsvgc2026regmcbo3": {"elo": 1234.6, "gxe": 61.27, "w": 10, "l": 5, "t": 0},
            "gen9championsvgc2026regmc": {"elo": 1100, "w": 1, "l": 1}}}))
        self.env["LOR_ELO_API"] = api.as_uri() + "/"
        self.cache = self.d / "lor-elo-bot.json"

    def elo(self) -> dict[str, str]:
        return dict(x.split("=", 1) for x in self.painel("estado").splitlines() if x.startswith("elo"))

    def esperar_cache(self):
        for _ in range(50):
            if self.cache.exists():
                return
            time.sleep(0.1)
        self.fail("o estado não pediu a consulta do Elo")

    def test_consulta_em_segundo_plano_e_mostra(self):
        self.assertEqual(self.elo(), {"elo": ""})  # primeira vez: ainda sem cache
        self.esperar_cache()
        self.assertEqual(self.elo(), {"elo": "1235", "elo_partidas": "15", "elo_gxe": "61.3"})

    def test_formato_e_conta_trocados_nao_usam_o_cache_velho(self):
        self.painel("_elo")
        self.painel("formato", "bo1")
        self.assertEqual(self.elo(), {"elo": ""})
        self.painel("_elo")
        self.assertEqual(self.elo()["elo"], "1100")
        (self.d / "bot.conf").write_text("conta=Outra\nformato=bo1\n")
        self.assertEqual(self.elo(), {"elo": ""})

    def test_nosso_servidor_nao_mostra(self):
        self.painel("_elo")
        with open(self.d / "bot.conf", "a") as f:
            f.write("servidor=lor\n")
        self.assertEqual(self.elo(), {"elo": ""})

    def test_sem_rede_mantem_o_ultimo(self):
        self.painel("_elo")
        self.env["LOR_ELO_API"] = (self.d / "nao-existe").as_uri() + "/"
        self.painel("_elo")
        self.assertEqual(self.elo()["elo"], "1235")


# curl falso para o "codigo": responde como a coleta ao /coleta/ping, conforme $D/ping (200, 401 ou nada).
CURL_PING = r'''#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done
codigo=$(cat "$D/ping" 2>/dev/null || echo 000)
[ "$codigo" = 200 ] && echo '{"ok": true, "nome": "joao"}' >"$out"
printf %s "$codigo"
[ "$codigo" != 000 ]
'''


class TestPainelColeta(TestPainelDesafio):
    """codigo: conferido na coleta antes de salvar; estado: como foi o último envio; backup."""

    def setUp(self):
        super().setUp()
        (self.d / "curl").write_text(CURL_PING)
        (self.d / "curl").chmod(0o755)
        self.env["LOR_AIVGC"] = str(self.d / "ai")
        (self.d / "ai" / "data" / "live_games").mkdir(parents=True)

    def test_codigo_recusado_nao_salva(self):
        (self.d / "ping").write_text("401")
        self.assertIn("não reconheceu", self.painel("codigo", entrada="abcdefgh12\n", ok=False))
        self.assertFalse((self.d / "coleta.env").exists())

    def test_codigo_conferido_salva_e_diz_de_quem_e(self):
        (self.d / "ping").write_text("200")
        saida = self.painel("codigo", entrada="abcdefgh12\r\n")
        self.assertIn("membro=joao", saida)
        self.assertIn("ok=codigo", saida)
        self.assertEqual((self.d / "coleta.env").read_text(), "COLETA_CODIGO=abcdefgh12\n")

    def test_coleta_fora_salva_com_aviso(self):
        saida = self.painel("codigo", entrada="abcdefgh12\n")
        self.assertIn("aviso=", saida)
        self.assertTrue((self.d / "coleta.env").exists())

    def test_estado_mostra_o_ultimo_envio(self):
        st = self.d / "ai" / "data" / "live_games" / ".coleta-status"
        self.assertIn("envio_status=", self.painel("estado").splitlines())
        st.write_text(json.dumps({"time": 1, "status": "codigo", "nome": None}))
        self.assertIn("envio_status=codigo", self.painel("estado").splitlines())
        st.write_text("{quebrado")
        self.assertIn("envio_status=", self.painel("estado").splitlines())

    def test_backup_grava_e_liga_o_timer(self):
        self.assertIn("erro=", self.painel("backup", "relativa", entrada="x" * 20 + "\n", ok=False))
        self.assertIn("erro=token", self.painel("backup", str(self.d / "copia"), entrada="curto\n", ok=False))
        self.assertIn("ok=backup", self.painel("backup", str(self.d / "copia"), entrada="A" * 40 + "\n"))
        env = (self.d / "backup.env").read_text()
        self.assertIn("BACKUP_TOKEN=" + "A" * 40, env)
        self.assertIn(f'BACKUP_DIR="{self.d / "copia"}"', env)
        self.assertIn("systemctl enable --now lor-backup.timer", self.chamadas())
        self.assertIn("ok=backup-desligado", self.painel("backup", "desligar"))


class TestPainelHoje(TestPainelPlacar):
    """estado: o placar do dia (vitórias e derrotas de hoje, por time) e o log na mesma chamada."""

    def escrever(self, dia: str, *linhas: dict):
        pasta = self.d / "ai" / "data" / "live_games" / dia
        pasta.mkdir(exist_ok=True)
        with open(pasta / "games.jsonl", "a") as f:
            for linha in linhas:
                f.write(json.dumps(linha) + "\n")

    def hoje(self) -> dict[str, str]:
        return dict(x.split("=", 1) for x in self.painel("estado").splitlines() if x.startswith("hoje_"))

    def test_conta_so_hoje_e_a_conta(self):
        hoje = time.strftime("%Y-%m-%d")
        ontem = time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400))
        jogo = {"user": "LoR Bot1", "team": "MC371", "result": "win", "time": f"{hoje} 10:00:00"}
        # O bot ligou ontem e passou da meia-noite: as partidas de hoje ainda caem na pasta de ontem.
        self.escrever(ontem, {**jogo, "time": f"{ontem} 23:00:00"}, jogo, {**jogo, "result": "loss"})
        self.escrever(hoje, {**jogo, "team": "LOR-NiceMeta"}, {**jogo, "user": "Outra"})
        self.assertEqual(self.hoje(), {"hoje_vitorias": "2", "hoje_derrotas": "1",
                                       "hoje_times": "MC371 1-1, NiceMeta 1-0"})
        self.escrever(hoje, {**jogo, "result": "loss"})  # arquivo mudou: recalcula
        self.assertEqual(self.hoje()["hoje_derrotas"], "2")

    def test_sem_partidas(self):
        self.assertEqual(self.hoje(), {"hoje_vitorias": "0", "hoje_derrotas": "0", "hoje_times": ""})

    def test_log_na_mesma_chamada(self):
        (self.d / "aceito").touch()  # o journalctl falso responde "watch: x"
        saida = self.painel("estado", "--log", "80")
        chaves, log = saida.split("---log---\n")
        self.assertIn("bot=active", chaves)
        self.assertEqual(log.strip(), "watch: x")
        self.assertNotIn("---log---", self.painel("estado"))


if __name__ == "__main__":
    unittest.main()
