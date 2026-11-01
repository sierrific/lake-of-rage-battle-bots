#!/usr/bin/env bash
# Instala ou atualiza os bots da Lake of Rage num Ubuntu 24.04: no WSL do PC de cada membro
# (o instalador de Windows chama este script) ou num servidor (a instância grátis da Oracle).
# Rodar de novo atualiza: é o que o botão "Atualizar" do painel faz, via atualizar.sh.
#
#   sudo linux/instalar.sh
#
# Fica tudo em /opt/lor-bots; a configuração de cada bot em /etc/lor-bots/<nome>.env (o painel
# cuida do bot "bot"; num servidor, copie linux/exemplo.env).
set -euo pipefail

DIR=/opt/lor-bots
SRC="$(cd "$(dirname "$0")/.." && pwd)"
# Versões fixas: o patch é feito para este commit do Ai-vgc, e o simulador é o mesmo Showdown
# do servidor do time.
# A cópia do time (fork) primeiro: se o repositório original sumir ou reescrever o histórico, as
# instalações novas continuam funcionando. Sem o fork (ou sem o commit nele), usa o original.
AIVGC_REPO=https://github.com/sierrific/ai-vgc
AIVGC_ORIGINAL=https://github.com/Nisanth-Nimashakavi/ai-vgc
AIVGC_COMMIT=0bd586d4b2c2cbca9e06d52dada06c46649a32a5
PS_COMMIT=c0845f33d381402dfcb18ce324c20a94f18af075

if [ "$(id -u)" -ne 0 ]; then
	echo "Rode como root: sudo $0" >&2
	exit 1
fi

echo "==> Pacotes do sistema"
export DEBIAN_FRONTEND=noninteractive
PACOTES=(git curl ca-certificates zsh build-essential python3)
# Numa atualização eles já estão: pular o apt deixa mais rápido e com um ponto de falha a menos.
instalados="$(dpkg-query -W -f='${Status}\n' "${PACOTES[@]}" 2>/dev/null | grep -c '^install ok installed$' || true)"
if [ "$instalados" -eq "${#PACOTES[@]}" ]; then
	echo "    já instalados"
else
	apt-get update -q
	apt-get install -y -q "${PACOTES[@]}"
fi

if ! command -v node >/dev/null || ! node -e 'const [a,b]=process.versions.node.split(".").map(Number); process.exit(a>22||(a===22&&b>=18)?0:1)'; then
	echo "==> Node.js 22 (NodeSource)"
	curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
	apt-get install -y -q nodejs
fi

echo "==> Usuário bots"
id bots >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash bots
# /opt/lor-bots é do root: os scripts dela (painel.sh, atualizar.sh, fonte/) rodam como root, e
# quem pode escrever na pasta pode trocar um arquivo dela, mesmo de outro dono. O usuário bots só
# escreve dentro de ai-vgc/ (partidas, times, ambiente Python, simulador).
mkdir -p "$DIR" /etc/lor-bots
chown root:root "$DIR"
chmod 755 "$DIR"
install -d -o bots -g bots "$DIR/ai-vgc"
# Instalações antigas deixavam a pasta com o bots: um link posto por ele no lugar de um arquivo
# sai, e o resto volta para o root.
find "$DIR" -mindepth 1 -maxdepth 1 -type l -delete
find "$DIR" -mindepth 1 -maxdepth 1 ! -name ai-vgc -exec chown -hR root:root {} +
chown root:bots /etc/lor-bots
chmod 750 /etc/lor-bots

as_bots() { sudo -u bots -H bash -lc "$1"; }

echo "==> uv (Python)"
as_bots 'command -v uv >/dev/null || curl -LsSf https://astral.sh/uv/install.sh | sh'
UV=/home/bots/.local/bin/uv

# O que um bot jogando carrega (Ai-vgc com o patch, ambiente Python, simulador) só é refeito quando
# muda este script ou o patch: numa atualização só de painel/scripts, um bot no meio da partida não
# tem arquivo trocado por baixo. O atualizar.sh faz a mesma conta para parar os bots antes quando
# precisa. A marca só é gravada no fim, então uma instalação interrompida refaz tudo na próxima.
RUNTIME="$DIR/.lor-runtime"
IMPRESSAO="$(cat "$SRC/linux/instalar.sh" "$SRC/linux/ai-vgc-lor.patch" | sha256sum | cut -d' ' -f1)"
if [ "$(cat "$RUNTIME" 2>/dev/null)" = "$IMPRESSAO" ] && [ -x "$DIR/ai-vgc/.venv/bin/python" ]; then
	echo "==> Ai-vgc, dependências e simulador: já nesta versão"
