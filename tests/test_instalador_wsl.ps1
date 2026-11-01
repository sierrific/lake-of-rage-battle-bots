# Exercita o fluxo real de criacao com WSL/registro/rede simulados; nunca chama o WSL real.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot) 'windows\instalar.ps1'
$source = [IO.File]::ReadAllText($path)
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
$inicio = $source.IndexOf('# 2. Distribuicao LoRBots')
$fim = $source.IndexOf('# Fora do C:', $inicio)
$criar = [scriptblock]::Create($source.Substring($inicio, $fim - $inicio))
function Falha($texto) { throw $texto }
function Passo($texto) { }
function RegistrosWsl { $script:registros }
function WslQuieto {
    if ($args[0] -eq '--status') { $global:LASTEXITCODE = 0; return }
    $script:consultas++
    $global:LASTEXITCODE = if ($script:consultas -ge $script:falharNa) { -1 } else { 0 }
    $script:listagem
}
function Wsl { throw 'PROIBIDO: importar ou alterar WSL' }
function Invoke-WebRequest { throw 'PROIBIDO: download' }
function PastaWslPadrao { Join-Path $Pasta 'wsl' }
function Get-CimInstance { @() }
# Nada fora da pasta temporaria: o .wslconfig real do usuario nunca e tocado.
function SwapForaDoC { }
function Assert($ok, $texto) { if (-not $ok) { throw $texto } }
$Distro = 'LoRBots'
$Sistema = $env:SystemDrive.TrimEnd('\').ToUpper()
$Pasta =Join-Path ([IO.Path]::GetTempPath()) ('lor-installer-' + [guid]::NewGuid().ToString('N'))
$originalEnv = $env:LOR_PASTA_WSL
$lorBots = { [pscustomobject]@{ DistributionName = 'LoRBots'; BasePath = (Join-Path $Pasta 'wsl') } }
function Rodar {
    $script:consultas = 0
    try { & $criar; '' } catch { $_.Exception.Message }
}
function DiscoIntacto($caso) {
    # O disco existente nunca e apagado nem sobrescrito: fica no lugar ou guardado ao lado.
    $achados = @(Get-ChildItem -LiteralPath (Join-Path $Pasta 'wsl') -Filter 'ext4.vhdx*' |
        Where-Object { [IO.File]::ReadAllText($_.FullName) -eq 'disco existente' })
    Assert ($achados.Count -eq 1) "$caso perdeu o VHDX"
    $achados[0]
}
try {
    $env:LOR_PASTA_WSL = $null
    [void][IO.Directory]::CreateDirectory((Join-Path $Pasta 'wsl'))
    $vhd = Join-Path $Pasta 'wsl\ext4.vhdx'
    [IO.File]::WriteAllText($vhd, 'disco existente')

    # LoRBots registrada e o "wsl -l" falha (na primeira consulta ou numa seguinte), ou lista outra
    # coisa: para antes de qualquer importacao, download ou mudanca no disco.
    foreach ($caso in @('falha-inicial', 'falha-posterior', 'malformada', 'listagem-sem-lorbots')) {
        $script:registros = @(& $lorBots)
        $script:falharNa = 100
        $script:listagem = @('L`0o`0R`0B`0o`0t`0s`0'.Replace('`0', "`0"))
        switch ($caso) {
            'falha-inicial' { $script:falharNa = 1 }
            'falha-posterior' { $script:falharNa = 2 }
            'malformada' { $script:listagem = @('Erro desconhecido: ??') }
            'listagem-sem-lorbots' { $script:listagem = @('Ubuntu') }
        }
        $erro = Rodar
        if ($caso -eq 'falha-posterior') {
            # A primeira consulta achou a LoRBots: segue para a mudanca de disco (nao pedida aqui),
            # e a consulta seguinte, que falha, interrompe.
            Assert ($erro -match 'enumerar') "$caso nao interrompeu: $erro"
        } else {
            Assert ($erro -and $erro -notmatch 'PROIBIDO') "$caso nao interrompeu no limite correto: $erro"
        }
        Assert ([IO.File]::ReadAllText($vhd) -eq 'disco existente') "$caso alterou o VHDX"
        Write-Host "PASS $caso"
    }

    # PC novo: nenhuma distribuicao, e o "wsl -l" sai com erro. Segue a instalacao (ate o download).
    $script:registros = @(); $script:falharNa = 1; $script:listagem = @('Nenhuma distribuicao instalada.')
    Remove-Item -LiteralPath $vhd
    $erro = Rodar
    Assert ($erro -match 'PROIBIDO: download') "PC sem distribuicao nao seguiu para a instalacao: $erro"
    Write-Host 'PASS pc-sem-distribuicao'

    # Disco sem registro (importacao que parou no meio): guardado com outro nome, instalacao segue.
    [IO.File]::WriteAllText($vhd, 'disco existente')
    $script:registros = @(); $script:falharNa = 100; $script:listagem = @('Ubuntu')
    $erro = Rodar
    Assert ($erro -match 'PROIBIDO: download') "Disco orfao bloqueou a instalacao: $erro"
    $guardado = DiscoIntacto 'orfao'
    Assert ($guardado.Name -like 'ext4.vhdx.preservado-*') 'Disco orfao nao foi guardado com outro nome'
    Write-Host 'PASS orfao-preservado'

    $script:consultas = 0; $script:falharNa = 100
    $script:registros = @(& $lorBots)
    $script:listagem = @("L`0o`0R`0B`0o`0t`0s`0")
    Assert (@(Distros)[0] -eq 'LoRBots') 'Listagem UTF-16 valida rejeitada'
    Assert ((PastaWslAtual) -eq (Join-Path $Pasta 'wsl')) 'Instalacao existente nao encontrada'
    $script:registros = @()
    ConferirDestinoWsl (Join-Path $Pasta 'novo')
    $script:registros = @([pscustomobject]@{ DistributionName = 'Outra'; BasePath = (Join-Path $Pasta 'novo') })
    $recusado = $false
    try { ConferirDestinoWsl (Join-Path $Pasta 'novo') } catch { $recusado = $true }
    Assert $recusado 'Aceitou destino de outra distribuicao'
    Write-Host 'PASS instalacao existente'
} finally {
    $env:LOR_PASTA_WSL = $originalEnv
    # Somente a pasta temporaria criada por este teste.
    $resolvido = [IO.Path]::GetFullPath($Pasta)
    if ($resolvido.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $resolvido -Leaf) -like 'lor-installer-*') {
        Remove-Item -LiteralPath $resolvido -Recurse -Force
    }
}
