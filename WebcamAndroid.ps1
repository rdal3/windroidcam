﻿#Requires -Version 5.1
# Webcam Android - interface para usar a camera do celular/tablet via scrcpy
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ErrorActionPreference = 'Continue'
$AppDir  = Join-Path $env:APPDATA 'WebcamAndroid'
$CfgPath = Join-Path $AppDir 'config.json'
$LogPath = Join-Path $AppDir 'scrcpy.log'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

$script:proc       = $null
$script:logPos     = 0L
$script:serials    = New-Object System.Collections.ArrayList
$script:devKey     = ''
$script:dialogOpen = $false
$script:busy       = $false

# ---------------- gerador de QR (versao 3-L, sem dependencias) ----------------
$script:qrOk = $true
try {
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Text;

public static class MiniQr {
    static readonly int[] EXP = new int[512];
    static readonly int[] LOG = new int[256];
    const int N = 29;

    static MiniQr() {
        int x = 1;
        for (int i = 0; i < 255; i++) {
            EXP[i] = x; LOG[x] = i; x <<= 1;
            if ((x & 0x100) != 0) x ^= 0x11D;
        }
        for (int i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
    }

    static int Mul(int a, int b) {
        if (a == 0 || b == 0) return 0;
        return EXP[LOG[a] + LOG[b]];
    }

    static int[] Rs(int[] data, int n) {
        int[] gen = new int[] { 1 };
        for (int i = 0; i < n; i++) {
            int[] ng = new int[gen.Length + 1];
            for (int j = 0; j < gen.Length; j++) {
                ng[j] ^= gen[j];
                ng[j + 1] ^= Mul(gen[j], EXP[i]);
            }
            gen = ng;
        }
        int[] res = new int[n];
        foreach (int d in data) {
            int f = d ^ res[0];
            for (int j = 0; j < n - 1; j++) res[j] = res[j + 1];
            res[n - 1] = 0;
            for (int j = 0; j < n; j++) res[j] ^= Mul(gen[j + 1], f);
        }
        return res;
    }

    static void Set(int[,] m, bool[,] f, int r, int c, int v) { m[r, c] = v; f[r, c] = true; }

    static void Finder(int[,] m, bool[,] f, int r0, int c0) {
        for (int r = -1; r <= 7; r++) {
            for (int c = -1; c <= 7; c++) {
                int rr = r0 + r, cc = c0 + c;
                if (rr < 0 || rr >= N || cc < 0 || cc >= N) continue;
                bool inside = r >= 0 && r <= 6 && c >= 0 && c <= 6;
                bool on = inside && (r == 0 || r == 6 || c == 0 || c == 6 || (r >= 2 && r <= 4 && c >= 2 && c <= 4));
                Set(m, f, rr, cc, on ? 1 : 0);
            }
        }
    }

    public static bool[,] Encode(string text) {
        byte[] data = Encoding.UTF8.GetBytes(text);
        if (data.Length > 53) throw new ArgumentException("Texto longo demais para QR versao 3-L");

        List<int> bits = new List<int>();
        Action<int, int> put = delegate(int v, int n) {
            for (int i = n - 1; i >= 0; i--) bits.Add((v >> i) & 1);
        };
        put(4, 4);
        put(data.Length, 8);
        foreach (byte b in data) put(b, 8);
        int term = Math.Min(4, 55 * 8 - bits.Count);
        for (int i = 0; i < term; i++) bits.Add(0);
        while (bits.Count % 8 != 0) bits.Add(0);

        int[] cw = new int[70];
        int nData = bits.Count / 8;
        for (int i = 0; i < nData; i++) {
            int v = 0;
            for (int k = 0; k < 8; k++) v = (v << 1) | bits[i * 8 + k];
            cw[i] = v;
        }
        int pk = 0;
        for (int i = nData; i < 55; i++) { cw[i] = (pk % 2 == 0) ? 0xEC : 0x11; pk++; }
        int[] dataCw = new int[55];
        Array.Copy(cw, dataCw, 55);
        int[] ecc = Rs(dataCw, 15);
        Array.Copy(ecc, 0, cw, 55, 15);

        int[,] m = new int[N, N];
        bool[,] f = new bool[N, N];
        Finder(m, f, 0, 0);
        Finder(m, f, 0, N - 7);
        Finder(m, f, N - 7, 0);
        for (int i = 8; i < N - 8; i++) {
            Set(m, f, 6, i, i % 2 == 0 ? 1 : 0);
            Set(m, f, i, 6, i % 2 == 0 ? 1 : 0);
        }
        for (int r = -2; r <= 2; r++)
            for (int c = -2; c <= 2; c++)
                Set(m, f, 22 + r, 22 + c, Math.Max(Math.Abs(r), Math.Abs(c)) != 1 ? 1 : 0);
        Set(m, f, N - 8, 8, 1);
        for (int i = 0; i < 9; i++) {
            if (!f[8, i]) Set(m, f, 8, i, 0);
            if (!f[i, 8]) Set(m, f, i, 8, 0);
        }
        for (int i = 0; i < 8; i++) {
            if (!f[8, N - 1 - i]) Set(m, f, 8, N - 1 - i, 0);
            if (!f[N - 1 - i, 8]) Set(m, f, N - 1 - i, 8, 0);
        }

        int total = 70 * 8, idx = 0;
        bool up = true;
        for (int col = N - 1; col > 0; col -= 2) {
            if (col == 6) col--;
            for (int i = 0; i < N; i++) {
                int r = up ? N - 1 - i : i;
                for (int dc = 0; dc < 2; dc++) {
                    int c = col - dc;
                    if (f[r, c]) continue;
                    int v = idx < total ? (cw[idx / 8] >> (7 - idx % 8)) & 1 : 0;
                    idx++;
                    if ((r + c) % 2 == 0) v ^= 1;
                    m[r, c] = v;
                }
            }
            up = !up;
        }

        int fmt = (1 << 3) | 0;
        int rem = fmt;
        for (int i = 0; i < 10; i++) rem = (rem << 1) ^ (((rem >> 9) & 1) * 0x537);
        int fb = ((fmt << 10) | (rem & 0x3FF)) ^ 0x5412;
        for (int i = 0; i < 6; i++) m[i, 8] = (fb >> i) & 1;
        m[7, 8] = (fb >> 6) & 1;
        m[8, 8] = (fb >> 7) & 1;
        m[8, 7] = (fb >> 8) & 1;
        for (int i = 9; i < 15; i++) m[8, 14 - i] = (fb >> i) & 1;
        for (int i = 0; i < 8; i++) m[8, N - 1 - i] = (fb >> i) & 1;
        for (int i = 8; i < 15; i++) m[N - 15 + i, 8] = (fb >> i) & 1;
        m[N - 8, 8] = 1;

        bool[,] outM = new bool[N, N];
        for (int r = 0; r < N; r++)
            for (int c = 0; c < N; c++)
                outM[r, c] = m[r, c] == 1;
        return outM;
    }

    public static Bitmap ToBitmap(string text, int scale) {
        bool[,] q = Encode(text);
        int quiet = 4;
        int size = (N + 2 * quiet) * scale;
        Bitmap bmp = new Bitmap(size, size);
        using (Graphics g = Graphics.FromImage(bmp)) {
            g.Clear(Color.White);
            for (int r = 0; r < N; r++)
                for (int c = 0; c < N; c++)
                    if (q[r, c]) g.FillRectangle(Brushes.Black, (c + quiet) * scale, (r + quiet) * scale, scale, scale);
        }
        return bmp;
    }
}
'@
} catch {
    $script:qrOk = $false
}

# ---------------- configuracao ----------------
$script:cfg = @{
    scrcpy = ''; serial = ''; facing = 'front'; size = '1280x720'; fps = '30'
    orientation = '0'; bitrate = '8M'; ontop = $true; borderless = $false; wifi = ''
}
if (Test-Path $CfgPath) {
    try {
        $j = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $script:cfg[$p.Name] = $p.Value }
    } catch {}
}
function Save-Config {
    try { $script:cfg | ConvertTo-Json | Set-Content -Path $CfgPath -Encoding UTF8 } catch {}
}

