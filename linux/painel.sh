#!/usr/bin/env bash
# Comandos do painel de Windows (e úteis no terminal). Cuida de um bot, "bot" por padrão
# (LOR_BOT=outro para outro), com a configuração em /etc/lor-bots/:
#   <bot>.conf   conta, formato e time escolhidos no painel
#   <bot>.senha  a senha da conta (só root e o usuário bots leem)
#   <bot>.env    gerado a partir dos dois acima, lido pelo serviço lor-bot@<bot>
#   coleta.env   o código para enviar as partidas à coleta do time
#
#   painel.sh estado [--log N]          chave=valor, para o painel (com --log, depois de uma linha
#                                       "---log---", as últimas N linhas do log: uma chamada só)
#   painel.sh diagnostico               versão, estado e logs (sem senha nem código), para suporte
#   painel.sh ligar | desligar | agora | reiniciar   (ligar e desafiar só com um código da
#                                       coleta válido, conferido na coleta: rodar-bot.sh --conferir)
#   painel.sh conta                     stdin: usuário na 1ª linha, senha na 2ª
#   painel.sh conta-navegador           stdin: usuário; senha só no site oficial
#   painel.sh codigo                    stdin: o código da coleta (conferido na coleta antes de salvar)
#   painel.sh formato bo3|bo1
#   painel.sh timer sim|nao             o bot liga o timer no começo de cada partida (padrão: sim)
#   painel.sh bloquear-bots sim|nao     /blockbots ou /allowbots no login e antes da próxima busca
#   painel.sh esperar-bots sim|nao      esperar bots adversários conhecidos saírem da fila (padrão: sim)
#   painel.sh chat sim|nao              o bot diz "glhf" no começo e "gg wp" no fim de cada partida
#                                       (padrão: sim; vale já na próxima partida, sem reiniciar)
#   painel.sh discord sim|nao           as séries deste PC são postadas no Discord do time (padrão:
#                                       sim); com nao, as partidas seguem indo para a coleta e o treino
#   painel.sh time top3|<nome>       top3 = o padrão (MC371 ou MC196)
#   painel.sh times                     os times salvos (um por linha)
#   painel.sh adicionar-time            stdin: nome na 1ª linha; depois o export do Showdown
#                                       ou um link do pokepast.es
#   painel.sh remover-time <nome>
#   painel.sh desafiar [partidas]       stdin: o usuário do Showdown a desafiar (1 a 10 partidas;
#                                       termina a partida do ladder antes e volta a ele depois)
#   painel.sh cancelar-desafio
#   painel.sh log [linhas]
#   painel.sh manter-vivo               segura o WSL ligado enquanto o bot roda
#   painel.sh atualizar                 baixa a versão nova do GitHub e reinstala
#   painel.sh backup <pasta>|desligar   stdin: o token de backup da coleta; copia as partidas de
#                                       todos para <pasta> uma vez por dia (C:\... ou /mnt/c/...)
set -euo pipefail

