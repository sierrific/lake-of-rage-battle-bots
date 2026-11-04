# Modo ao vivo do painel: baixa o pacote do WebView2 (NuGet, SHA-256 fixo), carrega as DLLs no
# PowerShell 5.1 e abre uma página num WebView2 de verdade. Precisa de rede e do runtime do
# WebView2 (já vem no Windows 10/11 e nas máquinas do GitHub Actions).
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$sourcePath = Join-Path (Split-Path $PSScriptRoot) 'windows\Painel.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$null)
foreach ($name in @('WebView2Versao', 'WebView2Sha256')) {
    $assignment = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$' + $name) }, $false) | Select-Object -First 1
    Set-Variable -Name $name -Value $assignment.Right.Extent.Text.Trim("'")
}
$definition = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Carregar-WebView2' }, $false) | Select-Object -First 1
. ([ScriptBlock]::Create($definition.Extent.Text))
function Assert($condition, [string]$message) { if (-not $condition) { throw "Falhou: $message" } }
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$env:LOCALAPPDATA = Join-Path ([IO.Path]::GetTempPath()) ('lor-webview2-' + [Guid]::NewGuid().ToString('N'))

# Pacote que não confere: recusa, apaga e o painel cai para o navegador.
$certo = $WebView2Sha256
$WebView2Sha256 = '0' * 64
$script:webView2 = $null
Assert (-not (Carregar-WebView2)) 'pacote com SHA-256 errado recusado'
Assert ($script:erroWebView2 -match 'SHA-256') "mensagem do SHA-256: $script:erroWebView2"
$dir = Join-Path $env:LOCALAPPDATA "LoRBots\webview2\$WebView2Versao"
Assert (-not (Test-Path (Join-Path $dir 'pacote.nupkg'))) 'pacote errado apagado'
Assert (-not (Test-Path (Join-Path $dir 'Microsoft.Web.WebView2.Core.dll'))) 'nada extraído do pacote errado'

# Pacote certo: baixa, extrai só as DLLs e carrega.
$WebView2Sha256 = $certo
$script:webView2 = $null
Assert (Carregar-WebView2) "WebView2 carregado: $script:erroWebView2"
Assert (Carregar-WebView2) 'segunda chamada usa o já carregado'
Assert (Test-Path (Join-Path $dir 'win-x64\WebView2Loader.dll')) 'loader x64 extraído'
Assert (-not (Test-Path (Join-Path $dir 'pacote.nupkg'))) 'pacote apagado depois de extrair'
Assert (@(Get-ChildItem $dir -Recurse -File).Count -eq 5) 'só as DLLs necessárias (2 + 3 loaders)'

# Uma página de verdade num WebView2, como a janela ao vivo faz.
$f = New-Object System.Windows.Forms.Form
$f.Size = New-Object System.Drawing.Size(800, 600)
$f.ShowInTaskbar = $false
$f.Opacity = 0
$wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
$props = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
$props.UserDataFolder = Join-Path $env:LOCALAPPDATA 'LoRBots\webview2-dados'
$wv.CreationProperties = $props
$wv.Dock = 'Fill'
$f.Controls.Add($wv)
$script:resultado = $null
$script:iniciou = $null
$wv.add_CoreWebView2InitializationCompleted({ param($s, $a) $script:iniciou = $a.IsSuccess; if (-not $a.IsSuccess) { $script:resultado = "init: $($a.InitializationException)" } })
$wv.add_NavigationCompleted({ param($s, $a) $script:resultado = if ($a.IsSuccess) { 'ok' } else { "erro $($a.WebErrorStatus)" } })
$f.Show()
$wv.Source = [Uri]'data:text/html,<title>LoR ao vivo</title><p>ok</p>'
$fim = (Get-Date).AddSeconds(90)
while (-not $script:resultado -and (Get-Date) -lt $fim) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
Assert $script:iniciou "WebView2 iniciou ($script:resultado)"
Assert ($script:resultado -eq 'ok') "página carregou ($script:resultado)"
Assert ($wv.CoreWebView2.DocumentTitle -eq 'LoR ao vivo') 'título da página'
Assert (Test-Path (Join-Path $env:LOCALAPPDATA 'LoRBots\webview2-dados')) 'dados do WebView2 na pasta do painel'
$f.Close(); $wv.Dispose(); $f.Dispose()
Write-Host 'Modo ao vivo (WebView2): OK'
