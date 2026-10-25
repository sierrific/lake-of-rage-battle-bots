# Skins do painel: material de partida

Tirado dos dois modelos do Thiago (1536×1024, ou seja, uma janela de 1024×683 a 150% de escala).

## Cabeçalhos

- `cabecalho-dragao.jpg` (1526×87): modelo 1, vermelho→dourado com escamas, dragão preto, "Lake of Rage /
  Painel do bot". O canto direito foi refeito repetindo o padrão (período de 74 px), então os botões da janela
  (skin, minimizar, fechar) são desenhados por cima. Glifos escuros (#1C1405).
- `cabecalho-lago.jpg` (1534×77): modelo 2, azul-marinho com escamas, dragão e título dourados, "| Painel do
  bot". Linha dourada embaixo. A direita escurece; glifos claros (#E6EAF2).
- Para embutir no Painel.ps1 (um arquivo só, que o Atualizar já sabe baixar): base64 dos JPGs.
- Desenho sugerido: "cover", ancorado à esquerda, altura ~60 px lógicos.

## Paletas (aproximadas dos modelos)

| Papel | Dragão (preto/dourado/vermelho) | Lago (azul/dourado) |
| --- | --- | --- |
| Fundo da janela | #0F1215 | #021631 |
| Moldura da janela | #8E1016 (vermelho, ~2 px) | #0A1F44 |
| Cartão | #161A1D | #061B38 |
| Borda do cartão | #4A3B1C (dourado apagado) | #12325E |
| Texto | #F1F1EF | #EEF2F8 |
| Texto secundário | #A7ADB2 | #9FB0C8 |
| Legenda do cartão | #A7ADB2 (à direita do título) | #7FA0D0 (abaixo do título) |
| Dourado (botão principal, contornos, link) | #E8BB52 | #DDB65E |
| Texto sobre dourado | #15120A | #10131A |
| Texto de botão com contorno dourado | #F1F1EF | #E8C46E |
| Campo (fundo / borda) | #1B2023 / #545C63 | #081A31 / #24416A |
| Botão secundário (borda) | #4B5157 | #2D4D7C |
| Desativado (fundo / texto) | #2C3136 / #7C838A | #1A2C45 / #6E83A0 |
| Perigo (Parar agora) | #E5484D | #EE5A52 |
| Selo verde (fundo / borda / texto) | #18301F / #2F6B44 / #74D693 | #1E6B42 / #1E6B42 / #EAFBF0 |
| Ponto verde | #56C377 | #4CBA71 |
| Chip de memória (fundo / borda) | #23282C / #383F45 | #13284A / #24406A |
| Atividade (fundo / borda) | #0D1012 / #2A3035 | #071426 / #16305A |
| Aviso (ponto "Não salvo") | #F49E2A | #F2A33A |
| Alternância desligada (trilho / bolinha) | #3A4045 / #D9D9D4 | #22385A / #9AA9C2 |

## Layout (px lógicos, janela 1024×683, cabeçalho 60)

Do modelo 1 (o 2 tem o mesmo, com o cartão de status numa linha só):

- Status (13,69, 1000×132): ponto (22,20, Ø22); "Bot em execução" negrito ~14pt (62,21); selo "Partida em
  andamento" logo à direita (h25); chip "1106 MB" à direita do selo; linha "conta · BO3 · Top 3" (62,50);
  "Ver ao vivo" (22,78, 133×36); "Histórico de partidas" (170,78, 180×36); divisória vertical x=606;
  "Iniciar" (635,22, 133×36, desativado quando rodando); "Parar após a partida" (780,22, 200×36, dourado);
  "Parar agora" (714,68, 187×33, contorno vermelho, ícone de aviso) e "Interrompe a partida atual" embaixo.
- Configuração de partidas (13,211, 595×164): rótulos Formato (20,47) e Time (261,47); listas (20,66, 222×32)
  e (261,66, 204×32); "Aplicar" (480,67, 100×31, contorno dourado); separador y=111; "Adicionar time"
  (20,122, 130×31, contorno dourado); "Remover time" (164,122, 130×31, secundário).
- Coleta (13,385, 595×101): campo "Cole seu código" (20,40, 440×34); "Salvar código" (473,40, 108×34);
  ponto + "Não salvo"/"Salvo" (20,79).
- Conta do Showdown (618,211, 395×276): Usuário (19,47), campo (19,66, 357×35); Senha (19,112), campo com
  olho (19,131, 357×35); cadeado + "A senha fica apenas neste PC." (20,170); "Salvar conta" (254,216, 121×33).
- Atividade (13,497, 1000×133): filtro "Todos" (761,7, 116×25); "Recolher" (887,7, 94×25); caixa do log
  (15,42, 969×79), com frases curtas ("Bot iniciado", "Conta conectada", "Partida em andamento").
- Rodapé: alternância (24,644, 38×18) + "Iniciar com o Windows"; à direita "Versão …" | "Verificar
  atualização" (link dourado).

## Como entram no painel

O `windows/Painel.ps1` traz estes dois JPGs em base64 (variáveis `$CabecalhoDragao` e `$CabecalhoLago`) e os
componentes da janela em C# (`$CodigoUI`), tudo no mesmo arquivo, que é o que o botão Atualizar baixa. Para
trocar um cabeçalho, gere o base64 do JPG novo (`[Convert]::ToBase64String([IO.File]::ReadAllBytes('x.jpg'))`)
e substitua o valor da variável. A escolha de tema de cada PC fica em `%LOCALAPPDATA%\LoRBots\skin.txt`
(`dragao` ou `lago`); o menu é o ícone de paleta no cabeçalho.

## Layouts do painel

As medidas acima documentam os modelos originais. O painel nativo agora permite três layouts,
todos na janela lógica de 1024×694 e usando as mesmas paletas e cabeçalhos:

- `central`: Central de comando, com navegação lateral e seções Batalhas, Times, Histórico e Ajustes.
- `arena`: Arena em foco, com navegação superior, confronto ampliado e atividade horizontal.
- `refinado`: Painel refinado, com configuração, conta e coleta na mesma tela.

O menu de aparência apresenta os três layouts e os dois temas. `layout.txt` salva o layout,
independentemente de `skin.txt`; ausência ou valor inválido usa `central`. Alterar aparência apenas
reorganiza os mesmos controles: preserva os campos e seletores e não chama o backend. No refinado,
o botão Histórico abre os replays diretamente; nos demais, há a seção Histórico com acesso também à
pasta local. A atividade mantém filtros, log completo e recolhimento sem redimensionar a janela.

`tests/test_panel_ui.ps1` compila os componentes reais com PowerShell 5.1 e verifica temas, layouts,
escala e eventos com fronteiras externas simuladas. As capturas usam dados sintéticos e não comprovam
integração física com WSL, Showdown ou entrega no Discord.