BOT_ID="${LOR_BOT:-bot}"
ETC="${LOR_ETC:-/etc/lor-bots}"  # LOR_ETC, LOR_RUN e LOR_AIVGC: só para os testes
CONF="$ETC/$BOT_ID.conf"
SENHA="$ETC/$BOT_ID.senha"
ENV="$ETC/$BOT_ID.env"
UNIT="lor-bot@$BOT_ID"
AIVGC="${LOR_AIVGC:-/opt/lor-bots/ai-vgc}"
TIMES="$AIVGC/data/teams/reg_mc_top"
MODELO=data/models/mc-bo3-rnad-v5.pt
# Times do padrão ("top3", nome antigo da opção): os dois melhores do Bo3 no ladder em 24/10
# (MC371 20-14, MC196 12-10); o MC147 do antigo --top 3 ficou em 3-7.
PADRAO="MC371 MC196"
# Adaptação no Bo3 (desligada no bot.sh): depois de perder um jogo, abre com outra dupla; no
# turno 1 dos jogos 2 e 3, a busca conta com o adversário respondendo ao nosso turno 1 anterior.
ADAPTA="--change-after-loss --counter-t1 0.5"
# Peso da política na busca (o bot.sh usa 0.1). Com 0.1 a busca quase nunca contraria a jogada
# favorita da rede; em 1200 partidas locais de cada lado, 0.03 ganhou 83,5% contra 80,9%.
# --search-protect: a busca sempre avalia Protect/Wide Guard, que a rede quase nunca sugere (nos
# replays de 24–29/10, Wide Guard contra Clanging Scales era a melhor jogada e nunca foi avaliado).
# Neutro em 1200 partidas locais (81,9% contra 81,6%), ~12% mais lento por decisão.
BUSCA="--search-prior 0.03 --search-protect"
# Modelos do oponente da busca ajustados com os jogos da coleta (linux/treino-oponente.py), do mais
# novo ao mais velho: vale o primeiro que existir. Só existem no PC onde foram treinados; nos outros a
# busca segue com o all-bo3-opp-v2 do bot.sh. Nas 396 partidas mais novas (31/10, fora do treino),
# acerto da jogada do oponente: v4 64,6%, v1 59,9%, v2 54,4% (BENCHMARKS.md).
OPONENTES="data/models/lor-opp-v4-tudo.pt data/models/lor-opp-v1-tudo.pt"
# Um desafio roda numa unit à parte, que troca o lor-bot@<bot> para --challenge e depois volta.
# O que ela precisa saber fica em $DESAFIO_DIR: alvo, partidas, fase (esperando = a partida do
# ladder terminar, aguardando = o adversário aceitar, jogando, cancelando), voltar (1 = religar o
# ladder no fim) e cancelado.
DESAFIO="lor-desafio-$BOT_ID"
DESAFIO_DIR="${LOR_RUN:-/run}/$DESAFIO"
ESPERA_ACEITE=300 # segundos para aceitar; depois disso o desafio é cancelado
# O Elo da conta no ladder oficial, guardado em $ELO_CACHE: o "estado" só lê o arquivo (rápido, sem
# rede) e, se ele tem mais de ELO_VALIDADE segundos, pede uma consulta nova em segundo plano.
ELO_CACHE="${LOR_RUN:-/run}/lor-elo-$BOT_ID.json"
ELO_VALIDADE=180
ELO_API="${LOR_ELO_API:-https://pokemonshowdown.com/users/}"
COLETA_PING="${LOR_COLETA_PING:-https://showdown.sierverso.com.br/coleta/ping}"
# Como foi o último contato do envio com a coleta (ok, codigo = código recusado, fora), gravado pelo
# enviar-partidas.py.
COLETA_STATUS="$AIVGC/data/live_games/.coleta-status"
# Existe = não postar no Discord: o enviar-partidas.py marca as partidas que manda com "discord":
# false (vale para todos os bots deste PC; a coleta continua recebendo tudo).
SEM_DISCORD="$ETC/sem-discord"
# Existe = o bot não manda "glhf" / "gg wp" no chat da partida (--chat-off: ele confere a cada partida).
SEM_CHAT="$ETC/$BOT_ID.sem-chat"
# Ausente = /blockbots; presente = /allowbots. O bot relê antes de cada busca no ladder.
PERMITIR_BOTS="$ETC/$BOT_ID.permitir-bots"
# Presente = pular a espera por adversários conhecidos; não altera a fila dos bots do time.
SEM_ESPERA_BOTS="$ETC/$BOT_ID.sem-espera-bots"
# O bot só liga com um código da coleta aceito pela coleta: rodar-bot.sh --conferir.
RODAR_BOT="$(dirname "$(readlink -f "$0")")/rodar-bot.sh"

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

