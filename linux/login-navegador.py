#!/usr/bin/env python3
"""Autorização pelo navegador. IPC local, temporário, sem senha ou cookie no Linux.

O Ai-vgc espera uma assertion para a SUA conexão. O auxiliar Windows autentica no site
oficial, usando um perfil separado da conta, e responde a este pedido. A resposta assinada
é conferida (conta, desafio e prazo), entregue sem alterações e apagada ao ser consumida.
O diretório pertence ao usuário bots, criado pelo RuntimeDirectory do systemd.
"""
import json
import os
import re
import secrets
import sys
import time
from pathlib import Path

TTL = 300
MAX_BYTES = 16384


def user_id(name):
    return re.sub(r"[^a-z0-9]", "", name.lower())


def read_json(path):
    if path.is_symlink():
        raise ValueError("arquivo de autorização inválido")
    with path.open("rb") as f:
        data = f.read(MAX_BYTES + 1)
    if len(data) > MAX_BYTES:
        raise ValueError("autorização grande demais")
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError("autorização inválida")
    return value


def write_json(path, value):
    data = json.dumps(value).encode("utf-8")
    if len(data) > MAX_BYTES:
        raise ValueError("autorização grande demais")
    tmp = path.with_name(path.name + "." + secrets.token_hex(8))
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def pending(directory, now=None):
    directory = Path(directory)
    if directory.is_symlink():
        raise ValueError("diretório de autorização inválido")
    try:
        req = read_json(directory / "pedido.json")
    except FileNotFoundError:
        return None
    now = time.time() if now is None else now
    if not isinstance(req.get("expires"), (int, float)) or not now < req["expires"] <= now + TTL + 5:
        return None
    if not re.fullmatch(r"[a-f0-9]{32}", str(req.get("id", ""))):
        raise ValueError("pedido inválido")
    if not re.fullmatch(r"[A-Za-z0-9 _.-]{1,18}", str(req.get("username", ""))):
        raise ValueError("conta inválida")
    if not user_id(req["username"]):
        raise ValueError("conta inválida")
    # Preserva possíveis campos adicionais do challstr, sem aceitar comandos/linhas.
    if not re.fullmatch(r"[0-9]+\|[a-f0-9]{32,1024}(?:\|[^\r\n]{1,2048})?", str(req.get("challstr", ""))):
        raise ValueError("desafio inválido")
    return req


def validate_assertion(assertion, req, now=None):
    if not isinstance(assertion, str) or len(assertion) > MAX_BYTES // 2 or re.search(r"[\r\n]", assertion):
        raise ValueError("autorização inválida")
    data, sep, signature = assertion.partition(";")
    fields = data.split(",")
    if not sep or not re.fullmatch(r"[0-9a-fA-F]{128,4096}", signature) or len(fields) != 5:
        raise ValueError("o navegador não retornou uma autorização")
    challenge, userid, kind, issued, host = fields
    if challenge != req["challstr"].split("|")[1] or userid != user_id(req["username"]):
        raise ValueError("autorização de outra conta ou conexão")
    now = time.time() if now is None else now
    if not issued.isdigit() or not now - 600 <= int(issued) <= now + 60 or now >= req["expires"]:
        raise ValueError("autorização vencida")
    if not kind.isdigit() or not host or kind == "1":
        raise ValueError("entre em uma conta registrada no navegador")
    # A assinatura e o tipo da conta são verificados pelo Showdown; não se modifica nenhum deles.
    return assertion


def respond(directory, value):
    req = pending(directory)
    if not req or value.get("id") != req["id"]:
        raise ValueError("pedido encerrado ou substituído")
    if "error" in value:
        response = {"id": req["id"], "error": "login não concluído no navegador"}
    else:
        response = {"id": req["id"], "assertion": validate_assertion(value.get("assertion"), req)}
    write_json(Path(directory) / "resposta.json", response)


def request_assertion(username, challstr, directory, stop=lambda: False):
    directory = Path(directory)
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("diretório temporário do login indisponível; reinstale o serviço")
    req = {"id": secrets.token_hex(16), "username": username, "challstr": challstr,
           "expires": time.time() + TTL}
    answer = directory / "resposta.json"
    request = directory / "pedido.json"
    answer.unlink(missing_ok=True)
    write_json(request, req)
    try:
        pending(directory)  # valida antes de o navegador consumir
        print(f"login navegador: entre como {username} na janela do Showdown (até 5 minutos)", flush=True)
        deadline = time.monotonic() + TTL
        while time.monotonic() < deadline:
            if stop():
                return None
            try:
                value = read_json(answer)
            except FileNotFoundError:
                time.sleep(0.25)
                continue
            if value.get("id") != req["id"]:
                answer.unlink(missing_ok=True)
                continue
            if "error" in value:
                raise ValueError("login não concluído no navegador; abra o painel e ligue novamente")
            return validate_assertion(value.get("assertion"), req)
        raise ValueError("login no navegador expirou; ligue novamente para tentar")
    finally:
        # Uma resposta atrasada nunca serve para a próxima conexão.
        try:
            current = read_json(request)
        except FileNotFoundError:
            current = {}
        if current.get("id") == req["id"]:
            request.unlink(missing_ok=True)
            answer.unlink(missing_ok=True)


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("pending", "respond"):
        raise ValueError("uso: login-navegador.py pending|respond <diretório>")
    if sys.argv[1] == "pending":
        print(json.dumps(pending(sys.argv[2])))
        return
    raw = sys.stdin.buffer.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError("resposta grande demais")
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("resposta inválida")
    respond(sys.argv[2], value)
    print("ok")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError):
        # Nunca imprime o corpo recebido (contém uma autorização temporária).
        print("Falha na autorização local do navegador.", file=sys.stderr)
        sys.exit(1)