# ---------------- localizar scrcpy / adb ----------------
function Find-Scrcpy {
    if ($script:cfg.scrcpy -and (Test-Path $script:cfg.scrcpy)) { return $script:cfg.scrcpy }
    $base = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path $base) {
        $found = Get-ChildItem $base -Directory -Filter 'Genymobile.scrcpy*' -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter 'scrcpy.exe' -ErrorAction SilentlyContinue } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    $cmd = Get-Command scrcpy.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $item = Get-Item $cmd.Source
        if ($item.Target) { return [string]($item.Target | Select-Object -First 1) }
        return $cmd.Source
    }
    return $null
}
function Get-Adb {
    if ($script:cfg.scrcpy) {
        $p = Join-Path (Split-Path $script:cfg.scrcpy) 'adb.exe'
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# ---------------- helpers ----------------
$fontUI = New-Object System.Drawing.Font('Segoe UI', 9)
function New-Ctl($type, $x, $y, $w, $h, $text, $parent) {
    $c = New-Object "System.Windows.Forms.$type"
    $c.Location = New-Object System.Drawing.Point($x, $y)
    $c.Size = New-Object System.Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }
    $parent.Controls.Add($c)
    return $c
}
function Write-Log([string]$msg) {
    if ($null -eq $msg) { return }
    $txtLog.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $msg))
}
function Invoke-Tool([string]$exe, [string[]]$argList) {
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $out = & $exe @argList 2>&1 | ForEach-Object { "$_" }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    return $out
}
function New-RandomText([int]$len) {
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'.ToCharArray()
    -join (1..$len | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# Servicos mDNS anunciados pelos aparelhos (Depuracao sem fio)
function Get-MdnsServices {
    $adb = Get-Adb
    if (-not $adb) { return @() }
    $list = @()
    foreach ($l in (& $adb mdns services 2>&1 | ForEach-Object { "$_" })) {
        if ($l -match '^(\S+)\s+(_adb-tls-(pairing|connect)\._tcp)\.?\s+(\d+\.\d+\.\d+\.\d+:\d+)') {
            $list += [pscustomobject]@{ Name = $Matches[1]; Kind = $Matches[3]; Addr = $Matches[4] }
        }
    }
    return $list
}

# Conecta aparelhos ja pareados que estao anunciando na rede e ainda nao estao na lista
function Connect-KnownDevices([bool]$verbose) {
    $adb = Get-Adb
    if (-not $adb) { return }
    $current = (& $adb devices 2>&1 | ForEach-Object { "$_" }) -join "`n"
    foreach ($s in (Get-MdnsServices | Where-Object { $_.Kind -eq 'connect' })) {
        if ($current -match [regex]::Escape($s.Name) -or $current -match [regex]::Escape($s.Addr)) { continue }
        $r = (& $adb connect $s.Addr 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($verbose) { Write-Log $r }
    }
}

# ---------------- janela principal ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Webcam Android'
$form.ClientSize = New-Object System.Drawing.Size(560, 700)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = $fontUI

$grpApp = New-Ctl GroupBox 10 8 540 55 'scrcpy' $form
$txtScrcpy = New-Ctl TextBox 10 22 415 23 '' $grpApp
$txtScrcpy.ReadOnly = $true
$btnBrowse = New-Ctl Button 430 20 100 27 'Procurar...' $grpApp

$grpDev = New-Ctl GroupBox 10 70 540 122 'Dispositivo' $form
$cmbDev = New-Ctl ComboBox 10 22 415 23 '' $grpDev
$cmbDev.DropDownStyle = 'DropDownList'
$btnRefresh = New-Ctl Button 430 20 100 27 'Atualizar' $grpDev
$btnAdd = New-Ctl Button 10 53 270 29 'Adicionar aparelho (QR ou código)...' $grpDev
$btnAdd.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$btnReconnect = New-Ctl Button 285 53 245 29 'Reconectar aparelhos salvos' $grpDev
[void](New-Ctl Label 10 92 155 20 'Manual (IP:porta)' $grpDev)
$txtWifi = New-Ctl TextBox 168 89 257 23 '' $grpDev
$btnConnect = New-Ctl Button 430 87 100 27 'Conectar' $grpDev

$grpCam = New-Ctl GroupBox 10 199 540 158 'Câmera' $form
$rbFront = New-Ctl RadioButton 10 22 90 22 'Frontal' $grpCam
$rbBack  = New-Ctl RadioButton 105 22 90 22 'Traseira' $grpCam
[void](New-Ctl Label 10 58 80 20 'Resolução' $grpCam)
$cmbSize = New-Ctl ComboBox 95 55 130 23 '' $grpCam
$cmbSize.DropDownStyle = 'DropDown'
[void]$cmbSize.Items.AddRange(@('640x480', '1280x720', '1920x1080'))
$btnSizes = New-Ctl Button 235 53 140 27 'Ver resoluções' $grpCam
[void](New-Ctl Label 10 91 80 20 'FPS' $grpCam)
$cmbFps = New-Ctl ComboBox 95 88 70 23 '' $grpCam
$cmbFps.DropDownStyle = 'DropDownList'
[void]$cmbFps.Items.AddRange(@('15', '24', '30', '60'))
[void](New-Ctl Label 180 91 70 20 'Qualidade' $grpCam)
$cmbBitrate = New-Ctl ComboBox 255 88 120 23 '' $grpCam
$cmbBitrate.DropDownStyle = 'DropDownList'
[void]$cmbBitrate.Items.AddRange(@('2M', '4M', '8M', '16M'))
[void](New-Ctl Label 10 124 80 20 'Orientação' $grpCam)
$cmbOrient = New-Ctl ComboBox 95 121 160 23 '' $grpCam
$cmbOrient.DropDownStyle = 'DropDownList'
$orientMap = [ordered]@{
    'Normal' = '0'; 'Girar 90°' = '90'; 'Girar 180°' = '180'; 'Girar 270°' = '270'
    'Espelhar' = 'flip0'; 'Espelhar + 90°' = 'flip90'; 'Espelhar + 180°' = 'flip180'; 'Espelhar + 270°' = 'flip270'
}
[void]$cmbOrient.Items.AddRange([string[]]$orientMap.Keys)
$chkTop = New-Ctl CheckBox 270 122 130 22 'Sempre no topo' $grpCam
$chkBorder = New-Ctl CheckBox 405 122 120 22 'Sem borda' $grpCam

$btnStart = New-Ctl Button 10 366 265 42 'Iniciar câmera' $form
$btnStart.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnStop = New-Ctl Button 285 366 265 42 'Parar' $form
$btnStop.Font = $btnStart.Font
$btnStop.Enabled = $false
$lblStatus = New-Ctl Label 10 414 540 20 'Parada' $form

$txtLog = New-Ctl TextBox 10 436 540 200 '' $form
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 8.5)

$btnShortcut = New-Ctl Button 10 644 230 28 'Criar atalho na área de trabalho' $form
$lblHint = New-Ctl Label 250 644 300 50 'OBS: Captura de janela > "Webcam Android" > Iniciar câmera virtual' $form
$lblHint.ForeColor = [System.Drawing.Color]::DimGray

# ---------------- aplicar config ----------------
$scr = Find-Scrcpy
if ($scr) { $script:cfg.scrcpy = $scr }
$txtScrcpy.Text = $script:cfg.scrcpy
if ($script:cfg.facing -eq 'back') { $rbBack.Checked = $true } else { $rbFront.Checked = $true }
$cmbSize.Text = $script:cfg.size
$cmbFps.SelectedItem = [string]$script:cfg.fps
if ($cmbFps.SelectedIndex -lt 0) { $cmbFps.SelectedItem = '30' }
$cmbBitrate.SelectedItem = [string]$script:cfg.bitrate
if ($cmbBitrate.SelectedIndex -lt 0) { $cmbBitrate.SelectedItem = '8M' }
$cmbOrient.SelectedIndex = 0
foreach ($k in $orientMap.Keys) { if ($orientMap[$k] -eq $script:cfg.orientation) { $cmbOrient.SelectedItem = $k } }
$chkTop.Checked = [bool]$script:cfg.ontop
$chkBorder.Checked = [bool]$script:cfg.borderless
$txtWifi.Text = $script:cfg.wifi

function Read-UiToConfig {
    $script:cfg.facing = if ($rbBack.Checked) { 'back' } else { 'front' }
    $script:cfg.size = $cmbSize.Text.Trim()
    $script:cfg.fps = [string]$cmbFps.SelectedItem
    $script:cfg.bitrate = [string]$cmbBitrate.SelectedItem
    $script:cfg.orientation = $orientMap[[string]$cmbOrient.SelectedItem]
    $script:cfg.ontop = $chkTop.Checked
    $script:cfg.borderless = $chkBorder.Checked
    $script:cfg.wifi = $txtWifi.Text.Trim()
    if ($cmbDev.SelectedIndex -ge 0) { $script:cfg.serial = $script:serials[$cmbDev.SelectedIndex] }
}

# ---------------- dispositivos ----------------
function Update-Devices([bool]$quiet = $false) {
    $adb = Get-Adb
    if (-not $adb) { if (-not $quiet) { Write-Log 'adb.exe não encontrado. Indique o scrcpy.exe em "Procurar...".' }; return }
    $lines = & $adb devices -l 2>&1 | ForEach-Object { "$_" }
    $found = @()
    foreach ($l in $lines) {
        if ($l -match '^(\S+)\s+device\b(.*)$') {
            $serial = $Matches[1]
            $rest = $Matches[2]
            $model = if ($rest -match 'model:(\S+)') { $Matches[1] } else { 'Android' }
            $via = if ($serial -match '_adb-tls-connect|:\d+$') { 'Wi-Fi' } else { 'USB' }
            $found += [pscustomobject]@{ Serial = $serial; Label = ("{0}  ({1})  {2}" -f $model, $via, $serial) }
        } elseif (-not $quiet -and $l -match '^(\S+)\s+(offline|unauthorized)') {
            Write-Log ("{0} está {1}. Use Adicionar aparelho para conectar pelo Wi-Fi." -f $Matches[1], $Matches[2])
        }
    }
    $key = ($found | ForEach-Object { $_.Serial }) -join '|'
    if ($quiet -and $key -eq $script:devKey) { return }
    $script:devKey = $key

    $keepSerial = if ($cmbDev.SelectedIndex -ge 0) { $script:serials[$cmbDev.SelectedIndex] } else { $script:cfg.serial }
    $cmbDev.Items.Clear()
    $script:serials.Clear()
    foreach ($d in $found) {
        [void]$script:serials.Add($d.Serial)
        [void]$cmbDev.Items.Add($d.Label)
    }
    if ($cmbDev.Items.Count -eq 0) {
        Write-Log 'Nenhum aparelho conectado. Clique em "Adicionar aparelho" ou ligue a Depuração sem fio no aparelho.'
        return
    }
    $idx = $script:serials.IndexOf($keepSerial)
    $cmbDev.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    Write-Log ("Aparelhos: {0}" -f (($found | ForEach-Object { ($_.Label -split '  ')[0] }) -join ', '))
}

# ---------------- janela de pareamento ----------------
function Show-PairDialog {
    $adb = Get-Adb
    if (-not $adb) { Write-Log 'adb.exe não encontrado.'; return }
    $script:dialogOpen = $true
    $before = @($script:serials)

    $qrName = 'WebcamAndroid-' + (New-RandomText 6)
    $qrPass = New-RandomText 10
    $st = @{ phase = 'wait'; t0 = $null; codeTry = $null; done = $false }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Adicionar aparelho'
    $dlg.ClientSize = New-Object System.Drawing.Size(400, 590)
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $fontUI

    $lbl1 = New-Ctl Label 15 10 370 50 "No aparelho: Opções do desenvolvedor > Depuração sem fio > Parear dispositivo com QR code. Aponte a câmera para o código abaixo." $dlg
    $pic = New-Ctl PictureBox 52 62 296 296 '' $dlg
    $pic.SizeMode = 'Zoom'
    if ($script:qrOk) {
        try { $pic.Image = [MiniQr]::ToBitmap("WIFI:T:ADB;S:$qrName;P:$qrPass;;", 8) } catch { $script:qrOk = $false }
    }
    if (-not $script:qrOk) {
        $lbl1.Text = 'O QR code não pôde ser gerado neste PC. Use o pareamento por código abaixo.'
        $pic.Visible = $false
    }
    $lblSt = New-Ctl Label 15 366 370 40 'Aguardando o aparelho...' $dlg
    $lblSt.ForeColor = [System.Drawing.Color]::DarkBlue

    $sep = New-Ctl Label 15 410 370 2 '' $dlg
    $sep.BorderStyle = 'Fixed3D'
    [void](New-Ctl Label 15 420 370 36 'Ou: Parear dispositivo com código de pareamento, e digite aqui os 6 dígitos (o IP é encontrado sozinho).' $dlg)
    $txtCode = New-Ctl TextBox 15 462 150 26 '' $dlg
    $txtCode.Font = New-Object System.Drawing.Font('Segoe UI', 12)
    $txtCode.MaxLength = 6
    $btnCode = New-Ctl Button 175 461 210 30 'Parear com código' $dlg
    $btnClose = New-Ctl Button 285 545 100 30 'Fechar' $dlg
    $dlg.CancelButton = $btnClose
    $btnClose.Add_Click({ $dlg.Close() })

    $setStatus = {
        param($text, $color)
        $lblSt.Text = $text
        if ($color) { $lblSt.ForeColor = $color }
        Write-Log $text
    }

    $tryPair = {
        param($addr, $secret)
        $out = (& $adb pair $addr $secret 2>&1 | ForEach-Object { "$_" }) -join ' '
        if ($out -match 'Successfully paired') {
            & $setStatus 'Pareado! Conectando...' ([System.Drawing.Color]::DarkGreen)
            $st.phase = 'connect'
            $st.t0 = Get-Date
        } else {
            & $setStatus ("Falha no pareamento: $out") ([System.Drawing.Color]::DarkRed)
            if ($st.phase -ne 'connect') { $st.phase = 'wait' }
        }
    }

    $btnCode.Add_Click({
        $code = $txtCode.Text.Trim()
        if ($code -notmatch '^\d{6}$') { & $setStatus 'Digite os 6 dígitos mostrados no aparelho.' ([System.Drawing.Color]::DarkRed); return }
        $st.codeTry = $code
        $st.phase = 'code'
        $st.t0 = Get-Date
        & $setStatus 'Procurando o aparelho na rede...' ([System.Drawing.Color]::DarkBlue)
    })

    $tmr = New-Object System.Windows.Forms.Timer
    $tmr.Interval = 1200
    $tmr.Add_Tick({
        if ($script:busy) { return }
        $script:busy = $true
        try {
            switch ($st.phase) {
                'wait' {
                    if (-not $script:qrOk) { break }
                    $svc = Get-MdnsServices | Where-Object { $_.Kind -eq 'pairing' -and $_.Name -eq $qrName } | Select-Object -First 1
                    if ($svc) {
                        & $setStatus "Aparelho encontrado em $($svc.Addr). Pareando..." ([System.Drawing.Color]::DarkBlue)
                        $st.phase = 'pairing'
                        & $tryPair $svc.Addr $qrPass
                    }
                }
                'code' {
                    $svc = Get-MdnsServices | Where-Object { $_.Kind -eq 'pairing' -and $_.Name -notlike 'WebcamAndroid-*' } | Select-Object -First 1
                    if ($svc) {
                        & $setStatus "Aparelho encontrado em $($svc.Addr). Pareando..." ([System.Drawing.Color]::DarkBlue)
                        $st.phase = 'pairing'
                        & $tryPair $svc.Addr $st.codeTry
                    } elseif (((Get-Date) - $st.t0).TotalSeconds -gt 20) {
                        & $setStatus 'Não achei o aparelho. Deixe a tela "Parear com código" aberta nele e tente de novo.' ([System.Drawing.Color]::DarkRed)
                        $st.phase = 'wait'
                    }
                }
                'connect' {
                    Connect-KnownDevices $false
                    Update-Devices $true
                    $new = @($script:serials | Where-Object { $before -notcontains $_ })
                    if ($new.Count -gt 0) {
                        $idx = $script:serials.IndexOf($new[0])
                        if ($idx -ge 0) { $cmbDev.SelectedIndex = $idx }
                        & $setStatus "Pronto! $($cmbDev.SelectedItem) adicionado." ([System.Drawing.Color]::DarkGreen)
                        $st.phase = 'done'
                        $st.t0 = Get-Date
                    } elseif (((Get-Date) - $st.t0).TotalSeconds -gt 20) {
                        & $setStatus 'Pareado, mas não conectou. Confira se a Depuração sem fio está ligada e clique em "Reconectar aparelhos salvos".' ([System.Drawing.Color]::DarkOrange)
                        $st.phase = 'idle'
                    }
                }
                'done' {
                    if (((Get-Date) - $st.t0).TotalSeconds -gt 1.5) { $dlg.Close() }
                }
            }
        } finally {
            $script:busy = $false
        }
    })

    $dlg.Add_Shown({ $tmr.Start() })
    $dlg.Add_FormClosed({ $tmr.Stop(); $tmr.Dispose() })
    [void]$dlg.ShowDialog($form)
    $script:dialogOpen = $false
    Update-Devices $true
}

# ---------------- iniciar / parar ----------------
function Get-ScrcpyArgs {
    $a = New-Object System.Collections.ArrayList
    if ($script:cfg.serial) { [void]$a.Add("-s $($script:cfg.serial)") }
    [void]$a.Add('--video-source=camera')
    [void]$a.Add("--camera-facing=$($script:cfg.facing)")
    if ($script:cfg.size) { [void]$a.Add("--camera-size=$($script:cfg.size)") }
    [void]$a.Add("--camera-fps=$($script:cfg.fps)")
    [void]$a.Add("--video-bit-rate=$($script:cfg.bitrate)")
    if ($script:cfg.orientation -and $script:cfg.orientation -ne '0') { [void]$a.Add("--orientation=$($script:cfg.orientation)") }
    [void]$a.Add('--no-audio')
    [void]$a.Add('--window-title="Webcam Android"')
    if ($script:cfg.ontop) { [void]$a.Add('--always-on-top') }
    if ($script:cfg.borderless) { [void]$a.Add('--window-borderless') }
    return ($a -join ' ')
}

function Set-Running([bool]$on) {
    $btnStart.Enabled = -not $on
    $btnStop.Enabled = $on
    $grpDev.Enabled = -not $on
    $grpCam.Enabled = -not $on
    $grpApp.Enabled = -not $on
    $lblStatus.Text = if ($on) { 'Câmera ligada (janela "Webcam Android")' } else { 'Parada' }
    $lblStatus.ForeColor = if ($on) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Black }
}

function Start-Camera {
    Read-UiToConfig
    if (-not $script:cfg.scrcpy -or -not (Test-Path $script:cfg.scrcpy)) { Write-Log 'scrcpy.exe não encontrado.'; return }
    if (-not $script:cfg.serial) { Write-Log 'Escolha um aparelho (ou clique em Adicionar aparelho).'; return }
    Save-Config
    $argStr = Get-ScrcpyArgs
    Write-Log "scrcpy $argStr"
    Set-Content -Path $LogPath -Value '' -Encoding UTF8
    $script:logPos = 0L
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/c ""' + $script:cfg.scrcpy + '" ' + $argStr + ' > "' + $LogPath + '" 2>&1"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path $script:cfg.scrcpy
    try {
        $script:proc = [System.Diagnostics.Process]::Start($psi)
        Set-Running $true
    } catch {
        Write-Log "Falha ao iniciar: $_"
    }
}

function Stop-Camera {
    if ($script:proc -and -not $script:proc.HasExited) {
        & taskkill.exe /PID $script:proc.Id /T /F 2>&1 | Out-Null
    }
    $script:proc = $null
    Set-Running $false
}

function Read-NewLog {
    if (-not (Test-Path $LogPath)) { return }
    try {
        $fs = [System.IO.File]::Open($LogPath, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            if ($fs.Length -gt $script:logPos) {
                [void]$fs.Seek($script:logPos, 'Begin')
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
                $script:logPos = $fs.Length
                foreach ($line in ($text -split "`r?`n")) { if ($line.Trim()) { Write-Log $line } }
            }
        } finally { $fs.Dispose() }
    } catch {}
}

# Timer principal: log do scrcpy e deteccao automatica de aparelhos
$script:tick = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    Read-NewLog
    if ($script:proc -and $script:proc.HasExited) {
        Read-NewLog
        Write-Log 'scrcpy foi encerrado.'
        $script:proc = $null
        Set-Running $false
    }
    $script:tick++
    if ($script:tick % 10 -eq 0 -and -not $script:proc -and -not $script:dialogOpen -and -not $script:busy -and -not $cmbDev.DroppedDown) {
        $script:busy = $true
        try {
            Connect-KnownDevices $false
            Update-Devices $true
        } finally { $script:busy = $false }
    }
})

