$ErrorActionPreference = 'Stop'
$path = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
foreach ($name in @('Invoke-ProcessoPainel', 'Atualizar-EmSegundoPlano', 'Encerrar-ConsultaEstado', 'Ler-Estado')) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    . ([scriptblock]::Create($f.Extent.Text))
}
function Assert($ok, $message) { if (-not $ok) { throw $message } }
function Inicio([string]$codigo) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments = '-NoProfile -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($codigo))
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi
}
$tempo = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-ProcessoPainel (Inicio 'Start-Sleep -Seconds 120') -TimeoutMs 900 -Entrada ('x' * 262144)
Assert ($r.Codigo -eq 124 -and $tempo.Elapsed.TotalSeconds -lt 5) 'Processo/entrada travados nao terminaram no prazo'
$r = Invoke-ProcessoPainel (Inicio '[Console]::Error.Write("e" * 524288); [Console]::Out.Write("ok")') -TimeoutMs 10000
Assert ($r.Codigo -eq 0 -and $r.Saida -eq 'ok' -and $r.Erro.Length -eq 524288) 'Deadlock ou perda dos pipes'

function Atualizar-EstadoTela($r) { $script:estado = Ler-Estado $r }
function Mostrar-Falha($erro) { $script:estado = @{}; $script:falha = $erro }
$ConsultaEstado = { param($inicio, $controle) Invoke-ProcessoPainel $inicio -TimeoutMs 900 -Controle $controle }
$script:pedido = $null
$script:estado = @{ bot = 'active'; partida = 'antiga' }
$Distro = Inicio 'Start-Sleep -Seconds 120'
Atualizar-EmSegundoPlano
$limite = [Diagnostics.Stopwatch]::StartNew()
while ($script:pedido -and $limite.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50; Atualizar-EmSegundoPlano }
Assert (-not $script:pedido -and $script:estado.Count -eq 0 -and $script:falha) 'Polling deixou estado antigo ou runspace preso'
$Distro = Inicio '[Console]::Out.Write("bot=inactive")'
Atualizar-EmSegundoPlano
$limite.Restart()
while ($script:pedido -and $limite.Elapsed.TotalSeconds -lt 5) { Start-Sleep -Milliseconds 50; Atualizar-EmSegundoPlano }
Assert ($script:estado.bot -eq 'inactive') 'Proxima consulta nao recuperou'
$Distro = Inicio 'Start-Sleep -Seconds 120'
Atualizar-EmSegundoPlano
$limite.Restart()
Encerrar-ConsultaEstado
Assert (-not $script:pedido -and $limite.Elapsed.TotalSeconds -lt 3) 'Fechamento nao cancelou/liberou consulta'
Write-Host 'PASS prazo, stdin bloqueado, stderr grande, estado invalidado, recuperacao e cancelamento'
