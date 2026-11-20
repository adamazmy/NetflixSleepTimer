# Netflix Sleep Timer - installer
# 1. Desktop + Start menu shortcuts (icon, Ctrl+Alt+N hotkey) that open the timer with no console window.
# 2. Registers the PC helper used by the browser extension (Chrome + Edge, current user only, no admin).
# 3. Generates the extension's icons.
#   Install:    powershell -ExecutionPolicy Bypass -File Install.ps1
#   Uninstall:  powershell -ExecutionPolicy Bypass -File Install.ps1 -Uninstall

param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$appName  = 'Netflix Sleep Timer'
$hotkey   = 'CTRL+ALT+N'
$root     = $PSScriptRoot
$script   = Join-Path $root 'NetflixSleepTimer.ps1'
$iconPath = Join-Path $root 'NetflixSleepTimer.ico'

# Native messaging host. The extension ID is fixed by the "key" in extension/manifest.json.
$hostName     = 'com.netflixsleeptimer.host'
$extensionId  = 'pojidohngdokbepnipgebellahihjddn'
$hostDir      = Join-Path $root 'native-host'
$hostManifest = Join-Path $hostDir "$hostName.json"
$hostRegKeys  = @(
    "HKCU:\Software\Google\Chrome\NativeMessagingHosts\$hostName",
    "HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\$hostName"
)

# GetFolderPath follows OneDrive / redirected Desktop folders.
$shortcutPaths = @(
    (Join-Path ([Environment]::GetFolderPath('Desktop'))  "$appName.lnk"),
    (Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk")
)

if ($Uninstall) {
    foreach ($p in $shortcutPaths) { if (Test-Path $p) { Remove-Item $p -Force; "Removed $p" } }
    foreach ($k in $hostRegKeys)   { if (Test-Path $k) { Remove-Item $k -Force; "Removed $k" } }
    if (Test-Path $hostManifest) { Remove-Item $hostManifest -Force }
    'To remove the browser extension: open chrome://extensions (or edge://extensions) and click Remove.'
    return
}

if (-not (Test-Path $script)) { throw "Cannot find $script" }

# ---------------- icon: red disc with a white crescent moon ----------------
# Small sizes are classic 32-bit DIB entries (System.Drawing.Icon in .NET Framework cannot
# decode PNG entries); the 256px size is PNG-compressed, which Windows Explorer reads natively.
function New-IconBitmap([int]$size) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    $red = [Drawing.Color]::FromArgb(229, 9, 20)
    $s = [float]$size
    $g.FillEllipse((New-Object Drawing.SolidBrush $red), 0, 0, $s - 1, $s - 1)
    # crescent = white disc, then a red disc offset up-right to carve it
    $g.FillEllipse([Drawing.Brushes]::White, $s * 0.22, $s * 0.22, $s * 0.56, $s * 0.56)
    $g.FillEllipse((New-Object Drawing.SolidBrush $red), $s * 0.38, $s * 0.14, $s * 0.50, $s * 0.50)
    $g.Dispose()
    return $bmp
}

function ConvertTo-IconEntry([Drawing.Bitmap]$bmp) {
    $ms = New-Object IO.MemoryStream
    $size = $bmp.Width
    if ($size -ge 256) {
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    } else {
        $bw = New-Object IO.BinaryWriter $ms
        # BITMAPINFOHEADER: height is doubled (XOR image + AND mask)
        $bw.Write([uint32]40); $bw.Write([int32]$size); $bw.Write([int32]($size * 2))
        $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0)
        $bw.Write([uint32]0); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
        for ($y = $size - 1; $y -ge 0; $y--) {          # BGRA pixels, bottom-up
            for ($x = 0; $x -lt $size; $x++) {
                $c = $bmp.GetPixel($x, $y)
                $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
            }
        }
        $maskRow = [int]([Math]::Ceiling($size / 32.0) * 4)  # AND mask unused (alpha wins), all zero
        $bw.Write((New-Object byte[] ($maskRow * $size)))
        $bw.Flush()
    }
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = 16, 32, 48, 256
$pngs  = foreach ($sz in $sizes) { ,(ConvertTo-IconEntry (New-IconBitmap $sz)) }
$fs = [IO.File]::Create($iconPath)
$w  = New-Object IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                   # ICONDIRENTRY
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $w.Write($png) }
$w.Close()

# extension toolbar / extensions-page icons
$extIcons = Join-Path $root 'extension\icons'
New-Item -ItemType Directory -Force $extIcons | Out-Null
foreach ($sz in 16, 32, 48, 128) {
    $bmp = New-IconBitmap $sz
    $bmp.Save((Join-Path $extIcons "icon$sz.png"), [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

# ---------------- PC helper for the browser extension ----------------
$hostJson = [ordered]@{
    name            = $hostName
    description     = 'Netflix Sleep Timer PC helper (sleep / screen off / shut down)'
    path            = (Join-Path $hostDir 'host.bat')
    type            = 'stdio'
    allowed_origins = @("chrome-extension://$extensionId/")
} | ConvertTo-Json
[IO.File]::WriteAllText($hostManifest, $hostJson, (New-Object Text.UTF8Encoding $false))
foreach ($k in $hostRegKeys) {
    New-Item -Path $k -Force | Out-Null
    Set-Item -Path $k -Value $hostManifest
}
"Registered browser helper for Chrome and Edge"

# ---------------- shortcuts ----------------
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
foreach ($p in $shortcutPaths) {
    $lnk = $shell.CreateShortcut($p)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation     = "$iconPath,0"
    $lnk.WindowStyle      = 7          # start minimized, so no console flashes up
    $lnk.Description      = 'Pause Netflix and sleep the PC after a countdown'
    # Windows only honours one hotkey per key combo: put it on the Start menu shortcut only.
    if ($p -like "*$([Environment]::GetFolderPath('Programs'))*") { $lnk.Hotkey = $hotkey }
    $lnk.Save()
    "Created $p"
}
@"

Done. Open the timer from the Desktop, the Start menu, or press $($hotkey.Replace('+', ' + ')).

To get the sleep timer button inside Netflix (one-time setup):
  1. In Chrome go to chrome://extensions  (Edge: edge://extensions)
  2. Turn on 'Developer mode'
  3. Click 'Load unpacked' and pick this folder:
       $(Join-Path $root 'extension')
  4. Reload Netflix and play something: a moon button appears at the top of the player.
"@
