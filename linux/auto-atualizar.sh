#!/usr/bin/env bash
# Atualização automática (opção "Atualizar sozinho" do painel; painel.sh auto-atualizar sim|nao).
# O lor-auto-atualizar.timer roda isto a cada ~10 min: se a branch deste PC (/opt/lor-bots/RAMO,
# estavel por padrão, ou a de teste com que ele foi instalado) tem uma revisão nova na VPS do time,
# roda o atualizar.sh dessa revisão, como o botão Atualizar. O atualizar.sh já espera: bot no meio
# de uma partida ou série termina ela antes de reiniciar com a versão nova; parado entre partidas,
# reinicia na hora. O painel do Windows, se aberto, troca o próprio arquivo depois.
#
# Uma revisão que falhou ao instalar não é tentada de novo sozinha (o atualizar.sh já voltou para a
# anterior): espera sair outra revisão, ou o Atualizar do painel.
set -euo pipefail
DIR="${LOR_DIR:-/opt/lor-bots}"  # LOR_DIR, LOR_ETC e LOR_ATUALIZAR: só para os testes
ETC="${LOR_ETC:-/etc/lor-bots}"
[ -e "$ETC/auto-atualizar" ] || { echo 'Atualização automática desligada.'; exit 0; }

VPS="${LOR_VPS:-https://showdown.sierverso.com.br/coleta}"
VPS="${VPS%/}"
VPS="${VPS%/bots}"
RAMO="$(head -n1 "$DIR/RAMO" 2>/dev/null | tr -cd 'A-Za-z0-9._/-' || true)"
# Como o painel: instalações antigas gravaram "main", que agora é a estavel.
[ -n "$RAMO" ] && [ "$RAMO" != main ] || RAMO=estavel

codigo="$(sed -n 's/^COLETA_CODIGO=//p' "$ETC/coleta.env" 2>/dev/null | head -n1)"
if ! [[ "$codigo" =~ ^[A-Za-z0-9_-]{8,128}$ ]]; then
	echo 'Sem o código da coleta: nada a fazer.'
	exit 0
fi
baixar() {  # baixar <segundos> <caminho em /bots> [opções do curl]
	local prazo="$1" caminho="$2"
	shift 2
	curl -fsSL --max-time "$prazo" -H "Authorization: Bearer $codigo" "$@" "$VPS/bots/$caminho"
}

ramo_url="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$RAMO")"
if ! revisao="$(baixar 20 "ramo/$ramo_url" | python3 -c 'import json, sys; print(json.load(sys.stdin)["sha"])' 2>/dev/null)"; then
	echo "Não consegui consultar a branch $RAMO na VPS; tento de novo na próxima."
	exit 0
fi
[[ "$revisao" =~ ^[0-9a-f]{40}$ ]] || { echo 'A VPS não informou uma revisão válida.'; exit 0; }
if [ "$(cat "$DIR/REVISION" 2>/dev/null || true)" = "$revisao" ]; then
	echo "Já está na revisão mais nova de $RAMO."
	exit 0
fi
FALHOU="$DIR/.auto-atualizar-falhou"
if [ "$(cat "$FALHOU" 2>/dev/null || true)" = "$revisao" ]; then
	echo "A revisão $revisao já falhou ao instalar: espero uma nova (ou o Atualizar do painel)."
	exit 0
fi

echo "==> Revisão nova em $RAMO: $revisao"
script="$(mktemp)"
trap 'rm -f "$script"' EXIT
if [ -n "${LOR_ATUALIZAR:-}" ]; then
	cp "$LOR_ATUALIZAR" "$script"
elif ! baixar 30 "$revisao/linux/atualizar.sh" -o "$script"; then
	echo 'Não consegui baixar o atualizador; tento de novo na próxima.'
	exit 0
fi
if LOR_REVISION="$revisao" LOR_RAMO="$RAMO" LOR_VPS="$VPS" bash "$script"; then
	rm -f "$FALHOU"
else
	codigo_saida=$?
	printf '%s\n' "$revisao" >"$FALHOU"
	echo "A atualização para $revisao falhou (código $codigo_saida)."
	exit "$codigo_saida"
fi
