#!/usr/bin/env python3
"""Cópia de segurança das partidas da coleta (VPS) num PC: o material do treino não fica só lá.

Baixa de /coleta/backup a lista dos games.jsonl de cada membro e, de cada um, só o que cresceu
desde a última cópia (a coleta só acrescenta linhas). Guarda em <BACKUP_DIR>/<membro>/games.jsonl.
Roda uma vez por dia pelo lor-backup.timer; configure com `painel.sh backup`.

    BACKUP_TOKEN=... BACKUP_DIR=/mnt/c/Users/.../LoR-backup-coleta python3 backup-coleta.py

O token sai de `sudo /opt/lor-sd-server/coleta/token-backup.sh` na VPS. Só biblioteca padrão.
"""

import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path

URL = os.environ.get("COLETA_BACKUP_URL", "https://showdown.sierverso.com.br/coleta/backup")
NOME = re.compile(r"^[A-Za-z0-9_-]{1,32}$")
PEDACO = 1024 * 1024


def pedir(caminho: str, token: str):
    req = urllib.request.Request(URL + caminho, headers={
        "Authorization": f"Bearer {token}", "User-Agent": "lor-bots-backup"})
    return urllib.request.urlopen(req, timeout=120)


def ate_ultima_linha(arq: Path) -> int:
    """Corta o arquivo logo depois do último fim de linha (uma cópia interrompida, ou uma partida
    que a coleta ainda gravava, deixaria uma linha pela metade). Devolve o tamanho final."""
    tamanho = arq.stat().st_size
    with open(arq, "r+b") as f:
        fim = tamanho
        while fim > 0:
            inicio = max(0, fim - PEDACO)
            f.seek(inicio)
            i = f.read(fim - inicio).rfind(b"\n")
            if i >= 0:
                fim = inicio + i + 1
                break
            fim = inicio
        if fim != tamanho:
            f.truncate(fim)
    return fim


def copiar(token: str, destino: Path, nome: str, remoto: int) -> int:
    """Traz o que falta de um membro; devolve quantos bytes vieram."""
    pasta = destino / nome
    pasta.mkdir(parents=True, exist_ok=True)
    arq = pasta / "games.jsonl"
    local = ate_ultima_linha(arq) if arq.exists() else 0
    if local > remoto:
        # Na VPS o arquivo ficou menor (trocado ou restaurado): guarda a cópia velha e recomeça.
        arq.replace(pasta / f"games.jsonl.{time.strftime('%Y%m%d-%H%M%S')}.antigo")
        print(f"{nome}: arquivo menor na coleta, cópia anterior guardada à parte", flush=True)
        local = 0
    if local == remoto:
        return 0
    veio = 0
    with pedir(f"/{nome}?desde={local}", token) as r, open(arq, "ab") as f:
        while pedaco := r.read(PEDACO):
            f.write(pedaco)
            veio += len(pedaco)
        f.flush()
        os.fsync(f.fileno())
    ate_ultima_linha(arq)
    return veio


def main() -> None:
    token = os.environ.get("BACKUP_TOKEN", "").strip()
    destino = Path(os.environ.get("BACKUP_DIR", "").strip() or "/")
    if not token or not destino.is_absolute() or destino == Path("/"):
        sys.exit(__doc__)
    destino.mkdir(parents=True, exist_ok=True)
    with pedir("", token) as r:
        arquivos = json.loads(r.read())["arquivos"]
    total = 0
    for nome, remoto in sorted(arquivos.items()):
        if NOME.match(nome):
            veio = copiar(token, destino, nome, int(remoto))
            total += veio
            print(f"{nome}: {veio / 1e6:.1f} MB novos", flush=True)
    resumo = f"{time.strftime('%Y-%m-%d %H:%M:%S')}: {len(arquivos)} membros, {total / 1e6:.1f} MB novos\n"
    (destino / "ultimo-backup.txt").write_text(resumo)
    print(resumo, end="", flush=True)


if __name__ == "__main__":
    main()
