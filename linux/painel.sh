#!/usr/bin/env bash
# Comandos do painel de Windows (e úteis no terminal). Cuida de um bot, "bot" por padrão
# (LOR_BOT=outro para outro), com a configuração em /etc/lor-bots/:
#   <bot>.conf   conta, formato e time escolhidos no painel
#   <bot>.senha  a senha da conta (só root e o usuário bots leem)
#   <bot>.env    gerado a partir dos dois acima, lido pelo serviço lor-bot@<bot>
#   coleta.env   o código para enviar as partidas à coleta do time
#
#   painel.sh estado                    chave=valor, para o painel
#   painel.sh ligar | desligar | agora | reiniciar
#   painel.sh conta                     stdin: usuário na 1ª linha, senha na 2ª
#   painel.sh codigo                    stdin: o código da coleta
#   painel.sh formato bo3|bo1
#   painel.sh time top3|<nome>
#   painel.sh times                     os times salvos (um por linha)
#   painel.sh adicionar-time            stdin: nome na 1ª linha; depois o export do Showdown
#                                       ou um link do pokepast.es
#   painel.sh remover-time <nome>
#   painel.sh log [linhas]
#   painel.sh manter-vivo               segura o WSL ligado enquanto o bot roda
#   painel.sh atualizar                 baixa a versão nova do GitHub e reinstala
set -euo pipefail

BOT_ID="${LOR_BOT:-bot}"
ETC=/etc/lor-bots
CONF="$ETC/$BOT_ID.conf"
SENHA="$ETC/$BOT_ID.senha"
ENV="$ETC/$BOT_ID.env"
UNIT="lor-bot@$BOT_ID"
AIVGC=/opt/lor-bots/ai-vgc
TIMES="$AIVGC/data/teams/reg_mc_top"
MODELO=data/models/mc-bo3-rnad-v5.pt

[ "$(id -u)" -eq 0 ] || { echo "erro=rode como root" >&2; exit 1; }

# Configuração: chave=valor simples, lida sem executar nada do arquivo.
conf_get() { [ -f "$CONF" ] && sed -n "s/^$1=//p" "$CONF" | tail -1 || true; }
conf_set() {
	touch "$CONF"
	grep -v "^$1=" "$CONF" >"$CONF.tmp" || true
	printf '%s=%s\n' "$1" "$2" >>"$CONF.tmp"
	mv "$CONF.tmp" "$CONF"
	chmod 640 "$CONF"
}

gerar_env() {
	local conta formato time modo
	conta="$(conf_get conta)"
	formato="$(conf_get formato)"
	time="$(conf_get time)"
	modo="--ladder"
	[ "$formato" = bo1 ] && modo+=" --bo1"
	if [ -n "$time" ] && [ "$time" != top3 ] && [ -f "$TIMES/LOR-$time.txt" ]; then
		modo+=" --use LOR-$time"
	else
		modo+=" --top 3"
	fi
	modo+=" --model $MODELO"
	{
		printf 'BOT="%s"\n' "$conta"
		printf 'SENHA_ARQUIVO=%s\n' "$SENHA"
		printf 'SERVIDOR=%s\n' "$(conf_get servidor || true)"
		printf 'MODO="%s"\n' "$modo"
	} >"$ENV.tmp"
	sed -i 's/^SERVIDOR=$/SERVIDOR=oficial/' "$ENV.tmp"
	chown root:bots "$ENV.tmp"
	chmod 640 "$ENV.tmp"
	mv "$ENV.tmp" "$ENV"
}

estado_unit() { systemctl show -p ActiveState --value "$1" 2>/dev/null || echo desconhecido; }

nome_valido() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

cmd="${1:-estado}"
shift || true
case "$cmd" in
estado)
	echo "versao=$(cat /opt/lor-bots/VERSION 2>/dev/null || echo ?)"
	echo "bot=$(estado_unit "$UNIT")"
	echo "envio=$(estado_unit lor-envio)"
	echo "conta=$(conf_get conta)"
	echo "senha=$([ -s "$SENHA" ] && echo sim || echo nao)"
	echo "codigo=$([ -s "$ETC/coleta.env" ] && echo sim || echo nao)"
	f="$(conf_get formato)"
	echo "formato=${f:-bo3}"
	t="$(conf_get time)"
	echo "time=${t:-top3}"
	mem=$(systemctl show -p MemoryCurrent --value "$UNIT" 2>/dev/null || true)
	[[ "$mem" =~ ^[0-9]+$ ]] && echo "memoria_mb=$((mem / 1024 / 1024))" || echo "memoria_mb="
	# A batalha em andamento: a última anunciada no log ("watch: https://play.pokemonshowdown.com/battle-..."),
	# se depois dela não veio o resultado ("win vs ...") e o bot está ligado (ou desligando após ela).
	p=""
	if [[ "$(estado_unit "$UNIT")" =~ ^(active|deactivating)$ ]]; then
		p="$(journalctl -u "$UNIT" -n 300 -o cat --no-pager 2>/dev/null \
			| awk '/^watch: /{p=$2} /^(win|loss|tie) vs /{p=""} END{print p}')"
	fi
	echo "partida=$p"
	;;
ligar)
	[ -n "$(conf_get conta)" ] && [ -s "$SENHA" ] || { echo "erro=configure a conta e a senha primeiro"; exit 1; }
	gerar_env
	systemctl start "$UNIT"
	[ -s "$ETC/coleta.env" ] && systemctl start lor-envio || true
	echo ok=ligado
	;;
desligar)
	# Termina a partida/série atual e para (pode levar até ~40 min numa série Bo3 longa).
	systemctl stop --no-block "$UNIT"
	echo ok=desligando
	;;
