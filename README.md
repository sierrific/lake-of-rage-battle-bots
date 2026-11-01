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

   **C: cheio?** Com menos de 15 GB livres no C:, o instalador põe o Linux dos bots sozinho no
   disco com mais espaço (`D:\LoRBots\wsl`, por exemplo) e muda para lá uma instalação que já
   estava no C:. No C: fica só o próprio WSL do Windows (~1 GB) e o painel (poucos KB). Para
   escolher a pasta, rode pelo PowerShell (como administrador):
   `$env:LOR_PASTA_WSL='D:\LoRBots'; irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/estavel/windows/instalar.ps1 | iex`

   <details><summary>Ou pelo PowerShell</summary>

   ```powershell
   irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/estavel/windows/instalar.ps1 | iex
   ```
   </details>
4. No **Painel LoR Bots** (atalho na Área de Trabalho): salve o usuário do bot e o código da
   coleta e clique em **Ligar**. O Edge ou Chrome abre o site oficial do Showdown em um perfil
   separado. Entre na mesma conta nessa janela, em até 5 minutos; a senha é digitada no site.
   Ao concluir a autorização, a janela fecha e o bot continua.

O bot usa ~1 GB de RAM enquanto joga. Ele roda numa distribuição Linux separada do WSL
(`LoRBots`), sem mexer em outras que você tenha.

### Painel

- **Aparência** (ícone de paleta no cabeçalho): escolha **Central de comando**, **Arena em foco** ou
  **Painel refinado** e combine com o tema **Lago** (azul/dourado) ou **Dragão** (vermelho/dourado).
  O layout e o tema são salvos separadamente neste PC. Trocar a aparência não reinicia o bot nem aplica
  configurações de partidas. A Central de comando é o layout inicial.
- **Central de comando**: navegação lateral por Batalhas, Times, Histórico e Ajustes. A partida atual
  ganha um placar próprio; conta e código da coleta ficam em Ajustes. **Arena em foco** usa navegação
  superior e prioriza o confronto. **Painel refinado** mantém controles, conta e coleta na mesma tela.
- **Atividade**: resumo dos últimos eventos, filtros Todos/Partidas/Avisos e opção de recolher.
  **Log técnico** exibe as linhas completas, inclusive eventos fora do resumo. O recolhimento não muda
  o tamanho da janela. Histórico continua abrindo os replays do Showdown; também há acesso à pasta local.
- **Ligar / Desligar (após a partida) / Desligar agora**. "Desligar" espera terminar a partida ou
  a série Bo3 atual, para o bot não perder por W.O.
- **Conta do Showdown**: salve somente o usuário; o login acontece no navegador ao ligar.
- **Bloquear bots** (em Ajustes, no cartão da conta; ligado por padrão): ligado envia
  `/blockbots`; desligado envia `/allowbots`. A escolha fica salva e é aplicada depois de cada
  login/reconexão e antes da próxima busca no ladder, sem reiniciar ou interromper a partida.
  Vale também para o login legado por senha. O comando configura a preferência de pareamento;
  não remove a classificação de bot da conta.
- **Esperar bots conhecidos** (em Ajustes; ligado por padrão): espera até 10 minutos para bots
  adversários recorrentes saírem da fila antes de buscar partida. Desligado, pula essa espera e
  encerra uma espera em curso, sem reiniciar. A escolha fica salva. A coordenação entre os bots
  do nosso time e a pausa entre partidas continuam funcionando; `/blockbots` é uma opção separada.
- **Esperar bots da colmeia** (em Ajustes; ligado por padrão): espera a vez de buscar no mesmo
  formato dos outros bots do time. Desligado, encerra essa espera e libera a vez reservada,
  permitindo buscas simultâneas. Nossos bots poderão se enfrentar, conforme as regras do Showdown.
  A escolha fica salva, sem reiniciar. Religar vale na próxima busca; a partida atual continua.
  É independente de **Esperar bots conhecidos**, de `/blockbots` e da pausa entre partidas.
- **Decisões Instantâneas** (em Ajustes; **Não** por padrão): com **Não**, completa o tempo de cada
  escolha de Pokémon e de cada turno até um alvo entre 10 e 20 segundos, contando o cálculo da IA.
  Com **Sim**, envia assim que o cálculo termina; vale também para uma espera em curso, sem reiniciar.
  Com pouco tempo no relógio, reduz ou pula a espera adicional, reservando 5 segundos para envio.
  Correções de jogadas recusadas não recebem nova espera. Se o cálculo sozinho passar de 20 segundos,
  envia ao terminar, sem espera extra. A preferência fica salva por bot e vale para cada jogo do Bo3.
- **Chat restrito pelo Showdown**: se o servidor recusar o chat por restrição do provedor,
  o bot suspende `glhf`/`gg wp` nessa conexão e mostra um aviso específico. A opção de chat fica
  salva como você escolheu; o bot não tenta reenviar as mensagens recusadas. Comandos e erros de
  batalha continuam sendo tratados normalmente.