# ---------------- eventos ----------------
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'scrcpy.exe|scrcpy.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:cfg.scrcpy = $dlg.FileName
        $txtScrcpy.Text = $dlg.FileName
        Save-Config
        Update-Devices
    }
})

$btnRefresh.Add_Click({ Update-Devices })
$btnAdd.Add_Click({ Show-PairDialog })

$btnReconnect.Add_Click({
    Write-Log 'Procurando aparelhos pareados na rede...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { Connect-KnownDevices $true } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $script:devKey = ''
    Update-Devices
})

$btnConnect.Add_Click({
    $adb = Get-Adb
    $addr = $txtWifi.Text.Trim()
    if (-not $adb -or -not $addr) { Write-Log 'Informe o IP:porta mostrado em Depuração sem fio.'; return }
    Invoke-Tool $adb @('connect', $addr) | ForEach-Object { Write-Log $_ }
    $script:cfg.wifi = $addr
    Save-Config
    $script:devKey = ''
    Update-Devices
})

$btnSizes.Add_Click({
    Read-UiToConfig
    if (-not $script:cfg.serial) { Write-Log 'Escolha um aparelho primeiro.'; return }
    Write-Log 'Consultando câmeras...'
    $out = Invoke-Tool $script:cfg.scrcpy @('-s', $script:cfg.serial, '--list-camera-sizes')
    $current = ''
    $sizes = New-Object System.Collections.ArrayList
    foreach ($l in $out) {
        if ($l -match '\((front|back|external)') { $current = $Matches[1]; Write-Log $l.Trim() }
        elseif ($l -match '^\s*-\s*(\d+x\d+)') {
            if ($current -eq $script:cfg.facing -and -not $sizes.Contains($Matches[1])) { [void]$sizes.Add($Matches[1]) }
        }
        elseif ($l -match 'ERROR|WARN') { Write-Log $l.Trim() }
    }
    if ($sizes.Count -gt 0) {
        $keep = $cmbSize.Text
        $cmbSize.Items.Clear()
        [void]$cmbSize.Items.AddRange([string[]]$sizes)
        $cmbSize.Text = $keep
        Write-Log ("Resoluções da câmera {0}: {1}" -f $script:cfg.facing, ($sizes -join ', '))
    } else {
        Write-Log 'Nenhuma resolução listada para essa câmera.'
    }
})

