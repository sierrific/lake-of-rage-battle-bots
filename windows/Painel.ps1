# Painel LoR Bots: liga, desliga e configura o bot da Lake of Rage que roda no WSL deste PC.
# Fala com o Linux pelo /opt/lor-bots/painel.sh (distribuição LoRBots).
#   Painel.ps1          abre a janela
#   Painel.ps1 -Ligar   só liga o bot e sai (usado ao iniciar o Windows)
param([switch]$Ligar)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Distro = 'LoRBots'
$Pasta = $PSScriptRoot
# main, ou a branch de teste com que o instalador rodou (ramo.txt)
$Ramo = 'main'
if ($env:LOR_RAMO) { $Ramo = $env:LOR_RAMO }
elseif (Test-Path (Join-Path $Pasta 'ramo.txt')) { $Ramo = (Get-Content (Join-Path $Pasta 'ramo.txt') -TotalCount 1).Trim() }
$Raw = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$Ramo"
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Painel {
    # Roda painel.sh no Linux; o que é texto do usuário (senha, nomes, times) vai pela entrada
    # padrão, nunca na linha de comando.
    param([string[]]$Argumentos, [string]$Entrada = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d $Distro -u root -e /opt/lor-bots/painel.sh " + ($Argumentos -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = $Utf8
    $psi.StandardErrorEncoding = $Utf8
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Entrada) {
        $bytes = $Utf8.GetBytes($Entrada)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    }
    $p.StandardInput.Close()
    $saida = $p.StandardOutput.ReadToEnd()
    $erro = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    [pscustomobject]@{ Codigo = $p.ExitCode; Saida = $saida.Trim(); Erro = $erro.Trim() }
}

function Ler-Estado {
    $r = Invoke-Painel @('estado')
    $e = @{}
    foreach ($linha in $r.Saida -split "`n") {
        $i = $linha.IndexOf('=')
        if ($i -gt 0) { $e[$linha.Substring(0, $i)] = $linha.Substring($i + 1).Trim() }
    }
    $e
}

function Manter-Vivo {
    # O WSL desliga o Linux quando nenhum programa do Windows o usa; este processo escondido
    # segura enquanto o bot estiver ligado (e sai sozinho depois).
    Start-Process wsl.exe -WindowStyle Hidden -ArgumentList "-d $Distro -u root -e /opt/lor-bots/painel.sh manter-vivo"
}

function Mensagem([string]$texto, [string]$titulo = 'Painel LoR Bots') {
    [System.Windows.Forms.MessageBox]::Show($texto, $titulo) | Out-Null
}