else
	rm -f "$RUNTIME"
	echo "==> Ai-vgc ($AIVGC_COMMIT) com o patch do time"
	if [ ! -d "$DIR/ai-vgc/.git" ]; then
		as_bots "git init -q $DIR/ai-vgc && git -C $DIR/ai-vgc remote add origin $AIVGC_REPO"
	fi
	as_bots "git -C $DIR/ai-vgc remote set-url origin $AIVGC_REPO"
	# checkout -f desfaz o patch anterior; data/ (partidas, times do painel) não é do git e fica.
	# O download (~300 MB, com os modelos) só acontece quando muda o commit.
	if [ "$(sudo -u bots git -C "$DIR/ai-vgc" rev-parse HEAD 2>/dev/null)" = "$AIVGC_COMMIT" ]; then
		as_bots "git -C $DIR/ai-vgc checkout -q -f HEAD"
	else
		echo "    baixando o Ai-vgc com os modelos (~300 MB, pode levar alguns minutos sem mostrar nada)"
		as_bots "git -C $DIR/ai-vgc fetch -q --depth 1 origin $AIVGC_COMMIT || git -C $DIR/ai-vgc fetch -q --depth 1 $AIVGC_ORIGINAL $AIVGC_COMMIT"
		as_bots "git -C $DIR/ai-vgc checkout -q -f FETCH_HEAD"
	fi
	# O patch instalado só é trocado depois que o novo aplicou: o reaplicar-patch.sh usa os dois
	# para apagar os arquivos que eles criam (sem isso, a segunda aplicação falharia).
	install -m 644 "$SRC/linux/ai-vgc-lor.patch" "$DIR/ai-vgc-lor.novo.patch"
	install -m 755 "$SRC/linux/reaplicar-patch.sh" "$DIR/reaplicar-patch.sh"
	as_bots "$DIR/reaplicar-patch.sh $DIR/ai-vgc $DIR/ai-vgc-lor.patch $DIR/ai-vgc-lor.novo.patch"
	mv -f "$DIR/ai-vgc-lor.novo.patch" "$DIR/ai-vgc-lor.patch"

	echo "==> Dependências Python (PyTorch etc.; a primeira vez demora)"
	# Os modelos (mc-bo3-rnad-v5 e companhia) já vêm no repositório do Ai-vgc, em data/models.
	# Em PC (x86) o PyTorch padrão traz CUDA (~5 GB); o bot só usa CPU, então instala a versão
	# CPU (~1 GB). O rodar-bot.sh usa UV_NO_SYNC=1 para o uv não trocar de volta. A versão do torch é
	# a mesma do uv.lock do Ai-vgc (sem ela, cada instalação nova pegaria o torch mais novo).
	dependencias() {
		if [ "$(uname -m)" = x86_64 ]; then
			as_bots "cd $DIR/ai-vgc && $UV venv -q --allow-existing && $UV export -q --extra nn --no-hashes --no-emit-project --frozen > /tmp/lor-req-todos.txt \
				&& grep -vE '^(torch|triton|nvidia-|cuda-)' /tmp/lor-req-todos.txt > /tmp/lor-req.txt \
				&& torch=\$(grep -oE '^torch==[^ ;]+' /tmp/lor-req-todos.txt | head -1) \
				&& $UV pip install -q -r /tmp/lor-req.txt \
				&& $UV pip install -q \"\${torch:-torch}\" --index-url https://download.pytorch.org/whl/cpu \
				&& $UV pip install -q --no-deps -e ."
		else
			as_bots "cd $DIR/ai-vgc && $UV sync -q --extra nn"
		fi
	}
	# Uma instalação que parou no meio (disco cheio, PC desligado) pode deixar o .venv com arquivo
	# vazio ("Failed to read metadata ... EOF"), e aí o uv falha sempre. Na falha, apaga o .venv e o
	# cache do uv (que pode ter ficado pela metade também) e instala do zero uma vez.
	if ! dependencias; then
		echo "    o ambiente Python estava quebrado: apagando e instalando do zero (baixa tudo de novo)"
		rm -rf "$DIR/ai-vgc/.venv"
		as_bots "$UV cache clean -q" || true
		dependencias
	fi

	echo "==> Simulador do Showdown ($PS_COMMIT; a busca de jogadas roda nele)"
	PS="$DIR/ai-vgc/pokemon-showdown-mc"
	if [ ! -d "$PS/.git" ]; then
		as_bots "git init -q $PS && git -C $PS remote add origin https://github.com/smogon/pokemon-showdown"
	fi
	# Só recompila quando muda a versão: o marcador é gravado no fim de uma compilação completa, então
	# uma atualização interrompida no meio (janela fechada) compila de novo na próxima.
	MARCA="$PS/.lor-compilado"
	if [ "$(cat "$MARCA" 2>/dev/null)" != "$PS_COMMIT" ]; then
		echo "    baixando e compilando o simulador (leva alguns minutos, sem mostrar nada)"
		rm -f "$MARCA"
		# Um download que parou no meio (disco cheio) pode deixar o .git do simulador estragado, e o
		# GitHub passa a recusar o fetch ("not our ref"). Na falha, apaga a pasta e baixa do zero uma vez.
		if ! as_bots "git -C $PS fetch -q --depth 1 origin $PS_COMMIT && git -C $PS checkout -q -f FETCH_HEAD"; then
			echo "    a cópia do simulador estava quebrada: apagando e baixando do zero"
			rm -rf "$PS"
			as_bots "git init -q $PS && git -C $PS remote add origin https://github.com/smogon/pokemon-showdown"
			as_bots "git -C $PS fetch -q --depth 1 origin $PS_COMMIT && git -C $PS checkout -q -f FETCH_HEAD"
		fi
		as_bots "cd $PS && npm ci --no-audit --no-fund --loglevel=error && cp -n config/config-example.js config/config.js && node build"
		as_bots "echo $PS_COMMIT > $MARCA"
	fi
	# Partes do Ai-vgc procuram a pasta pokemon-showdown/ mesmo quando usam a de Reg M-C.
	as_bots "ln -sfn pokemon-showdown-mc $DIR/ai-vgc/pokemon-showdown"

	echo "==> Limpando caches de download (~1,5 GB)"
	as_bots "$UV cache clean -q; npm cache clean --force --loglevel=error" || true
	echo "$IMPRESSAO" >"$RUNTIME"
