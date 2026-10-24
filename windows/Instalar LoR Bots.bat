@echo off
rem Instalador dos bots da Lake of Rage: de dois cliques neste arquivo.
rem Ele baixa e roda o instalador mais novo do GitHub (windows/instalar.ps1).
title Instalador LoR Bots
rem Como administrador (para ligar o WSL na primeira vez): o Windows pede confirmacao.
net session >nul 2>&1 || (powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/sierrific/lake-of-rage-battle-bots/main/windows/instalar.ps1 | iex"
echo.
pause
