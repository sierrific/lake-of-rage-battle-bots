# lake-of-rage-battle-bots

Bots de batalha da Lake of Rage: IA de VGC ([Ai-vgc](https://github.com/Nisanth-Nimashakavi/ai-vgc))
que joga no Showdown. Cada membro do time pode rodar um bot no próprio PC. As partidas de todos
vão para a coleta do time, que alimenta o treino e o canal do Discord.

## Instalar (Windows 10/11)

1. Crie uma conta para o bot no [Showdown](https://play.pokemonshowdown.com) e registre-a
   (engrenagem → Register). Use uma conta só do bot, não a sua.
2. Peça ao Thiago o seu **código da coleta**.
3. Baixe o **[Instalar LoR Bots.bat](https://github.com/sierrific/lake-of-rage-battle-bots/releases/latest/download/Instalar-LoR-Bots.bat)**
   e dê dois cliques nele. O Windows vai perguntar se pode rodar como administrador: aceite.
   Se aparecer "O Windows protegeu o computador", clique em *Mais informações* → *Executar assim mesmo*
   (o arquivo não tem assinatura digital, mas é só um atalho para o instalador deste repositório).

   Na primeira vez ele pode pedir para reiniciar o PC (para ligar o WSL); depois de reiniciar ele
   continua sozinho. A instalação leva uns 10–20 min e ocupa ~3 GB.

   <details><summary>Ou pelo PowerShell</summary>

   ```powershell
   irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/main/windows/instalar.ps1 | iex
   ```
   </details>
4. No **Painel LoR Bots** (atalho na Área de Trabalho): preencha a conta e a senha do bot e o
   código da coleta e clique em **Ligar**.

O bot usa ~1 GB de RAM enquanto joga. Ele roda numa distribuição Linux separada do WSL
(`LoRBots`), sem mexer em outras que você tenha.

### Painel

- **Ligar / Desligar (após a partida) / Desligar agora**. "Desligar" espera terminar a partida ou
  a série Bo3 atual, para o bot não perder por W.O.
- **Conta do Showdown**: usuário e senha do bot. A senha fica só no seu PC.
- **Formato** (Bo3/Bo1) e **Time**: o padrão (MC371 ou MC196, os melhores do bot no ladder) ou um time seu. Em
  "Adicionar time…" cole um link do pokepast.es ou o export do Showdown; o time é validado antes
  de ser salvo. **Aplicar** passa a valer depois da partida atual.
- **Desafiar jogador**: o usuário do Showdown e quantas partidas (1 a 10). O bot termina a partida
  (ou série) atual do ladder, desafia no formato e com o time escolhidos, e volta ao ladder no
  fim. Se ninguém aceitar em 5 minutos, o desafio é cancelado. O mesmo botão vira **Cancelar desafio**.
- **Atualizar**: quando sai versão nova aqui no GitHub, o botão fica amarelo. Um clique baixa a
  versão nova do bot e do painel.
- **Ligar o bot junto com o Windows**.
- **Ver ao vivo** (abre no navegador a partida em andamento) e **Abrir partidas** (replays e `games.jsonl`).

## Num servidor Linux (Oracle etc.)

```bash
git clone https://github.com/sierrific/lake-of-rage-battle-bots && cd lake-of-rage-battle-bots
sudo linux/instalar.sh
```

Um arquivo por bot em `/etc/lor-bots/<nome>.env` (veja `linux/exemplo.env`: ladder, aceitar
desafios, desafiar outro bot) e `sudo systemctl enable --now lor-bot@<nome>`. Envio para a
coleta: `COLETA_CODIGO=...` em `/etc/lor-bots/coleta.env` e `sudo systemctl enable --now lor-envio`.
Atualizar: `sudo /opt/lor-bots/atualizar.sh`.

## Para quem mantém

- **Lançar uma versão**: faça as mudanças na `main` e aumente o número em `VERSION`. O painel
  compara esse arquivo com o instalado para oferecer a atualização. Para testar antes, use outra
  branch: `$env:LOR_RAMO='minha-branch'` antes do comando de instalar (ou `LOR_RAMO=... sudo -E
  /opt/lor-bots/atualizar.sh`).
- `linux/ai-vgc-lor.patch`: o que mudamos no Ai-vgc (commit fixo em `linux/instalar.sh`).
  Acrescenta `--server-url`/`--client-url` para jogar no servidor do time, `/savereplay` em cada
  partida do oficial (link do replay no `games.jsonl`), os nomes dos Pokémon e uma nova busca no
  ladder quando 10 min passam sem partida (o Showdown às vezes descarta a busca sem avisar).
- `linux/enviar-partidas.py` manda as linhas novas de `data/live_games/*/games.jsonl` para a
  coleta (`https://showdown.sierverso.com.br/coleta/`, código por membro). A coleta e o poster do
  Discord rodam na VPS e estão no repositório do servidor (LOR-SD-Server, pasta `coleta/`).
- Parar com calma: o serviço `lor-bot@` manda SIGINT ao `rodar-bot.sh`, que repassa ao Python do
  bot. É o mesmo que um Ctrl-C no `bot.sh`: termina a partida ou série atual e sai.
- Senhas, códigos e webhooks nunca entram no repositório.
