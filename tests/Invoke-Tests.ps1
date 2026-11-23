#Requires -Version 5.1
<#
    Testes do WebcamAndroid.ps1, sem dependencias (nao precisa de Pester).

    O script principal abre uma janela assim que roda, entao ele NAO e executado aqui.
    Em vez disso, o arquivo e lido como AST e so as partes testaveis sao carregadas:
    o gerador de QR (C#) e algumas funcoes puras.

    Uso:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
    Sai com codigo 1 se algum teste falhar.
#>
$ErrorActionPreference = 'Stop'
$Root   = Split-Path $PSScriptRoot -Parent
$Script = Join-Path $Root 'WebcamAndroid.ps1'

# ---------------- mini framework ----------------
$script:passed = 0
$script:failed = New-Object System.Collections.ArrayList
function Test([string]$name, [scriptblock]$body) {
    try {
        & $body
        $script:passed++
        Write-Host "  [ok]   $name" -ForegroundColor Green
    } catch {
        [void]$script:failed.Add($name)
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}
function Assert-True($cond, [string]$msg = 'esperava verdadeiro') { if (-not $cond) { throw $msg } }
function Assert-Equal($expected, $actual, [string]$msg = '') {
    if ($expected -cne $actual) { throw "esperado <$expected>, obtido <$actual> $msg" }
}
function Assert-Throws([scriptblock]$body) {
    $threw = $false
    try { & $body } catch { $threw = $true }
    if (-not $threw) { throw 'esperava uma excecao' }
}

# ---------------- carregar partes do script via AST ----------------
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$parseErrors)

function Import-ScriptFunction([string]$name) {
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) |
        Select-Object -First 1
    if (-not $fn) { throw "funcao $name nao encontrada no script" }
    . ([scriptblock]::Create($fn.Extent.Text))
    # redefine no escopo do script de teste
    Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
}

$qrSource = $ast.FindAll({ param($n)
        $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -match 'public static class MiniQr'
    }, $true) | Select-Object -First 1
if ($qrSource) {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition $qrSource.Value
}

# Leitor de QR independente do gerador: le o formato pelas posicoes da especificacao,
# remove a mascara, confere o Reed-Solomon pelas sindromes e decodifica o modo byte.
Add-Type -TypeDefinition @'
using System;
using System.Text;