if ($Ligar) {
    $r = Invoke-Painel @('ligar')
    if ($r.Codigo -eq 0) { Manter-Vivo }
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Painel LoR Bots'
$form.Size = New-Object System.Drawing.Size(560, 720)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

function Novo($tipo, $x, $y, $w, $h, $pai = $form) {
    $c = New-Object "System.Windows.Forms.$tipo"
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    $pai.Controls.Add($c)
    $c
}

# Status
$gStatus = Novo GroupBox 10 8 525 112
$gStatus.Text = 'Status'
$lBot = Novo Label 12 22 500 20 $gStatus
$lBot.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$lInfo = Novo Label 12 44 500 20 $gStatus
$lPartida = Novo LinkLabel 12 66 500 20 $gStatus
$lVersao = Novo Label 12 88 360 20 $gStatus
$bAtualizar = Novo Button 380 82 135 26 $gStatus
$bAtualizar.Text = 'Atualizar'
$lPartida.Add_LinkClicked({ if ($lPartida.Tag) { Start-Process $lPartida.Tag } })

# Conta
$gConta = Novo GroupBox 10 126 525 88
$gConta.Text = 'Conta do Showdown usada pelo bot'
(Novo Label 12 26 60 20 $gConta).Text = 'Usuário'
$tUsuario = Novo TextBox 75 22 160 24 $gConta
(Novo Label 250 26 50 20 $gConta).Text = 'Senha'
$tSenha = Novo TextBox 300 22 130 24 $gConta
$tSenha.UseSystemPasswordChar = $true
$bConta = Novo Button 440 20 75 28 $gConta
$bConta.Text = 'Salvar'
$lConta = Novo Label 12 56 500 22 $gConta
$lConta.ForeColor = [System.Drawing.Color]::DimGray
$lConta.Text = 'A conta precisa estar registrada no Showdown. A senha fica só neste PC.'

# Coleta
$gColeta = Novo GroupBox 10 220 525 62
$gColeta.Text = 'Código da coleta do time (para o treino e o Discord)'
$tCodigo = Novo TextBox 12 24 330 24 $gColeta
$tCodigo.UseSystemPasswordChar = $true
$bCodigo = Novo Button 350 22 75 28 $gColeta
$bCodigo.Text = 'Salvar'
$lCodigo = Novo Label 432 27 90 20 $gColeta

# Jogo
$gJogo = Novo GroupBox 10 288 525 96
$gJogo.Text = 'Partidas (ladder oficial, Reg M-C)'
(Novo Label 12 28 60 20 $gJogo).Text = 'Formato'
$cFormato = Novo ComboBox 75 24 80 24 $gJogo
$cFormato.DropDownStyle = 'DropDownList'
[void]$cFormato.Items.AddRange(@('Bo3', 'Bo1'))
(Novo Label 170 28 40 20 $gJogo).Text = 'Time'
$cTime = Novo ComboBox 210 24 170 24 $gJogo
$cTime.DropDownStyle = 'DropDownList'
$bAplicar = Novo Button 390 22 125 28 $gJogo
$bAplicar.Text = 'Aplicar'
$bAddTime = Novo Button 75 58 150 28 $gJogo
$bAddTime.Text = 'Adicionar time…'
$bRemTime = Novo Button 230 58 150 28 $gJogo
$bRemTime.Text = 'Remover time'

# Botões
$bLigar = Novo Button 10 392 125 34
$bLigar.Text = 'Ligar'
$bDesligar = Novo Button 140 392 175 34
$bDesligar.Text = 'Desligar (após a partida)'
$bAgora = Novo Button 320 392 105 34
$bAgora.Text = 'Desligar agora'
$bLog = Novo Button 430 392 105 34
$bLog.Text = 'Ver ao vivo'
$bPartidas = Novo Button 10 432 125 28
$bPartidas.Text = 'Abrir partidas'
$xAuto = Novo CheckBox 145 436 300 22
$xAuto.Text = 'Ligar o bot junto com o Windows'

$tLog = Novo TextBox 10 468 525 200
$tLog.Multiline = $true
$tLog.ReadOnly = $true
$tLog.ScrollBars = 'Vertical'
$tLog.Font = New-Object System.Drawing.Font('Consolas', 8)

$Atalho = Join-Path ([Environment]::GetFolderPath('Startup')) 'LoR Bots (ligar).lnk'
$xAuto.Checked = Test-Path $Atalho

$script:estado = @{}
$script:versaoNova = $null

function Atualizar-Tela {
    $e = Ler-Estado
    $script:estado = $e
    $nomes = @{ active = 'Rodando'; activating = 'Ligando…'; deactivating = 'Desligando após a partida atual…';
        inactive = 'Parado'; failed = 'Parou com erro (veja o log)' }
    $txt = $nomes[$e['bot']]
    if (-not $txt) { $txt = "Bot: $($e['bot'])" }
    $lBot.Text = "Bot: $txt"
    $lBot.ForeColor = if ($e['bot'] -eq 'active') { [System.Drawing.Color]::ForestGreen }
        elseif ($e['bot'] -eq 'failed') { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::Black }
    $conta = if ($e['conta']) { $e['conta'] } else { '(sem conta)' }
    $mem = if ($e['memoria_mb']) { " · $($e['memoria_mb']) MB" } else { '' }
    $envio = if ($e['codigo'] -ne 'sim') { 'sem código' } elseif ($e['envio'] -eq 'active') { 'ativo' } else { 'parado' }
    $lInfo.Text = "Conta: $conta · $($e['formato'].ToUpper()) · Time: $($e['time'])$mem · Envio: $envio"
    if ($e['partida']) { $lPartida.Text = "Partida: $($e['partida'])"; $lPartida.Tag = $e['partida'] }
    else { $lPartida.Text = ''; $lPartida.Tag = $null }
    $lVersao.Text = "Versão $($e['versao'])"
    if ($script:versaoNova -and $script:versaoNova -ne $e['versao']) {
        $bAtualizar.Text = "Atualizar ($($script:versaoNova))"
        $bAtualizar.BackColor = [System.Drawing.Color]::Gold
    } else {
        $bAtualizar.Text = 'Atualizar'
        $bAtualizar.UseVisualStyleBackColor = $true
    }
    if (-not $tUsuario.Focused -and -not $tUsuario.Modified) { $tUsuario.Text = $e['conta'] }
    $lCodigo.Text = if ($e['codigo'] -eq 'sim') { 'salvo ✓' } else { 'não salvo' }
    $tLog.Text = ((Invoke-Painel @('log', '14')).Saida -replace "`r?`n", "`r`n")
    $tLog.SelectionStart = $tLog.Text.Length
    $tLog.ScrollToCaret()
    $ligado = $e['bot'] -in @('active', 'activating')
    $bLigar.Enabled = -not $ligado -and $e['bot'] -ne 'deactivating'
    $bDesligar.Enabled = $ligado
    $bAgora.Enabled = $e['bot'] -in @('active', 'activating', 'deactivating')
}

function Carregar-Opcoes {
    $e = Ler-Estado
    $cFormato.SelectedItem = if ($e['formato'] -eq 'bo1') { 'Bo1' } else { 'Bo3' }
    $cTime.Items.Clear()
    [void]$cTime.Items.Add('Top 3 (padrão)')
    foreach ($t in ((Invoke-Painel @('times')).Saida -split "`n")) { if ($t.Trim()) { [void]$cTime.Items.Add($t.Trim()) } }
    if ($e['time'] -and $e['time'] -ne 'top3' -and $cTime.Items.Contains($e['time'])) { $cTime.SelectedItem = $e['time'] }
    else { $cTime.SelectedIndex = 0 }
}

function Resultado($r, [string]$ok) {
    if ($r.Codigo -eq 0) { if ($ok) { Mensagem $ok }; return $true }
    $msg = (($r.Saida + "`n" + $r.Erro).Trim() -replace '^erro=', '')
    Mensagem "Não deu certo:`n`n$msg"
    $false
}

$bConta.Add_Click({
    if (-not $tUsuario.Text.Trim()) { Mensagem 'Coloque o usuário do Showdown.'; return }
    if (-not $tSenha.Text -and $script:estado['senha'] -ne 'sim') { Mensagem 'Coloque a senha da conta.'; return }
    $r = Invoke-Painel @('conta') ("$($tUsuario.Text.Trim())`n$($tSenha.Text)`n")
    $tSenha.Text = ''
    $tUsuario.Modified = $false
    if (Resultado $r '') {
        if ($script:estado['bot'] -eq 'active') {
            Invoke-Painel @('reiniciar') | Out-Null
            Mensagem 'Conta salva. O bot entra com ela depois da partida atual.'
        } else { Mensagem 'Conta salva.' }
    }
    Atualizar-Tela
})

$bCodigo.Add_Click({
    if (-not $tCodigo.Text.Trim()) { Mensagem 'Cole o código que o Thiago passou.'; return }
    $r = Invoke-Painel @('codigo') ($tCodigo.Text.Trim() + "`n")
    if (Resultado $r 'Código salvo. As partidas deste bot vão para a coleta do time.') { $tCodigo.Text = '' }
    Atualizar-Tela
})

$bAplicar.Add_Click({
    $f = if ($cFormato.SelectedItem -eq 'Bo1') { 'bo1' } else { 'bo3' }
    $t = if ($cTime.SelectedIndex -le 0) { 'top3' } else { [string]$cTime.SelectedItem }
    if (-not (Resultado (Invoke-Painel @('formato', $f)) '')) { return }
    if (-not (Resultado (Invoke-Painel @('time', $t)) '')) { return }
    $r = Invoke-Painel @('reiniciar')
    if ($r.Saida -match 'reiniciando') { Mensagem 'Salvo. O bot reinicia com isso depois da partida (ou série) atual.' }
    else { Mensagem 'Salvo. Vale na próxima vez que ligar.' }
    Atualizar-Tela
})

$bAddTime.Add_Click({
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Adicionar time'
    $d.Size = New-Object System.Drawing.Size(460, 440)
    $d.StartPosition = 'CenterParent'
    $d.Font = $form.Font
    (Novo Label 12 12 420 20 $d).Text = 'Nome (letras, números, - e _):'
    $tNome = Novo TextBox 12 34 200 24 $d
    (Novo Label 12 66 420 20 $d).Text = 'Link do pokepast.es ou o export do Showdown:'
    $tTexto = Novo TextBox 12 88 420 260 $d
    $tTexto.Multiline = $true
    $tTexto.ScrollBars = 'Vertical'
    $tTexto.AcceptsReturn = $true
    $bOk = Novo Button 252 356 90 30 $d
    $bOk.Text = 'Salvar'
    $bCancelar = Novo Button 345 356 90 30 $d
    $bCancelar.Text = 'Cancelar'
    $bCancelar.Add_Click({ $d.Close() })
    $bOk.Add_Click({
        $d.Cursor = 'WaitCursor'
        $r = Invoke-Painel @('adicionar-time') ($tNome.Text.Trim() + "`n" + $tTexto.Text)
        $d.Cursor = 'Default'
        if (Resultado $r 'Time válido e salvo. Escolha ele na lista e clique em Aplicar.') { $d.Close() }
    })
    [void]$d.ShowDialog($form)
    Carregar-Opcoes
})

$bRemTime.Add_Click({
    if ($cTime.SelectedIndex -le 0) { Mensagem 'Escolha na lista um time que você adicionou.'; return }
    $t = [string]$cTime.SelectedItem
    if ([System.Windows.Forms.MessageBox]::Show("Remover o time $t?", 'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    [void](Resultado (Invoke-Painel @('remover-time', $t)) '')
    Carregar-Opcoes
    Atualizar-Tela
})

$bLigar.Add_Click({
    if (Resultado (Invoke-Painel @('ligar')) '') { Manter-Vivo }
    Atualizar-Tela
})
$bDesligar.Add_Click({ [void](Resultado (Invoke-Painel @('desligar')) ''); Atualizar-Tela })
$bAgora.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show('Desligar agora? A partida em andamento fica pela metade (o bot perde por W.O.).',
        'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    [void](Resultado (Invoke-Painel @('agora')) '')
    Atualizar-Tela
})
$bLog.Add_Click({
    Start-Process wsl.exe -ArgumentList "-d $Distro -u root -e journalctl -fu lor-bot@bot -o cat -n 50"
})
$bPartidas.Add_Click({ Start-Process explorer.exe "\\wsl$\$Distro\opt\lor-bots\ai-vgc\data\live_games" })

$xAuto.Add_CheckedChanged({
    if ($xAuto.Checked) {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Atalho)
        $s.TargetPath = 'powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Pasta\Painel.ps1`" -Ligar"
        $s.WorkingDirectory = $Pasta
        $s.Save()
    } elseif (Test-Path $Atalho) { Remove-Item $Atalho }
})

$bAtualizar.Add_Click({
    if ([System.Windows.Forms.MessageBox]::Show(
        'Baixar a versão mais nova do bot e do painel? Se o bot estiver jogando, ele termina a partida atual antes de reiniciar.',
        'Painel LoR Bots', 'YesNo') -ne 'Yes') { return }
    try {
        # Primeiro o painel (este arquivo), depois o Linux numa janela que mostra o progresso.
        $novo = Join-Path $Pasta 'Painel.novo.ps1'
        Invoke-WebRequest -UseBasicParsing -Uri "$Raw/windows/Painel.ps1" -OutFile $novo
        Move-Item -Force $novo (Join-Path $Pasta 'Painel.ps1')
        Start-Process wsl.exe -Wait -ArgumentList "-d $Distro -u root -e env LOR_RAMO=$Ramo /opt/lor-bots/painel.sh atualizar"
        Manter-Vivo
        Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Pasta\Painel.ps1`""
        $form.Close()
    } catch {
        Mensagem "Não consegui atualizar: $($_.Exception.Message)"
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ try { Atualizar-Tela } catch { $lBot.Text = "Bot: sem resposta do WSL ($($_.Exception.Message))" } })

$form.Add_Shown({
    $form.Cursor = 'WaitCursor'
    try {
        Carregar-Opcoes
        if ($script:estado['bot'] -in @('active', 'activating', 'deactivating')) { Manter-Vivo }
        # Versão nova no GitHub? (só avisa; atualizar é no botão)
        try { $script:versaoNova = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 -Uri "$Raw/VERSION").Content.Trim() } catch { }
        Atualizar-Tela
        if ($script:estado['bot'] -in @('active', 'activating', 'deactivating')) { Manter-Vivo }
    } catch {
        $lBot.Text = "Bot: sem resposta do WSL ($($_.Exception.Message))"
    }
    $form.Cursor = 'Default'
    $timer.Start()
})

[void]$form.ShowDialog()
$timer.Stop()
