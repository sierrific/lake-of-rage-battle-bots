# Instalador: bot, painel, VERSION e icone vem todos do mesmo commit, mesmo se a branch andar no
# meio da instalacao (revisao de codigo de 05/11). Rede e Linux simulados.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Join-Path (Split-Path $PSScriptRoot) 'windows') 'instalar.ps1'
$source = [IO.File]::ReadAllText($path)
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
$f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'RevisaoDoRamo' }, $true)
. ([scriptblock]::Create($f.Extent.Text))
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
function Invoke-WebRequest {
    param($Uri, $OutFile, $TimeoutSec, [switch]$UseBasicParsing)
    $script:urls.Add($Uri)
    if ($Uri -like 'https://api.github.com/*/commits/*') {
        if ($script:apiFalha) { throw 'sem rede' }
        # A branch anda logo depois da primeira consulta (um merge no meio da instalacao).
        $sha = if ($script:consultas++ -eq 0) { $A } else { $B }
        return [pscustomobject]@{ Content = ('{"sha":"' + $sha + '"}') }
    }
    Assert ($Uri -like "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$A/*") "baixou de outro lugar: $Uri"
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
    Assert ($script:linux.Count -eq 1) 'o Linux devia rodar o atualizar.sh uma vez'
    Assert ($script:linux[0].Contains("/$A/linux/atualizar.sh")) "atualizar.sh de outra revisao: $($script:linux[0])"
    Assert ($script:linux[0].Contains("LOR_REVISION=$A ")) "o Linux nao recebeu a revisao: $($script:linux[0])"
    Assert (-not $script:linux[0].Contains('/estavel/')) "o Linux leu a branch: $($script:linux[0])"
    foreach ($arq in @('windows/Painel.ps1', 'VERSION', 'windows/painel.ico')) {
        Assert ($script:urls -contains "https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/$A/$arq") "nao baixou $arq do commit fixado"
    }
    Assert (Test-Path (Join-Path $Pasta 'Painel.ps1')) 'nao gravou o painel'

    # Sem resposta do GitHub: para com uma mensagem, sem baixar nada nem mexer no Linux.
    $script:urls.Clear(); $script:linux.Clear(); $script:apiFalha = $true
    $erro = & { try { & $passos; '' } catch { $_.Exception.Message } }
    Assert ($erro -like 'FALHA: Nao consegui consultar a versao do bot no GitHub*') "sem GitHub: '$erro'"
    Assert ($script:linux.Count -eq 0) 'rodou o Linux sem revisao'
    Assert (@($script:urls | Where-Object { $_ -notlike 'https://api.github.com/*' }).Count -eq 0) 'baixou sem revisao'
    Assert (@($script:urls).Count -eq 3) "tentativas: $(@($script:urls).Count)"
    Write-Host 'instalador fixa um commit: ok'
} finally {
    Remove-Item -LiteralPath $Pasta -Recurse -Force -ErrorAction SilentlyContinue
}
