# Contrato do auxiliar Windows em PowerShell 5.1, CDP local e cliente JS sinteticos.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'windows\Login-Navegador.ps1') -LibraryOnly
function Assert($condition, [string]$message) {
    if (-not $condition) { throw "Falhou: $message" }
}
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = 'node.exe'
$psi.Arguments = '"' + (Join-Path $PSScriptRoot 'login-cdp.cjs') + '"'
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$p = [Diagnostics.Process]::Start($psi)
try {
    $portTask = $p.StandardOutput.ReadLineAsync()
    if (-not $portTask.Wait(10000)) { throw 'Servidor sintetico nao iniciou' }
    $port = [int]$portTask.Result
    $socket = Get-LoginPage $port
    Assert ($socket -eq "ws://127.0.0.1:$port/test") 'apenas origem oficial e socket loopback'
    $unicode = 'autoriza' + [char]0x00E7 + [char]0x00E3 + 'o'
    $echo = Invoke-CDP $socket 'test.echo' @{text=$unicode}
    Assert ($echo.echo -eq $unicode) 'CDP envia Unicode, ignora eventos e recebe fragmentos'
    foreach ($method in @('test.close', 'test.error', 'test.exception')) {
        $failed = $false
        try { [void](Invoke-CDP $socket $method @{}) } catch { $failed = $true }
        Assert $failed "CDP rejeita $method"
    }
    # Inclui aspas para conferir a serializacao: nunca vira codigo JavaScript.
    $challenge = '4|' + ('b' * 256) + '|"extra'''
    $expression = New-AuthorizationExpression @{username='Conta Teste'; challstr=$challenge}
    foreach ($state in @('wrong', 'guest', 'origin', 'new', 'old', 'http', 'html')) {
        $result = Invoke-CDP $socket 'Runtime.evaluate' @{
            expression=$expression; awaitPromise=$true; returnByValue=$true
            testState=$state; testChallenge=$challenge
        }
        $value = $result.result.value
        if ($state -in @('wrong', 'guest', 'origin')) { Assert $value.waiting "aguarda $state sem requisitar token" }
        elseif ($state -in @('http', 'html')) { Assert $value.error "falha fechada $state" }
        else { Assert ($value.assertion -match ',contateste,10,') "preserva tipo de conta $state" }
    }
    $p.StandardInput.Close()
    if (-not $p.WaitForExit(5000)) { throw 'Servidor sintetico nao encerrou' }
    Assert ($p.ExitCode -eq 0) 'servidor terminou'
    Assert (-not $p.StandardError.ReadToEnd()) 'contrato JavaScript sem erros'
    Write-Output 'OK: CDP, origem, cliente atual/antigo, conta errada, erros e serializacao (PowerShell 5.1).'
} finally {
    if (-not $p.HasExited) { $p.Kill() }
    $p.Dispose()
}
