# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/). Versões seguem [SemVer](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-11-16

Primeira versão.

### Adicionado

- Interface Windows Forms para usar a câmera do Android como webcam via scrcpy.
- Pareamento por Wi-Fi com QR code gerado localmente ou com código de 6 dígitos, com descoberta de IP/porta por mDNS.
- Reconexão automática a aparelhos já pareados e botão "Reconectar aparelhos salvos".
- Conexão manual por IP:porta e suporte a USB.
- Opções de câmera frontal/traseira, resolução (com consulta das resoluções suportadas), FPS, bitrate, orientação/espelhamento, sempre no topo e sem borda.
- Log do scrcpy em tempo real na janela.
- Configuração persistida em `%APPDATA%\WebcamAndroid\config.json`.
- Botão para criar atalho na área de trabalho e launcher `Abrir Webcam Android.cmd`.
- Testes automatizados sem dependências (`tests/Invoke-Tests.ps1`) e CI no GitHub Actions.
