#!/usr/bin/env bash
# Baixa a versão mais nova deste repositório (GitHub, branch estavel: a main depois que os testes
# passaram nela) e reinstala por cima.
# Partidas, times salvos e configuração ficam. Se o bot estiver jogando, ele só reinicia
# depois de terminar a partida/série atual.
#
# O que um bot jogando usa (Ai-vgc com o patch, ambiente Python, simulador) só é mexido com os
# bots parados: quando a versão nova muda isso (instalar.sh ou o patch mudaram), os bots terminam
# a partida/série, param, a instalação roda e eles voltam. Nas outras versões (painel, scripts) os
# bots seguem jogando e só reiniciam no fim da partida. Se a instalação falhar no meio, a versão
# anterior é reinstalada e os bots voltam como estavam.
#
#   sudo /opt/lor-bots/atualizar.sh
set -euo pipefail
DIR="${LOR_DIR:-/opt/lor-bots}"  # LOR_DIR e LOR_RUN: só para os testes
# Duas atualizações ao mesmo tempo (dois cliques no botão) se atropelariam: a segunda espera.
exec 8>"${LOR_RUN:-/run}/lor-atualizar.lock"
flock -n 8 || { echo "Já tem uma atualização rodando; esperando ela terminar..."; flock 8; }

REPO=https://github.com/sierrific/lake-of-rage-battle-bots
RAMO="${LOR_RAMO:-estavel}"  # outra branch (main, ou uma de teste) só para testar uma versão
FONTE="$DIR/fonte"

nova="$(curl -fsSL --max-time 20 "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$RAMO/VERSION")"
atual="$(cat "$DIR/VERSION" 2>/dev/null || echo nenhuma)"
if [ "$nova" = "$atual" ] && [ "${1:-}" != --forcar ]; then
	echo "Já está na versão mais nova ($atual)."
	exit 0
fi
echo "==> Atualizando de $atual para $nova"
rm -rf "$FONTE.novo"
mkdir -p "$FONTE.novo"
curl -fsSL --max-time 300 "$REPO/archive/refs/heads/$RAMO.tar.gz" | tar xz -C "$FONTE.novo" --strip-components 1 --no-same-owner

# Mesma conta do instalar.sh: muda quando muda o que um bot jogando usa.
impressao() { cat "$1/linux/instalar.sh" "$1/linux/ai-vgc-lor.patch" | sha256sum | cut -d' ' -f1; }
parar=0
if [ "$(cat "$DIR/.lor-runtime" 2>/dev/null)" != "$(impressao "$FONTE.novo")" ]; then
	parar=1
fi

if [ "$parar" = 1 ]; then
	# Um desafio liga e desliga o bot por conta própria e, no fim, só volta ao ladder se ele estava
	# ligado antes: espera ele acabar, e aí o estado do bot é o que o membro escolheu.
	while systemctl list-units --plain --no-legend --state=active,activating,deactivating 'lor-desafio-*' | grep -q .; do
		echo "==> Esperando o desafio em andamento terminar antes de atualizar..."
		sleep "${LOR_ESPERA:-30}"
	done
fi

# Bots ligados (ou com um "Aplicar" esperando para religar): são os que voltam no fim.
ativos=()
for unit in $(systemctl list-units --plain --no-legend --state=active,activating 'lor-bot@*' | awk '{print $1}'); do
	unit="${unit#lor-bot@}"
	ativos+=("${unit%.service}")
done
for unit in $(systemctl list-units --plain --no-legend 'lor-reinicio-*' | awk '{print $1}'); do
	bot="$(sed -E 's/^lor-reinicio-(.*)-[0-9]+\.service$/\1/' <<<"$unit")"
	[[ " ${ativos[*]} " == *" $bot "* ]] || ativos+=("$bot")
done
# Bots desligando (Desligar no painel: terminam a série, até ~45 min): ainda jogam com o que está
# instalado, então também são esperados, mas continuam desligados no fim.
parando=()
for unit in $(systemctl list-units --plain --no-legend --state=deactivating 'lor-bot@*' | awk '{print $1}'); do
	unit="${unit#lor-bot@}"
	bot="${unit%.service}"
	[[ " ${ativos[*]} " == *" $bot "* ]] || parando+=("$bot")
done

religar() {
	# Depois da troca: reiniciar refaz o .env do bot com o painel novo; parado, ele só liga de novo.
	for bot in "${ativos[@]}"; do
		LOR_BOT="$bot" "$DIR/painel.sh" reiniciar >/dev/null || true
		[ "$parar" = 1 ] && systemctl start "lor-bot@$bot.service" || true
	done
	systemctl try-restart lor-envio || true
}

if [ "$parar" = 1 ] && ((${#ativos[@]} + ${#parando[@]})); then
	echo "==> Esta versão muda o Ai-vgc, as dependências ou o simulador: os bots terminam a partida/série"
	echo "    atual e param antes da instalação (numa série Bo3 longa, até ~40 min); os que estavam"
	echo "    ligados voltam sozinhos."
	for unit in $(systemctl list-units --plain --no-legend 'lor-reinicio-*' | awk '{print $1}'); do
		systemctl stop "$unit" || true
	done
	unidades=()
	for bot in "${ativos[@]}" "${parando[@]}"; do unidades+=("lor-bot@$bot.service"); done
	systemctl stop "${unidades[@]}"
	echo "    bots parados"
fi

# A versão em uso fica guardada até a nova terminar de instalar: é para ela que se volta numa falha.
rm -rf "$FONTE.anterior"
[ -d "$FONTE" ] && mv "$FONTE" "$FONTE.anterior"
mv "$FONTE.novo" "$FONTE"
if ! bash "$FONTE/linux/instalar.sh"; then
	echo
	echo "==> A instalação de $nova parou no meio: voltando para $atual"
	if [ -d "$FONTE.anterior" ]; then
		rm -rf "$FONTE.falhou"
		mv "$FONTE" "$FONTE.falhou"
		mv "$FONTE.anterior" "$FONTE"
		# A volta mexe no que um bot jogando usa se a nova chegou a mexer: com os bots parados.
		[ "$(cat "$DIR/.lor-runtime" 2>/dev/null)" = "$(impressao "$FONTE")" ] || parar=1
		if [ "$parar" = 1 ]; then
			for bot in "${ativos[@]}" "${parando[@]}"; do systemctl stop "lor-bot@$bot.service" || true; done
		fi
		if bash "$FONTE/linux/instalar.sh"; then
			echo "==> Voltou para $atual."
		else
			echo "!! A volta para $atual também falhou: os bots ficam parados. Clique em Atualizar de novo."
			exit 1
		fi
	elif [ ! -s "$DIR/.lor-runtime" ]; then
		# Sem versão anterior guardada (instalação antiga feita direto de um clone) e com o Ai-vgc,
		# as dependências ou o simulador pela metade: ligar os bots só os faria cair em seguida.
		echo "!! Não há versão anterior guardada para voltar: os bots ficam parados. Clique em Atualizar de novo."
		systemctl try-restart lor-envio || true
		exit 1
	fi
	religar
	exit 1
fi
religar
echo "Atualizado para $nova."
