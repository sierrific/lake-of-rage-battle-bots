# Testes nativos sem WSL, rede, credenciais reais, atalhos ou instância do bot.
param([string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) ('lor-panel-ui-' + [Guid]::NewGuid().ToString('N'))))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$sourcePath = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$bytes = [IO.File]::ReadAllBytes($sourcePath)
if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) { throw 'Painel.ps1 precisa de UTF-8 com BOM.' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)

# Somente constantes e construção da UI são carregadas. O bootstrap operacional
# (mutex, atalhos, DPI global, -Ligar, timer e ShowDialog) nunca é executado.
foreach ($name in @('CodigoUI', 'CabecalhoDragao', 'CabecalhoLago')) {
    $assignment = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $name) }, $false) | Select-Object -First 1
    $literal = $assignment.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $false)
    if (-not $literal) { throw "Constante literal ausente: $name" }
    Set-Variable -Name $name -Value $literal.Value
}
Add-Type -TypeDefinition $CodigoUI -ReferencedAssemblies System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
foreach ($name in @('S', 'Cor', 'Imagem', 'Novo-Tema', 'Ler-Estado')) {
    $definition = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false) | Select-Object -First 1
    . ([ScriptBlock]::Create($definition.Extent.Text))
}
$uiStart = $source.IndexOf('# Paletas tiradas dos modelos')
$stateStart = $source.IndexOf('# Estado', $uiStart)
$timerStart = $source.IndexOf('$timer = New-Object System.Windows.Forms.Timer', $stateStart)
$ui = $source.Substring($uiStart, $timerStart - $uiStart)
$script:assertions = 0
function Assert($condition, [string]$message) {
    $script:assertions++
    if (-not $condition) { throw "Falhou: $message" }
}
function Fresh-State {
    $script:historicoFalso = $null
    $script:logFalso = "Started lor-bot@bot`nteam: SolUgarte`nwin vs AdversarioTeste in 7 turns`nwatch: https://play.pokemonshowdown.com/battle-teste`nWARNING exemplo de aviso"
    $script:fake = @{
        hoje_vitorias = '3'; hoje_derrotas = '1'; hoje_times = 'MC371 2-1, MC196 1-0'
        bot = 'active'; conta = 'LoRBotTeste'; senha = 'sim'; codigo = 'sim'; envio = 'active'
        formato = 'bo3'; timer = 'sim'; discord = 'sim'; chat = 'sim'; bloquear_bots = 'sim'; esperar_bots = 'sim'; esperar_colmeia = 'sim'; decisoes_instantaneas = 'nao'; time = 'SolUgarte'; versao = '2026.10.24.19'; memoria_mb = '531'
        partida = 'https://play.pokemonshowdown.com/battle-teste'; desafio = ''; desafio_fase = ''
        placar_oponente = 'AdversarioTeste'; placar_bo3 = 'sim'; placar_jogo = '2'; placar_vitorias = '1'; placar_derrotas = '0'
        placar_turno = '4'; placar_nossos = '3'; placar_deles = '1'; placar_resultado = ''
    }
    $script:commands = New-Object System.Collections.Generic.List[object]
    $script:messages = New-Object System.Collections.Generic.List[string]
    $script:launches = New-Object System.Collections.Generic.List[string]
    $script:failure = ''
    $script:approve = $false
    $script:keepalive = 0
    $script:startupChanges = 0
}
function Install-Fakes {
    function script:Invoke-Painel {
        param([string[]]$Argumentos, [string]$Entrada = '')
        $script:commands.Add([pscustomobject]@{ Args = ($Argumentos -join '|'); Input = $Entrada })
        $cmd = $Argumentos[0]
        if ($script:failure -eq $cmd) { return [pscustomobject]@{ Codigo = 1; Saida = 'erro=falha sintetica'; Erro = '' } }
        $out = 'ok=' + $cmd
        switch ($cmd) {
            estado {
                $out = ($script:fake.Keys | Sort-Object | ForEach-Object { "$_=$($script:fake[$_])" }) -join "`n"
                if ($Argumentos -contains '--log') { $out += "`n---log---`n" + $script:logFalso }
                if ($Argumentos -contains '--log' -and $null -ne $script:historicoFalso) { $out += "`n---historico---`n" + $script:historicoFalso }
            }
            times { $out = "SolUgarte`nOutroTime" }
            log { $out = $script:logFalso }
            formato { $script:fake.formato = $Argumentos[1] }
            timer { $script:fake.timer = $Argumentos[1] }
            discord { $script:fake.discord = $Argumentos[1] }
            chat { $script:fake.chat = $Argumentos[1] }
            'bloquear-bots' { $script:fake.bloquear_bots = $Argumentos[1] }
            'esperar-bots' { $script:fake.esperar_bots = $Argumentos[1] }
            'esperar-colmeia' { $script:fake.esperar_colmeia = $Argumentos[1] }
            'decisoes-instantaneas' { $script:fake.decisoes_instantaneas = $Argumentos[1] }
            time { $script:fake.time = $Argumentos[1] }
            reiniciar { $out = if ($script:fake.desafio) { 'ok=depois-do-desafio' } else { 'ok=reiniciando' } }
            'conta-navegador' { $script:fake.conta = ($Entrada -split "`n")[0]; $script:fake.login = 'navegador' }
            codigo { $script:fake.codigo = 'sim'; $out = "membro=joao`nok=codigo" }
            desligar { $script:fake.bot = 'deactivating' }
            agora { $script:fake.bot = 'inactive'; $script:fake.partida = ''; $script:fake.placar_oponente = '' }
            ligar { $script:fake.bot = 'active' }
            'cancelar-desafio' { $script:fake.desafio = ''; $script:fake.desafio_fase = '' }
        }
        [pscustomobject]@{ Codigo = 0; Saida = $out; Erro = '' }
    }
    function script:Mensagem([string]$texto, [string]$titulo) { $script:messages.Add($texto) }
    function script:Confirmar([string]$texto) { $script:approve }
    function script:Manter-Vivo { $script:keepalive++ }
    function script:Mudar-Auto { $script:startupChanges++ }
    function script:Start-Process { param([string]$FilePath, $ArgumentList, [switch]$PassThru) $script:launches.Add("$FilePath $ArgumentList") }
    function script:Invoke-WebRequest {
        param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing)
        if ($OutFile) { throw 'Download nao permitido neste teste.' }
        [pscustomobject]@{ Content = $(if ($Uri -like '*/commits/*') { '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' } else { '2026.10.25.01' }) }
    }
}
function Assert-Layout($parent) {
    foreach ($child in $parent.Controls) {
        if (-not $child.Visible) { continue }
        Assert ($child.Left -ge 0 -and $child.Top -ge 0 -and $child.Right -le $parent.ClientSize.Width + 1 -and $child.Bottom -le $parent.ClientSize.Height + 1) ("controle fora do pai: " + $child.GetType().Name + ' / ' + $child.Text + ' / bounds=' + $child.Bounds + ' / parent=' + $parent.ClientSize + ' / escala=' + [LoR.Tema]::F)
        Assert-Layout $child
    }
}
function Capture([string]$name) {
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    try { $form.DrawToBitmap($bitmap, $form.ClientRectangle); $bitmap.Save((Join-Path $OutputDirectory ($name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
}
function Has-Command([string]$value) { @($script:commands | Where-Object { $_.Args -eq $value }).Count -gt 0 }

function Exercise-Dialog([string]$kind) {
    $script:dialogKind = $kind
    # Intercepta somente a construção da janela modal: ela continua sendo um
    # Form real, transparente, com os controles e handlers originais.
    function script:New-Object {
        param([Parameter(Position=0)][string]$TypeName, [Parameter(Position=1)][object[]]$ArgumentList)
        $object = if ($PSBoundParameters.ContainsKey('ArgumentList')) {
            Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName -ArgumentList $ArgumentList
        } else { Microsoft.PowerShell.Utility\New-Object -TypeName $TypeName }
        if ($object -is [System.Windows.Forms.Form]) {
            $object.Opacity = 0
            $object.ShowInTaskbar = $false
            $object.Add_Shown({
                param($sender)
                $fields = @($sender.Controls | Where-Object { $_ -is [LoR.Campo] })
                if ($script:dialogKind -eq 'team') {
                    $fields[0].Caixa.Text = 'TimeSintetico'
                    $fields[1].Caixa.Text = 'Pikachu @ Light Ball'
                    ($sender.Controls | Where-Object { $_ -is [LoR.Botao] -and $_.Text -eq 'Salvar' }).PerformClick()
                } else {
                    $fields[0].Caixa.Text = 'RivalSintetico'
                    ($sender.Controls | Where-Object { $_ -is [LoR.Lista] }).Indice = 2
                    ($sender.Controls | Where-Object { $_ -is [LoR.Botao] -and $_.Text -eq 'Desafiar' }).PerformClick()
                }
            })
        }
        ,$object
    }
    try {
        if ($kind -eq 'team') { $bAddTime.PerformClick() } else { $bDesafiar.PerformClick() }
    } finally { Remove-Item Function:\New-Object }
}

foreach ($scale in @(1, 1.25, 1.5)) {
    [LoR.Tema]::F = $scale
    $Pasta = $OutputDirectory
    $ArquivoSkin = Join-Path $OutputDirectory 'skin.txt'
    $ArquivoLayout = Join-Path $OutputDirectory 'layout.txt'
    $ArquivoVersao = Join-Path $OutputDirectory 'VERSION'
    $AtalhoLigar = Join-Path $OutputDirectory 'startup-inexistente.lnk'
    $Lancador = Join-Path $OutputDirectory 'Painel.vbs'
    $Distro = 'LoRBots'
    $Ramo = 'estavel'
    $Raw = 'https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/main'
    [IO.File]::WriteAllText($ArquivoVersao, '2026.10.24.19')
    $startupLayout = if ($scale -eq 1) { 'invalido' } elseif ($scale -eq 1.25) { 'arena' } else { 'refinado' }
    [IO.File]::WriteAllText($ArquivoLayout, $startupLayout)
    . ([ScriptBlock]::Create($ui))
    Assert ($script:layout -eq $(if ($startupLayout -eq 'invalido') { 'central' } else { $startupLayout })) 'restaurar layout salvo e fallback invalido'
    Install-Fakes
    Fresh-State
    # Uma janela transparente força a criação nativa dos controles sem aparecer
    # na área de trabalho. Não carrega o evento Shown operacional do painel.
    $form.ShowInTaskbar = $false
    $form.Opacity = 0
    # O desktop virtual do runner pode ser menor que a janela a 125/150%.
    # Preserve a geometria sob teste em vez de aceitar o limite de tracking do SO.
    $requiredSize = New-Object System.Drawing.Size((S 1024), (S 694))
    $form.MinimumSize = $requiredSize
    $form.MaximumSize = $requiredSize
    $form.ClientSize = $requiredSize
    $form.Show()
    try {
        Assert ($form.ClientSize -eq $requiredSize) ('janela sintetica deve conservar tamanho solicitado: ' + $form.ClientSize + ' / esperado=' + $requiredSize)
        Escolher-Layout 'central'
        Carregar-Opcoes
        Atualizar-Tela
        foreach ($layout in @('central', 'arena', 'refinado')) {
        Escolher-Layout $layout
        foreach ($theme in @('lago', 'dragao')) {
            Escolher-Tema $theme
            $sections = if ($layout -eq 'refinado') { @('batalhas') } else { @('batalhas', 'times', 'historico', 'ajustes') }
            foreach ($section in $sections) {
                Mostrar-Secao $section
                Assert ($Navegacao[$section].Selecionado) "navegacao $section"
                Assert-Layout $form
                if ($scale -eq 1) { Capture "$theme-$layout-$section" }
            }
            Mostrar-Secao 'batalhas'
            Assert ($lPlacar.Text -eq '1 : 0') 'placar BO3'
            Assert ($lPokemon.Text -eq 'Pokémon: 3 × 1') 'Pokemon restantes'
            Assert ($bDesligar.Text -eq 'Parar ao fim da série') 'parada BO3'
            Assert ($bVer.Visible -and -not $bLigar.Visible) 'acao principal em partida'
            Assert ($atividade.Itens.Count -eq 4) 'atividade estruturada'
            Assert ($tLog.Caixa.Text -match 'WARNING exemplo') 'log bruto conservado'
            Assert ($lLoginNavegador.Text -match 'Login no navegador' -and $tCodigo.Caixa.UseSystemPasswordChar) 'login no navegador e codigo mascarado'
            Assert ($xAuto.TabStop -and $cFormato.TabStop -and $nTimes.TabStop -and $lAtualizar.TabStop) 'acesso por teclado'
            $isKey = [LoR.Base].GetMethod('IsInputKey', [Reflection.BindingFlags]'Instance,NonPublic')
            Assert ($isKey.Invoke($bAplicar, @([System.Windows.Forms.Keys]::Enter))) 'Enter roteado ao botao'
            Assert ($isKey.Invoke($cTime, @([System.Windows.Forms.Keys]::Down))) 'seta roteada ao seletor'
        }
        }
        Escolher-Layout 'central'
        if ($scale -ne 1) { Capture ('lago-escala-' + $scale.ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)) }

        # Estados e navegação não apagam escolhas ou campos ainda não salvos.
        $cFormato.Indice = 1; $cTimer.Indice = 1; $cTime.Indice = 2
        Mostrar-Secao 'times'; Mostrar-Secao 'ajustes'; Mostrar-Secao 'batalhas'
        Assert ($cFormato.Indice -eq 1 -and $cTimer.Indice -eq 1 -and $cTime.Indice -eq 2) 'selecao preservada entre secoes'
        $before = $commands.Count
        foreach ($layout in @('arena', 'refinado', 'central')) { Escolher-Layout $layout }
        Assert ($cFormato.Indice -eq 1 -and $cTimer.Indice -eq 1 -and $cTime.Indice -eq 2 -and $commands.Count -eq $before) 'trocar layout nao aplica configuracao nem chama backend'
        Assert ((Get-Content $ArquivoLayout -Raw).Trim() -eq 'central' -and [LoR.Tema]::Atual.Id -eq 'dragao') 'layout salvo independente do tema'
        $tUsuario.Caixa.Text = 'EdicaoNaoSalva'; $tUsuario.Caixa.Modified = $true
        Atualizar-Tela
        Assert ($tUsuario.Caixa.Text -eq 'EdicaoNaoSalva') 'polling preserva usuario editado'
        $tUsuario.Caixa.Modified = $false
        $fake.placar_bo3 = 'nao'; $fake.formato = 'bo1'; $fake.placar_nossos = '0'
        Atualizar-Tela
        Assert ($lPlacar.Text -eq 'VS' -and $bDesligar.Text -eq 'Parar após a partida') 'BO1 sem placar de serie'
        Assert ($lPokemon.Text -eq 'Pokémon: 0 × 1') 'zero Pokemon continua visivel'
        foreach ($state in @('activating', 'deactivating', 'inactive', 'failed', 'active')) {
            $fake.bot = $state
            Atualizar-Tela
            Assert ($bAgora.Enabled -eq ($state -in @('active', 'activating', 'deactivating'))) "parada imediata $state"
            Assert ($bDesligar.Enabled -eq ($state -in @('active', 'activating'))) "parada normal $state"
            Assert-Layout $form
        }
        $fake.desafio = 'Rival'; $fake.desafio_fase = 'aguardando'; $fake.partida = ''
        Atualizar-Tela
        Assert ($selo.Text -eq 'Esperando Rival aceitar' -and $bDesafiar.Text -eq 'Cancelar desafio') 'desafio aguardando'
        $fake.desafio_fase = 'jogando'; $fake.partida = 'https://play.pokemonshowdown.com/battle-teste'
        Atualizar-Tela
        Assert ($selo.Text -eq 'Desafio contra Rival') 'desafio jogando'
        $fake.desafio = ''
        $savedAccount = $fake.conta; $fake.conta = ''; $fake.codigo = 'nao'; $fake.senha = 'nao'
        Atualizar-Tela
        Assert ($lResumoColeta.Text -eq 'Código não configurado' -and $lNavEstado.Text -eq 'Configure em Ajustes') 'configuracao ausente'
        $fake.conta = $savedAccount; $fake.codigo = 'sim'; $fake.senha = 'nao'; $fake.envio = 'active'; $fake.envio_status = 'codigo'
        Atualizar-Tela
        Assert ($lResumoColeta.Text -eq 'Código recusado pela coleta' -and $lCodigo.CorNome -eq 'vermelho') 'codigo recusado pela coleta'
        $fake.envio_status = 'fora'
        Atualizar-Tela
        Assert ($lResumoColeta.Text -eq 'Código salvo · coleta fora do ar') 'coleta fora do ar'
        Fresh-State
        $script:commands.Clear()
        Atualizar-Tela
        Assert ((Has-Command 'estado|--log|80') -and -not (Has-Command 'log|80')) 'estado e log numa chamada so'
        Assert (@($script:logLinhas).Count -eq 5) 'log veio junto com o estado'
        # Conversas persistidas chegam separadas do log tecnico, em JSON (texto nunca e executado).
        $conversas = @(
            @{ kind = 'log'; text = 'win vs Rival in 7 turns'; time = '2026-11-01T18:00:00+00:00' },
            @{ kind = 'chat'; sender = 'LoRBotTeste'; own = $true; room = 'battle-teste'; text = 'gl hf!'; time = '2026-11-01T18:00:01+00:00' },
            @{ kind = 'chat'; sender = 'Rival'; own = $false; room = 'battle-teste'; text = 'Boa partida | valeu!'; time = '2026-11-01T18:00:02+00:00' },
            @{ kind = 'pm'; sender = 'Amigo'; own = $false; text = 'Vamos jogar depois? Mensagem privada.'; time = '2026-11-01T18:00:03+00:00' }
        )
        # Registros antigos de controles Bo3 e HTML nao aparecem como falas do oponente.
        foreach ($kind in @('chat', 'pm')) {
            foreach ($controle in @('/uhtml controls,<div>Are you ready for game 2?</div>', '/uhtmlchange controls,', '/raw <b>aviso</b>', '/html <b>aviso</b>', '/challenge format', '/UHTML controls,', '/uhtml')) {
                $conversas += @{ kind = $kind; sender = 'Rival'; text = $controle; time = '2026-11-01T18:00:04+00:00' }
            }
            foreach ($remetente in @('', '~', $null)) {
                $conversas += @{ kind = $kind; sender = $remetente; text = 'Aviso do servidor'; time = '2026-11-01T18:00:05+00:00' }
            }
        }
        $script:historicoFalso = ($conversas | ForEach-Object { $_ | ConvertTo-Json -Compress }) -join "`n"
        Mostrar-Secao 'historico'; Atualizar-Tela
        Assert ($atividadeHistorico.Itens.Count -eq 4) 'historico mistura partida, bot, oponente e PM'
        Assert ($atividadeHistorico.Itens[0].Titulo -match 'PM recebida.*Amigo') 'PM mais recente identifica remetente'
        Assert ($atividadeHistorico.Itens[1].Detalhe -match 'Boa partida \| valeu!') 'corpo preserva separador do protocolo'
        Assert ($atividadeHistorico.Itens[2].Titulo -match 'Seu bot') 'identifica a fala do bot'
        Assert ($atividadeHistorico.Caixa.Lines.Count -ge 8) 'cada mensagem tem cabecalho e corpo em linhas separadas'
        Assert ($atividadeHistorico.Caixa.Height -eq $atividadeHistorico.Height) 'area rolavel usa toda a altura do historico'
        Assert ($tLog.Caixa.Text -notmatch 'Mensagem privada') 'PM nao entra no log tecnico'
        $cFiltroHistorico.Indice = 2; Atualizar-Atividade
        Assert ($atividadeHistorico.Itens.Count -eq 3 -and @($atividadeHistorico.Itens | Where-Object { $_.Tipo -ne 'mensagem' }).Count -eq 0) 'filtro exclusivo de mensagens'
        if ($scale -eq 1) { Escolher-Tema 'lago'; Capture 'historico-mensagens' }
        Assert ($atividadeHistorico.Caixa.Text -notmatch '/uhtml|/raw|/html|/challenge|Aviso do servidor') 'controles antigos nao aparecem no historico'
        $historicoAnterior = $script:historicoLinhas
        $textosLiterais = @('Use /uhtml para isso', '<b>texto literal</b> & ola | :)', '/me acena', '//uhtml exemplo', '/uhtml_exemplo', '/challengecup')
        $script:historicoLinhas = @($textosLiterais | ForEach-Object { @{ kind = 'chat'; sender = 'Rival'; text = $_ } | ConvertTo-Json -Compress })
        $literais = @(Ler-Historico @() 'Mensagens')
        Assert ($literais.Count -eq $textosLiterais.Count) 'texto comum e acoes de chat nao sao filtrados'
        for ($i = 0; $i -lt $literais.Count; $i++) {
            Assert ($literais[$i].Detalhe -ceq $textosLiterais[$textosLiterais.Count - 1 - $i]) 'corpo literal permanece intacto'
        }
        $script:historicoLinhas = $historicoAnterior
        $cFiltroHistorico.Indice = 1; Atualizar-Atividade
        Assert ($atividadeHistorico.Itens.Count -eq 1 -and $atividadeHistorico.Itens[0].Tipo -eq 'partida') 'filtro partidas exclui todas as conversas'
        $longa = ('Conversa longa com acentos e varias linhas. ' * 150) + 'FIM DA MENSAGEM'
        $script:historicoFalso += "`n" + (@{ kind = 'pm'; sender = 'Amigo'; own = $false; text = $longa; time = '2026-11-01T18:01:00+00:00' } | ConvertTo-Json -Compress)
        $cFiltroHistorico.Indice = 2; Atualizar-Tela
        Assert ($atividadeHistorico.Caixa.Text.Contains('FIM DA MENSAGEM')) 'mensagem longa permanece inteira e acessivel por rolagem'
        Assert ($atividadeHistorico.Caixa.ReadOnly -and $atividadeHistorico.Caixa.WordWrap -and $atividadeHistorico.Caixa.ScrollBars -eq 'Vertical') 'historico rolavel e somente leitura'
        $atividadeHistorico.Caixa.Select(12, 7); Atualizar-Atividade
        Assert ($atividadeHistorico.Caixa.SelectionStart -eq 12 -and $atividadeHistorico.Caixa.SelectionLength -eq 7) 'polling sem mudanca preserva leitura e selecao'
        Assert-Layout $form
        $cFiltroHistorico.Indice = 0
        Fresh-State; Atualizar-Tela
        Assert ($null -eq $script:historicoLinhas) 'resposta antiga sem historico limpa mensagens da conta anterior'
        if ($script:layout -ne 'refinado') {
            Mostrar-Secao 'historico'
            Assert ($lSubtitulo.Text -eq 'Hoje: 3V–1D · MC371 2-1, MC196 1-0') 'resumo do dia no historico'
            Mostrar-Secao 'batalhas'
        }
        $formSize = $form.ClientSize
        $bTecnico.PerformClick()
        Assert ($tLog.Visible -and -not $atividade.Visible) 'abrir log tecnico'
        $bRecolher.PerformClick()
        Assert ($script:recolhido -and -not $tLog.Visible -and $form.ClientSize -eq $formSize) 'recolher preserva janela'
        $bRecolher.PerformClick(); $bTecnico.PerformClick()
        Assert ($atividade.Visible -and -not $tLog.Visible) 'restaurar resumo'
        $avisos = @(Ler-Atividade @('win vs Rival in 7 turns', 'WARNING teste') 'Avisos')
        Assert ($avisos.Count -eq 1 -and $avisos[0].Tipo -eq 'aviso') 'filtro avisos'
        $prefixoServidor = '2026-11-01 13:15:46,631 - ContaTeste - WARNING - Received pm: |pm| ContaTeste|~|'
        foreach ($textoServidor in @(
            '/error You are not opted-in to playing against bots on the ladder.',
            '/error You are already opted-in to playing against bots on the ladder.',
            'You have opted out of playing against bots on the ladder.',
            'You have opted in to matching against bots on the ladder.'
        )) {
            $linhaServidor = $prefixoServidor + $textoServidor
            $eventosBots = @(Ler-Atividade @($linhaServidor) 'Todos')
            Assert ($eventosBots.Count -eq 1 -and $eventosBots[0].Titulo -eq 'Preferência do ladder' -and $eventosBots[0].Tipo -eq 'outro') 'resposta esperada nao e aviso'
            Assert ($eventosBots[0].Detalhe -notmatch '^Mensagem de|WARNING|Received pm') 'resposta esperada traduzida'
            Assert (@(Ler-Atividade @($linhaServidor) 'Avisos').Count -eq 0) 'resposta esperada fora do filtro avisos'
        }
        $bloqueioAtivo = @(Ler-Atividade @($prefixoServidor + '/error You are not opted-in to playing against bots on the ladder.') 'Todos')
        Assert ($bloqueioAtivo[0].Detalhe -eq 'O bloqueio de bots já estava ativo no ladder.') 'explica o caso observado'
        foreach ($comando in @('block', 'allow')) {
            $envioBots = @(Ler-Atividade @("ladder preference: /$($comando)bots sent") 'Todos')
            Assert ($envioBots[0].Titulo -eq 'Preferência enviada' -and $envioBots[0].Detalhe -match 'solicitad') 'envio nao afirma confirmacao'
        }
        $erroServidor = @(Ler-Atividade @($prefixoServidor + '/error Comando recusado para esta conta.') 'Avisos')
        Assert ($erroServidor.Count -eq 1 -and $erroServidor[0].Tipo -eq 'aviso' -and $erroServidor[0].Detalhe -eq 'Comando recusado para esta conta.') 'erro desconhecido conserva texto e filtro aviso'
        $privada = 'WARNING - Received pm: |pm| Rival| ContaTeste|/error You are not opted-in to playing against bots on the ladder.'
        Assert ($null -eq (Ler-RespostaShowdown $privada)) 'PM de jogador nao e confirmacao do servidor'
        if ($scale -eq 1) {
            $atividade.Definir([LoR.EventoAtividade[]]$bloqueioAtivo)
            Capture 'resposta-bloqueio-ja-ativo'
            Atualizar-Tela
        }
        $textoRestricao = "Due to spam from your internet provider, you can't speak except to staff. Logging into an account you've used a lot in the past will allow you to chat."
        $chatAntigo = '2026-11-01 14:23:49,096 - ContaTeste - CRITICAL - Unexpected error message: [' + "'', 'error', " + '"' + $textoRestricao + '"]'
        $chatNovo = '2026-11-01 14:23:49,096 - ContaTeste - WARNING - showdown chat restricted: ' + $textoRestricao
        foreach ($linhaChat in @($chatAntigo, $chatNovo)) {
            $eventosChat = @(Ler-Atividade @($linhaChat) 'Avisos')
            Assert ($eventosChat.Count -eq 1 -and $eventosChat[0].Titulo -eq 'Chat restrito pelo Showdown' -and $eventosChat[0].Tipo -eq 'aviso') 'restricao de chat tem aviso especifico'
            Assert ($eventosChat[0].Detalhe -notmatch 'CRITICAL|Unexpected|Due to spam') 'restricao de chat traduzida'
        }
        Assert ((Ler-RespostaShowdown $chatNovo).Detalhe -match 'suspensas') 'novo aviso informa suspensao dos envios'
        Assert ((Ler-RespostaShowdown $chatAntigo).Detalhe -notmatch 'suspensas') 'historico nao afirma suspensao retroativa'
        Assert ($null -eq (Ler-RespostaShowdown ('2026-11-01 14:23:49,096 - ContaTeste - WARNING - Received pm: |pm|Rival|ContaTeste|' + $textoRestricao))) 'PM de jogador nao vira restricao'
        $erroReal = '2026-11-01 14:23:49,096 - ContaTeste - CRITICAL - Unexpected error message: erro desconhecido'
        $outroAviso = @(Ler-Atividade @($erroReal) 'Avisos')
        Assert ($outroAviso.Count -eq 1 -and $outroAviso[0].Detalhe -match 'erro desconhecido') 'outros erros continuam visiveis'
        if ($scale -eq 1) {
            $atividade.Definir([LoR.EventoAtividade[]]@(Ler-Atividade @($chatNovo) 'Todos'))
            Capture 'chat-restrito-showdown'
            Atualizar-Tela
        }
        $partidas = @(Ler-Atividade @('team: SolUgarte', 'win vs Rival in 7 turns') 'Partidas')
        Assert ($partidas.Count -eq 1 -and $partidas[0].Titulo -eq 'Vitória') 'filtro partidas'
        $conexao = @(Ler-Atividade @('could not connect to Showdown: exiting to reconnect', 'reconnecting in 10 s (Ctrl-C to stop)') 'Todos')
        Assert ($conexao.Count -eq 2 -and $conexao[0].Titulo -eq 'Reconectando' -and $conexao[1].Titulo -eq 'Conexão perdida' -and $conexao[1].Tipo -eq 'aviso') 'queda de conexao'

        if ($scale -eq 1) {
            $keyDown = [LoR.Botao].GetMethod('OnKeyDown', [Reflection.BindingFlags]'Instance,NonPublic')
            $keyArgs = New-Object System.Windows.Forms.KeyEventArgs([System.Windows.Forms.Keys]::Enter)
            [void]$keyDown.Invoke($nTimes, @($keyArgs.PSObject.BaseObject))
            Assert ($script:secao -eq 'times') 'navegar por Enter'
            Mostrar-Secao 'batalhas'
            $menu = Criar-MenuAparencia
            try {
                Assert ($menu.Items.Count -eq 6) 'menu oferece tres layouts e dois temas'
                $menu.Items[1].PerformClick()
                Assert ($script:layout -eq 'arena') 'menu seleciona Arena'
                $menu.Items[2].PerformClick()
                Assert ($script:layout -eq 'refinado') 'menu seleciona Painel refinado'
                $menu.Items[5].PerformClick()
                Assert ([LoR.Tema]::Atual.Id -eq 'lago' -and $script:layout -eq 'refinado') 'tema independente no menu'
                $menu.Items[0].PerformClick()
            } finally { $menu.Dispose() }
            Fresh-State; Atualizar-Tela
            Exercise-Dialog 'team'
            Assert (Has-Command 'adicionar-time') 'dialogo de adicionar usa validacao do backend'
            Assert (($commands | Where-Object { $_.Args -eq 'adicionar-time' } | Select-Object -Last 1).Input -match '^TimeSintetico\nPikachu') 'time e export enviados pela entrada padrao'
            $fake.senha = 'nao' # Login pelo navegador permite desafiar sem senha no painel.
            Exercise-Dialog 'challenge'
            Assert (Has-Command 'desafiar|3') 'dialogo desafia com quantidade selecionada'
            Assert (($commands | Where-Object { $_.Args -eq 'desafiar|3' } | Select-Object -Last 1).Input -eq "RivalSintetico`n") 'alvo do desafio enviado pela entrada padrao'
            Fresh-State; Atualizar-Tela
            # Os eventos reais são acionados; apenas as fronteiras externas são falsas.
            $script:commands.Clear()
            $cFormato.Indice = 1; $cTimer.Indice = 1; $cTime.Indice = 1
            $bAplicar.PerformClick()
            $mutations = @($commands | Where-Object { $_.Args -notmatch '^(estado|log)' } | ForEach-Object { $_.Args })
            Assert (($mutations -join ',') -eq 'formato|bo1,timer|nao,time|SolUgarte,reiniciar') 'aplicar conserva ordem e argumentos'
            Assert ($lConfigStatus.Text -match 'Salvo') 'feedback aplicar'
            $script:commands.Clear(); $script:failure = 'timer'
            $bAplicar.PerformClick()
            Assert (-not (Has-Command 'reiniciar') -and -not (Has-Command 'time|SolUgarte')) 'aplicar interrompe em falha'
            $script:failure = ''
            $script:commands.Clear(); $script:approve = $false
            $bAgora.PerformClick()
            Assert (-not (Has-Command 'agora')) 'interrupcao recusada nao chega ao backend'
            $script:approve = $true; $bAgora.PerformClick()
            Assert ((Has-Command 'agora') -and $lBot.Text -eq 'Bot parado') 'interrupcao confirmada'
            $bLigar.PerformClick()
            Assert ((Has-Command 'ligar') -and $script:keepalive -eq 1) 'iniciar conserva keepalive'
            $bDesligar.PerformClick()
            Assert ((Has-Command 'desligar') -and -not $bLigar.Enabled) 'parada normal aguarda termino'
            Fresh-State; Atualizar-Tela
            $tUsuario.Caixa.Text = 'ContaTesteNova'
            $bConta.PerformClick()
            Assert ((Has-Command 'conta-navegador') -and (Has-Command 'reiniciar')) 'salvar conta pelo navegador agenda troca'
            Assert (($script:commands | Where-Object { $_.Args -eq 'conta-navegador' } | Select-Object -Last 1).Input -eq "ContaTesteNova`n") 'salvar conta nao transmite senha'
            $tCodigo.Caixa.Text = 'codigo-sintetico'; $bCodigo.PerformClick()
            Assert ((Has-Command 'codigo') -and $tCodigo.Caixa.Text -eq '') 'salvar codigo limpa campo'
            Assert ($script:messages[$script:messages.Count - 1] -like 'Código de joao conferido*') 'codigo conferido diz de quem e'
            Assert $xDiscord.Marcado 'discord ligado por padrao'
            $script:commands.Clear(); $xDiscord.Marcado = $false; Mudar-Discord
            Assert ((Has-Command 'discord|nao') -and $fake.discord -eq 'nao' -and -not (Has-Command 'reiniciar')) 'desligar discord vale sem reiniciar'
            $script:failure = 'discord'; $xDiscord.Marcado = $true; Mudar-Discord
            Assert (-not $xDiscord.Marcado) 'falha no backend volta a chave'
            $script:failure = ''
            $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xDiscord.Marcado) 'chave do discord vem do estado'
            $xDiscord.Marcado = $true; Mudar-Discord
            Assert ($fake.discord -eq 'sim') 'religar discord'
            Assert $xChat.Marcado 'glhf/gg wp ligado por padrao'
            $script:commands.Clear(); $xChat.Marcado = $false; Mudar-Chat
            Assert ((Has-Command 'chat|nao') -and $fake.chat -eq 'nao' -and -not (Has-Command 'reiniciar')) 'desligar chat vale sem reiniciar'
            $script:failure = 'chat'; $xChat.Marcado = $true; Mudar-Chat
            Assert (-not $xChat.Marcado) 'falha no backend volta a chave do chat'
            $script:failure = ''
            $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xChat.Marcado) 'chave do chat vem do estado'
            $xChat.Marcado = $true; Mudar-Chat
            Assert ($fake.chat -eq 'sim') 'religar chat'
            Assert $xBloquearBots.Marcado 'blockbots ligado por padrao'
            $script:commands.Clear(); $xBloquearBots.Marcado = $false; Mudar-BloquearBots
            Assert ((Has-Command 'bloquear-bots|nao') -and $fake.bloquear_bots -eq 'nao' -and -not (Has-Command 'reiniciar')) 'toggle permite bots sem reiniciar'
            Assert ($script:messages[$script:messages.Count - 1] -match '/allowbots') 'feedback allowbots'
            $script:failure = 'bloquear-bots'; $xBloquearBots.Marcado = $true; Mudar-BloquearBots
            Assert (-not $xBloquearBots.Marcado) 'falha volta toggle de bots'
            $script:failure = ''; $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xBloquearBots.Marcado) 'toggle recupera preferencia salva'
            $xBloquearBots.Marcado = $true; Mudar-BloquearBots
            Assert ($fake.bloquear_bots -eq 'sim') 'toggle volta a bloquear bots'
            Assert ($script:messages[$script:messages.Count - 1] -match '/blockbots') 'feedback blockbots'
            Assert $xEsperarBots.Marcado 'espera de bots ligada por padrao'
            $script:commands.Clear(); $xEsperarBots.Marcado = $false; Mudar-EsperarBots
            Assert ((Has-Command 'esperar-bots|nao') -and $fake.esperar_bots -eq 'nao' -and -not (Has-Command 'reiniciar')) 'desligar espera sem reiniciar'
            Assert ($fake.bloquear_bots -eq 'sim') 'espera independente de blockbots'
            Assert ($script:messages[$script:messages.Count - 1] -match 'em curso') 'feedback sobre espera em curso'
            $script:failure = 'esperar-bots'; $xEsperarBots.Marcado = $true; Mudar-EsperarBots
            Assert (-not $xEsperarBots.Marcado) 'falha volta toggle da espera'
            $script:failure = ''; $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xEsperarBots.Marcado) 'espera recupera preferencia salva'
            $xEsperarBots.Marcado = $true; Mudar-EsperarBots
            Assert ($fake.esperar_bots -eq 'sim') 'religar espera'
            $fake.Remove('esperar_bots'); $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert $xEsperarBots.Marcado 'estado antigo preserva espera ligada'
            $fake.esperar_bots = 'sim'
            Assert $xEsperarColmeia.Marcado 'espera da colmeia ligada por padrao'
            $script:commands.Clear(); $xEsperarColmeia.Marcado = $false; Mudar-EsperarColmeia
            Assert ((Has-Command 'esperar-colmeia|nao') -and $fake.esperar_colmeia -eq 'nao' -and -not (Has-Command 'reiniciar')) 'desligar espera da colmeia sem reiniciar'
            Assert ($fake.esperar_bots -eq 'sim' -and $fake.bloquear_bots -eq 'sim') 'colmeia independente dos adversarios e blockbots'
            $script:failure = 'esperar-colmeia'; $xEsperarColmeia.Marcado = $true; Mudar-EsperarColmeia
            Assert (-not $xEsperarColmeia.Marcado) 'falha restaura toggle da colmeia'
            $script:failure = ''; $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xEsperarColmeia.Marcado) 'colmeia recupera preferencia salva'
            $xEsperarColmeia.Marcado = $true; Mudar-EsperarColmeia
            Assert ($fake.esperar_colmeia -eq 'sim') 'religar espera da colmeia'
            $fake.Remove('esperar_colmeia'); $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert $xEsperarColmeia.Marcado 'estado antigo mantem espera da colmeia'
            $fake.esperar_colmeia = 'sim'
            Assert (-not $xDecisoesInstantaneas.Marcado -and $lDecisoesValor.Text -eq 'Não') 'instantaneas nao por padrao'
            $script:commands.Clear(); $xDecisoesInstantaneas.Marcado = $true; Mudar-DecisoesInstantaneas
            Assert ((Has-Command 'decisoes-instantaneas|sim') -and $fake.decisoes_instantaneas -eq 'sim' -and -not (Has-Command 'reiniciar')) 'instantaneas sim sem reiniciar'
            Assert ($lDecisoesValor.Text -eq 'Sim') 'rotulo instantaneas sim'
            Assert ($fake.esperar_bots -eq 'sim' -and $fake.bloquear_bots -eq 'sim') 'instantaneas independente das opcoes de bots'
            $script:failure = 'decisoes-instantaneas'; $xDecisoesInstantaneas.Marcado = $false; Mudar-DecisoesInstantaneas
            Assert ($xDecisoesInstantaneas.Marcado -and $lDecisoesValor.Text -eq 'Sim') 'falha restaura estado e rotulo das decisoes'
            $script:failure = ''; $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert ($xDecisoesInstantaneas.Marcado -and $lDecisoesValor.Text -eq 'Sim') 'instantaneas recupera preferencia salva'
            $xDecisoesInstantaneas.Marcado = $false; Mudar-DecisoesInstantaneas
            Assert ($fake.decisoes_instantaneas -eq 'nao' -and $lDecisoesValor.Text -eq 'Não') 'instantaneas nao restaura 10-20 segundos'
            $fake.Remove('decisoes_instantaneas'); $script:opcoesCarregadas = $false; Atualizar-Tela
            Assert (-not $xDecisoesInstantaneas.Marcado) 'estado antigo usa instantaneas nao'
            $fake.decisoes_instantaneas = 'nao'
            $cTime.Indice = 1; $bRemTime.PerformClick()
            Assert (-not (Has-Command 'remover-time|SolUgarte')) 'remover recusa sem confirmacao'
            $script:approve = $true; $bRemTime.PerformClick()
            Assert (Has-Command 'remover-time|SolUgarte') 'remover confirmado usa mesmo comando'
            $fake.desafio = 'Rival'; $fake.desafio_fase = 'aguardando'
            Atualizar-Tela
            $bDesafiar.PerformClick()
            Assert (Has-Command 'cancelar-desafio') 'cancelar desafio preservado'
            $fake.partida = 'https://play.pokemonshowdown.com/battle-teste'
            $bVer.PerformClick(); $bHistorico.PerformClick(); $bPastaPartidas.PerformClick()
            Assert ($script:launches.Count -eq 3 -and $script:launches[0] -match 'battle-teste' -and $script:launches[1] -match 'replay.pokemonshowdown.com' -and $script:launches[2] -match 'live_games') 'ao vivo, replays e pasta local'
            $script:approve = $false; $lAtualizar.PerformClick()
            Assert ($script:versaoNova -eq '2026.10.25.01') 'verificacao de atualizacao'
            $onClick = [LoR.Chave].GetMethod('OnClick', [Reflection.BindingFlags]'Instance,NonPublic')
            [void]$onClick.Invoke($xAuto, @([EventArgs]::Empty))
            Assert ($script:startupChanges -eq 1) 'alternancia inicializacao Windows'
            $script:failure = 'estado'
            Atualizar-Tela
            Assert ($lBot.Text -eq 'Sem resposta do WSL' -and -not $bVer.Enabled -and -not $bAgora.Enabled -and -not $bAplicar.Enabled -and -not $xDecisoesInstantaneas.Enabled -and -not $xEsperarColmeia.Enabled) 'erro WSL limpa acoes antigas'
            $script:failure = ''; Atualizar-Tela
            Assert ($bAplicar.Enabled -and $xEsperarColmeia.Enabled -and $xDecisoesInstantaneas.Enabled -and $lBot.Text -eq 'Bot em execução') 'recuperacao do WSL'
        }
    } finally {
        $form.Close(); $form.Dispose(); $ttTema.Dispose()
        foreach ($theme in $Temas.Values) { $theme.ImagemCabecalho.Dispose() }
    }
}
Write-Host "LOR_PANEL_UI_PASS assertions=$script:assertions scales=100,125,150 themes=lago,dragao layouts=central,arena,refinado"
Write-Host "Capturas sinteticas: $OutputDirectory"