agora)
	systemctl kill -s SIGKILL "$UNIT" 2>/dev/null || true
	systemctl stop --no-block "$UNIT"
	echo ok=desligado
	;;
reiniciar)
	# Aplica conta/formato/time novos: termina a partida atual e volta (via systemd, para não
	# depender desta chamada continuar viva). Bots sem .conf (configurados à mão num servidor)
	# mantêm o .env deles.
	[ -f "$CONF" ] && gerar_env
	if [ "$(estado_unit "$UNIT")" = active ]; then
		systemd-run --quiet --collect --unit "lor-reinicio-$BOT_ID-$(date +%s)" \
			bash -c "systemctl stop $UNIT; systemctl start $UNIT"
		echo ok=reiniciando
	else
		echo ok=parado
	fi
	;;
conta)
	IFS= read -r usuario || true
	IFS= read -r senha || true
	usuario="${usuario%$'\r'}"
	senha="${senha%$'\r'}"
	if [[ ! "$usuario" =~ ^[A-Za-z0-9\ _.-]{1,18}$ ]]; then
		echo "erro=nome de usuário inválido (até 18 letras, números, espaço, . _ -)"
		exit 1
	fi
	conf_set conta "$usuario"
	if [ -n "$senha" ]; then
		umask 077
		printf '%s' "$senha" >"$SENHA.tmp"
		chown root:bots "$SENHA.tmp"
		chmod 640 "$SENHA.tmp"
		mv "$SENHA.tmp" "$SENHA"
	fi
	gerar_env
	echo ok=conta
	;;
codigo)
	IFS= read -r codigo || true
	codigo="${codigo%$'\r'}"
	codigo="${codigo//[[:space:]]/}"
	[[ "$codigo" =~ ^[A-Za-z0-9_-]{8,128}$ ]] || { echo "erro=código inválido"; exit 1; }
	umask 077
	printf 'COLETA_CODIGO=%s\n' "$codigo" >"$ETC/coleta.env.tmp"
	chown root:bots "$ETC/coleta.env.tmp"
	chmod 640 "$ETC/coleta.env.tmp"
	mv "$ETC/coleta.env.tmp" "$ETC/coleta.env"
	systemctl restart lor-envio
	echo ok=codigo
	;;
formato)
	[[ "${1:-}" =~ ^bo[13]$ ]] || { echo "erro=use bo3 ou bo1"; exit 1; }
	conf_set formato "$1"
	gerar_env
	echo ok=formato
	;;
time)
	t="${1:-top3}"
	if [ "$t" != top3 ]; then
		nome_valido "$t" && [ -f "$TIMES/LOR-$t.txt" ] || { echo "erro=time não encontrado"; exit 1; }
	fi
	conf_set time "$t"
	gerar_env
	echo ok=time
	;;
times)
	for f in "$TIMES"/LOR-*.txt; do
		[ -e "$f" ] || continue
		b="$(basename "$f" .txt)"
		echo "${b#LOR-}"
	done
	;;
adicionar-time)
	IFS= read -r nome || true
	nome="${nome%$'\r'}"
	nome_valido "$nome" || { echo "erro=nome do time: só letras, números, - e _ (até 32)"; exit 1; }
	texto="$(cat | tr -d '\r')"
	tmp="$(mktemp)"
	trap 'rm -f "$tmp"' EXIT
	if [[ "$(echo "$texto" | tr -d '[:space:]')" =~ ^https?://pokepast\.es/([0-9a-fA-F]+)(/raw)?/?$ ]]; then
		curl -fsSL --max-time 20 "https://pokepast.es/${BASH_REMATCH[1]}/raw" | tr -d '\r' >"$tmp" \
			|| { echo "erro=não consegui baixar o pokepast"; exit 1; }
	else
		printf '%s\n' "$texto" >"$tmp"
	fi
	grep -q '[A-Za-z]' "$tmp" || { echo "erro=time vazio"; exit 1; }
	cd "$AIVGC/pokemon-showdown-mc"
	if ! saida="$(sudo -u bots ./pokemon-showdown validate-team gen9championsvgc2026regmc <"$tmp" 2>&1)"; then
		echo "erro=o Showdown recusou o time:"
		echo "$saida" | head -20
		exit 1
	fi
	install -o bots -g bots -m 644 "$tmp" "$TIMES/LOR-$nome.txt"
	# A busca de jogadas adivinha sets pela pasta reg_mc; o time também vai para lá.
	install -o bots -g bots -m 644 "$tmp" "$AIVGC/data/teams/reg_mc/LOR-$nome.txt"
	echo ok=time-adicionado
	;;
remover-time)
	nome_valido "${1:-}" || { echo "erro=nome inválido"; exit 1; }
	rm -f "$TIMES/LOR-$1.txt" "$AIVGC/data/teams/reg_mc/LOR-$1.txt"
	if [ "$(conf_get time)" = "$1" ]; then
		conf_set time top3
		gerar_env
	fi
	echo ok=time-removido
	;;
log)
	journalctl -u "$UNIT" -n "${1:-15}" -o cat --no-pager 2>/dev/null || true
	;;
manter-vivo)
	# O WSL desliga a distribuição quando nenhum programa do Windows a usa, mesmo com serviços
	# rodando; o painel deixa este comando aberto (escondido) enquanto o bot estiver ligado.
	exec 9>/run/lor-manter-vivo.lock
	flock -n 9 || exit 0
	sleep 20
	while :; do
		case "$(estado_unit "$UNIT")" in
		inactive | failed) break ;;
		esac
		sleep 30
	done
	sleep 120 # o envio manda as últimas partidas
	;;
atualizar)
	exec /opt/lor-bots/atualizar.sh
	;;
*)
	sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
	;;
esac
