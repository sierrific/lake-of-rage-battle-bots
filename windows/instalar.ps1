# Instalador dos bots da Lake of Rage para Windows 10/11.
#
# Abra o PowerShell (de preferencia como administrador) e cole:
#   irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/main/windows/instalar.ps1 | iex
#
# O que ele faz: liga o WSL (se preciso), cria uma distribuicao Linux so para os bots
# ("LoRBots", Ubuntu 24.04), instala o bot dentro dela e poe o "Painel LoR Bots" na Area de
# Trabalho. Rodar de novo e seguro: ele pula o que ja esta pronto.
# (Arquivo sem acentos de proposito: o "irm | iex" do PowerShell 5 nao gosta.)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # o Invoke-WebRequest fica 10x mais lento com a barra
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Ramo = if ($env:LOR_RAMO) { $env:LOR_RAMO } else { 'main' }  # outra branch so para testes
$Raw = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$Ramo"
$Distro = 'LoRBots'
$Pasta = Join-Path $env:LOCALAPPDATA 'LoRBots'
$Rootfs = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$RootfsSums = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/SHA256SUMS'

function Passo($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Falha($texto) {
    Write-Host "`n$texto" -ForegroundColor Red
    throw 'Instalacao interrompida.'
}
function Distros() { (& wsl.exe -l -q 2>$null) -replace "`0", '' | Where-Object { $_ } | ForEach-Object { $_.Trim() } }
function NoLinux([string]$comando) {
    & wsl.exe -d $Distro -u root -e bash -lc $comando
    if ($LASTEXITCODE -ne 0) { Falha "Falhou dentro do Linux (codigo $LASTEXITCODE): $comando" }
}

Write-Host 'Instalador dos bots da Lake of Rage' -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $Pasta | Out-Null

# 1. WSL
Passo 'Verificando o WSL'
& wsl.exe --status *> $null
if ($LASTEXITCODE -ne 0) {
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        Falha 'O WSL ainda nao esta instalado. Feche esta janela, abra o PowerShell como administrador (botao direito > Executar como administrador) e rode o comando de novo.'
    }
    Passo 'Instalando o WSL (o Windows pode pedir para reiniciar)'
    & wsl.exe --install --no-distribution
    # Depois de reiniciar, o instalador abre sozinho para continuar.
    $volta = "irm $Raw/windows/instalar.ps1 | iex"
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'LoRBots' -Force `
        -Value "powershell.exe -NoExit -ExecutionPolicy Bypass -Command `"$volta`"" | Out-Null
    Write-Host "`nWSL instalado. REINICIE o computador; o instalador continua sozinho depois." -ForegroundColor Yellow
    Read-Host 'Aperte Enter para fechar'
    return
}

# 2. Distribuicao LoRBots
if ((Distros) -notcontains $Distro) {
    $arq = Join-Path $Pasta 'ubuntu-24.04.rootfs.tar.gz'
    # O SHA256SUMS vem como binario para o PowerShell 5; salvar em arquivo e ler como texto.
    $somas = Join-Path $Pasta 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri $RootfsSums -OutFile $somas
    $linha = Get-Content $somas | Where-Object { $_ -match '^([0-9a-fA-F]{64})\s+\*?ubuntu-noble-wsl-amd64-24\.04lts\.rootfs\.tar\.gz$' } | Select-Object -First 1
    if (-not $linha) { Falha 'Nao achei a soma SHA256 do Ubuntu no site da Canonical. Tente de novo mais tarde.' }
    $esperado = ($linha -split '\s+')[0].ToUpper()
    # Um download anterior ja certo e reaproveitado.
    if (-not (Test-Path $arq) -or (Get-FileHash -Algorithm SHA256 $arq).Hash -ne $esperado) {
        Passo 'Baixando o Ubuntu 24.04 (~350 MB)'
        Invoke-WebRequest -UseBasicParsing -Uri $Rootfs -OutFile $arq
    }
    $obtido = (Get-FileHash -Algorithm SHA256 $arq).Hash
    if ($obtido -ne $esperado) { Falha "O download do Ubuntu veio corrompido (SHA256 $obtido, esperado $esperado). Rode o instalador de novo." }
    Passo "Criando a distribuicao $Distro"
    & wsl.exe --import $Distro (Join-Path $Pasta 'wsl') $arq --version 2
    if ($LASTEXITCODE -ne 0) { Falha 'Nao consegui criar a distribuicao do WSL.' }
    Remove-Item $arq, $somas
}
# systemd ligado (os bots rodam como servicos) e root como usuario padrao.
NoLinux "printf '[boot]\nsystemd=true\n[user]\ndefault=root\n' > /etc/wsl.conf"
& wsl.exe --terminate $Distro | Out-Null
Start-Sleep -Seconds 3
$pid1 = (& wsl.exe -d $Distro -u root -e ps -p 1 -o comm= | Out-String).Trim()
if ($pid1 -ne 'systemd') {
    # WSL antigo demais para systemd. O "wsl --update" fecha TODAS as distribuicoes (derruba um
    # bot no meio da partida), entao so roda quando precisa.
    Passo 'Atualizando o WSL (fecha as distribuicoes Linux abertas)'
    & wsl.exe --update
    & wsl.exe --terminate $Distro | Out-Null
    Start-Sleep -Seconds 3
    $pid1 = (& wsl.exe -d $Distro -u root -e ps -p 1 -o comm= | Out-String).Trim()
}
if ($pid1 -ne 'systemd') { Falha "O WSL deste PC nao ligou o systemd (achei '$pid1'). Rode 'wsl --update' como administrador e tente de novo." }

# 3. Bot (dentro do Linux): o mesmo script do botao Atualizar do painel.
Passo 'Instalando o bot no Linux (Node, Python, PyTorch, simulador; a primeira vez leva uns 10-20 min)'
NoLinux "curl -fsSL $Raw/linux/atualizar.sh -o /tmp/lor-atualizar.sh && LOR_RAMO=$Ramo bash /tmp/lor-atualizar.sh --forcar"

# 4. Painel
Passo 'Instalando o painel'
Invoke-WebRequest -UseBasicParsing -Uri "$Raw/windows/Painel.ps1" -OutFile (Join-Path $Pasta 'Painel.ps1')
Invoke-WebRequest -UseBasicParsing -Uri "$Raw/VERSION" -OutFile (Join-Path $Pasta 'VERSION')
# A branch escolhida (main, ou outra num teste) fica gravada para o botao Atualizar do painel.
Set-Content -Path (Join-Path $Pasta 'ramo.txt') -Value $Ramo -Encoding ASCII
$shell = New-Object -ComObject WScript.Shell
$destinos = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
foreach ($d in $destinos) {
    $atalho = $shell.CreateShortcut((Join-Path $d 'Painel LoR Bots.lnk'))
    $atalho.TargetPath = 'powershell.exe'
    $atalho.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Pasta\Painel.ps1`""
    $atalho.WorkingDirectory = $Pasta
    $atalho.IconLocation = 'shell32.dll,137'
    $atalho.Save()
}

Write-Host "`nPronto! Abrindo o Painel LoR Bots (tambem tem um atalho na Area de Trabalho)." -ForegroundColor Green
Write-Host 'No painel: coloque a conta e a senha do Showdown do bot, o codigo da coleta que o Thiago passou, e clique em Ligar.'
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Pasta\Painel.ps1`""
