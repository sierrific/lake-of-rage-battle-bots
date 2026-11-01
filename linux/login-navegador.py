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
ERROR_MESSAGES = {
    "assertion-format": "o Showdown retornou uma autorização em formato inválido",
    "assertion-mismatch": "a autorização não corresponde à conta ou à conexão atual",
    "assertion-expired": "a autorização expirou; confira o relógio do PC e tente novamente",
    "account-unregistered": "entre na conta registrada no navegador antes de ligar o bot",
    "browser-error": "não foi possível concluir a autorização no navegador; tente novamente",
}


class LoginError(ValueError):
    def __init__(self, code):
        self.code = code if isinstance(code, str) and code in ERROR_MESSAGES else "browser-error"
        super().__init__(ERROR_MESSAGES[self.code])


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
        raise LoginError("assertion-format")
    data, sep, signature = assertion.partition(";")
    fields = data.split(",")
    if not sep or not re.fullmatch(r"[0-9a-fA-F]{128,4096}", signature) or len(fields) < 5:
        raise LoginError("assertion-format")
    # O Showdown usa os cinco primeiros campos e permite extensões assinadas (s1/s2/s3).
    # Conferimos esses campos sem reconstruir o texto: as extensões também fazem parte da assinatura.
    challenge, userid, kind, issued, host = fields[:5]
    if challenge != req["challstr"].split("|")[1] or userid != user_id(req["username"]):
        raise LoginError("assertion-mismatch")
    now = time.time() if now is None else now
    if not issued.isdigit() or not now - 600 <= int(issued) <= now + 60 or now >= req["expires"]:
        raise LoginError("assertion-expired")
    if not kind.isdigit() or not host or kind == "1":
        raise LoginError("account-unregistered")
    # A assinatura e o tipo da conta são verificados pelo Showdown; não se modifica nenhum deles.
    return assertion


def respond(directory, value):
    req = pending(directory)
    if not req or value.get("id") != req["id"]:
        raise ValueError("pedido encerrado ou substituído")
    if "error" in value:
        response = {"id": req["id"], "error": LoginError(value["error"]).code}
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
                raise LoginError(value["error"])
            return validate_assertion(value.get("assertion"), req)
        raise ValueError("login no navegador expirou; ligue novamente para tentar")
    except LoginError as error:
        # Só mensagens da lista fixa; nunca inclui a autorização ou o texto remoto.
        print(f"login navegador: {error}", flush=True)
        raise
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
    except LoginError as error:
        print(f"LOGIN_ERROR:{error.code}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError):
        # Nunca imprime o corpo recebido (contém uma autorização temporária).
        print("Falha na autorização local do navegador.", file=sys.stderr)
        sys.exit(1)
