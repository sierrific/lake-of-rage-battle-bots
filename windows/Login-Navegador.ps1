# Auxiliar do Painel: login manual no site oficial; cookies ficam num perfil separado.
# Apenas o pedido ligado a conta/desafio/prazo atuais recebe a autorizacao assinada.
# Nao altera fingerprint, flags de conta, assinatura, cookies ou controles do site.
param([string]$Distro = 'LoRBots', [switch]$LibraryOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Invoke-LoginMailbox([string]$Action, [string]$InputText = '') {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d $Distro -u bots -e python3 -I /opt/lor-bots/login-navegador.py $Action /run/lor-login-bot"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $p = [Diagnostics.Process]::Start($psi)
    try {
        if ($InputText) {
            $b = [Text.Encoding]::UTF8.GetBytes($InputText)
            $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
        }
        $p.StandardInput.Close()
        $outputTask = $p.StandardOutput.ReadToEndAsync()
        $errorTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit(20000)) { $p.Kill(); throw 'WSL sem resposta' }
        if ($p.ExitCode -ne 0) { throw 'Autorizacao local indisponivel' }
        return $outputTask.Result.Trim()
    } finally { $p.Dispose() }
}

function Find-LoginBrowser {
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:LOCALAPPDATA)) {
        if (-not $base) { continue }
        foreach ($rel in @('Microsoft\Edge\Application\msedge.exe', 'Google\Chrome\Application\chrome.exe')) {
            $exe = Join-Path $base $rel
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    throw 'Instale o Microsoft Edge ou Google Chrome para entrar pelo navegador.'
}

function Get-LoginPage([int]$Port) {
    $pages = Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 -Uri "http://127.0.0.1:$Port/json/list"
    foreach ($page in $pages) {
        $url = $null
        if ($page.type -eq 'page' -and [Uri]::TryCreate($page.url, [UriKind]::Absolute, [ref]$url) -and
            $url.Scheme -eq 'https' -and $url.Host -eq 'play.pokemonshowdown.com' -and $url.IsDefaultPort) {
            $ws = [Uri]$page.webSocketDebuggerUrl
            if ($ws.Scheme -eq 'ws' -and $ws.Host -in @('127.0.0.1', 'localhost') -and $ws.Port -eq $Port) {
                return $page.webSocketDebuggerUrl
            }
        }
    }
    return $null
}

function Invoke-CDP([string]$SocketUrl, [string]$Method, $Parameters) {
    $ws = New-Object Net.WebSockets.ClientWebSocket
    $cts = New-Object Threading.CancellationTokenSource
    $cts.CancelAfter(20000)
    try {
        [void]$ws.ConnectAsync([Uri]$SocketUrl, $cts.Token).GetAwaiter().GetResult()
        $msg = @{ id = 1; method = $Method; params = $Parameters } | ConvertTo-Json -Depth 12 -Compress
        $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$bytes)
        [void]$ws.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult()
        $buffer = New-Object byte[] 16384
        $received = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buffer)
        while ($true) {
            $stream = New-Object IO.MemoryStream
            try {
                do {
                    $part = $ws.ReceiveAsync($received, $cts.Token).GetAwaiter().GetResult()
                    if ($part.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Navegador fechado' }
                    $stream.Write($buffer, 0, $part.Count)
                    if ($stream.Length -gt 65536) { throw 'Resposta do navegador invalida' }
                } until ($part.EndOfMessage)
                $reply = [Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            } finally { $stream.Dispose() }
            if ($reply.id -ne 1) { continue }
            if ($reply.error -or $reply.result.exceptionDetails) { throw 'Nao foi possivel autorizar pelo navegador' }
            return $reply.result
        }
    } finally { $ws.Dispose(); $cts.Dispose() }
}

function New-AuthorizationExpression($Request) {
    $userid = ($Request.username.ToLowerInvariant() -replace '[^a-z0-9]', '') | ConvertTo-Json -Compress
    $challenge = $Request.challstr | ConvertTo-Json -Compress
    # Nao le senha nem exporta cookies. Aguarda o login feito pelo usuario no cliente oficial.
    # A requisicao de getassertion usa a sessao do proprio navegador e um desafio de uso unico.
    return @"
(async () => {
  if (location.origin !== 'https://play.pokemonshowdown.com') return {waiting: true};
  const expected = $userid;
  const user = window.PS && window.PS.user;
  const old = window.app && window.app.user;
  const id = user ? user.userid : old && old.get('userid');
  const named = user ? user.named : old && old.get('named');
  if (!named || id !== expected) return {waiting: true};
  const body = new URLSearchParams({act: 'getassertion', userid: expected, challstr: $challenge});
  const response = await fetch('/~~showdown/action.php', {
    method: 'POST', credentials: 'same-origin', redirect: 'error',
    headers: {'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'}, body: body.toString()
  });
  if (!response.ok) return {error: true};
  const assertion = (await response.text()).trim();
  if (!assertion || assertion.startsWith(';') || assertion.includes('<')) return {error: true};
  return {assertion};
})()
"@
}

function Authorize-Login($Request) {
    if ($Request.id -notmatch '^[a-f0-9]{32}$' -or $Request.username -notmatch '^[A-Za-z0-9 _.-]{1,18}$') {
        throw 'Pedido de login invalido'
    }
    $account = $Request.username.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $account) { throw 'Conta invalida' }
    $profile = Join-Path $env:LOCALAPPDATA "LoRBots\login\$account"
    [void][IO.Directory]::CreateDirectory($profile)
    $portFile = Join-Path $profile 'DevToolsActivePort'
    # Cada autorizacao abre um navegador visivel, num perfil exclusivo desta conta.
    # A porta de depuracao e aleatoria e restrita a loopback; fecha junto da janela ao terminar.
    $socket = $null
    $browser = $null
    $port = 0
    $profileRunning = $false
    if (Test-Path -LiteralPath $portFile) {
        if ([int]::TryParse((Get-Content -LiteralPath $portFile -TotalCount 1), [ref]$port) -and $port -gt 0 -and $port -lt 65536) {
            try {
                [void](Invoke-RestMethod -UseBasicParsing -TimeoutSec 3 -Uri "http://127.0.0.1:$port/json/version")
                $profileRunning = $true
                $socket = Get-LoginPage $port
            } catch {}
        }
    }
    if (-not $socket) {
        # Se o perfil ficou aberto em outra pagina, --new-window reabre o Showdown nele.
        # O navegador existente nao regrava DevToolsActivePort: preserve o arquivo nesse caso.
        if (-not $profileRunning) { Remove-Item -LiteralPath $portFile -ErrorAction SilentlyContinue }
        $browser = Start-Process -FilePath (Find-LoginBrowser) -PassThru -ArgumentList @(
            "--user-data-dir=`"$profile`"", '--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1',
            '--no-first-run', '--no-default-browser-check', '--new-window', 'https://play.pokemonshowdown.com/'
        )
    }
    $deadline = [DateTimeOffset]::FromUnixTimeSeconds([long][Math]::Floor($Request.expires))
    try {
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            $current = Invoke-LoginMailbox 'pending' | ConvertFrom-Json
            if (-not $current -or $current.id -ne $Request.id) { return }
            if (Test-Path -LiteralPath $portFile) {
                $port = 0
                if ([int]::TryParse((Get-Content -LiteralPath $portFile -TotalCount 1), [ref]$port) -and $port -gt 0 -and $port -lt 65536) {
                    # A porta pode surgir antes de o servidor de depuracao ficar pronto.
                    try { $socket = Get-LoginPage $port } catch { $socket = $null }
                    if ($socket) {
                        $result = Invoke-CDP $socket 'Runtime.evaluate' @{
                            expression = (New-AuthorizationExpression $Request); awaitPromise = $true; returnByValue = $true
                        }
                        $value = $result.result.value
                        if ($value.error) { throw 'Entre na conta pelo site oficial e tente novamente.' }
                        if ($value.assertion) {
                            $reply = @{ id = $Request.id; assertion = $value.assertion } | ConvertTo-Json -Compress
                            [void](Invoke-LoginMailbox 'respond' $reply)
                            return
                        }
                    }
                }
            }
            Start-Sleep -Seconds 2
        }
        throw 'Tempo de login esgotado'
    } finally {
        # Somente o navegador do perfil dedicado que este auxiliar iniciou.
        if ($socket) { try { [void](Invoke-CDP $socket 'Browser.close' @{}) } catch {} }
        if ($browser) {
            # Browser.close precisa de tempo para persistir a sessao do perfil.
            if (-not $browser.WaitForExit(5000)) { $browser.Kill() }
            $browser.Dispose()
        }
    }
}

if ($LibraryOnly) { return }
$mutex = New-Object Threading.Mutex($false, 'Local\LoRBotsLoginNavegador')
if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); exit }
try {
    # O guardiao do painel mantem o WSL vivo. Este auxiliar fica enquanto o servico tem seu
    # RuntimeDirectory (inclusive reconexoes) e sai depois de 2 min sem o bot.
    $absent = 0
    while ($absent -lt 24) {
        try {
            $request = Invoke-LoginMailbox 'pending' | ConvertFrom-Json
            if ($request) {
                $absent = 0
                try { Authorize-Login $request }
                catch {
                    try { [void](Invoke-LoginMailbox 'respond' (@{id=$request.id; error=$true} | ConvertTo-Json -Compress)) } catch {}
                }
            }
            # Sem pedido pode estar jogando: existencia do RuntimeDirectory e consultada sem root.
            $check = New-Object Diagnostics.ProcessStartInfo
            $check.FileName = 'wsl.exe'
            $check.Arguments = "-d $Distro -u bots -e test -d /run/lor-login-bot"
            $check.UseShellExecute = $false; $check.CreateNoWindow = $true
            $p = [Diagnostics.Process]::Start($check)
            if (-not $p.WaitForExit(10000)) { $p.Kill(); $absent++ }
            elseif ($p.ExitCode -eq 0) { $absent = 0 } else { $absent++ }
            $p.Dispose()
        } catch { $absent++ }
        Start-Sleep -Seconds 5
    }
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