# Sem argumentos, o ladder; com "<alvo> <partidas>", um desafio a essa conta.
gerar_env() {
	local conta formato time modo
	conta="$(conf_get conta)"
	formato="$(conf_get formato)"
	time="$(conf_get time)"
	modo="--ladder"
	[ $# -eq 2 ] && modo="--challenge $1 $2 --challenge-wait $ESPERA_ACEITE"
	[ "$formato" = bo1 ] && modo+=" --bo1"
	[ "$(conf_get timer)" = nao ] && modo+=" --no-timer"
	modo+=" --chat-off $SEM_CHAT"
	if [ -n "$time" ] && [ "$time" != top3 ] && [ -f "$TIMES/LOR-$time.txt" ]; then
		modo+=" --use LOR-$time"
	else
		modo+=" --use $PADRAO"
	fi
	modo+=" --model $MODELO $ADAPTA $BUSCA"
	local oponente
	for oponente in $OPONENTES; do
		if [ -f "$AIVGC/$oponente" ]; then
			modo+=" --opp-model $oponente"
			break
		fi
	done
	{
		printf 'BOT="%s"\n' "$conta"
		printf 'LOGIN=%s\n' "$(conf_get login || true)"
		printf 'SENHA_ARQUIVO=%s\n' "$SENHA"
		printf 'PERMITIR_BOTS_ARQUIVO=%s\n' "$PERMITIR_BOTS"
		printf 'SEM_ESPERA_BOTS_ARQUIVO=%s\n' "$SEM_ESPERA_BOTS"
		printf 'SERVIDOR=%s\n' "$(conf_get servidor || true)"
		printf 'MODO="%s"\n' "$modo"
	} >"$ENV.tmp"
	sed -i 's/^SERVIDOR=$/SERVIDOR=oficial/' "$ENV.tmp"
	sed -i 's/^LOGIN=$/LOGIN=navegador/' "$ENV.tmp"
	chown root:bots "$ENV.tmp"
	chmod 640 "$ENV.tmp"
	mv "$ENV.tmp" "$ENV"
}

estado_unit() { systemctl show -p ActiveState --value "$1" 2>/dev/null || echo desconhecido; }

# Um "Aplicar" agenda parar+ligar numa unit à parte (lor-reinicio-<bot>-*). Desligar, ou um
# novo Aplicar, cancela o que ainda esperava; a parada já pedida segue. Volta 0 se cancelou algum.
cancelar_reinicio() {
	local u achou=1
	for u in $(systemctl list-units --plain --no-legend "lor-reinicio-$BOT_ID-[0-9]*.service" 2>/dev/null | awk '{print $1}'); do
		systemctl stop "$u" 2>/dev/null || true
		achou=0
	done
	return $achou
}

# O placar da partida (ou série Bo3) atual, que o bot grava a cada turno em
# data/live_games/placar-<conta>.json. Só enquanto o bot está ligado e o placar é recente
# (ou a partida ainda está em andamento): depois de 10 min parado, some do painel.
placar() {
	local id arq=""
	id="$(conf_get conta | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
	[ -n "$id" ] && arq="$AIVGC/data/live_games/placar-$id.json"
	if [ -n "$arq" ] && [ -f "$arq" ] && [[ "$(estado_unit "$UNIT")" =~ ^(active|deactivating)$ ]]; then
		python3 -I - "$arq" "$1" <<'PY' 2>/dev/null && return
import json, sys, time
d = json.load(open(sys.argv[1]))
if time.time() - d["time"] > 600 and not sys.argv[2]:
    sys.exit(1)
serie = d.get("serie") or []
print(f"placar_oponente={d.get('opponent') or ''}")
print(f"placar_bo3={'sim' if d.get('bo3') else 'nao'}")
print(f"placar_jogo={d.get('jogo') or 1}")
print(f"placar_vitorias={serie.count('win')}")
print(f"placar_derrotas={serie.count('loss')}")
print(f"placar_turno={d.get('turn') or 0}")
print(f"placar_nossos={d.get('nossos', '')}")
print(f"placar_deles={d.get('deles', '')}")
print(f"placar_resultado={d.get('resultado') or ''}")
PY
	fi
	echo "placar_oponente="
}

# O formato do ladder que o bot joga (o mesmo que o bot.sh monta: Reg M-C, Bo3 ou Bo1).
formato_ladder() {
	local f
	f="$(conf_get formato)"
	[ "$f" = bo1 ] && echo gen9championsvgc2026regmc || echo gen9championsvgc2026regmcbo3
}

# elo=, elo_partidas= e elo_gxe= do cache, se for da conta e do formato atuais (vazio se não houver).
elo() {
	local conta
	conta="$(conf_get conta)"
	if [ -z "$conta" ] || [ "$(conf_get servidor)" = lor ]; then
		echo "elo="  # no nosso servidor o Elo não aparece no site oficial
		return
	fi
	local saida rc=0
	saida="$(python3 -I - "$ELO_CACHE" "$(id_showdown "$conta")" "$(formato_ladder)" "$ELO_VALIDADE" 2>/dev/null <<'PY'
import json, sys, time
cache, conta, fmt, validade = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    d = json.load(open(cache))
except (OSError, ValueError):
    d = {}
atual = d.get("conta") == conta and d.get("formato") == fmt
if atual and d.get("elo") is not None:
    print(f"elo={d['elo']}")
    print(f"elo_partidas={d.get('partidas', '')}")
    print(f"elo_gxe={d.get('gxe', '')}")
else:
    print("elo=")
sys.exit(3 if not atual or time.time() - d.get("time", 0) > validade else 0)
PY
)" || rc=$?
	[ -n "$saida" ] && echo "$saida" || echo "elo="
	# 3 = cache velho ou de outra conta: consulta de novo em segundo plano, sem segurar o painel.
	if [ "$rc" -eq 3 ]; then
		setsid -f bash "$0" _elo fundo >/dev/null 2>&1 </dev/null || true
	fi
}