public static class QrCheck {
    static readonly int[] EXP = new int[512];
    static readonly int[] LOG = new int[256];
    static QrCheck() {
        int x = 1;
        for (int i = 0; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if ((x & 0x100) != 0) x ^= 0x11D; }
        for (int i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
    }
    static int Mul(int a, int b) { return (a == 0 || b == 0) ? 0 : EXP[LOG[a] + LOG[b]]; }

    // Bits de formato, copia 1 e copia 2 (bit i = (fmt >> i) & 1)
    public static int Format1(bool[,] m) {
        int f = 0;
        for (int i = 0; i <= 5; i++) f |= (m[i, 8] ? 1 : 0) << i;
        f |= (m[7, 8] ? 1 : 0) << 6;
        f |= (m[8, 8] ? 1 : 0) << 7;
        f |= (m[8, 7] ? 1 : 0) << 8;
        for (int i = 9; i < 15; i++) f |= (m[8, 14 - i] ? 1 : 0) << i;
        return f;
    }
    public static int Format2(bool[,] m) {
        int n = m.GetLength(0), f = 0;
        for (int i = 0; i < 8; i++) f |= (m[8, n - 1 - i] ? 1 : 0) << i;
        for (int i = 8; i < 15; i++) f |= (m[n - 15 + i, 8] ? 1 : 0) << i;
        return f;
    }

    static bool IsFunction(int r, int c, int n) {
        if (r < 9 && c < 9) return true;               // localizador + separador + formato (sup. esq.)
        if (r < 9 && c >= n - 8) return true;          // localizador sup. dir. + formato
        if (r >= n - 8 && c < 9) return true;          // localizador inf. esq. + formato + modulo escuro
        if (r == 6 || c == 6) return true;             // timing
        if (Math.Abs(r - 22) <= 2 && Math.Abs(c - 22) <= 2) return true; // alinhamento (versao 3)
        return false;
    }

    public static int[] ReadCodewords(bool[,] m) {
        int n = m.GetLength(0);
        int[] cw = new int[70];
        int i = 0;
        for (int right = n - 1; right >= 1; right -= 2) {
            if (right == 6) right = 5;
            bool upward = ((right + 1) & 2) == 0;
            for (int vert = 0; vert < n; vert++) {
                int r = upward ? n - 1 - vert : vert;
                for (int j = 0; j < 2; j++) {
                    int c = right - j;
                    if (IsFunction(r, c, n) || i >= 70 * 8) continue;
                    bool bit = m[r, c] ^ ((r + c) % 2 == 0); // mascara 0
                    if (bit) cw[i >> 3] |= 1 << (7 - (i & 7));
                    i++;
                }
            }
        }
        return cw;
    }

    public static bool SyndromesZero(int[] cw, int ecLen) {
        for (int k = 0; k < ecLen; k++) {
            int s = 0;
            foreach (int c in cw) s = Mul(s, EXP[k]) ^ c;
            if (s != 0) return false;
        }
        return true;
    }

    public static string DecodeByteMode(int[] cw) {
        int pos = 0;
        Func<int, int> read = delegate(int len) {
            int v = 0;
            for (int k = 0; k < len; k++) { v = (v << 1) | ((cw[pos >> 3] >> (7 - (pos & 7))) & 1); pos++; }
            return v;
        };
        int mode = read(4);
        if (mode != 4) throw new Exception("modo inesperado: " + mode);
        int len2 = read(8);
        byte[] data = new byte[len2];
        for (int k = 0; k < len2; k++) data[k] = (byte)read(8);
        return Encoding.UTF8.GetString(data);
    }
}
'@

# ================================================================
Write-Host "`nArquivos" -ForegroundColor Cyan
# ================================================================

Test 'WebcamAndroid.ps1 nao tem erros de sintaxe' {
    Assert-Equal 0 $parseErrors.Count (($parseErrors | ForEach-Object { $_.Message }) -join '; ')
}

Test 'WebcamAndroid.ps1 esta em UTF-8 com BOM (exigido pelo PowerShell 5.1 por causa dos acentos)' {
    $b = [System.IO.File]::ReadAllBytes($Script)
    Assert-True ($b.Length -gt 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) 'BOM UTF-8 ausente'
}

foreach ($f in @('WebcamAndroid.ps1', 'Abrir Webcam Android.cmd')) {
    Test "$f usa CRLF em todas as linhas" {
        $text = [System.IO.File]::ReadAllText((Join-Path $Root $f))
        $bareLf = [regex]::Matches($text, '(?<!\r)\n').Count
        Assert-Equal 0 $bareLf 'quebras de linha LF sem CR'
    }
}

Test 'Launcher .cmd chama o WebcamAndroid.ps1 da mesma pasta' {
    $cmd = Get-Content (Join-Path $Root 'Abrir Webcam Android.cmd') -Raw
    Assert-True ($cmd -match '%~dp0WebcamAndroid\.ps1') 'caminho do script nao encontrado no .cmd'
}

# ================================================================
Write-Host "`nGerador de QR (MiniQr)" -ForegroundColor Cyan
# ================================================================

Test 'Codigo C# do MiniQr foi encontrado e compilou' {
    Assert-True ($null -ne $qrSource) 'here-string do MiniQr nao encontrado'
    Assert-True ($null -ne ('MiniQr' -as [type])) 'tipo MiniQr nao carregado'
}

$samples = @(
    'WIFI:T:ADB;S:WebcamAndroid-AbC234;P:xYz23456Kq;;',
    'A',
    'texto com acentuação: câmera',
    ('x' * 53)
)

foreach ($text in $samples) {
    $label = if ($text.Length -gt 30) { $text.Substring(0, 30) + '...' } else { $text }
    Test "Codifica e decodifica de volta: '$label'" {
        $m = [MiniQr]::Encode($text)
        Assert-Equal 29 $m.GetLength(0) 'linhas'
        Assert-Equal 29 $m.GetLength(1) 'colunas'
        $cw = [QrCheck]::ReadCodewords($m)
        Assert-True ([QrCheck]::SyndromesZero($cw, 15)) 'Reed-Solomon invalido'
        Assert-Equal $text ([QrCheck]::DecodeByteMode($cw))
    }
}

Test 'Informacao de formato = nivel L, mascara 0 (0x77C4) nas duas copias' {
    $m = [MiniQr]::Encode('teste')
    Assert-Equal 0x77C4 ([QrCheck]::Format1($m)) 'copia 1'
    Assert-Equal 0x77C4 ([QrCheck]::Format2($m)) 'copia 2'
}

Test 'Padroes fixos: localizadores, timing, alinhamento e modulo escuro' {
    $m = [MiniQr]::Encode('teste')
    $n = 29
    foreach ($o in @(@(0, 0), @(0, ($n - 7)), @(($n - 7), 0))) {
        for ($r = 0; $r -lt 7; $r++) {
            for ($c = 0; $c -lt 7; $c++) {
                $ring = ($r -eq 0 -or $r -eq 6 -or $c -eq 0 -or $c -eq 6)
                $core = ($r -ge 2 -and $r -le 4 -and $c -ge 2 -and $c -le 4)
                Assert-Equal ($ring -or $core) $m[($o[0] + $r), ($o[1] + $c)] "localizador em $($o -join ',') ($r,$c)"
            }
        }
    }
    for ($i = 8; $i -lt $n - 8; $i++) {
        Assert-Equal ($i % 2 -eq 0) $m[6, $i] "timing horizontal $i"
        Assert-Equal ($i % 2 -eq 0) $m[$i, 6] "timing vertical $i"
    }
    for ($r = -2; $r -le 2; $r++) {
        for ($c = -2; $c -le 2; $c++) {
            $dark = [Math]::Max([Math]::Abs($r), [Math]::Abs($c)) -ne 1
            Assert-Equal $dark $m[(22 + $r), (22 + $c)] "alinhamento ($r,$c)"
        }
    }
    Assert-True $m[($n - 8), 8] 'modulo escuro'
}

Test 'Recusa texto maior que 53 bytes' {
    Assert-Throws { [MiniQr]::Encode('x' * 54) }
    Assert-Throws { [MiniQr]::Encode('ç' * 27) }   # 54 bytes em UTF-8
}

Test 'ToBitmap tem zona de silencio de 4 modulos e escala correta' {
    $scale = 8
    $bmp = [MiniQr]::ToBitmap('teste', $scale)
    try {
        Assert-Equal ((29 + 8) * $scale) $bmp.Width 'largura'
        Assert-Equal $bmp.Width $bmp.Height 'altura'
        Assert-Equal 'ffffffff' $bmp.GetPixel(0, 0).Name 'zona de silencio deveria ser branca'
        Assert-Equal 'ff000000' $bmp.GetPixel(4 * $scale, 4 * $scale).Name 'canto do localizador deveria ser preto'
    } finally { $bmp.Dispose() }
}

# ================================================================
Write-Host "`nFuncoes" -ForegroundColor Cyan
# ================================================================

Import-ScriptFunction 'Get-ScrcpyArgs'
Import-ScriptFunction 'Get-MdnsServices'
Import-ScriptFunction 'Connect-KnownDevices'
Import-ScriptFunction 'New-RandomText'

function New-TestConfig {
    @{
        scrcpy = ''; serial = ''; facing = 'front'; size = '1280x720'; fps = '30'
        orientation = '0'; bitrate = '8M'; ontop = $true; borderless = $false; wifi = ''
    }
}

Test 'Get-ScrcpyArgs com a configuracao padrao' {
    $script:cfg = New-TestConfig
    Assert-Equal '--video-source=camera --camera-facing=front --camera-size=1280x720 --camera-fps=30 --video-bit-rate=8M --no-audio --window-title="Webcam Android" --always-on-top' (Get-ScrcpyArgs)
}

Test 'Get-ScrcpyArgs com serial, traseira, orientacao e sem borda' {
    $script:cfg = New-TestConfig
    $script:cfg.serial = 'adb-R58N123-abc._adb-tls-connect._tcp'
    $script:cfg.facing = 'back'
    $script:cfg.size = '1920x1080'
    $script:cfg.fps = '60'
    $script:cfg.bitrate = '16M'
    $script:cfg.orientation = 'flip90'
    $script:cfg.ontop = $false
    $script:cfg.borderless = $true
    Assert-Equal '-s adb-R58N123-abc._adb-tls-connect._tcp --video-source=camera --camera-facing=back --camera-size=1920x1080 --camera-fps=60 --video-bit-rate=16M --orientation=flip90 --no-audio --window-title="Webcam Android" --window-borderless' (Get-ScrcpyArgs)
}

Test 'Get-ScrcpyArgs omite --camera-size quando a resolucao esta vazia' {
    $script:cfg = New-TestConfig
    $script:cfg.size = ''
    Assert-True ((Get-ScrcpyArgs) -notmatch '--camera-size') 'nao deveria ter --camera-size'
}

# adb falso: devolve saidas fixas e registra as chamadas
$script:adbCalls = New-Object System.Collections.ArrayList
$script:fakeDevices = @('List of devices attached')
function Invoke-FakeAdb {
    [void]$script:adbCalls.Add(($args -join ' '))
    switch ($args[0]) {
        'mdns' {
            'List of discovered mdns services'
            "adb-R58N123-abc`t_adb-tls-connect._tcp`t192.168.0.10:37123"
            "adb-ZZ99-def`t_adb-tls-connect._tcp.`t192.168.0.11:40001"
            "WebcamAndroid-AbC234`t_adb-tls-pairing._tcp`t192.168.0.12:41234"
            "adb-R58N123-abc`t_adb._tcp`t192.168.0.10:5555"
        }
        'devices' { $script:fakeDevices }
        'connect' { "connected to $($args[1])" }
    }
}
function Get-Adb { 'Invoke-FakeAdb' }
function Write-Log($msg) { }

Test 'Get-MdnsServices le servicos de pareamento e conexao e ignora o resto' {
    $s = @(Get-MdnsServices)
    Assert-Equal 3 $s.Count 'quantidade'
    Assert-Equal 'adb-R58N123-abc' $s[0].Name
    Assert-Equal 'connect' $s[0].Kind
    Assert-Equal '192.168.0.10:37123' $s[0].Addr
    Assert-Equal '192.168.0.11:40001' $s[1].Addr 'aceita o ponto final em _tcp.'
    Assert-Equal 'pairing' $s[2].Kind
    Assert-Equal 'WebcamAndroid-AbC234' $s[2].Name
}

Test 'Connect-KnownDevices so conecta aparelhos que ainda nao estao conectados' {
    $script:adbCalls.Clear()
    $script:fakeDevices = @('List of devices attached', "adb-R58N123-abc._adb-tls-connect._tcp`tdevice")
    Connect-KnownDevices $false
    $connects = @($script:adbCalls | Where-Object { $_ -like 'connect *' })
    Assert-Equal 1 $connects.Count 'quantidade de adb connect'
    Assert-Equal 'connect 192.168.0.11:40001' $connects[0]
}

Test 'Connect-KnownDevices nao conecta nada quando todos ja estao na lista' {
    $script:adbCalls.Clear()
    $script:fakeDevices = @('List of devices attached', "adb-R58N123-abc._adb-tls-connect._tcp`tdevice", "192.168.0.11:40001`tdevice")
    Connect-KnownDevices $false
    Assert-Equal 0 @($script:adbCalls | Where-Object { $_ -like 'connect *' }).Count
}

Test 'New-RandomText gera o tamanho pedido sem caracteres ambiguos' {
    for ($i = 0; $i -lt 50; $i++) {
        $t = New-RandomText 10
        Assert-Equal 10 $t.Length
        Assert-True ($t -cmatch '^[A-HJ-NP-Za-kmnp-z2-9]+$') "caractere inesperado em '$t'"
    }
}

# ---------------- resultado ----------------
Write-Host ''
if ($script:failed.Count -gt 0) {
    Write-Host ("{0} passaram, {1} falharam: {2}" -f $script:passed, $script:failed.Count, ($script:failed -join '; ')) -ForegroundColor Red
    exit 1
}
Write-Host ("Todos os {0} testes passaram." -f $script:passed) -ForegroundColor Green
exit 0
