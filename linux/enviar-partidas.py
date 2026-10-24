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
    if estado_arq.exists():
        estado = json.loads(estado_arq.read_text())
    else:
        print("primeira execução: enviando também as partidas que já existiam", flush=True)
        estado = {"desde": time.strftime("%Y-%m-%d %H:%M:%S"), "enviados": {}}
        estado_arq.write_text(json.dumps(estado))
    # Partidas de antes da instalação vão para o treino, mas não para o Discord.
    desde: str = estado["desde"]
    enviados: dict[str, int] = estado["enviados"]

    def salvar() -> None:
        estado_arq.write_text(json.dumps(estado))

    while True:
        for jsonl in sorted(raiz.glob("*/games.jsonl")):
            chave = str(jsonl.relative_to(raiz))
            pos = enviados.get(chave, 0)
            tamanho = jsonl.stat().st_size
            if tamanho <= pos:
                enviados[chave] = min(pos, tamanho)
                continue
            with open(jsonl, "rb") as f:
                f.seek(pos)
                bloco = f.read()
            fim = bloco.rfind(b"\n") + 1  # só linhas completas
            # Lotes de até LOTE bytes; a posição só avança depois que a coleta aceita o lote.
            lote: list[bytes] = []
            lido = 0  # bytes do arquivo cobertos pelo lote
            for original in bloco[:fim].splitlines(keepends=True):
                linha = original
                if original.strip():
                    row = json.loads(original)
                    if str(row.get("time", "")) < desde:
                        linha = json.dumps({**row, "antigo": True}).encode() + b"\n"
                if lote and sum(map(len, lote)) + len(linha) > LOTE:
                    if not _mandar(codigo, lote):
                        break
                    pos, lote, lido = pos + lido, [], 0
                    enviados[chave] = pos
                    salvar()
                if original.strip():
                    lote.append(linha)
                lido += len(original)
            else:
                if not lote or _mandar(codigo, lote):
                    enviados[chave] = pos + lido
                    salvar()
        time.sleep(POLL)


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
