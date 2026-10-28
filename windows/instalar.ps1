# Instalador dos bots da Lake of Rage para Windows 10/11.
#
# Abra o PowerShell (de preferencia como administrador) e cole:
#   irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/main/windows/instalar.ps1 | iex
#
# O que ele faz: liga o WSL (se preciso), cria uma distribuicao Linux so para os bots
# ("LoRBots", Ubuntu 24.04), instala o bot dentro dela e poe o "Painel LoR Bots" na Area de
# Trabalho. Rodar de novo e seguro: ele pula o que ja esta pronto.
#
# O Linux dos bots (~3 GB, cresce com o tempo) fica no C: se sobrar espaco; com o C: apertado vai
# sozinho para o disco com mais espaco livre (X:\LoRBots\wsl) e, se ja estava no C:, e mudado de
# disco. Para escolher a pasta na mao:
#   $env:LOR_PASTA_WSL='D:\LoRBots'; irm .../windows/instalar.ps1 | iex
# (Arquivo sem acentos de proposito: o "irm | iex" do PowerShell 5 nao gosta.)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # o Invoke-WebRequest fica 10x mais lento com a barra
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# estavel = a main depois que os testes do GitHub passaram nela; outra branch so para testes
$Ramo = if ($env:LOR_RAMO) { $env:LOR_RAMO } else { 'estavel' }
$Raw = "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$Ramo"
$Distro = 'LoRBots'
# Painel, versao e marcas (poucos KB) ficam sempre aqui; o Linux dos bots pode ir para outro disco.
$Pasta = Join-Path $env:LOCALAPPDATA 'LoRBots'
$GB = 1GB
$PrecisaGB = 8     # Linux dos bots (~3 GB) + o Ubuntu baixado durante a criacao + folga para crescer
$CApertadoGB = 15  # com menos que isto livre no C:, a distribuicao vai para outro disco
$Rootfs = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$RootfsSums = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current/SHA256SUMS'