$btnStart.Add_Click({ Start-Camera })
$btnStop.Add_Click({ Stop-Camera })

$btnShortcut.Add_Click({
    try {
        $desk = [Environment]::GetFolderPath('Desktop')
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut((Join-Path $desk 'Webcam Android.lnk'))
        $lnk.TargetPath = 'powershell.exe'
        $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $PSScriptRoot 'WebcamAndroid.ps1') + '"'
        $lnk.WorkingDirectory = $PSScriptRoot
        $lnk.IconLocation = if ($script:cfg.scrcpy) { "$($script:cfg.scrcpy),0" } else { 'shell32.dll,203' }
        $lnk.WindowStyle = 7
        $lnk.Save()
        Write-Log 'Atalho "Webcam Android" criado na área de trabalho.'
    } catch { Write-Log "Não foi possível criar o atalho: $_" }
})

$form.Add_Shown({
    if (-not $script:qrOk) { Write-Log 'Aviso: gerador de QR indisponível, use o pareamento por código.' }
    if (-not $script:cfg.scrcpy) { Write-Log 'scrcpy não encontrado. Use "Procurar..." para indicar o scrcpy.exe.' }
    else {
        Write-Log "scrcpy: $($script:cfg.scrcpy)"
        Connect-KnownDevices $false
        Update-Devices
    }
    $timer.Start()
})
$form.Add_FormClosing({
    $timer.Stop()
    Read-UiToConfig
    Save-Config
    Stop-Camera
})

[void]$form.ShowDialog()