# Consulta o ladder oficial e grava o cache, uma consulta por vez. Em segundo plano ("fundo"), se
# já há uma consulta andando, não faz outra.
elo_consultar() {
	local conta
	conta="$(conf_get conta)"
	[ -n "$conta" ] || return 0
	exec 9>"$ELO_CACHE.lock"
	if [ "${1:-}" = fundo ]; then flock -n 9 || return 0; else flock -w 30 9 || return 0; fi
	python3 -I - "$ELO_API" "$(id_showdown "$conta")" "$(formato_ladder)" "$ELO_CACHE" <<'PY'
import json, os, sys, time, urllib.request
api, conta, fmt, cache = sys.argv[1:5]
d = {"time": time.time(), "conta": conta, "formato": fmt, "elo": None}
try:
    req = urllib.request.Request(api + conta + ".json", headers={"User-Agent": "lor-bots-painel"})
    ratings = json.loads(urllib.request.urlopen(req, timeout=15).read()).get("ratings") or {}
    if isinstance(ratings, list):
        ratings = {r.get("formatid"): r for r in ratings}
    r = ratings.get(fmt)
    if r:
        d["elo"] = round(float(r["elo"]))
        d["partidas"] = sum(int(r.get(k) or 0) for k in ("w", "l", "t"))
        if r.get("gxe") is not None:
            d["gxe"] = round(float(r["gxe"]), 1)
except Exception as e:
    print(f"elo: {e!r}", file=sys.stderr)
    try:  # sem rede: mantém o último Elo conhecido, mas tenta de novo na próxima validade
        antigo = json.load(open(cache))
        if antigo.get("conta") == conta and antigo.get("formato") == fmt:
            d.update({k: antigo[k] for k in ("elo", "partidas", "gxe") if k in antigo})
    except (OSError, ValueError):
        pass
tmp = cache + ".tmp"
with open(tmp, "w") as f:
    json.dump(d, f)
os.replace(tmp, cache)
PY
}

nome_valido() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,32}$ ]]; }

conta_pronta() {
	[ -n "$(conf_get conta)" ] || return 1
	[ "$(conf_get login)" != senha ] || [ -s "$SENHA" ]
}

# O id do Showdown: só letras minúsculas e números ("Sier VGC" -> siervgc).
id_showdown() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }

# O dia de hoje: vitórias e derrotas da conta, no total e por time, das partidas de hoje no
# games.jsonl. O bot grava na pasta do dia em que ligou (um bot ligado na segunda ainda grava na
# dela na quarta), então olha todas as pastas cujo games.jsonl mudou desde a meia-noite. Recalcula
# só quando um desses arquivos muda; senão lê o cache.
hoje() {
	local conta
	conta="$(conf_get conta)"
	[ -n "$conta" ] || { echo "hoje_vitorias="; return; }
	python3 -I - "$AIVGC/data/live_games" "$conta" "${LOR_RUN:-/run}/lor-hoje-$BOT_ID.json" 2>/dev/null <<'PY' || echo "hoje_vitorias="
import json, os, sys, time
raiz, conta, cache = sys.argv[1], sys.argv[2], sys.argv[3]
hoje = time.strftime("%Y-%m-%d")
meia_noite = time.mktime(time.strptime(hoje, "%Y-%m-%d"))
arqs = []
for d in sorted(os.listdir(raiz)) if os.path.isdir(raiz) else []:
    a = os.path.join(raiz, d, "games.jsonl")
    try:
        if os.path.getmtime(a) >= meia_noite:
            arqs.append(a)
    except OSError:
        pass
chave = [hoje, conta] + [[a, os.path.getmtime(a)] for a in arqs]
try:
    c = json.load(open(cache))
    if c.get("chave") != chave:
        raise ValueError
except (OSError, ValueError):
    v = d = 0
    times = {}
    for a in arqs:
        if not os.path.exists(a):
            continue
        with open(a, "rb") as f:
            for linha in f:
                try:
                    r = json.loads(linha)
                except ValueError:
                    continue
                if not str(r.get("time", "")).startswith(hoje) or r.get("user") != conta:
                    continue
                res = r.get("result")
                if res not in ("win", "loss"):
                    continue
                t = times.setdefault(str(r.get("team") or "?").removeprefix("LOR-"), [0, 0])
                t[res == "loss"] += 1
                v += res == "win"
                d += res == "loss"
    c = {"chave": chave, "v": v, "d": d, "times": times}
    try:
        tmp = cache + ".tmp"
        with open(tmp, "w") as f:
            json.dump(c, f)
        os.replace(tmp, cache)
    except OSError:
        pass
print(f"hoje_vitorias={c['v']}")
print(f"hoje_derrotas={c['d']}")
print("hoje_times=" + ", ".join(f"{n} {a}-{b}" for n, (a, b) in sorted(c["times"].items(), key=lambda x: -sum(x[1]))))
PY
}