function Passo($texto) { Write-Host "`n==> $texto" -ForegroundColor Cyan }
function Falha($texto) {
    Write-Host "`n$texto" -ForegroundColor Red
    throw 'Instalacao interrompida.'
}
# O wsl.exe escreve avisos no stderr (ex.: "O Subsistema do Windows para Linux nao esta
# instalado"). Com $ErrorActionPreference = 'Stop' o PowerShell 5 transforma isso num erro que
# encerra o instalador, entao as chamadas ao wsl.exe rodam com 'Continue' e olham o codigo de saida.
function Wsl {
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & wsl.exe @args } catch { $global:LASTEXITCODE = 1 } finally { $ErrorActionPreference = $antes }
}
# O mesmo, sem mostrar o stderr (para perguntas: "o WSL existe?", "quais distribuicoes?").
function WslQuieto {
    $antes = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & wsl.exe @args 2>$null } catch { $global:LASTEXITCODE = 1 } finally { $ErrorActionPreference = $antes }
}
function Distros() { (WslQuieto -l -q) -replace "`0", '' | Where-Object { $_ } | ForEach-Object { $_.Trim() } }
function EAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# O comando que roda o instalador de novo (na mesma branch, se era um teste).
$Volta = "`$env:LOR_RAMO='$Ramo'; irm $Raw/windows/instalar.ps1 | iex"
if ($env:LOR_PASTA_WSL) { $Volta = "`$env:LOR_PASTA_WSL='$($env:LOR_PASTA_WSL)'; $Volta" }
# Depois de reiniciar, o instalador abre sozinho para continuar.
function ContinuarDepoisDeReiniciar {
    New-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'LoRBots' -Force `
        -Value "powershell.exe -NoExit -ExecutionPolicy Bypass -Command `"$Volta`"" | Out-Null
}
function PedirReinicio($texto) {
    ContinuarDepoisDeReiniciar
    Write-Host "`n$texto REINICIE o computador; o instalador continua sozinho depois." -ForegroundColor Yellow
    [void](Read-Host 'Aperte Enter para fechar')
}
# Abre o instalador de novo como administrador (o Windows pergunta "Sim/Nao"). Devolve $true se
# abriu outra janela, e entao esta para por aqui.
function ReabrirComoAdmin($motivo) {
    if (EAdmin) { return $false }
    Write-Host "`n$motivo O Windows vai perguntar se pode abrir como administrador: clique em Sim." -ForegroundColor Yellow
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoExit -ExecutionPolicy Bypass -Command `"$Volta`""
    } catch {
        Falha 'Sem permissao de administrador nao da para continuar. Rode o instalador de novo e clique em Sim.'
    }
    Write-Host 'O instalador continua na janela nova; esta pode ser fechada.' -ForegroundColor Yellow
    return $true
}
# O WSL 2 precisa da "Plataforma de Maquina Virtual" do Windows e da virtualizacao ligada na BIOS.
# Sem elas o "wsl --import" falha com HCS_E_SERVICE_NOT_AVAILABLE. Liga o que o Windows consegue
# ligar sozinho e pede para reiniciar. Devolve $true se o instalador deve parar (reinicio pendente).
function ConferirVirtualizacao([switch]$DepoisDeFalhar) {
    $marca = Join-Path $Pasta 'virtualizacao-tentada.txt'
    $tentado = if (Test-Path $marca) { (Get-Content $marca) } else { @() }
    $recurso = try { (Get-CimInstance Win32_OptionalFeature -Filter "Name='VirtualMachinePlatform'").InstallState } catch { 1 }
    if ($recurso -ne 1) {
        if ($tentado -contains 'recurso') { Falha 'Liguei a Plataforma de Maquina Virtual, mas o Windows ainda nao a ativou. Reinicie o computador (Reiniciar, nao Desligar) e rode o instalador de novo.' }
        if (ReabrirComoAdmin 'Falta ligar a Plataforma de Maquina Virtual do Windows.') { return $true }
        Passo 'Ligando a Plataforma de Maquina Virtual do Windows'
        & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
        # 3010 = ligado, falta reiniciar
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { Falha "Nao consegui ligar a Plataforma de Maquina Virtual (dism codigo $LASTEXITCODE)." }
        Add-Content $marca 'recurso'
        PedirReinicio 'Plataforma de Maquina Virtual ligada.'
        return $true
    }
    # So depois de o WSL falhar: num PC que ja roda WSL 2 o hypervisor esta sempre presente.
    if (-not $DepoisDeFalhar) { return $false }
    $hypervisor = try { (Get-CimInstance Win32_ComputerSystem).HypervisorPresent } catch { $true }
    if ($hypervisor) { return $false }
    $bios = try { (Get-CimInstance Win32_Processor | Select-Object -First 1).VirtualizationFirmwareEnabled } catch { $null }
    if ($bios -eq $false) {
        ContinuarDepoisDeReiniciar
        Falha ("A virtualizacao do processador esta DESLIGADA na BIOS deste PC, e o Windows nao consegue ligar isso sozinho.`n" +
            "1. Reinicie e, logo ao ligar, aperte a tecla da BIOS (geralmente Del, F2, F10 ou F1; em notebook as vezes Esc ou F12).`n" +
            "2. Procure 'Intel Virtualization Technology' / 'VT-x' (Intel) ou 'SVM Mode' / 'AMD-V' (AMD), normalmente em Advanced ou CPU Configuration.`n" +
            "3. Mude para Enabled, salve (geralmente F10) e saia.`n" +
            'Quando o Windows abrir, o instalador continua sozinho.')
    }
    # Virtualizacao ligada mas o Windows nao subiu o hypervisor (hypervisorlaunchtype off).
    if ($tentado -contains 'hypervisor') { Falha 'O Windows nao esta ligando a virtualizacao mesmo depois de reiniciar. Confira se ela esta ligada na BIOS (Intel VT-x ou AMD SVM) e rode o instalador de novo.' }
    if (ReabrirComoAdmin 'O Windows esta com a virtualizacao desligada.') { return $true }
    Passo 'Ligando a virtualizacao do Windows (hypervisor)'
    & bcdedit.exe /set hypervisorlaunchtype auto | Out-Null
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui ligar o hypervisor do Windows (bcdedit codigo $LASTEXITCODE)." }
    Add-Content $marca 'hypervisor'
    PedirReinicio 'Virtualizacao ligada.'
    return $true
}
function NoLinux([string]$comando) {
    Wsl -d $Distro -u root -e bash -lc $comando
    if ($LASTEXITCODE -ne 0) { Falha "Falhou dentro do Linux (codigo $LASTEXITCODE): $comando" }
}