- **Código da coleta**: conferido na coleta ao salvar (o painel diz de quem é o código). Se depois a
  coleta recusar o código ou estiver fora do ar, o aviso aparece ali mesmo.
- **Formato** (Bo3/Bo1) e **Time**: o padrão (MC371 ou MC196, os melhores do bot no ladder) ou um time seu. Em
  "Adicionar time…" cole um link do pokepast.es ou o export do Showdown; o time é validado antes
  de ser salvo. **Aplicar** passa a valer depois da partida atual.
- **Desafiar jogador**: o usuário do Showdown e quantas partidas (1 a 10). O bot termina a partida
  (ou série) atual do ladder, desafia no formato e com o time escolhidos, e volta ao ladder no
  fim. Se ninguém aceitar em 5 minutos, o desafio é cancelado. O mesmo botão vira **Cancelar desafio**.
- **Atualizar**: quando sai versão nova aqui no GitHub, o botão fica amarelo. Um clique baixa a
  versão nova do bot e do painel. O bot que estava jogando termina a partida/série antes de reiniciar;
  quando a versão muda o próprio Ai-vgc ou o simulador, ele para antes da instalação e volta no fim.
  Se algo falhar no meio, a versão anterior é reinstalada e o bot volta como estava.
- **Postar no Discord** (em Ajustes, no cartão da coleta): desligado, as séries deste PC não aparecem
  no canal do Discord, mas as partidas continuam indo para a coleta e o treino. Vale já para a
  próxima partida, sem reiniciar o bot.
- **glhf / gg wp no chat** (em Ajustes, no cartão da conta; ligado por padrão): o bot diz "glhf" no
  chat da batalha no começo da partida (no Bo3, só no jogo 1) e "gg wp" no fim de cada jogo. Vale já
  para a próxima partida, sem reiniciar o bot.
- **Ligar o bot junto com o Windows**.
- Enquanto o bot está ligado, o PC **não entra em suspensão** sozinho (com o PC dormindo, o timer da
  partida corre e o bot perde). A tela ainda apaga normalmente. Num notebook, fechar a tampa segue a
  configuração do Windows: deixe "Ao fechar a tampa: não fazer nada" se quiser jogar de tampa fechada.
- **Ver ao vivo** (abre no navegador a partida em andamento) e **Abrir partidas** (replays e `games.jsonl`).
- **Histórico** mostra o placar de hoje: vitórias e derrotas, e por time.
- **Ícone na bandeja** (perto do relógio): o estado e o placar do dia ao passar o mouse, um aviso
  quando o bot para com erro, e **Copiar diagnóstico**, que junta versão, estado e logs (sem senha
  nem código) para colar no Discord quando precisar de ajuda.

### Login pelo navegador

Requer Microsoft Edge ou Google Chrome instalado no Windows. Cada conta usa um perfil em
`%LOCALAPPDATA%\LoRBots\login\<id-da-conta>`, separado do seu navegador pessoal. A sessão fica
nesse perfil: nas próximas conexões, o navegador pode autorizar sem pedir a senha novamente.
Se entrar em outra conta, o bot aguarda a conta configurada; não assume a conta que estiver aberta.

A janela abre a cada conexão, inclusive ao reconectar. O bot recebe uma autorização assinada
para a sua conexão, sem receber a senha nem copiar cookies para o Linux. Essa autorização expira
e é apagada depois de consumida. Se o login falhar ou passar de 5 minutos, o bot para; abra o painel
e clique em **Ligar** para tentar novamente. Não há retorno automático ao login por senha.
Erros de formato, conta/conexão e validade aparecem na atividade sem expor a autorização.
A validação aceita os campos adicionais assinados do protocolo do Showdown e os preserva.

Contas já configuradas pelo painel passam a esse fluxo ao ligar/reiniciar com esta versão.
Arquivos de senha antigos não são lidos no modo navegador. Uma configuração manual que tenha
`login=senha` continua no modo legado; **Salvar conta** no painel muda para navegador.

**Isso não garante evitar a marca de bot do Showdown e não remove uma marca existente.** A
classificação vem na resposta assinada pelo servidor e é preservada. O novo fluxo muda como a
conta é autenticada; não mascara a automação nem modifica a classificação da conta. Os testes
automatizados usam respostas sintéticas, sem autenticar contas reais.

## Cópia de segurança da coleta (só no PC de quem guarda a cópia)

Uma vez por dia o PC baixa da coleta (VPS) as partidas de todos os membros que ainda não tem, para
uma pasta do Windows. Precisa do token de backup, que sai de
`sudo /opt/lor-sd-server/coleta/token-backup.sh` na VPS. No PowerShell (troque `TOKEN` e a pasta):

```powershell
"TOKEN" | wsl -d LoRBots -u root -e /opt/lor-bots/painel.sh backup 'C:\Users\Thiago\LoR-backup-coleta'
```

