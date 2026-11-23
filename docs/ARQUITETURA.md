# Arquitetura

Como o `WebcamAndroid.ps1` funciona por dentro. Os números de linha se referem à versão 1.0.0.

## Visão geral

```
┌──────────────────────── WebcamAndroid.ps1 (Windows Forms) ────────────────────────┐
│                                                                                    │
│  config.json ◀──▶ $script:cfg          Timer 500 ms ──▶ lê scrcpy.log → log da UI  │
│                                                     └─▶ a cada 5 s: mDNS + adb     │
│                                                                                    │
│  Adicionar aparelho ──▶ MiniQr (C#) ──▶ QR "WIFI:T:ADB;S:<nome>;P:<senha>;;"       │
│                        Timer 1,2 s ──▶ adb mdns services ──▶ adb pair ──▶ connect  │
│                                                                                    │
│  Iniciar câmera ──▶ cmd /c scrcpy.exe <args> > scrcpy.log 2>&1                     │
│  Parar          ──▶ taskkill /T /F                                                 │
└────────────────────────────────────────────────────────────────────────────────────┘
            │ adb (USB ou TCP/TLS)
            ▼
     Android: scrcpy-server (Camera2 API) ──▶ H.264 ──▶ janela "Webcam Android"
```

O script não fala com a câmera diretamente. Ele só:

1. gerencia a conexão ADB (pareamento, conexão, lista de aparelhos);
2. monta a linha de comando do scrcpy a partir das opções da interface;
3. inicia/para o processo e mostra o log.

## Blocos do script

