#!/usr/bin/env bash
# Roda um bot com as opções do seu /etc/lor-bots/<nome>.env (carregado pelo systemd, serviço
# lor-bot@<nome>). O scripts/bot.sh do Ai-vgc cuida de reconectar se a conexão cair.
#
# Parar com calma: o systemd manda SIGINT a este script, que repassa só ao Python do bot; é o
# mesmo que um Ctrl-C no bot.sh: ele termina a partida (ou a série Bo3) atual e sai.
#
# O bot só joga com um código da coleta válido: antes de tudo, confere o código salvo em
# /etc/lor-bots/coleta.env na coleta (/coleta/ping). "rodar-bot.sh --conferir" faz só isso (o
# painel.sh usa no ligar e no desafiar) e imprime uma linha chave=valor. Sai com:
#   0   código aceito pela coleta (ou coleta fora do ar, mas este código já foi aceito antes)
#   78  sem código, ou a coleta recusou o código (RestartPreventExitStatus: o systemd não religa)
#   1   coleta fora do ar e este código nunca foi conferido (o systemd tenta de novo em 30 s)
set -euo pipefail
ETC="${LOR_ETC:-/etc/lor-bots}"  # LOR_ETC e LOR_COLETA_PING: só para os testes
AIVGC=/opt/lor-bots/ai-vgc
PING="${LOR_COLETA_PING:-https://showdown.sierverso.com.br/coleta/ping}"

conferir_codigo() {
	# Impressão (sha256) do último código que a coleta aceitou, para quando ela estiver fora do ar.
	# Gravada pelo painel.sh (root); como usuário "bots" este script só lê.
	local conferido="$ETC/coleta.conferido" codigo impressao http
	codigo="$(sed -n 's/^COLETA_CODIGO=//p' "$ETC/coleta.env" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
	if [ -z "$codigo" ]; then
		echo "erro=salve o código da coleta de partidas (em Ajustes) antes de ligar o bot. Peça um ao Thiago."
		return 78
	fi
	impressao="$(printf %s "$codigo" | sha256sum | cut -d' ' -f1)"
	http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $codigo" "$PING" 2>/dev/null || true)"
	case "$http" in
	200)
		if [ -w "$ETC" ]; then
			printf '%s\n' "$impressao" >"$conferido.tmp" && chmod 644 "$conferido.tmp" \
				&& mv "$conferido.tmp" "$conferido" || true
		fi
		echo "ok=codigo-valido"
		return 0
		;;
	401 | 403)
		echo "erro=a coleta recusou o código salvo, então o bot não liga. Peça um código novo ao Thiago e salve em Ajustes."
		return 78
		;;
	esac
	# Coleta fora do ar: não trava quem já tinha o código aceito (aqui ou pelo envio das partidas,
	# cujo status o painel apaga quando o código muda).
	if [ "$(cat "$conferido" 2>/dev/null)" = "$impressao" ] \
		|| grep -q '"status": *"ok"' "$AIVGC/data/live_games/.coleta-status" 2>/dev/null; then
		echo "aviso=coleta fora do ar agora; o código já tinha sido aceito, então o bot liga assim mesmo"
		return 0
	fi
	echo "erro=não consegui falar com a coleta para conferir o código. Tente de novo em alguns minutos."
	return 1
}

if [ "${1:-}" = --conferir ]; then
	conferir_codigo && exit 0 || exit $?
fi
conferido="$(conferir_codigo)" && ret=0 || ret=$?
if [ "$ret" -ne 0 ]; then
	echo "Bot não ligou: ${conferido#erro=}" >&2  # fica no log, que o painel mostra
	exit "$ret"
fi
[[ "$conferido" == aviso=* ]] && echo "${conferido#aviso=}"

cd "$AIVGC"
# O código também vai para o bot: com ele, o bot pede à coleta a vez de buscar partida (um bot do
# time por formato na fila do ladder, para os nossos nunca se enfrentarem).
COLETA_CODIGO="$(sed -n 's/^COLETA_CODIGO=//p' "$ETC/coleta.env" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)"
export COLETA_CODIGO
export PATH="$HOME/.local/bin:$PATH"
export UV_NO_SYNC=1  # o instalador escolhe o PyTorch (CPU); o uv run não deve trocar
export SERVER=showdown  # bot.sh: login pelo servidor oficial (vale também para o nosso)

case "${LOGIN:-senha}" in
navegador)
	# Sem senha no Python, inclusive em reconexões. Uma falha não muda para o modo antigo.
	export LOR_BROWSER_LOGIN=/opt/lor-bots/login-navegador.py
	PS_PASSWORD=''
	;;
senha)
	# Compatibilidade explícita com bots Linux configurados à mão.
	unset LOR_BROWSER_LOGIN
	if [ -n "${SENHA_ARQUIVO:-}" ]; then PS_PASSWORD="$(cat "$SENHA_ARQUIVO")"; fi
	if [ -z "${PS_PASSWORD:-}" ]; then
		echo "Sem senha para a conta $BOT: configure no painel (ou PS_PASSWORD no .env)." >&2
		exit 78
	fi
	;;
*) echo "Modo de login inválido." >&2; exit 78 ;;
esac
export BOT PS_PASSWORD

read -ra args <<<"$MODO"
if [ "${SERVIDOR:-oficial}" = lor ]; then
	args+=(--server-url wss://showdown.sierverso.com.br/showdown/websocket
	       --client-url https://showdown-sierverso-com-br.psim.us/)
fi

set -m  # sem isto o bash faz o filho ignorar SIGINT (e o Python perderia o Ctrl-C)
zsh scripts/bot.sh "${args[@]}" &
filho=$!

descendentes() {
	local p
	for p in $(pgrep -P "$1" || true); do
		echo "$p"
		descendentes "$p"
	done
}

# O Python do bot (descendente deste script): outros bots na mesma máquina seguem jogando.
python_do_bot() {
	local p
	for p in $(descendentes "$filho"); do
		if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'ai_vgc.nn.player'; then
			echo "$p"
		fi
	done
}

parando=0
parar() {
	# Um pedido só: um segundo SIGINT no Python seria "sair já" e cortaria a partida. Para matar
	# na hora existe o "Desligar agora" (systemctl kill).
	((parando)) && return
	parando=1
	local p
	for p in $(python_do_bot); do
		kill -INT "$p" 2>/dev/null || true
	done
	# Se não há Python (esperando para reconectar, ou começando) ou se ele cair depois disso, o
	# bot.sh lançaria outro que nunca recebeu o pedido. Então, enquanto o bot.sh existir, sem
	# Python do bot não há partida para terminar: encerra o bot.sh antes que ele relance.
	(
		while kill -0 "$filho" 2>/dev/null; do
			[ -n "$(python_do_bot)" ] || kill -TERM -- "-$filho" 2>/dev/null || true
			sleep 2
		done
	) &
}
trap parar INT TERM

# wait volta quando chega um sinal; espera de novo até o bot sair de verdade.
codigo=0
while kill -0 "$filho" 2>/dev/null; do
	wait "$filho" && codigo=0 || codigo=$?
done
((parando)) && exit 0  # parada pedida: não é falha (nem motivo para o systemd religar)
exit "$codigo"