desafio_ativo() { [[ "$(estado_unit "$DESAFIO")" =~ ^(active|activating|deactivating)$ ]]; }
desafio_get() { cat "$DESAFIO_DIR/$1" 2>/dev/null || true; }
desafio_set() { [ -d "$DESAFIO_DIR" ] && echo "$2" >"$DESAFIO_DIR/$1" || true; }

cmd="${1:-estado}"
shift || true
case "$cmd" in
estado)
	echo "versao=$(cat /opt/lor-bots/VERSION 2>/dev/null || echo ?)"
	echo "bot=$(estado_unit "$UNIT")"
	envio="$(estado_unit lor-envio)"
	echo "envio=$envio"
	st=""
	if [ "$envio" = active ] && [ -f "$COLETA_STATUS" ]; then
		st="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status") or "")' \
			"$COLETA_STATUS" 2>/dev/null || true)"
	fi
	echo "envio_status=$st"
	echo "conta=$(conf_get conta)"
	echo "login=$(conf_get login)"
	echo "senha=$([ -s "$SENHA" ] && echo sim || echo nao)"
	echo "codigo=$([ -s "$ETC/coleta.env" ] && echo sim || echo nao)"
	f="$(conf_get formato)"
	echo "formato=${f:-bo3}"
	t="$(conf_get time)"
	echo "time=${t:-top3}"
	tm="$(conf_get timer)"
	echo "timer=${tm:-sim}"
	echo "discord=$([ -e "$SEM_DISCORD" ] && echo nao || echo sim)"
	echo "chat=$([ -e "$SEM_CHAT" ] && echo nao || echo sim)"
	echo "bloquear_bots=$([ -e "$PERMITIR_BOTS" ] && echo nao || echo sim)"
	echo "esperar_bots=$([ -e "$SEM_ESPERA_BOTS" ] && echo nao || echo sim)"
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
	placar "$p"
	elo
	hoje
	if desafio_ativo; then
		echo "desafio=$(desafio_get alvo)"
		echo "desafio_fase=$(desafio_get fase)"
	else
		echo "desafio="
		echo "desafio_fase="
	fi
	if [ "${1:-}" = --log ] && [[ "${2:-}" =~ ^[0-9]+$ ]]; then
		echo "---log---"
		journalctl -u "$UNIT" -u "$DESAFIO" -n "$2" -o cat --no-pager 2>/dev/null || true
	fi
	;;
diagnostico)
	# Para colar no Discord quando algo dá errado: nada de senha, código da coleta ou token.
	echo "== LoR Bots $(cat /opt/lor-bots/VERSION 2>/dev/null || echo ?) · $(date '+%Y-%m-%d %H:%M:%S %z')"
	echo "== estado"
	bash "$0" estado 2>&1 || true
	echo "== sistema"
	uname -r
	free -m | sed -n 1,2p
	df -h /opt/lor-bots 2>/dev/null | tail -1
	echo "== bot (últimas 200 linhas)"
	journalctl -u "$UNIT" -u "$DESAFIO" -n 200 -o short-iso --no-pager 2>/dev/null || true
	echo "== envio para a coleta (últimas 20)"
	journalctl -u lor-envio -n 20 -o short-iso --no-pager 2>/dev/null || true
	echo "== backup (últimas 10)"
	journalctl -u lor-backup -n 10 -o short-iso --no-pager 2>/dev/null || true
	;;
ligar)
	conta_pronta || { echo "erro=configure a conta primeiro"; exit 1; }
	conferido="$(LOR_ETC="$ETC" LOR_COLETA_PING="$COLETA_PING" bash "$RODAR_BOT" --conferir)" \
		|| { echo "$conferido"; exit 1; }
	[[ "$conferido" == aviso=* ]] && echo "$conferido"
	if desafio_ativo; then
		# O bot está no desafio: o ladder liga quando ele acabar.
		desafio_set voltar 1
		echo ok=depois-do-desafio
		exit 0
	fi
	gerar_env
	systemctl start "$UNIT"
	[ -s "$ETC/coleta.env" ] && systemctl enable --now lor-envio >/dev/null 2>&1 || true
	echo ok=ligado
	;;
desligar)
	# Termina a partida/série atual e para (pode levar até ~40 min numa série Bo3 longa).
	cancelar_reinicio || true
	# Num desafio: não começa (se ainda esperava o ladder) nem volta ao ladder no fim.
	if desafio_ativo; then
		desafio_set voltar 0
		desafio_set cancelado 1
	fi
	systemctl stop --no-block "$UNIT"
	echo ok=desligando
	;;