| Bloco | Linhas | Função |
|---|---|---|
| Inicialização | 1–18 | Carrega Windows Forms/Drawing, define `%APPDATA%\WebcamAndroid`, estado global (`$script:*`) |
| `MiniQr` (C#) | 20–188 | Gerador de QR code embutido, compilado em memória com `Add-Type` |
| Configuração | 190–203 | Valores padrão, leitura/gravação de `config.json` |
| Localizar scrcpy/adb | 205–231 | `Find-Scrcpy`, `Get-Adb` |
| Helpers | 233–284 | Criação de controles, log, mDNS, reconexão |
| Janela principal | 286–381 | Layout da interface e aplicação da config salva |
| Dispositivos | 383–418 | `Update-Devices`: lê `adb devices -l` e preenche a lista |
| Pareamento | 420–549 | `Show-PairDialog`: janela de QR/código e máquina de estados |
| Iniciar/parar | 551–623 | Monta argumentos, roda scrcpy, acompanha o log |
| Timer principal | 625–645 | Log em tempo real + reconexão automática |
| Eventos | 647–741 | Handlers dos botões, abertura e fechamento da janela |

## Localização do scrcpy e do adb

`Find-Scrcpy` tenta, em ordem:

1. o caminho salvo em `config.json` (se o arquivo ainda existir);
2. `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Genymobile.scrcpy*\**\scrcpy.exe` (o mais recente);
3. `scrcpy.exe` no `PATH`. Se for um link simbólico (o winget cria links em `WinGet\Links`), segue o link até o executável real, para que o `adb.exe` ao lado dele seja encontrado.

`Get-Adb` usa o `adb.exe` da mesma pasta do scrcpy e, se não houver, o `adb.exe` do `PATH`. Usar o adb que vem com o scrcpy evita conflito de versão entre cliente e servidor adb.

## Gerador de QR (`MiniQr`)

Implementação mínima de QR code, sem dependências, só para o que o pareamento precisa:

- **Versão 3** (29×29 módulos), **nível de correção L**, **modo byte**, **máscara 0** fixa.
- 55 codewords de dados + 15 de correção Reed-Solomon (GF(256), polinômio `0x11D`), num único bloco.
- Desenha padrões de localização, timing, padrão de alinhamento em (22,22), módulo escuro e informação de formato com BCH.
- Limite de 53 bytes de conteúdo. O texto usado tem 48.
- `ToBitmap(texto, escala)` devolve um `Bitmap` com zona de silêncio de 4 módulos.

Se a compilação falhar (por exemplo, política que bloqueia `Add-Type`), `$script:qrOk` vira `$false` e a janela de pareamento mostra só a opção por código.

## Pareamento sem fio

O Android 11+ anuncia dois serviços mDNS quando a Depuração sem fio está ligada:

| Serviço | Quando aparece | Uso |
|---|---|---|
| `_adb-tls-pairing._tcp` | Enquanto a tela de pareamento (QR ou código) está aberta no celular | `adb pair <ip:porta> <senha>` |
| `_adb-tls-connect._tcp` | Sempre que a Depuração sem fio está ligada | `adb connect <ip:porta>` |

`Get-MdnsServices` roda `adb mdns services` e extrai nome, tipo e endereço de cada linha.

### Por QR code

1. O script gera um nome `WebcamAndroid-XXXXXX` e uma senha aleatória de 10 caracteres (alfabeto sem caracteres ambíguos como `0/O/1/l/I`).
2. Codifica `WIFI:T:ADB;S:<nome>;P:<senha>;;` no QR. Esse é o formato que o Android espera em "Parear dispositivo com QR code".
3. Ao ler o QR, o celular anuncia `_adb-tls-pairing._tcp` **com aquele nome**. O timer encontra o serviço pelo nome e chama `adb pair <endereço> <senha>`.

### Por código de 6 dígitos

O usuário digita o código. O timer procura qualquer serviço de pareamento cujo nome **não** comece com `WebcamAndroid-` (ou seja, o anunciado pela tela "Parear com código") e chama `adb pair <endereço> <código>`. Desiste após 20 s.

### Máquina de estados da janela de pareamento

O timer de 1,2 s avança entre estes estados (`$st.phase`):

| Estado | O que o timer faz | Próximo estado |
|---|---|---|
| `wait` | Procura o serviço de pareamento com o nome do QR | `pairing` ao encontrar |
| `code` | (após clicar "Parear com código") procura um serviço de pareamento de outro nome | `pairing` ao encontrar; `wait` após 20 s |
| `pairing` | Roda `adb pair` | `connect` se `Successfully paired`; senão `wait` |
| `connect` | Roda `Connect-KnownDevices` + `Update-Devices` e procura um serial novo | `done` ao achar; `idle` após 20 s |
| `done` | Mostra "Pronto!" | Fecha a janela após 1,5 s |
| `idle` | Nada (avisa para usar "Reconectar aparelhos salvos") | — |

O serial "novo" é comparado com a lista que existia antes de abrir a janela; o primeiro novo é selecionado.

A flag `$script:busy` impede que o timer de pareamento e o timer principal rodem `adb` ao mesmo tempo.

## Reconexão automática

`Connect-KnownDevices` lista os serviços `_adb-tls-connect` e roda `adb connect` para cada um que ainda não aparece em `adb devices`. Só aparelhos **já pareados** aceitam a conexão; os outros recusam e são ignorados.

O timer principal (500 ms) faz isso a cada 10 ticks (~5 s), desde que:

- a câmera não esteja ligada;
- a janela de pareamento não esteja aberta;
- nenhuma outra operação adb esteja em andamento;
- a lista de aparelhos não esteja aberta (para não fechar o dropdown na mão do usuário).

`Update-Devices $true` (modo silencioso) só redesenha a lista quando o conjunto de seriais muda (`$script:devKey`).

A porta da Depuração sem fio muda toda vez que ela é ligada. Por isso o script prefere o serial mDNS (`adb-<id>._adb-tls-connect._tcp`) e a descoberta automática em vez de guardar IP:porta.

## Execução do scrcpy

`Get-ScrcpyArgs` monta a string de argumentos a partir de `$script:cfg` (tabela completa no README). O processo é iniciado assim:

```
cmd.exe /c ""<scrcpy.exe>" <args> > "%APPDATA%\WebcamAndroid\scrcpy.log" 2>&1"
```

- `CreateNoWindow` esconde o console; só a janela de vídeo do scrcpy aparece.
- A saída vai para um arquivo em vez de pipes do .NET porque ler pipes de forma assíncrona em PowerShell + Windows Forms é frágil (eventos rodam em outra thread). O timer da UI lê o arquivo incrementalmente (`$script:logPos`), abrindo com compartilhamento `ReadWrite, Delete`.
- **Parar** usa `taskkill /PID <cmd> /T /F` para matar o `cmd.exe` e o `scrcpy.exe` filho.
- Quando o processo termina sozinho (janela fechada, aparelho desconectado), o timer detecta `HasExited`, lê o resto do log e volta a interface para "Parada".

Enquanto a câmera está ligada, os grupos de configuração ficam desabilitados.

## Configuração

`$script:cfg` é uma hashtable com os padrões abaixo. Na inicialização, as chaves de `config.json` sobrescrevem os padrões. A config é gravada ao clicar em **Iniciar câmera**, **Conectar**, **Procurar...** e ao fechar a janela.

| Chave | Padrão | Descrição |
|---|---|---|
| `scrcpy` | `''` | Caminho do `scrcpy.exe` |
| `serial` | `''` | Serial adb do último aparelho usado |
| `facing` | `front` | `front` ou `back` |
| `size` | `1280x720` | Resolução |
| `fps` | `30` | Quadros por segundo |
| `orientation` | `0` | `0`, `90`, `180`, `270`, `flip0`, `flip90`, `flip180`, `flip270` |
| `bitrate` | `8M` | Bitrate do vídeo |
| `ontop` | `true` | Janela sempre no topo |
| `borderless` | `false` | Janela sem borda |
| `wifi` | `''` | Último IP:porta digitado no campo manual |

## Atalho na área de trabalho

Cria `Webcam Android.lnk` apontando para:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "<pasta do script>\WebcamAndroid.ps1"
```

com o ícone do `scrcpy.exe` (ou `shell32.dll,203` se o scrcpy não foi encontrado) e janela minimizada. Usa `$PSScriptRoot`, então o atalho aponta para onde o script está naquele momento. Se mover a pasta, crie o atalho de novo.

## Encoding

O arquivo contém textos com acento (interface em português). O Windows PowerShell 5.1 interpreta arquivos **sem BOM** usando a página de código ANSI do sistema, o que quebra os acentos. Por isso o arquivo é mantido em **UTF-8 com BOM** e CRLF.