A primeira cópia começa na hora. O WSL só fica ligado junto com o bot, então uma cópia perdida roda
quando o bot ligar de novo. `ultimo-backup.txt`, na pasta, diz quando foi a última.
Para parar: `wsl -d LoRBots -u root -e /opt/lor-bots/painel.sh backup desligar`.

## Num servidor Linux (Oracle etc.)

```bash
git clone https://github.com/sierrific/lake-of-rage-battle-bots && cd lake-of-rage-battle-bots
sudo linux/instalar.sh
```

Um arquivo por bot em `/etc/lor-bots/<nome>.env` (veja `linux/exemplo.env`: ladder, aceitar
desafios, desafiar outro bot) e `sudo systemctl enable --now lor-bot@<nome>`. Envio para a
coleta: `COLETA_CODIGO=...` em `/etc/lor-bots/coleta.env` e `sudo systemctl enable --now lor-envio`.
Atualizar: `sudo /opt/lor-bots/atualizar.sh`.

O exemplo Linux mantém `LOGIN=senha` para instalações sem interface gráfica. O fluxo pelo
navegador desta versão integra o painel Windows e a distribuição `LoRBots`; não é um login
por navegador remoto para servidores Linux.

## Para quem mantém

- Login: `linux/login-navegador.py` troca pedidos e respostas temporários em `/run/lor-login-<bot>`
  (systemd, modo 0700). `windows/Login-Navegador.ps1` acompanha o bot, abre o perfil dedicado e
  solicita `getassertion` no cliente oficial, com a sessão do próprio navegador. O CDP usa uma
  porta aleatória em loopback, disponível apenas enquanto essa janela está aberta. A conta, o
  desafio e o prazo são conferidos antes de entregar a resposta intacta ao Ai-vgc.
- Teste do auxiliar Windows: `powershell.exe -NoProfile -File tests/test_login_navegador.ps1`
  (Node.js necessário apenas para o servidor sintético do teste). Exercita o transporte CDP,
  origem, serialização, cliente atual/antigo e falhas, sem navegador ou contas reais.
- Testes Linux: `python3 -m unittest discover -s tests -v` (zsh e numpy). Depois de aplicar o
  patch no Ai-vgc, rode também `tests/ai_vgc/login_navegador.py` com o caminho do `player.py`.
- Teste nativo do painel no Windows: `powershell.exe -NoProfile -STA -File tests/test_panel_ui.ps1`.
  Compila o C# embutido com PowerShell 5.1, exercita os controles com comandos simulados e verifica os
  três layouts e dois temas nas escalas 100%, 125% e 150%. Não inicia WSL/bot, não usa credenciais reais
  nem altera atalhos. As capturas são sintéticas; não substituem um teste da integração com o bot real.
- **Lançar uma versão**: faça as mudanças na `main` e aumente o número em `VERSION`. Quando todos
  os testes do GitHub passam nesse commit, o CI avança a branch `estavel`, que é de onde o painel e o
  instalador baixam; um merge com teste vermelho não chega aos PCs. O painel compara o `VERSION` da
  `estavel` com o instalado para oferecer a atualização. Para testar antes, use outra branch:
  `$env:LOR_RAMO='minha-branch'` antes do comando de instalar (ou `LOR_RAMO=... sudo -E
  /opt/lor-bots/atualizar.sh`).
- **Ai-vgc**: o instalador baixa o commit fixo da cópia do time (`sierrific/ai-vgc`, um fork) e,
  se ela não existir, do repositório original. Não use "Sync fork" se o original reescrever o
  histórico: o commit fixo precisa continuar existindo na cópia.
- `linux/ai-vgc-lor.patch`: o que mudamos no Ai-vgc (commit fixo em `linux/instalar.sh`).
  Acrescenta `--server-url`/`--client-url` para jogar no servidor do time, `/savereplay` em cada
  partida do oficial (link do replay no `games.jsonl`), os nomes dos Pokémon e uma nova busca no
  ladder quando 10 min passam sem partida (o Showdown às vezes descarta a busca sem avisar), e uma
  pausa aleatória de 1 a 5 min entre partidas do ladder (outros bots voltam à fila na hora; sem a
  pausa o nosso cai quase sempre com eles).
- `linux/enviar-partidas.py` manda as linhas novas de `data/live_games/*/games.jsonl` para a
  coleta (`https://showdown.sierverso.com.br/coleta/`, código por membro). A coleta e o poster do
  Discord rodam na VPS e estão no repositório do servidor (LOR-SD-Server, pasta `coleta/`).
- Parar com calma: o serviço `lor-bot@` manda SIGINT ao `rodar-bot.sh`, que repassa ao Python do
  bot. É o mesmo que um Ctrl-C no `bot.sh`: termina a partida ou série atual e sai.
- Senhas, códigos e webhooks nunca entram no repositório.