agora)
	cancelar_reinicio || true
	if desafio_ativo; then
		desafio_set voltar 0
		desafio_set cancelado 1
		systemctl stop --no-block "$DESAFIO" 2>/dev/null || true
		[ -f "$CONF" ] && gerar_env
	fi
	systemctl kill -s SIGKILL "$UNIT" 2>/dev/null || true
	systemctl stop --no-block "$UNIT"
	echo ok=desligado
	;;
reiniciar)
	# Aplica conta/formato/time novos: termina a partida atual e volta (via systemd, para não
	# depender desta chamada continuar viva). Bots sem .conf (configurados à mão num servidor)
	# mantêm o .env deles. Num desafio, o que mudou vale quando ele voltar ao ladder.
	if desafio_ativo; then
		echo ok=depois-do-desafio
		exit 0
	fi
	[ -f "$CONF" ] && gerar_env
	# Um "Aplicar" novo substitui o que ainda esperava (e liga de volta no fim, como ele faria).
	if cancelar_reinicio || [ "$(estado_unit "$UNIT")" = active ]; then
		systemd-run --quiet --collect --unit "lor-reinicio-$BOT_ID-$(date +%s)" \
			bash -c "systemctl stop $UNIT; systemctl start $UNIT"
		echo ok=reiniciando
	else
		echo ok=parado
	fi
	;;
conta|conta-navegador)
	IFS= read -r usuario || true
	senha=''
	if [ "$cmd" = conta ]; then IFS= read -r senha || true; fi
	usuario="${usuario%$'\r'}"
	senha="${senha%$'\r'}"
	if [[ ! "$usuario" =~ ^[A-Za-z0-9\ _.-]{1,18}$ ]]; then
		echo "erro=nome de usuário inválido (até 18 letras, números, espaço, . _ -)"
		exit 1
	fi
	conf_set conta "$usuario"
	if [ "$cmd" = conta-navegador ]; then conf_set login navegador; else conf_set login senha; fi
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
	# Confere na coleta antes de salvar: um código errado salvo só daria 401 em silêncio.
	resp="$(mktemp)"
	http="$(curl -s -o "$resp" -w '%{http_code}' --max-time 15 -H "Authorization: Bearer $codigo" "$COLETA_PING" 2>/dev/null || true)"
	membro="$(sed -n 's/.*"nome": *"\([A-Za-z0-9_-]*\)".*/\1/p' "$resp")"
	rm -f "$resp"
	case "$http" in
	200) ;;
	401 | 403)
		echo "erro=a coleta não reconheceu este código. Confira se copiou inteiro ou peça outro ao Thiago."
		exit 1
		;;
	*) echo "aviso=não consegui falar com a coleta agora; o código foi salvo e o envio confere sozinho" ;;
	esac
	umask 077
	printf 'COLETA_CODIGO=%s\n' "$codigo" >"$ETC/coleta.env.tmp"
	chown root:bots "$ETC/coleta.env.tmp"
	chmod 640 "$ETC/coleta.env.tmp"
	mv "$ETC/coleta.env.tmp" "$ETC/coleta.env"
	# Fica habilitado: depois de reiniciar o Linux, o envio volta sozinho com as partidas pendentes.
	systemctl enable lor-envio >/dev/null 2>&1 || true
	rm -f "$COLETA_STATUS"  # o do código anterior
	# Aceito pela coleta: vale para ligar o bot mesmo se a coleta sair do ar depois.
	if [ "$http" = 200 ]; then
		printf %s "$codigo" | sha256sum | cut -d' ' -f1 >"$ETC/coleta.conferido"
		chmod 644 "$ETC/coleta.conferido"  # o rodar-bot.sh (usuário bots) lê
	else
		rm -f "$ETC/coleta.conferido"
	fi
	systemctl restart lor-envio
	[ -n "$membro" ] && echo "membro=$membro"
	echo ok=codigo
	;;
formato)
	[[ "${1:-}" =~ ^bo[13]$ ]] || { echo "erro=use bo3 ou bo1"; exit 1; }
	conf_set formato "$1"
	gerar_env
	echo ok=formato
	;;
timer)
	[[ "${1:-}" =~ ^(sim|nao)$ ]] || { echo "erro=use sim ou nao"; exit 1; }
	conf_set timer "$1"
	gerar_env
	echo ok=timer
	;;
bloquear-bots)
	case "${1:-}" in
	sim) rm -f "$PERMITIR_BOTS" ;;
	nao) touch "$PERMITIR_BOTS" && chmod 644 "$PERMITIR_BOTS" ;;
	*) echo "erro=use sim ou nao"; exit 1 ;;
	esac
	echo ok=bloquear-bots
	;;
