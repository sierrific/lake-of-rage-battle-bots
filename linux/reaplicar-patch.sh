#!/usr/bin/env bash
# Reaplica o patch do time no Ai-vgc depois do checkout -f (que desfaz as mudanças do patch
# anterior nos arquivos do git, mas não apaga os arquivos que ele criou: esses ficam não
# rastreados, e o git apply seguinte falharia com "already exists").
# Apaga só os arquivos criados pelo patch anterior e pelo novo, e só se não forem do git; o
# resto do que não é do git (data/, modelos, simulador compilado) não é tocado.
#
#   reaplicar-patch.sh <checkout do Ai-vgc> <patch anterior (pode não existir)> <patch novo>
set -euo pipefail
dir="$1" anterior="$2" novo="$3"
cd "$dir"
for patch in "$anterior" "$novo"; do
	[ -f "$patch" ] || continue
	git apply --summary "$patch" | awk '$1 == "create" {print $NF}' | while read -r f; do
		case "$f" in /* | ../* | */../*) continue ;; esac
		git ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && continue
		rm -f -- "$f"
	done
done
git apply "$novo"
