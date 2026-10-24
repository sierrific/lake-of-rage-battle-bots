#!/usr/bin/env bash
# Baixa a versão mais nova deste repositório (GitHub, branch main) e reinstala por cima.
# Partidas, times salvos e configuração ficam. Se o bot estiver jogando, ele só reinicia
# depois de terminar a partida/série atual.
#
#   sudo /opt/lor-bots/atualizar.sh
set -euo pipefail
# Duas atualizações ao mesmo tempo (dois cliques no botão) se atropelariam: a segunda espera.
exec 8>/run/lor-atualizar.lock
flock -n 8 || { echo "Já tem uma atualização rodando; esperando ela terminar..."; flock 8; }

REPO=https://github.com/sierrific/lake-of-rage-battle-bots
RAMO="${LOR_RAMO:-main}"  # outra branch só para testar uma versão antes de ir para a main
FONTE=/opt/lor-bots/fonte

nova="$(curl -fsSL --max-time 20 "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$RAMO/VERSION")"
atual="$(cat /opt/lor-bots/VERSION 2>/dev/null || echo nenhuma)"
if [ "$nova" = "$atual" ] && [ "${1:-}" != --forcar ]; then
	echo "Já está na versão mais nova ($atual)."
	exit 0
fi
echo "==> Atualizando de $atual para $nova"
rm -rf "$FONTE.novo"
mkdir -p "$FONTE.novo"
curl -fsSL --max-time 300 "$REPO/archive/refs/heads/$RAMO.tar.gz" | tar xz -C "$FONTE.novo" --strip-components 1
rm -rf "$FONTE"
mv "$FONTE.novo" "$FONTE"
bash "$FONTE/linux/instalar.sh"
for unit in $(systemctl list-units --plain --no-legend --state=active 'lor-bot@*' | awk '{print $1}'); do
	bot="${unit#lor-bot@}"
	LOR_BOT="${bot%.service}" /opt/lor-bots/painel.sh reiniciar >/dev/null || true
done
systemctl try-restart lor-envio || true
echo "Atualizado para $nova."
