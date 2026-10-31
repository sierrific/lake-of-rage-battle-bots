#!/usr/bin/env python3
"""Manda as partidas deste bot para a coleta do time (na VPS), para o treino e o Discord.

Lê as linhas novas de data/live_games/*/games.jsonl (uma por partida, com o log completo) e
envia para COLETA_URL com o código do bot. Guarda até onde já enviou em <pasta>/.coleta-enviado;
se a VPS estiver fora, tenta de novo no próximo ciclo sem perder nada.

    COLETA_CODIGO=... python3 enviar-partidas.py /opt/lor-bots/ai-vgc/data/live_games

Grava em <pasta>/.coleta-status como foi o último contato com a coleta ("ok", "codigo" = código
recusado, "fora" = sem resposta), para o painel mostrar se o envio funciona de verdade.

A cada minuto manda também um sinal de vida para /coleta/sinal: as contas de bot deste PC, se
cada uma está ligada e a partida em andamento (do journal do lor-bot@<bot>). É o que a página de
admin da coleta usa para mostrar quem está online agora.

Manda também as partidas de antes da primeira execução (servem para o treino), marcadas com
"antigo" para o Discord não postar tudo de uma vez. Com o Discord desligado no painel (existe
SEM_DISCORD), as partidas vão com "discord": false: a coleta guarda para o treino e não posta.
Só biblioteca padrão.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ.get("COLETA_URL", "https://showdown.sierverso.com.br/coleta/partidas")
POLL = 30  # segundos entre leituras
LOTE = 3 * 1024 * 1024  # bytes por envio, juntando várias partidas
LIMITE = 4 * 1024 * 1024  # o máximo que a coleta aceita por envio: uma partida maior vai para a quarentena
TAG = re.compile(r"^battle-[a-z0-9-]{1,120}$")  # o mesmo que a coleta exige em cada linha
SEM_DISCORD = Path(os.environ.get("LOR_SEM_DISCORD", "/etc/lor-bots/sem-discord"))  # painel.sh discord
ETC = Path(os.environ.get("LOR_ETC", "/etc/lor-bots"))  # um <bot>.env por bot (BOT=conta, SERVIDOR=...)
VERSAO = Path(os.environ.get("LOR_VERSAO", "/opt/lor-bots/VERSION"))
SINAL_A_CADA = 60  # segundos entre sinais de vida; a página considera offline depois de 3 min sem
STATUS: Path | None = None  # <pasta>/.coleta-status (definido no main)
_membro: str | None = None  # o nome que a coleta deu a este código (resposta do ping)


def status(situacao: str, nome: str | None = None) -> None:
    """Anota o último contato com a coleta para o painel; nunca atrapalha o envio."""
    global _membro
    _membro = nome or _membro
    if STATUS is None:
        return
    try:
        tmp = STATUS.with_name(STATUS.name + ".tmp")
        tmp.write_text(json.dumps({"time": time.time(), "status": situacao, "nome": _membro}))
        os.replace(tmp, STATUS)
    except OSError:
        pass


def testar(codigo: str) -> None:
    """Confere o código em /coleta/ping ao começar, para o painel saber logo se ele vale."""
    req = urllib.request.Request(URL.rsplit("/", 1)[0] + "/ping", headers={
        "Authorization": f"Bearer {codigo}", "User-Agent": "lor-bots-envio"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            status("ok", json.loads(r.read()).get("nome"))
    except urllib.error.HTTPError as e:
        status("codigo" if e.code == 401 else "fora")
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        status("fora")


def enviar(codigo: str, corpo: bytes) -> dict:
    req = urllib.request.Request(URL, data=corpo, headers={
        "Authorization": f"Bearer {codigo}", "Content-Type": "application/x-ndjson",
        "User-Agent": "lor-bots-envio (https://github.com/sierrific/LOR-SD-Server)"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def main() -> None:
    codigo = os.environ.get("COLETA_CODIGO", "").strip()
    if not codigo or len(sys.argv) != 2:
        sys.exit(__doc__)
    raiz = Path(sys.argv[1])
    raiz.mkdir(parents=True, exist_ok=True)
    global STATUS
    STATUS = raiz / ".coleta-status"
    testar(codigo)
    estado_arq = raiz / ".coleta-enviado"
    estado = _ler_estado(estado_arq)
    if estado is None:
        print("primeira execução: enviando também as partidas que já existiam", flush=True)
        estado = {"desde": time.strftime("%Y-%m-%d %H:%M:%S"), "enviados": {}}
        _gravar(estado_arq, estado)
    ultimo_sinal = 0.0
    while True:
        ciclo(codigo, raiz, estado_arq, estado)
        if time.monotonic() - ultimo_sinal >= SINAL_A_CADA:
            sinal(codigo)
            ultimo_sinal = time.monotonic()
        time.sleep(POLL)


def _rodar(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def _ler_env(arq: Path) -> dict[str, str]:
    """chave=valor do <bot>.env, sem executar nada."""
    conf = {}
    try:
        for linha in arq.read_text().splitlines():
            chave, igual, valor = linha.partition("=")
            if igual and re.fullmatch(r"[A-Z_]+", chave.strip()):
                conf[chave.strip()] = valor.strip().strip('"\'')
    except OSError:
        pass
    return conf


def partida_atual(log: str) -> str:
    """A última partida anunciada no log ("watch: <url>") se depois dela não veio o resultado
    (o mesmo que o painel.sh estado faz)."""
    p = ""
    for linha in log.splitlines():
        if linha.startswith("watch: "):
            p = linha.split()[1] if len(linha.split()) > 1 else ""
        elif re.match(r"^(win|loss|tie) vs ", linha):
            p = ""
    return p


def bots_deste_pc(rodar=_rodar) -> list[dict]:
    """As contas configuradas neste PC e o estado de cada uma (ActiveState do lor-bot@<bot>)."""
    bots = []
    for env in sorted(ETC.glob("*.env")):
        bot_id = env.stem
        if bot_id in ("coleta", "backup", "exemplo"):  # exemplo.env é o modelo (BOT=LoRBot1), não um bot
            continue
        conf = _ler_env(env)
        if not conf.get("BOT"):
            continue
        unit = f"lor-bot@{bot_id}"
        estado = rodar(["systemctl", "show", "-p", "ActiveState", "--value", unit]).strip() or "desconhecido"
        partida = ""
        if estado in ("active", "deactivating"):
            partida = partida_atual(rodar(["journalctl", "-u", unit, "-n", "300", "-o", "cat", "--no-pager"]))
        desafio = rodar(["systemctl", "show", "-p", "ActiveState", "--value", f"lor-desafio-{bot_id}"]).strip()
        bots.append({"conta": conf["BOT"], "estado": estado, "partida": partida,
                     "servidor": conf.get("SERVIDOR") or "oficial",
                     "desafio": desafio in ("active", "activating", "deactivating")})
    return bots


_sinal_anterior: str | None = None


def sinal(codigo: str) -> None:
    """Sinal de vida para a página de admin. Nunca atrapalha o envio; só avisa no log quando muda
    (uma coleta antiga, sem /coleta/sinal, responde 404: fica quieto)."""
    global _sinal_anterior
    try:
        versao = VERSAO.read_text().strip()
    except OSError:
        versao = ""
    corpo = json.dumps({"versao": versao, "bots": bots_deste_pc()}).encode()
    req = urllib.request.Request(URL.rsplit("/", 1)[0] + "/sinal", data=corpo, headers={
        "Authorization": f"Bearer {codigo}", "Content-Type": "application/json", "User-Agent": "lor-bots-envio"})
    try:
        with urllib.request.urlopen(req, timeout=20):
            agora = "ok"
    except urllib.error.HTTPError as e:
        agora = f"recusado ({e.code})"
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        agora = f"sem resposta ({e})"
    if agora != _sinal_anterior and not agora.startswith("recusado (404"):
        print(f"sinal de vida para a coleta: {agora}", flush=True)
    _sinal_anterior = agora


def ciclo(codigo: str, raiz: Path, estado_arq: Path, estado: dict) -> None:
    """Uma leitura: manda o que houver de novo em cada games.jsonl."""
    # Partidas de antes da instalação vão para o treino, mas não para o Discord.
    desde: str = estado["desde"]
    # Relido a cada ciclo: o painel liga e desliga sem reiniciar o envio.
    discord = not SEM_DISCORD.exists()
    enviados: dict[str, int] = estado["enviados"]
    for jsonl in sorted(raiz.glob("*/games.jsonl")):
        chave = str(jsonl.relative_to(raiz))
        pos = enviados.get(chave, 0)
        tamanho = jsonl.stat().st_size
        if tamanho <= pos:
            enviados[chave] = min(pos, tamanho)
            continue
        # Lê no máximo LIMITE bytes por vez (só linhas completas), sem carregar o resto do
        # arquivo; a posição só avança depois que a coleta aceita cada lote.
        with open(jsonl, "rb") as f:
            while pos < tamanho:
                f.seek(pos)
                bloco = f.read(LIMITE)
                fim = bloco.rfind(b"\n") + 1
                if not fim:
                    if len(bloco) < LIMITE:
                        break  # a última partida ainda está sendo escrita
                    fim_linha = _fim_da_linha(f, pos + LIMITE)
                    if fim_linha is None:
                        break  # uma partida enorme ainda sendo escrita: espera ela terminar
                    _quarentena_arquivo(raiz, chave, f, pos, fim_linha)
                    pos = fim_linha
                    enviados[chave] = pos
                    _gravar(estado_arq, estado)
                    continue
                inicio, falhou = pos, False
                for lote, ate in _lotes(bloco[:fim], desde, chave, raiz, inicio, discord):
                    if lote:
                        r = _mandar(codigo, lote)
                        if r == "grande":
                            _quarentena(raiz, chave, inicio + ate, lote)
                        elif r != "ok":
                            falhou = True
                            break
                    pos = inicio + ate
                    enviados[chave] = pos
                    _gravar(estado_arq, estado)
                if falhou:
                    break


def _lotes(bloco: bytes, desde: str, chave: str, raiz: Path, base: int, discord: bool = True):
    """Divide as linhas completas de `bloco` em lotes de até LOTE bytes (uma partida maior que
    LOTE vai sozinha). Devolve (lote, fim): fim é onde o lote termina dentro de `bloco`. Uma
    partida acima de LIMITE, que a coleta recusaria, vai para a quarentena."""
    lote: list[bytes] = []
    soma = desloc = 0
    for original in bloco.splitlines(keepends=True):
        linha = _marcar(original, desde, chave, discord) if original.strip() else None
        if linha is None and original.strip():
            # A coleta recusaria o lote inteiro por causa dela (e o envio voltaria ao mesmo ponto
            # para sempre): fica guardada à parte e as outras seguem.
            _quarentena(raiz, chave, base + desloc, [original], "inválida(s)")
        elif linha is not None and len(linha) > LIMITE:
            _quarentena(raiz, chave, base + desloc, [original])
            linha = None
        if linha is not None and lote and soma + len(linha) > LOTE:
            yield lote, desloc
            lote, soma = [], 0
        desloc += len(original)
        if linha is not None:
            lote.append(linha)
            soma += len(linha)
    yield lote, desloc


def _quarentena(raiz: Path, chave: str, pos: int, linhas: list[bytes], motivo: str = "grande(s) demais") -> None:
    # Partidas que a coleta não aceita (grandes demais ou inválidas) ficam guardadas aqui em vez de travar o
    # envio das outras ou se perderem; dá para mandar à mão depois.
    pasta = raiz / ".coleta-quarentena"
    pasta.mkdir(exist_ok=True)
    arq = pasta / f"{chave.replace('/', '_')}-{pos}"
    arq.write_bytes(b"".join(linhas))
    print(f"{chave}: {len(linhas)} partida(s) {motivo} para a coleta, guardada(s) em {arq}", flush=True)


def _fim_da_linha(f, de: int) -> int | None:
    """Posição logo depois do próximo fim de linha a partir de `de`, lendo aos pedaços (uma
    partida enorme não vai inteira para a memória); None se a linha ainda não terminou."""
    f.seek(de)
    while pedaco := f.read(1024 * 1024):
        i = pedaco.find(b"\n")
        if i >= 0:
            return f.tell() - len(pedaco) + i + 1
    return None


def _quarentena_arquivo(raiz: Path, chave: str, f, de: int, ate: int) -> None:
    pasta = raiz / ".coleta-quarentena"
    pasta.mkdir(exist_ok=True)
    arq = pasta / f"{chave.replace('/', '_')}-{de}"
    f.seek(de)
    with open(arq, "wb") as saida:
        while de < ate:
            pedaco = f.read(min(1024 * 1024, ate - de))
            saida.write(pedaco)
            de += len(pedaco)
    print(f"{chave}: partida de {arq.stat().st_size} bytes, grande demais para a coleta, guardada em {arq}",
          flush=True)


def _marcar(linha: bytes, desde: str, chave: str, discord: bool = True) -> bytes | None:
    """A linha pronta para a coleta, ou None se ela a recusaria (não é um objeto JSON com tag)."""
    try:
        row = json.loads(linha)
    except ValueError:
        print(f"{chave}: linha que não é JSON (gravação interrompida?)", flush=True)
        return None
    if not isinstance(row, dict) or not TAG.match(str(row.get("tag", ""))):
        print(f"{chave}: linha sem o formato de partida (objeto com tag battle-...)", flush=True)
        return None
    extra = {}
    if str(row.get("time", "")) < desde:
        extra["antigo"] = True
    if not discord:
        extra["discord"] = False
    return json.dumps({**row, **extra}).encode() + b"\n" if extra else linha


def _ler_estado(arq: Path) -> dict | None:
    if not arq.exists():
        return None
    try:
        estado = json.loads(arq.read_text())
        if isinstance(estado.get("desde"), str) and isinstance(estado.get("enviados"), dict):
            return estado
    except (ValueError, AttributeError):
        pass
    # Corrompido (ex.: o PC desligou no meio de uma gravação antiga): guarda uma cópia e começa
    # de novo. A coleta ignora partidas repetidas; todas as que já existem vão como "antigo",
    # para o Discord não repostar.
    arq.replace(arq.with_name(arq.name + ".ruim"))
    print("registro de envios corrompido: reenviando tudo como antigo (a coleta ignora repetidas)", flush=True)
    estado = {"desde": time.strftime("%Y-%m-%d %H:%M:%S"), "enviados": {}}
    _gravar(arq, estado)
    return estado


def _gravar(arq: Path, estado: dict) -> None:
    # Arquivo novo + rename: uma queda no meio deixa o registro antigo inteiro, nunca um pela metade.
    tmp = arq.with_name(arq.name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(estado, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, arq)


def _mandar(codigo: str, lote: list[bytes]) -> str:
    """"ok", "grande" (a coleta recusou pelo tamanho) ou "falha" (tentar de novo depois)."""
    try:
        r = enviar(codigo, b"".join(lote))
        print(f"enviadas {r.get('recebidas')} partidas ({r.get('novas')} novas)", flush=True)
        status("ok")
        return "ok"
    except urllib.error.HTTPError as e:
        print(f"coleta recusou: {e.code} {e.read()[:200]!r}", flush=True)
        if e.code == 413:
            status("ok")
            return "grande"
        if e.code == 401:
            status("codigo")
            time.sleep(600)  # código errado: não adianta insistir a cada 30 s
        else:
            status("fora")
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        print(f"coleta fora do ar, tento de novo depois: {e}", flush=True)
        status("fora")
    return "falha"


if __name__ == "__main__":
    main()