# --- Em que disco fica o Linux dos bots ---
$Sistema = $env:SystemDrive.TrimEnd('\').ToUpper()  # "C:"
function LivreGB([string]$unidade) {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$unidade'" -ErrorAction SilentlyContinue
    if ($d) { [math]::Round($d.FreeSpace / $GB, 1) } else { 0 }
}
# Pasta padrao da distribuicao: no C: se ha espaco; se nao, no disco local (NTFS, nao removivel)
# com mais espaco livre. Devolve $null se nenhum disco tem $PrecisaGB livres.
function PastaWslPadrao {
    if ($env:LOR_PASTA_WSL) { return (Join-Path $env:LOR_PASTA_WSL 'wsl') }
    $noC = Join-Path $Pasta 'wsl'
    if ((LivreGB $Sistema) -ge $CApertadoGB) { return $noC }
    $outro = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Where-Object { $_.DeviceID -ne $Sistema -and $_.FileSystem -eq 'NTFS' -and $_.FreeSpace -ge $PrecisaGB * $GB } |
        Sort-Object FreeSpace -Descending | Select-Object -First 1
    if ($outro) { return (Join-Path ($outro.DeviceID + '\') 'LoRBots\wsl') }
    if ((LivreGB $Sistema) -ge $PrecisaGB) { return $noC }
    return $null
}
# Onde esta a distribuicao LoRBots ja criada (registro do WSL), ou $null.
function PastaWslAtual {
    $chaves = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' -ErrorAction SilentlyContinue
    foreach ($c in $chaves) {
        $p = Get-ItemProperty $c.PSPath -ErrorAction SilentlyContinue
        if ($p.DistributionName -eq $Distro -and $p.BasePath) { return ($p.BasePath -replace '^\\\\\?\\', '') }
    }
    return $null
}
function Unidade([string]$caminho) { ([IO.Path]::GetPathRoot($caminho)).TrimEnd('\').ToUpper() }
function MesmaPasta($a, $b) { ([IO.Path]::GetFullPath($a).TrimEnd('\')) -eq ([IO.Path]::GetFullPath($b).TrimEnd('\')) }
function FaltaEspaco {
    Falha ("Falta espaco em disco: o Linux dos bots precisa de uns $PrecisaGB GB livres e o $Sistema tem $(LivreGB $Sistema) GB, " +
        "sem outro disco com espaco.`nLibere espaco (Configuracoes > Sistema > Armazenamento > Arquivos temporarios) ou ligue um HD/SSD " +
        "e rode o instalador de novo.")
}
# O WSL guarda a memoria de troca (swap.vhdx, ate 1/4 da RAM) no TEMP do C:. Com o Linux em outro
# disco por falta de espaco, ela vai junto. Vale para todo o WSL deste usuario, entao so mexe se o
# .wslconfig ainda nao escolheu um lugar.
function SwapForaDoC([string]$pastaWsl) {
    $cfg = Join-Path $env:USERPROFILE '.wslconfig'
    $linhas = @(if (Test-Path $cfg) { Get-Content $cfg })
    if ($linhas -match '^\s*swapFile\s*=') { return }
    $swap = (Join-Path (Split-Path $pastaWsl -Parent) 'swap.vhdx') -replace '\\', '\\'
    $i = [array]::FindIndex([string[]]$linhas, [Predicate[string]]{ param($l) $l -match '^\s*\[wsl2\]\s*$' })
    if ($i -ge 0) {
        $linhas = @($linhas[0..$i]) + "swapFile=$swap" + @($linhas | Select-Object -Skip ($i + 1))
    } else {
        if ($linhas.Count) { $linhas += '' }
        $linhas = $linhas + '[wsl2]' + "swapFile=$swap"
    }
    Set-Content -Path $cfg -Value $linhas -Encoding ASCII
}
# Muda a distribuicao ja criada para outra pasta (os bots param enquanto isso).
function MoverDistro([string]$destino) {
    Passo "Mudando o Linux dos bots para $destino (os bots param por alguns minutos)"
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    Wsl --terminate $Distro | Out-Null
    # WSL 2.3 ou mais novo tem o --move pronto.
    Wsl --manage $Distro --move $destino
    if ($LASTEXITCODE -eq 0) { return }
    # WSL antigo: exporta para um arquivo no disco novo, apaga a antiga e importa de novo. Se a
    # importacao falhar, o arquivo fica la e o instalador o usa na proxima vez (ver passo 2).
    $tar = Join-Path $destino 'LoRBots-exportado.tar'
    Wsl --export $Distro $tar
    if ($LASTEXITCODE -ne 0) { Remove-Item $tar -ErrorAction SilentlyContinue; Falha 'Nao consegui copiar o Linux dos bots para o outro disco. Nada foi apagado; rode o instalador de novo.' }
    Wsl --unregister $Distro | Out-Null
    Wsl --import $Distro $destino $tar --version 2
    if ($LASTEXITCODE -ne 0) { Falha "Nao consegui terminar a mudanca de disco. A copia esta em $tar: rode o instalador de novo que ele a usa." }
    Remove-Item $tar
}

Write-Host 'Instalador dos bots da Lake of Rage' -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $Pasta | Out-Null

# 1. WSL
Passo 'Verificando o WSL'
$global:LASTEXITCODE = 1
WslQuieto --status | Out-Null
if ($LASTEXITCODE -ne 0) {
    if (ReabrirComoAdmin 'O WSL ainda nao esta instalado.') { return }
    Passo 'Instalando o WSL (o Windows pode pedir para reiniciar)'
    Wsl --install --no-distribution
    if ($LASTEXITCODE -ne 0) {
        # Windows 10 mais antigo nao conhece o --no-distribution: liga os recursos do Windows direto.
        # O kernel do WSL vem depois, no "wsl --update" antes de criar a distribuicao.
        & dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart | Out-Null
        & dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart | Out-Null
    }
    PedirReinicio 'WSL instalado.'
    return
}

# 2. Distribuicao LoRBots
$atual = if ((Distros) -contains $Distro) { PastaWslAtual } else { $null }
if ($atual) {
    # Ja existe. Muda de disco se pediram outra pasta, ou se esta no C: e o C: esta quase cheio.
    $destino = $null
    if ($env:LOR_PASTA_WSL) {
        $destino = Join-Path $env:LOR_PASTA_WSL 'wsl'
        if (MesmaPasta $destino $atual) { $destino = $null }
    } elseif ((Unidade $atual) -eq $Sistema -and (LivreGB $Sistema) -lt 5) {
        $destino = PastaWslPadrao
        if ($destino -and (Unidade $destino) -eq $Sistema) { $destino = $null }
    }
    if ($destino) {
        MoverDistro $destino
        if ((Unidade $destino) -ne $Sistema) { SwapForaDoC $destino }
    }
}
if ((Distros) -notcontains $Distro) {
    # Sobras de uma tentativa que falhou (ex.: C: cheio no meio): sem distribuicao registrada, a
    # pasta e so nossa, e o Ubuntu baixado antes no C: ocupa ~350 MB.
    $velhaNoC = Join-Path $Pasta 'wsl'
    if (Test-Path (Join-Path $velhaNoC 'ext4.vhdx')) { Remove-Item (Join-Path $velhaNoC 'ext4.vhdx') -Force -ErrorAction SilentlyContinue }
    # Uma mudanca de disco que parou no meio deixou a copia: usa ela em vez de comecar do zero.
    $pastasCopia = @($velhaNoC) + @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path ($_.DeviceID + '\') 'LoRBots\wsl' })
    if ($env:LOR_PASTA_WSL) { $pastasCopia = @(Join-Path $env:LOR_PASTA_WSL 'wsl') + $pastasCopia }
    $PastaWsl = $pastasCopia | Where-Object { Test-Path (Join-Path $_ 'LoRBots-exportado.tar') } | Select-Object -First 1
    if (-not $PastaWsl) { $PastaWsl = PastaWslPadrao }
    if (-not $PastaWsl) { FaltaEspaco }
    New-Item -ItemType Directory -Force -Path $PastaWsl | Out-Null
    if (-not (MesmaPasta $PastaWsl $velhaNoC)) {
        Remove-Item (Join-Path $Pasta 'ubuntu-24.04.rootfs.tar.gz'), (Join-Path $Pasta 'SHA256SUMS') -ErrorAction SilentlyContinue
    }
    if ((Unidade $PastaWsl) -ne $Sistema) {
        Write-Host "O $Sistema tem $(LivreGB $Sistema) GB livres: o Linux dos bots vai ficar em $PastaWsl." -ForegroundColor Yellow
        SwapForaDoC $PastaWsl
    }
    $copia = Join-Path $PastaWsl 'LoRBots-exportado.tar'
    if (Test-Path $copia) {
        Passo "Recriando a distribuicao $Distro a partir de $copia"
        Wsl --import $Distro $PastaWsl $copia --version 2
        if ($LASTEXITCODE -ne 0) { Falha "Nao consegui recriar a distribuicao a partir de $copia. Reinicie o computador e rode o instalador de novo." }
        Remove-Item $copia
    }
}
if ((Distros) -notcontains $Distro) {
    # O Ubuntu baixado (~350 MB) fica no mesmo disco da distribuicao, nao no C: apertado.
    $arq = Join-Path $PastaWsl 'ubuntu-24.04.rootfs.tar.gz'
    # O SHA256SUMS vem como binario para o PowerShell 5; salvar em arquivo e ler como texto.
    $somas = Join-Path $PastaWsl 'SHA256SUMS'
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
    if (ConferirVirtualizacao) { return }
    Passo "Criando a distribuicao $Distro"
    Wsl --import $Distro $PastaWsl $arq --version 2
    if ($LASTEXITCODE -ne 0) {
        if (ConferirVirtualizacao -DepoisDeFalhar) { return }
        # WSL recem-ligado as vezes ainda nao tem o kernel: atualiza e tenta de novo.
        # (Aqui ainda nao ha bot nenhum rodando, entao o --update nao derruba partida.)
        Passo 'Atualizando o WSL'
        Wsl --update
        Wsl --import $Distro $PastaWsl $arq --version 2
    }
    if ($LASTEXITCODE -ne 0) { Falha 'Nao consegui criar a distribuicao do WSL. Reinicie o computador e rode o instalador de novo.' }
    Remove-Item $arq, $somas
}
# systemd ligado (os bots rodam como servicos) e root como usuario padrao.
NoLinux "printf '[boot]\nsystemd=true\n[user]\ndefault=root\n' > /etc/wsl.conf"
Wsl --terminate $Distro | Out-Null
Start-Sleep -Seconds 3
$pid1 = (Wsl -d $Distro -u root -e ps -p 1 -o comm= | Out-String).Trim()
if ($pid1 -ne 'systemd') {
    # WSL antigo demais para systemd. O "wsl --update" fecha TODAS as distribuicoes (derruba um
    # bot no meio da partida), entao so roda quando precisa.
    Passo 'Atualizando o WSL (fecha as distribuicoes Linux abertas)'
    Wsl --update
    Wsl --terminate $Distro | Out-Null
    Start-Sleep -Seconds 3
    $pid1 = (Wsl -d $Distro -u root -e ps -p 1 -o comm= | Out-String).Trim()
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
# O Painel.vbs abre o painel sem janela do PowerShell (com o Windows Terminal como console padrao, o
# -WindowStyle Hidden ainda abre uma janela). O proprio painel reescreve este arquivo quando abre.
$vbs = Join-Path $Pasta 'Painel.vbs'
Set-Content -Path $vbs -Encoding Unicode -Value @(
    'Set sh = CreateObject("WScript.Shell")',
    'args = ""',
    'For Each a In WScript.Arguments : args = args & " " & a : Next',
    ('sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{0}""" & args, 0, False' -f (Join-Path $Pasta 'Painel.ps1'))
)
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'
$shell = New-Object -ComObject WScript.Shell
$destinos = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
foreach ($d in $destinos) {
    $atalho = $shell.CreateShortcut((Join-Path $d 'Painel LoR Bots.lnk'))
    $atalho.TargetPath = $wscript
    $atalho.Arguments = "`"$vbs`""
    $atalho.WorkingDirectory = $Pasta
    $atalho.IconLocation = 'shell32.dll,137'
    $atalho.Save()
}

# Se sobrou um "continuar depois de reiniciar" (ex.: o aviso da BIOS), nao precisa mais.
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'LoRBots' -ErrorAction SilentlyContinue
Write-Host "`nPronto! Abrindo o Painel LoR Bots (tambem tem um atalho na Area de Trabalho)." -ForegroundColor Green
Write-Host 'No painel: coloque a conta e a senha do Showdown do bot, o codigo da coleta que o Thiago passou, e clique em Ligar.'
Start-Process $wscript -ArgumentList "`"$vbs`""