fi

echo "==> Scripts e serviços"
install -m 755 "$SRC/linux/rodar-bot.sh" "$DIR/rodar-bot.sh"
install -m 644 "$SRC/linux/login-navegador.py" "$DIR/login-navegador.py"
install -m 644 "$SRC/windows/Login-Navegador.ps1" "$DIR/Login-Navegador.ps1"
install -m 755 "$SRC/linux/painel.sh" "$DIR/painel.sh"
install -m 755 "$SRC/linux/atualizar.sh" "$DIR/atualizar.sh"
install -m 755 "$SRC/linux/enviar-partidas.py" "$DIR/enviar-partidas.py"
install -m 755 "$SRC/linux/backup-coleta.py" "$DIR/backup-coleta.py"
install -m 644 "$SRC/VERSION" "$DIR/VERSION"
install -m 644 "$SRC/linux/lor-bot@.service" /etc/systemd/system/lor-bot@.service
install -m 644 "$SRC/linux/lor-envio.service" /etc/systemd/system/lor-envio.service
install -m 644 "$SRC/linux/lor-backup.service" /etc/systemd/system/lor-backup.service
install -m 644 "$SRC/linux/lor-backup.timer" /etc/systemd/system/lor-backup.timer
[ -f /etc/lor-bots/exemplo.env ] || install -m 640 -g bots "$SRC/linux/exemplo.env" /etc/lor-bots/exemplo.env
if [ -d /run/systemd/system ]; then
	systemctl daemon-reload
fi

# Instalado direto de um clone (sudo linux/instalar.sh, num servidor): guarda esta versão em
# fonte/, que é para onde o atualizar.sh volta se a primeira atualização falhar no meio.
if [ "$(readlink -f "$SRC")" != "$(readlink -f "$DIR/fonte")" ]; then
	rm -rf "$DIR/fonte.tmp"
	mkdir "$DIR/fonte.tmp"
	tar -C "$SRC" --exclude=.git -cf - . | tar -C "$DIR/fonte.tmp" -xf - --no-same-owner
	rm -rf "$DIR/fonte"
	mv "$DIR/fonte.tmp" "$DIR/fonte"
fi

apt-get clean

echo
echo "Pronto: versão $(cat "$DIR/VERSION")."