esperar-bots)
	case "${1:-}" in
	sim) rm -f "$SEM_ESPERA_BOTS" ;;
	nao) touch "$SEM_ESPERA_BOTS" && chmod 644 "$SEM_ESPERA_BOTS" ;;
	*) echo "erro=use sim ou nao"; exit 1 ;;
	esac
	echo ok=esperar-bots
	;;
chat)
	# Vale já na próxima partida, sem reiniciar o bot (ele confere o arquivo a cada partida).
	case "${1:-}" in
	sim) rm -f "$SEM_CHAT" ;;
	nao) touch "$SEM_CHAT" && chmod 644 "$SEM_CHAT" ;;
	*) echo "erro=use sim ou nao"; exit 1 ;;
	esac
	echo ok=chat
	;;
discord)
	# Vale já para a próxima partida enviada, sem reiniciar o bot nem o envio.
	case "${1:-}" in
	sim) rm -f "$SEM_DISCORD" ;;
	nao) touch "$SEM_DISCORD" && chmod 644 "$SEM_DISCORD" ;;
	*) echo "erro=use sim ou nao"; exit 1 ;;
	esac
	echo ok=discord
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
	# As pastas do Ai-vgc são do usuário bots: quem grava nelas é ele, não o root (um link posto
	# ali não faz o root escrever fora). A busca de jogadas adivinha sets pela pasta reg_mc; o time
	# também vai para lá.
	chmod 644 "$tmp"
	sudo -u bots install -m 644 "$tmp" "$TIMES/LOR-$nome.txt"
	sudo -u bots install -m 644 "$tmp" "$AIVGC/data/teams/reg_mc/LOR-$nome.txt"
	echo ok=time-adicionado
	;;
remover-time)
	nome_valido "${1:-}" || { echo "erro=nome inválido"; exit 1; }
	sudo -u bots rm -f "$TIMES/LOR-$1.txt" "$AIVGC/data/teams/reg_mc/LOR-$1.txt"
	if [ "$(conf_get time)" = "$1" ]; then
		conf_set time top3
		gerar_env
	fi
	echo ok=time-removido
	;;
desafiar)
	IFS= read -r alvo || true
	alvo="$(id_showdown "${alvo%$'\r'}")"
	n="${1:-1}"
	[[ "$alvo" =~ ^[a-z0-9]{1,18}$ ]] || { echo "erro=usuário do Showdown inválido"; exit 1; }
	[[ "$n" =~ ^([1-9]|10)$ ]] || { echo "erro=partidas: de 1 a 10"; exit 1; }
	conta_pronta || { echo "erro=configure a conta primeiro"; exit 1; }
	[ "$alvo" != "$(id_showdown "$(conf_get conta)")" ] || { echo "erro=essa é a conta do próprio bot"; exit 1; }
	desafio_ativo && { echo "erro=já tem um desafio em andamento (contra $(desafio_get alvo))"; exit 1; }
	conferido="$(LOR_ETC="$ETC" LOR_COLETA_PING="$COLETA_PING" bash "$RODAR_BOT" --conferir)" \
		|| { echo "$conferido"; exit 1; }
	cancelar_reinicio || true
	rm -rf "$DESAFIO_DIR"
	mkdir -p "$DESAFIO_DIR"
	echo "$alvo" >"$DESAFIO_DIR/alvo"
	echo "$n" >"$DESAFIO_DIR/partidas"
	echo esperando >"$DESAFIO_DIR/fase"
	# Volta ao ladder no fim só se ele estava ligado (e não parando a pedido).
	[[ "$(estado_unit "$UNIT")" =~ ^(active|activating)$ ]] && echo 1 >"$DESAFIO_DIR/voltar" || echo 0 >"$DESAFIO_DIR/voltar"
	systemd-run --quiet --collect --unit "$DESAFIO" --description "Desafio do bot LoR ($BOT_ID)" \
		-E LOR_BOT="$BOT_ID" "$(readlink -f "$0")" _desafio
	echo ok=desafiando
	;;
cancelar-desafio)
	desafio_ativo || { echo "erro=nenhum desafio em andamento"; exit 1; }
	desafio_set cancelado 1
	# Já desafiando: a parada do bot cancela o desafio não aceito, ou termina a partida dele.
	[[ "$(desafio_get fase)" =~ ^(aguardando|jogando)$ ]] && systemctl stop --no-block "$UNIT"
	echo ok=cancelando
	;;
