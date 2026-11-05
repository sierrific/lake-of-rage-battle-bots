@echo off
rem Instalador dos bots da Lake of Rage: de dois cliques neste arquivo.
rem Ele baixa e roda o instalador mais novo da VPS do time (windows/instalar.ps1 da branch
rem estavel: a main so depois que os testes passaram nela). O instalador pede o codigo da coleta.
title Instalador LoR Bots
rem Como administrador (para ligar o WSL na primeira vez): o Windows pede confirmacao.
net session >nul 2>&1 || (powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs" & exit /b)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://showdown.sierverso.com.br/coleta/instalar.ps1 | iex"
echo.
pause
