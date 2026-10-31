# Testes de força do bot

Cada mudança de busca, modelo ou time entra aqui com data, como foi medida e o resultado, para
que a próxima mudança seja comparada com a base certa. Mais novo primeiro.

Base atual (painel desde 2026.10.25.3): `--use MC371 MC196 --model data/models/mc-bo3-rnad-v5.pt
--change-after-loss --counter-t1 0.5 --search-prior 0.03`, Ai-vgc no commit `0bd586d`.

## Testes locais (bot contra o pool, no PC)

| Data | O que mudou | Como | Resultado |
| --- | --- | --- | --- |
| 2026-10-31 | `--opp-model` lor-opp-v4-tudo (v2 ajustado com 2.337 jogos da coleta, sem jogos entre bots nossos) | Acerto da jogada do oponente nas 396 partidas mais novas (fora do treino); 1.200 jogos Bo1 contra `all-bo3-bc-v2` | 1º palpite 64,6% vs 59,9% do v1 e 54,4% do v2; dupla entre as 6 da busca 70,5% vs 65,8% / 63,0%. Local 83,8% [81,6–85,7] vs 83,5% (v1: 82,0%) → v4 no painel |
| 2026-10-27 | `--opp-model` lor-opp-v1-tudo (v2 ajustado com 1.244 jogos da coleta, `linux/treino-oponente.py`) | Acerto da jogada do oponente nas 225 partidas mais novas (fora do treino); 1.200 jogos Bo1 contra `all-bo3-bc-v2` | 1º palpite 59,0% vs 55,5% do v2; dupla entre as 6 da busca 65,9% vs 63,1% (só a cabeça: 58,6% / 65,5%). Local 82,0% vs 83,5% (p≈0,33, sem diferença; o bc-v2 não joga como a ladder) → teste na ladder |
| 2026-10-25 | `--search-prior` 0.03 vs 0.1 (confirmação) | 1.200 jogos Bo1 cada, contra `all-bo3-bc-v2` | 0.03: 83,5% · 0.1: 80,9% → 0.03 virou padrão (PR #27) |
| 2026-10-25 | prior 0.1/0.03 × `--search-opp-k` 6/12 | 400 jogos Bo1 cada, contra `all-bo3-bc-v2` | 0.1/k6 79,2% · 0.03/k6 83,2% · 0.1/k12 76,8% · 0.03/k12 79,8% (k12 ~70% mais lento) |
| 2026-10-25 | Times (team test, `mc-bo3-rnad-v5` contra o pool `reg_mc`) | 1.528 jogos cada | MC196 77,2% [75,0–79,2] · MC371 75,6% [73,4–77,7] · MC301 71,4% · LOR-SolUgarte 70,1% · LOR-NiceEstudo 54,2% · LOR-NiceMeta 53,9% [51,4–56,4] |
| 2026-10-25 | `--search-depth 2` | Cenários fixos tirados de replays | Quase não muda as escolhas e custa 5–10× o tempo (13–37 s/turno): não usar |

## Ladder oficial (MadMageofMtBaratok, Bo3 Reg M-C)

| Data | Configuração | Resultado |
| --- | --- | --- |
| 2026-10-26 | + prior 0.03 (desde 25/10 20:12) | Elo 1337 no painel; 38–29 jogos (57%), 16–12 séries |
| 2026-10-25 | `--use MC371 MC196` + `--change-after-loss --counter-t1 0.5` (PR #16) | Elo 1230, GXE 53,4%, Glicko 1526±35 |
| 2026-10-24 | `--top 3` (MC196 MC147 MC371), sem adaptação | Elo 1138 (pico 1152), GXE 47%; 35–31; jogo 1 68%, jogo 2 40%; contra 1300+: 3–13 |

O resumo da semana no Discord (LOR-SD-Server, `coleta/relatorio-semanal.py`) traz os números do
ladder por bot, por time e por jogo da série; copie para cá quando fechar um experimento.
