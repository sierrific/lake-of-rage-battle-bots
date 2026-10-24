#!/usr/bin/env bash
# Roda um bot com as opções do seu /etc/lor-bots/<nome>.env (carregado pelo systemd, serviço
# lor-bot@<nome>). O scripts/bot.sh do Ai-vgc cuida de reconectar se a conexão cair.
#
# Parar com calma: o systemd manda SIGINT a este script, que repassa só ao Python do bot; é o
# mesmo que um Ctrl-C no bot.sh: ele termina a partida (ou a série Bo3) atual e sai.
set -euo pipefail
cd /opt/lor-bots/ai-vgc
export PATH="$HOME/.local/bin:$PATH"
export UV_NO_SYNC=1  # o instalador escolhe o PyTorch (CPU); o uv run não deve trocar
export SERVER=showdown  # bot.sh: login pelo servidor oficial (vale também para o nosso)

if [ -n "${SENHA_ARQUIVO:-}" ]; then
	PS_PASSWORD="$(cat "$SENHA_ARQUIVO")"
fi
if [ -z "${PS_PASSWORD:-}" ]; then
	echo "Sem senha para a conta $BOT: configure no painel (ou PS_PASSWORD no .env)." >&2
	exit 1
fi
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

parando=0
parar() {
	# Um pedido só: um segundo SIGINT no Python seria "sair já" e cortaria a partida. Para matar
	# na hora existe o "Desligar agora" (systemctl kill).
	((parando)) && return
	parando=1
	# Só o Python do bot (descendente deste script): outros bots na mesma máquina seguem jogando.
	local p
	for p in $(descendentes "$filho"); do
		if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -q 'ai_vgc.nn.player'; then
			kill -INT "$p" 2>/dev/null || true
		fi
	done
}
trap parar INT TERM

# wait volta quando chega um sinal; espera de novo até o bot sair de verdade.
codigo=0
while kill -0 "$filho" 2>/dev/null; do
	wait "$filho" && codigo=0 || codigo=$?
done
exit "$codigo"
