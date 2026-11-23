# Webcam Android (windroidcam)

Use a câmera do celular ou tablet Android como webcam no Windows, via **ADB** (USB ou Wi-Fi), com uma interface gráfica simples.

É um único script PowerShell (`WebcamAndroid.ps1`) que monta uma janela Windows Forms por cima do [scrcpy](https://github.com/Genymobile/scrcpy). O scrcpy abre a câmera do aparelho e mostra a imagem numa janela chamada **"Webcam Android"**; o OBS Studio captura essa janela e a publica como câmera virtual, que aparece no Discord, Meet, Teams, Zoom etc.

```
Celular (câmera) ──ADB/USB ou Wi-Fi──▶ scrcpy (janela "Webcam Android") ──▶ OBS (Câmera virtual) ──▶ Discord / Meet / Zoom
```

## Recursos

- Pareamento Wi-Fi **por QR code** (o QR é gerado pelo próprio script, sem bibliotecas externas) ou **por código de 6 dígitos**. Nos dois casos o IP e a porta são descobertos sozinhos via mDNS.
- **Reconexão automática**: a cada ~5 s o script procura na rede os aparelhos já pareados e conecta os que não estiverem na lista.
- Funciona também por **cabo USB** (com Depuração USB ligada).
- Escolha de câmera frontal ou traseira, resolução (com botão que lista as resoluções suportadas pelo aparelho), FPS, bitrate, rotação e espelhamento.
- Janela "Sempre no topo" e "Sem borda", úteis para capturar no OBS.
- Log do scrcpy dentro da própria janela.
- Configurações salvas automaticamente entre execuções.
- Botão para criar um atalho na área de trabalho.
- Nenhuma instalação: não precisa de Python, Node nem permissão de administrador.

## Requisitos

| O quê | Versão | Observação |
|---|---|---|
| Windows | 10 ou 11 | Usa o Windows PowerShell 5.1, que já vem no sistema |
| [scrcpy](https://github.com/Genymobile/scrcpy) | 3.0 ou mais novo (recomendado) | Câmera existe desde a 2.2; testado com a 5.0.1. O `adb.exe` vem junto |
| Android | 12 ou mais novo | Exigência do scrcpy para espelhar a **câmera** |
| Android (Wi-Fi) | 11 ou mais novo | Para "Depuração sem fio". Com cabo USB não precisa |
| [OBS Studio](https://obsproject.com/) | 26 ou mais novo | Opcional: só se quiser a câmera virtual para outros apps |

PC e celular precisam estar **na mesma rede** para usar Wi-Fi.

## Instalação

1. Instale o scrcpy:

   ```powershell
   winget install Genymobile.scrcpy
   ```

   Ou baixe o zip `scrcpy-win64-*.zip` na [página de releases](https://github.com/Genymobile/scrcpy/releases) e extraia em qualquer pasta.

2. Baixe este repositório (Code > Download ZIP, ou `git clone`) e extraia numa pasta fixa, por exemplo `C:\Ferramentas\windroidcam`.

3. Dê dois cliques em **`Abrir Webcam Android.cmd`**.

   Ou rode direto:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Ferramentas\windroidcam\WebcamAndroid.ps1"
   ```

4. Na janela, clique em **Criar atalho na área de trabalho** se quiser um atalho.

O script acha o scrcpy sozinho quando ele foi instalado pelo winget ou está no `PATH`. Se não achar, use o botão **Procurar...** e aponte para o `scrcpy.exe`.

> `-ExecutionPolicy Bypass` vale só para esta execução e não altera a política do sistema.

## Preparar o celular (uma vez só)

1. **Ativar as Opções do desenvolvedor:** Configurações > Sobre o telefone > toque 7 vezes em **Número da versão** (em alguns aparelhos fica em "Informações do software").
2. Em **Opções do desenvolvedor**, ligue:
   - **Depuração USB**, para usar com cabo;
   - **Depuração sem fio**, para usar pelo Wi-Fi.

## Uso

### Conectar pelo Wi-Fi (recomendado)

1. Na janela, clique em **Adicionar aparelho (QR ou código)...**.
2. No celular: Opções do desenvolvedor > **Depuração sem fio** > **Parear dispositivo com QR code** e aponte para o QR da tela.
   - Alternativa: **Parear dispositivo com código de pareamento** e digite os 6 dígitos no campo da janela. Deixe essa tela aberta no celular até o pareamento terminar.
3. Quando aparecer "Pronto!", a janela fecha e o aparelho já está selecionado.

O pareamento é feito **uma vez por aparelho**. Nas próximas vezes basta a Depuração sem fio estar ligada: o script reconecta sozinho, ou você clica em **Reconectar aparelhos salvos**.

Se o mDNS não funcionar na sua rede, use o campo **Manual (IP:porta)** com o endereço mostrado na tela "Depuração sem fio" (o aparelho já precisa estar pareado).

### Conectar por USB

Ligue o cabo, aceite o aviso "Permitir depuração USB?" no celular e clique em **Atualizar**.

### Ligar a câmera

1. Escolha o aparelho, **Frontal/Traseira**, resolução, FPS e qualidade.
   - **Ver resoluções** consulta o aparelho e preenche a lista com as resoluções que a câmera escolhida aceita.
2. Clique em **Iniciar câmera**. Abre a janela "Webcam Android" com a imagem.
3. **Parar** encerra o scrcpy. Fechar a janela principal também encerra.

### Usar como webcam em outros apps (OBS)

1. No OBS, adicione uma fonte **Captura de janela** e escolha `[scrcpy.exe]: Webcam Android`.
   - Se a imagem ficar preta, mude o "Método de captura" para **Windows 10 (1903 e superior)**.
2. Ajuste a fonte ao tamanho da cena (botão direito > Transformar > Ajustar à tela).
3. Clique em **Iniciar câmera virtual**.
4. No Discord/Meet/Zoom/Teams, escolha **OBS Virtual Camera** como câmera.

A janela do scrcpy precisa continuar aberta (pode ficar atrás de outras janelas, mas não minimizada).

## Opções da interface

| Opção | Efeito | Argumento do scrcpy |
|---|---|---|
| Frontal / Traseira | Qual câmera usar | `--camera-facing=front\|back` |
| Resolução | Tamanho do vídeo (`LxA`). Aceita digitar qualquer valor | `--camera-size=` |
| FPS | 15, 24, 30 ou 60 | `--camera-fps=` |
| Qualidade | Bitrate do vídeo: 2M, 4M, 8M, 16M | `--video-bit-rate=` |
| Orientação | Rotação e espelhamento | `--orientation=0\|90\|180\|270\|flip0\|flip90\|flip180\|flip270` |
| Sempre no topo | Janela fica por cima das outras | `--always-on-top` |
| Sem borda | Remove a moldura da janela | `--window-borderless` |

O áudio é sempre desligado (`--no-audio`). Exemplo do comando que o script monta (aparece no log):

```
scrcpy -s 192.168.0.10:37123 --video-source=camera --camera-facing=front --camera-size=1280x720 --camera-fps=30 --video-bit-rate=8M --no-audio --window-title="Webcam Android" --always-on-top
```

## Onde ficam os dados

Tudo fica em `%APPDATA%\WebcamAndroid\`:

| Arquivo | Conteúdo |
|---|---|
| `config.json` | Últimas escolhas da interface (veja abaixo) |
| `scrcpy.log` | Saída do scrcpy da última execução (sobrescrito a cada "Iniciar câmera") |

Exemplo de `config.json`:

```json
{
  "scrcpy": "C:\\...\\scrcpy-win64-v5.0.1\\scrcpy.exe",
  "serial": "adb-R58N123ABC-xYz12a._adb-tls-connect._tcp",
  "facing": "front",
  "size": "1280x720",
  "fps": "30",
  "orientation": "0",
  "bitrate": "8M",
  "ontop": true,
  "borderless": false,
  "wifi": ""
}
```

Para voltar às configurações padrão, apague esse arquivo.

## Solução de problemas

| Sintoma | O que fazer |
|---|---|
| Acentos aparecem errados na janela (`CÃ¢mera`) | O `.ps1` perdeu o BOM UTF-8. O Windows PowerShell 5.1 lê arquivos sem BOM como ANSI. Salve de novo como **UTF-8 com BOM** (veja [Desenvolvimento](#desenvolvimento)) |
| "scrcpy não encontrado" | Use **Procurar...** e aponte para o `scrcpy.exe` |
| Nenhum aparelho aparece | Confira se a Depuração sem fio está ligada e se PC e celular estão na mesma rede. Clique em **Reconectar aparelhos salvos** |
| O QR não é reconhecido / fica em "Aguardando o aparelho..." | Use o pareamento por código. Redes com "isolamento de clientes" (Wi-Fi de visitante, hotspots corporativos) bloqueiam o mDNS: use outra rede ou o roteador do celular |
| Aparelho `unauthorized` | Aceite o aviso de depuração no celular. Se não aparecer, em Opções do desenvolvedor use **Revogar autorizações de depuração USB** e conecte de novo |
| Aparelho `offline` | Desligue e ligue a Depuração sem fio, ou rode `adb kill-server` e clique em **Atualizar** |
| scrcpy fecha logo após iniciar | Leia o log na janela. Causas comuns: resolução não suportada (use **Ver resoluções**), Android abaixo do 12, ou outro app usando a câmera no celular |
| Imagem deitada ou invertida | Ajuste **Orientação** |
| Imagem preta no OBS | Método de captura **Windows 10 (1903 e superior)** e não minimize a janela do scrcpy |
| Imagem travando no Wi-Fi | Baixe a qualidade para 4M ou 2M, use 720p/30fps, ou use cabo USB |
| Conexão cai quando a tela do celular apaga | Em alguns aparelhos a Depuração sem fio desliga com economia de energia. Deixe o celular carregando ou use USB |
| Firewall do Windows pergunta sobre o `adb.exe` | Permita em **Redes privadas**. Sem isso a descoberta por mDNS não funciona |

## Limitações

- Só Windows (usa Windows Forms e o PowerShell 5.1).
- Sem áudio: o microfone do celular não é usado.
- A câmera virtual depende do OBS (ou outro programa que capture janela). O script não cria um dispositivo de câmera próprio.
- O nome do serviço de pareamento cabe num QR versão 3 (até 53 bytes), o que é mais que suficiente para o formato usado.

## Desenvolvimento

- Arquivo único: [`WebcamAndroid.ps1`](WebcamAndroid.ps1). Como ele funciona por dentro está em [`docs/ARQUITETURA.md`](docs/ARQUITETURA.md).
- **Encoding:** o `.ps1` precisa ser salvo como **UTF-8 com BOM** e **CRLF**. O `.gitattributes` mantém o CRLF; o BOM o git preserva como está. No VS Code: barra de status > "UTF-8" > *Save with Encoding* > *UTF-8 with BOM*.
- O botão de atalho procura `WebcamAndroid.ps1` na mesma pasta do script: não renomeie o arquivo.
- Testes automatizados (sem dependências, rodam também no GitHub Actions a cada push):

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
  ```

  Eles não abrem a janela: leem o script como AST e testam o encoding do arquivo, o gerador de QR (decodificando o QR de volta e conferindo o Reed-Solomon) e as funções que montam o comando do scrcpy e leem a saída do `adb`.
- Para testar a interface, rode sem `-WindowStyle Hidden` para ver erros no console:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\WebcamAndroid.ps1
  ```

## Créditos

- [scrcpy](https://github.com/Genymobile/scrcpy) (Genymobile), que faz todo o trabalho de vídeo.
- [Android Debug Bridge (adb)](https://developer.android.com/tools/adb), distribuído junto com o scrcpy.

## Licença

[MIT](LICENSE). O scrcpy, que este projeto usa mas não inclui, é distribuído sob a licença Apache 2.0.
