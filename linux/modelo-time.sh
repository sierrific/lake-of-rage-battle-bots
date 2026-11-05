#!/usr/bin/env bash
# Garante um modelo treinado pelo time antes de o bot ligar, e imprime o caminho a usar.
#
#   modelo-time.sh data/models/<arquivo>.pt
#
# Os modelos do time não vêm no Ai-vgc (que é público): ficam na VPS e só baixa quem tem um
# código da coleta válido (GET /coleta/modelo/<arquivo>). O arquivo só é usado se o sha256 bater
# com o da lista abaixo. Se faltar, não baixar ou não conferir, imprime o modelo original
# (RESERVA) e avisa no log: o bot nunca deixa de ligar por causa disso.
set -uo pipefail
AIVGC="${LOR_AIVGC:-/opt/lor-bots/ai-vgc}"
ETC="${LOR_ETC:-/etc/lor-bots}"
URL="${LOR_COLETA_MODELO:-https://showdown.sierverso.com.br/coleta/modelo}"
RESERVA=data/models/mc-bo3-rnad-v5.pt

# arquivo sha256 (um por linha)
MODELOS_TIME="
mc-bo3-rnad-v6.pt bb72b5b604392e89941bfede3f9d38383c899e82e2f06b65e6cfb3eba0a53801
"

pedido="${1:-$RESERVA}"
nome="$(basename "$pedido")"
esperado="$(printf '%s\n' "$MODELOS_TIME" | awk -v n="$nome" '$1 == n {print $2}')"
# Grupo de controle: com /etc/lor-bots/sem-modelo-time, o PC segue no modelo original.
if [ -n "$esperado" ] && [ -e "$ETC/sem-modelo-time" ]; then
	printf '%s\n' "$RESERVA"
	exit 0
fi
if [ -z "$esperado" ]; then  # modelo do Ai-vgc: nada a baixar
	printf '%s\n' "$pedido"
	exit 0
fi
destino="$AIVGC/$pedido"
confere() { [ -f "$1" ] && [ "$(sha256sum "$1" | cut -d' ' -f1)" = "$esperado" ]; }
if confere "$destino"; then
	printf '%s\n' "$pedido"
	exit 0
fi
codigo="$(sed -n 's/^COLETA_CODIGO=//p' "$ETC/coleta.env" 2>/dev/null | tail -1 | tr -d '[:space:]')"
tmp="$destino.baixando"
echo "baixando o modelo $nome da coleta" >&2
if [ -n "$codigo" ] && mkdir -p "$(dirname "$destino")" \
	&& curl -sf --max-time 600 -H "Authorization: Bearer $codigo" -o "$tmp" "$URL/$nome" \
	&& confere "$tmp" && mv -f "$tmp" "$destino"; then
	printf '%s\n' "$pedido"
	exit 0
fi
rm -f "$tmp"
echo "aviso: não consegui o modelo $nome (coleta fora do ar ou arquivo diferente); usando $(basename "$RESERVA") nesta vez" >&2
printf '%s\n' "$RESERVA"
