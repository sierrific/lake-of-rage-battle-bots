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
    $script:fake = @{
        bot = 'active'; conta = 'LoRBotTeste'; senha = 'sim'; codigo = 'sim'; envio = 'active'
        formato = 'bo3'; timer = 'sim'; time = 'SolUgarte'; versao = '2026.10.24.19'; memoria_mb = '531'
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
            estado { $out = ($script:fake.Keys | Sort-Object | ForEach-Object { "$_=$($script:fake[$_])" }) -join "`n" }
            times { $out = "SolUgarte`nOutroTime" }
            log { $out = "Started lor-bot@bot`nteam: SolUgarte`nwin vs AdversarioTeste in 7 turns`nwatch: https://play.pokemonshowdown.com/battle-teste`nWARNING exemplo de aviso" }
            formato { $script:fake.formato = $Argumentos[1] }
            timer { $script:fake.timer = $Argumentos[1] }
            time { $script:fake.time = $Argumentos[1] }
            reiniciar { $out = if ($script:fake.desafio) { 'ok=depois-do-desafio' } else { 'ok=reiniciando' } }
            conta { $script:fake.conta = ($Entrada -split "`n")[0]; $script:fake.senha = 'sim' }
            codigo { $script:fake.codigo = 'sim' }
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
    function script:Invoke-WebRequest { param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing) if ($OutFile) { throw 'Download nao permitido neste teste.' }; [pscustomobject]@{ Content = '2026.10.25.01' } }
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
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.Show()
    try {
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
            Assert ($tSenha.Caixa.UseSystemPasswordChar -and $tCodigo.Caixa.UseSystemPasswordChar) 'segredos mascarados'
            Assert ($xAuto.TabStop -and $cFormato.TabStop -and $nTimes.TabStop -and $lAtualizar.TabStop -and $tSenha.Olho.TabStop) 'acesso por teclado'
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
        $fake.codigo = 'nao'; $fake.senha = 'nao'
        Atualizar-Tela
        Assert ($lResumoColeta.Text -eq 'Código não configurado' -and $lNavEstado.Text -eq 'Configure em Ajustes') 'configuracao ausente'
        Fresh-State; Atualizar-Tela
        $formSize = $form.ClientSize
        $bTecnico.PerformClick()
        Assert ($tLog.Visible -and -not $atividade.Visible) 'abrir log tecnico'
        $bRecolher.PerformClick()
        Assert ($script:recolhido -and -not $tLog.Visible -and $form.ClientSize -eq $formSize) 'recolher preserva janela'
        $bRecolher.PerformClick(); $bTecnico.PerformClick()
        Assert ($atividade.Visible -and -not $tLog.Visible) 'restaurar resumo'
        $avisos = @(Ler-Atividade @('win vs Rival in 7 turns', 'WARNING teste') 'Avisos')
        Assert ($avisos.Count -eq 1 -and $avisos[0].Tipo -eq 'aviso') 'filtro avisos'
        $partidas = @(Ler-Atividade @('team: SolUgarte', 'win vs Rival in 7 turns') 'Partidas')
        Assert ($partidas.Count -eq 1 -and $partidas[0].Titulo -eq 'Vitória') 'filtro partidas'

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
            $tUsuario.Caixa.Text = 'ContaTesteNova'; $tSenha.Caixa.Text = 'senha-sintetica'
            $bConta.PerformClick()
            Assert ((Has-Command 'conta') -and $tSenha.Caixa.Text -eq '' -and (Has-Command 'reiniciar')) 'salvar conta limpa senha e agenda troca'
            $tCodigo.Caixa.Text = 'codigo-sintetico'; $bCodigo.PerformClick()
            Assert ((Has-Command 'codigo') -and $tCodigo.Caixa.Text -eq '') 'salvar codigo limpa campo'
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
            Assert ($lBot.Text -eq 'Sem resposta do WSL' -and -not $bVer.Enabled -and -not $bAgora.Enabled -and -not $bAplicar.Enabled) 'erro WSL limpa acoes antigas'
            $script:failure = ''; Atualizar-Tela
            Assert ($bAplicar.Enabled -and $lBot.Text -eq 'Bot em execução') 'recuperacao do WSL'
        }
    } finally {
        $form.Close(); $form.Dispose(); $ttTema.Dispose()
        foreach ($theme in $Temas.Values) { $theme.ImagemCabecalho.Dispose() }
    }
}
Write-Host "LOR_PANEL_UI_PASS assertions=$script:assertions scales=100,125,150 themes=lago,dragao layouts=central,arena,refinado"
Write-Host "Capturas sinteticas: $OutputDirectory"
