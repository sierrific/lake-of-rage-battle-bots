$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in @('Consultar-Atualizacao', 'Comando-Atualizacao', 'Atualizar-Painel')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$script:sha = 'a' * 40
$script:urls = New-Object Collections.Generic.List[string]
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing)
    $script:urls.Add($Uri)
    if ($Uri -like '*/commits/*') { return [pscustomobject]@{ Content = ('{"sha":"' + $script:sha + '"}') } }
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
    Assert ($bash.Contains("/$(('a' * 40))/linux/atualizar.sh")) 'Updater de outra revisao'
    Assert ($bash.Contains("LOR_REVISION='$(('a' * 40))' LOR_VERSION='2'")) 'Runtime recebeu outra revisao/versao'
    Assert ($bash.Contains('-o "$script"')) 'Script executado antes de completar download'
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
$Ramo = 'estavel'; $Distro = 'LoRBots'
$timer = New-Object PSObject
$timer | Add-Member ScriptMethod Stop { }
$timer | Add-Member ScriptMethod Start { }
$trava = New-Object PSObject
$trava | Add-Member ScriptMethod ReleaseMutex { }
$form = New-Object PSObject
$form | Add-Member ScriptMethod Close { }
$lAtualizar = [pscustomobject]@{ Text = ''; Enabled = $true }
foreach ($name in @('bLigar','bVer','bDesligar','bAgora','bAplicar','bConta','bCodigo','xDiscord','xChat','xBloquearBots','xEsperarBots','xEsperarColmeia','xDecisoesInstantaneas','bDesafiar')) {
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
    Write-Host 'PASS SHA unico, branch mutada, falha Linux preserva painel e metadados invalidos'
} finally {
    $resolvido = [IO.Path]::GetFullPath($Pasta)
    if ($resolvido.StartsWith([IO.Path]::GetTempPath()) -and (Split-Path $resolvido -Leaf) -like 'lor-update-*') {
        Remove-Item -LiteralPath $resolvido -Recurse -Force
    }
}
