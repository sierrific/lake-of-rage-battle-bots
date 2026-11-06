$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in @('Codigo-Coleta', 'Consultar-Atualizacao', 'Comando-Atualizacao', 'Atualizar-Painel')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$script:sha = 'a' * 40
$script:urls = New-Object Collections.Generic.List[string]
$script:codigoSalvo = 'codigo-teste'
function Invoke-Painel {
    param([string[]]$Argumentos, [string]$Entrada = '')
    Assert (($Argumentos -join ' ') -eq 'codigo-atual') "painel.sh chamado com: $Argumentos"
    [pscustomobject]@{ Codigo = 0; Saida = "codigo=$($script:codigoSalvo)"; Erro = '' }
}
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $Headers, [switch]$UseBasicParsing)
    $script:urls.Add($Uri)
    Assert ($Uri -like 'https://vps.teste/coleta/bots/*') "baixou de fora da VPS: $Uri"
    Assert ($Headers -and $Headers.Authorization -eq 'Bearer codigo-teste') "sem o codigo da coleta: $Uri"
    if ($Uri -like '*/ramo/*') { return [pscustomobject]@{ Content = ('{"sha":"' + $script:sha + '"}') } }
    Assert ($Uri -like ('*/' + ('a' * 40) + '/*')) 'Leu branch mutavel depois de resolver SHA'
    if ($Uri -like '*/VERSION') { return [pscustomobject]@{ Content = '2' } }
    if ($OutFile) { [IO.File]::WriteAllText($OutFile, '# painel do commit a'); return }
    throw "URL inesperada: $Uri"
}
function Confirmar($texto) { $true }
function Mensagem($texto) { Write-Host $texto }
function Encerrar-ConsultaEstado { }
function Manter-Vivo { }
function Atualizar-Tela { }
function Start-Process {
    param($FilePath, $ArgumentList, [switch]$PassThru)
    if ($FilePath -ne 'wsl.exe') { return }
    Assert ($ArgumentList -match 'echo ([A-Za-z0-9+/=]+) \| base64') 'Bootstrap sem script codificado'
    $bash = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))
    Assert ($bash.Contains("https://vps.teste/coleta/bots/$(('a' * 40))/linux/atualizar.sh")) 'Updater de outra revisao'
    Assert (-not $bash.Contains('codigo-teste')) 'O codigo da coleta foi na linha de comando do Windows'
    Assert ($bash.Contains('/etc/lor-bots/coleta.env')) 'O Linux nao le o codigo salvo'
    Assert ($bash.Contains("LOR_REVISION='$(('a' * 40))' LOR_VERSION='2'")) 'Runtime recebeu outra revisao/versao'
    Assert ($bash.Contains('-o "$script"')) 'Script executado antes de completar download'
    # A mesma raiz da coleta que o instalador passa (revisao de codigo de 06/11).
    Assert ($bash.Contains("LOR_VPS='https://vps.teste/coleta' bash")) 'o Linux nao recebeu a VPS do painel'
    # Simula outra versao publicada enquanto o runtime atualiza.
    $script:versaoNova = '999'
    $p = [pscustomobject]@{ Handle = 1; HasExited = $true; ExitCode = $script:exitCode }
    $p | Add-Member ScriptMethod Dispose { }
    $p
}
$Pasta = Join-Path ([IO.Path]::GetTempPath()) ('lor-update-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Pasta)
$ArquivoVersao = Join-Path $Pasta 'VERSION'
$Lancador = Join-Path $Pasta 'Painel.vbs'
$Ramo = 'estavel'; $Distro = 'LoRBots'; $Vps = 'https://vps.teste/coleta/bots'
$timer = New-Object PSObject
$timer | Add-Member ScriptMethod Stop { }
$timer | Add-Member ScriptMethod Start { }
$trava = New-Object PSObject
$trava | Add-Member ScriptMethod ReleaseMutex { }
$form = New-Object PSObject
$form | Add-Member ScriptMethod Close { }
$lAtualizar = [pscustomobject]@{ Text = ''; Enabled = $true }
foreach ($name in @('bLigar','bVer','bDesligar','bAgora','bAplicar','bConta','bCodigo','xDiscord','xChat','xBloquearBots','xEsperarBots','xEsperarColmeia','xPausa','xDecisoesInstantaneas','bDesafiar')) {
    Set-Variable $name ([pscustomobject]@{ Enabled = $true })
}
try {
    foreach ($codigo in @(1, 0)) {
        $script:sha = 'a' * 40
        $script:exitCode = $codigo
        [IO.File]::WriteAllText((Join-Path $Pasta 'Painel.ps1'), '# anterior')
        Set-Content $ArquivoVersao '1'
        Consultar-Atualizacao
        $script:sha = 'b' * 40
        Atualizar-Painel
        if ($codigo) {
            Assert ((Get-Content $ArquivoVersao -Raw).Trim() -eq '1') 'Falha Linux ativou versao nova'
            Assert ((Get-Content (Join-Path $Pasta 'Painel.ps1') -Raw) -eq '# anterior') 'Falha Linux trocou painel'
        } else {
            Assert ((Get-Content $ArquivoVersao -Raw).Trim() -eq '2') 'Versao gravada veio da branch mutada'
            Assert ((Get-Content (Join-Path $Pasta 'REVISION') -Raw).Trim() -eq ('a' * 40)) 'SHA gravado diverge'
            Assert ((Get-Content (Join-Path $Pasta 'Painel.ps1') -Raw) -eq '# painel do commit a') 'Painel ativado incorreto'
        }
    }
    $script:sha = 'invalido'
    try { Consultar-Atualizacao; throw 'aceitou SHA invalido' } catch {
        Assert (-not $script:atualizacao -and -not $script:versaoNova) 'Consulta falha reutilizou metadados antigos'
    }
    # Sem codigo salvo: nao consulta nada e avisa que falta o codigo.
    $script:sha = 'a' * 40
    $script:codigoSalvo = ''
    $script:urls.Clear()
    try { Consultar-Atualizacao; throw 'consultou sem codigo' } catch {
        Assert ($script:semCodigo) 'Nao marcou a falta do codigo'
        Assert ($script:urls.Count -eq 0) 'Pediu a VPS sem codigo'
    }
    Write-Host 'PASS SHA unico, branch mutada, falha Linux preserva painel e metadados invalidos'
} finally {
    $resolvido = [IO.Path]::GetFullPath($Pasta)
    if ($resolvido.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $resolvido -Leaf) -like 'lor-update-*') {
        Remove-Item -LiteralPath $resolvido -Recurse -Force
    }
}