_desafio)
	# Interno: o corpo da unit lor-desafio-<bot>, lançada pelo "desafiar".
	alvo="$(desafio_get alvo)"
	n="$(desafio_get partidas)"
	terminar() {
		# Sempre devolve o .env do ladder (um "ligar" depois não pode cair no desafio).
		[ -f "$CONF" ] && gerar_env
		if [ "$(desafio_get voltar)" = 1 ]; then
			echo "Voltando ao ladder"
			systemctl start "$UNIT" || true
		fi
		rm -rf "$DESAFIO_DIR"
	}
	trap terminar EXIT
	trap 'exit 0' INT TERM
	if [[ "$(estado_unit "$UNIT")" =~ ^(active|activating|deactivating)$ ]]; then
		echo "Desafio a $alvo: esperando a partida do ladder terminar"
		systemctl stop "$UNIT"
	fi
	[ -n "$(desafio_get cancelado)" ] && { echo "Desafio a $alvo cancelado"; exit 0; }
	gerar_env "$alvo" "$n"
	inicio=$(date +%s)
	desafio_set fase aguardando
	systemctl start "$UNIT"
	sleep 5
	while [[ "$(estado_unit "$UNIT")" =~ ^(active|activating|deactivating)$ ]]; do
		fase="$(desafio_get fase)"
		if [ -n "$(desafio_get cancelado)" ] && [ "$fase" != cancelando ]; then
			echo "Desafio a $alvo cancelado"
			desafio_set fase cancelando
			systemctl stop --no-block "$UNIT"
		elif [ "$fase" = aguardando ]; then
			if journalctl -u "$UNIT" --since "@$inicio" -o cat --no-pager 2>/dev/null | grep -q '^watch: '; then
				desafio_set fase jogando
			elif (($(date +%s) - inicio > ESPERA_ACEITE)); then
				echo "$alvo não aceitou o desafio em $((ESPERA_ACEITE / 60)) min: cancelado"
				desafio_set fase cancelando
				systemctl stop --no-block "$UNIT"
			fi
		fi
		sleep 5
	done
	echo "Desafio a $alvo terminado"
	;;
log)
	journalctl -u "$UNIT" -u "$DESAFIO" -n "${1:-15}" -o cat --no-pager 2>/dev/null || true
	;;
manter-vivo)
	# O WSL desliga a distribuição quando nenhum programa do Windows a usa, mesmo com serviços
	# rodando; o painel deixa este comando aberto (escondido) enquanto o bot estiver ligado.
	exec 9>"${LOR_RUN:-/run}/lor-manter-vivo.lock"
	flock -n 9 || exit 0
	ligado() {
		case "$(estado_unit "$UNIT")" in
		inactive | failed) desafio_ativo ;; # um desafio religa o bot daqui a pouco
		esac
	}
	sleep 20
	while :; do
		while ligado; do sleep 30; done
		sleep 120 # o envio manda as últimas partidas
		# Desligar e Ligar seguidos: o guardião que o Ligar abriu saiu sem a trava, que ainda era
		# deste. Então este confere de novo e, com o bot de volta, continua segurando.
		ligado || break
	done
	;;
atualizar)
	exec /opt/lor-bots/atualizar.sh
	;;
_elo)
	elo_consultar "${1:-}"
	;;
backup)
	# Cópia diária das partidas de todos da coleta para uma pasta deste PC (lor-backup.timer).
	if [ "${1:-}" = desligar ]; then
		systemctl disable --now lor-backup.timer >/dev/null 2>&1 || true
		echo ok=backup-desligado
		exit 0
	fi
	pasta="${1:-}"
	if [[ "$pasta" =~ ^[A-Za-z]:[\\/] ]] && command -v wslpath >/dev/null; then
		pasta="$(wslpath -u "$pasta")"
	fi
	[[ "$pasta" == /* && "$pasta" != *[\"$'\n']* && "$pasta" != / ]] || { echo "erro=use: painel.sh backup <pasta> (C:\\... ou /mnt/c/...)"; exit 1; }
	IFS= read -r token || true
	token="${token%$'\r'}"
	token="${token//[[:space:]]/}"
	[[ "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || { echo "erro=token inválido (é o do token-backup.sh da VPS)"; exit 1; }
	mkdir -p "$pasta"
	umask 077
	printf 'BACKUP_TOKEN=%s\nBACKUP_DIR="%s"\n' "$token" "$pasta" >"$ETC/backup.env.tmp"
	chmod 600 "$ETC/backup.env.tmp"
	mv "$ETC/backup.env.tmp" "$ETC/backup.env"
	systemctl enable --now lor-backup.timer >/dev/null 2>&1 || true
	systemctl start --no-block lor-backup.service || true
	echo "ok=backup em $pasta (primeira cópia começando; depois uma vez por dia)"
	;;
*)
	sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
	;;
esac
