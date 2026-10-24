#!/usr/bin/env python3
"""Manda as partidas deste bot para a coleta do time (na VPS), para o treino e o Discord.

Lê as linhas novas de data/live_games/*/games.jsonl (uma por partida, com o log completo) e
envia para COLETA_URL com o código do bot. Guarda até onde já enviou em <pasta>/.coleta-enviado;
se a VPS estiver fora, tenta de novo no próximo ciclo sem perder nada.

    COLETA_CODIGO=... python3 enviar-partidas.py /opt/lor-bots/ai-vgc/data/live_games

Manda também as partidas de antes da primeira execução (servem para o treino), marcadas com
"antigo" para o Discord não postar tudo de uma vez. Só biblioteca padrão.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = os.environ.get("COLETA_URL", "https://showdown.sierverso.com.br/coleta/partidas")
POLL = 30  # segundos entre leituras
LOTE = 3 * 1024 * 1024  # bytes por envio (a coleta aceita até 4 MB)


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
    estado_arq = raiz / ".coleta-enviado"
    estado = _ler_estado(estado_arq)
    if estado is None:
        print("primeira execução: enviando também as partidas que já existiam", flush=True)
        estado = {"desde": time.strftime("%Y-%m-%d %H:%M:%S"), "enviados": {}}
        _gravar(estado_arq, estado)
    # Partidas de antes da instalação vão para o treino, mas não para o Discord.
    desde: str = estado["desde"]
    enviados: dict[str, int] = estado["enviados"]

    while True:
        for jsonl in sorted(raiz.glob("*/games.jsonl")):
            chave = str(jsonl.relative_to(raiz))
            pos = enviados.get(chave, 0)
            tamanho = jsonl.stat().st_size
            if tamanho <= pos:
                enviados[chave] = min(pos, tamanho)
                continue
            # Um lote de até LOTE bytes por vez (só linhas completas), sem ler o resto do arquivo:
            # a posição só avança depois que a coleta aceita o lote.
            with open(jsonl, "rb") as f:
                while pos < tamanho:
                    f.seek(pos)
                    bloco = f.read(LOTE)
                    fim = bloco.rfind(b"\n") + 1
                    if not fim:
                        if len(bloco) < LOTE:
                            break  # a última linha ainda está sendo escrita
                        f.seek(pos)
                        pulada = len(f.readline())  # uma partida maior que o lote: a coleta recusaria
                        print(f"{chave}: partida de {pulada} bytes, grande demais para enviar; pulando", flush=True)
                        pos += pulada
                    else:
                        lote = [m for linha in bloco[:fim].splitlines(keepends=True)
                                if linha.strip() and (m := _marcar(linha, desde, chave))]
                        if lote and not _mandar(codigo, lote):
                            break
                        pos += fim
                    enviados[chave] = pos
                    _gravar(estado_arq, estado)
        time.sleep(POLL)


def _marcar(linha: bytes, desde: str, chave: str) -> bytes | None:
    try:
        row = json.loads(linha)
    except ValueError:
        print(f"{chave}: linha inválida (gravação interrompida?), pulando", flush=True)
        return None
    if str(row.get("time", "")) < desde:
        return json.dumps({**row, "antigo": True}).encode() + b"\n"
    return linha


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


def _mandar(codigo: str, lote: list[bytes]) -> bool:
    try:
        r = enviar(codigo, b"".join(lote))
        print(f"enviadas {r.get('recebidas')} partidas ({r.get('novas')} novas)", flush=True)
        return True
    except urllib.error.HTTPError as e:
        print(f"coleta recusou: {e.code} {e.read()[:200]!r}", flush=True)
        if e.code == 401:
            time.sleep(600)  # código errado: não adianta insistir a cada 30 s
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        print(f"coleta fora do ar, tento de novo depois: {e}", flush=True)
    return False


if __name__ == "__main__":
    main()
