# Instalador: bot, painel, VERSION e icone vem todos do mesmo commit, mesmo se a branch andar no
# meio da instalacao (revisao de codigo de 05/11). Rede e Linux simulados.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Join-Path (Split-Path $PSScriptRoot) 'windows') 'instalar.ps1'
$source = [IO.File]::ReadAllText($path)
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($nome in @('RevisaoDoRamo', 'BaixarSubstituindo')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $nome }, $true)
    if (-not $f) { throw "funcao $nome nao encontrada" }
    . ([scriptblock]::Create($f.Extent.Text))
}
$inicio = $source.IndexOf('# 3. Bot (dentro do Linux)')
$fim = $source.IndexOf('# A branch escolhida', $inicio)
if ($inicio -lt 0 -or $fim -lt 0) { throw 'trecho dos passos 3 e 4 nao encontrado' }
$passos = [scriptblock]::Create($source.Substring($inicio, $fim - $inicio))

function Assert($ok, $texto) { if (-not $ok) { throw $texto } }
function Falha($texto) { throw "FALHA: $texto" }
function Passo($texto) { }
function Start-Sleep { }
$A = 'a' * 40
$B = 'b' * 40
$Vps = 'https://vps.teste/coleta'
$Codigo = 'codigo-teste'
$Autorizacao = @{ Authorization = "Bearer $Codigo" }
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, $Headers, [switch]$UseBasicParsing)
    $script:urls.Add($Uri)
    Assert ($Headers -and $Headers.Authorization -eq 'Bearer codigo-teste') "sem o codigo da coleta: $Uri"
    if ($Uri -like 'https://vps.teste/coleta/bots/ramo/*') {
        if ($script:apiFalha) { throw 'sem rede' }
        # A branch anda logo depois da primeira consulta (um merge no meio da instalacao).
        $sha = if ($script:consultas++ -eq 0) { $A } else { $B }
        return [pscustomobject]@{ Content = ('{"sha":"' + $sha + '"}') }
    }
    Assert ($Uri -like "https://vps.teste/coleta/bots/$A/*") "baixou de outro lugar: $Uri"
    if ($OutFile -and $Uri -like '*/windows/Painel.ps1') {
        # Reinstalacao interrompida: metade do painel chega (string sem fim) ou a conexao cai.
        if ($script:modoPainel -eq 'metade') { [IO.File]::WriteAllText($OutFile, "Write-Host 'metade do pai"); return }
        if ($script:modoPainel -eq 'caiu') { [IO.File]::WriteAllText($OutFile, '# come'); throw 'a conexao caiu' }
        [IO.File]::WriteAllText($OutFile, "# painel novo`nWrite-Host 'ok'")
        return
    }
    if ($OutFile) { [IO.File]::WriteAllText($OutFile, 'x') }
}
function NoLinux([string]$comando) { $script:linux.Add($comando) }
$Pasta = Join-Path ([IO.Path]::GetTempPath()) ('lor-revisao-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($Pasta)
try {
    $Ramo = 'estavel'
    $script:urls = New-Object Collections.Generic.List[string]
    $script:linux = New-Object Collections.Generic.List[string]
    $script:consultas = 0
    $script:apiFalha = $false
    & $passos
    Assert ($script:consultas -eq 1) "consultou a branch $($script:consultas) vezes"
    Assert ($script:linux.Count -eq 2) 'o Linux devia rodar o atualizar.sh e salvar o codigo'
    Assert ($script:linux[0].Contains('LOR_CODIGO=codigo-teste ')) "o atualizar.sh nao recebeu o codigo: $($script:linux[0])"
    Assert ($script:linux[1].Contains('painel.sh codigo')) "o codigo nao foi salvo no Linux: $($script:linux[1])"
    Assert ($script:linux[0].Contains("/$A/linux/atualizar.sh")) "atualizar.sh de outra revisao: $($script:linux[0])"
    Assert ($script:linux[0].Contains("LOR_REVISION=$A ")) "o Linux nao recebeu a revisao: $($script:linux[0])"
    Assert (-not $script:linux[0].Contains('/estavel/')) "o Linux leu a branch: $($script:linux[0])"
    foreach ($arq in @('windows/Painel.ps1', 'VERSION', 'windows/painel.ico')) {
        Assert ($script:urls -contains "https://vps.teste/coleta/bots/$A/$arq") "nao baixou $arq do commit fixado"
    }
    Assert (Test-Path (Join-Path $Pasta 'Painel.ps1')) 'nao gravou o painel'
    Assert ($script:linux[0].Contains('LOR_VPS=https://vps.teste/coleta ')) "o Linux nao recebeu a VPS: $($script:linux[0])"

    # Reinstalacao interrompida no meio do download do painel: o que funcionava fica inteiro
    # (revisao de codigo de 06/11), sem temporario sobrando, e o instalador para com aviso.
    $painel = Join-Path $Pasta 'Painel.ps1'
    foreach ($modo in @('metade', 'caiu')) {
        [IO.File]::WriteAllText($painel, '# painel que funcionava')
        $script:modoPainel = $modo; $script:consultas = 0; $script:linux.Clear()
        $erro = & { try { & $passos; '' } catch { $_.Exception.Message } }
        Assert ($erro -like 'FALHA: Nao consegui baixar Painel.ps1*') "$($modo): '$erro'"
        Assert ([IO.File]::ReadAllText($painel) -eq '# painel que funcionava') "$($modo): estragou o painel que funcionava"
        Assert (-not (Test-Path "$painel.baixando")) "$($modo): sobrou o temporario"
    }
    $script:modoPainel = $null

    # Sem resposta do GitHub: para com uma mensagem, sem baixar nada nem mexer no Linux.
    $script:urls.Clear(); $script:linux.Clear(); $script:apiFalha = $true
    $erro = & { try { & $passos; '' } catch { $_.Exception.Message } }
    Assert ($erro -like 'FALHA: Nao consegui consultar a versao do bot no servidor do time*') "sem VPS: '$erro'"
    Assert ($script:linux.Count -eq 0) 'rodou o Linux sem revisao'
    Assert (@($script:urls | Where-Object { $_ -notlike 'https://vps.teste/coleta/bots/ramo/*' }).Count -eq 0) 'baixou sem revisao'
    Assert (@($script:urls).Count -eq 3) "tentativas: $(@($script:urls).Count)"
    Write-Host 'instalador fixa um commit: ok'
} finally {
    Remove-Item -LiteralPath $Pasta -Recurse -Force -ErrorAction SilentlyContinue
}
