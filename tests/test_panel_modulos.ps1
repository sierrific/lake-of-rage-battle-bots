# Rodape do painel: versao + modulos (modelo, oponente, branch) e o detalhe no tooltip.
$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in @('Versao-Painel', 'Nome-Curto', 'Resumo-Modulos')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert($ok, $message) { if (-not $ok) { throw $message } }
$ArquivoVersao = Join-Path $env:TEMP 'lor-nao-existe-VERSION'

Assert ((Nome-Curto 'mc-bo3-rnad-v6') -eq 'v6') 'nome curto do modelo'
Assert ((Nome-Curto 'lor-opp-v4-tudo') -eq 'v4') 'nome curto do oponente'
Assert ((Nome-Curto 'meu-modelo') -eq 'meu-modelo') 'nome sem versao fica inteiro'

$e = @{ versao = '2026.11.04.1'; modelo = 'mc-bo3-rnad-v6'; oponente = 'lor-opp-v4-tudo'; busca = 'prior 0.03 protect'
    aivgc = '0bd586d'; patch = '2d71164'; revisao = 'abcdef012345'; formato = 'bo3'; timer = 'sim'
    esperar_colmeia = 'nao'; pausa = 'sim'; esperar_bots = 'sim'; decisoes_instantaneas = 'nao' }
$Ramo = 'claude/v041-pausa'
$r = Resumo-Modulos $e
Assert ($r.Curto -like '*2026.11.04.1 * v041-pausa * mod. v6 * op. v4') "curto: $($r.Curto)"
Assert (-not $r.Curto.Contains('claude') -and -not $r.Detalhe.Contains('claude')) "prefixo da branch: $($r.Curto)"
foreach ($trecho in @('mc-bo3-rnad-v6', 'lor-opp-v4-tudo', 'prior 0.03 protect', '0bd586d + patch 2d71164',
        'branch v041-pausa', 'abcdef012345', 'colmeia n')) {
    Assert ($r.Detalhe.Contains($trecho)) "detalhe sem '$trecho': $($r.Detalhe)"
}

# Branch estavel e oponente original: nada de branch no rodape, "original" no lugar do oponente.
$Ramo = 'estavel'
$e['oponente'] = ''
$r = Resumo-Modulos $e
Assert (-not $r.Curto.Contains('estavel')) "curto com a branch padrao: $($r.Curto)"
Assert ($r.Curto -like '* op. original') "curto: $($r.Curto)"
Assert ($r.Detalhe.Contains('all-bo3-opp-v2')) 'detalhe sem o oponente original'

# Linux de versao antiga (sem as chaves novas): so a versao, sem inventar modelo.
$r = Resumo-Modulos @{ versao = '2026.11.01.1'; formato = 'bo3' }
Assert ($r.Curto -like '*2026.11.01.1') "curto antigo: $($r.Curto)"
Assert (-not $r.Detalhe.Contains('Modelo')) 'detalhe inventou o modelo'
Write-Host 'PASS rodape com versao e modulos'
