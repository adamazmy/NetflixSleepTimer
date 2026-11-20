# Netflix Sleep Timer for Windows
# Counts down, fades the volume over the last minute, pauses whatever is playing
# (via Windows media sessions), restores the volume, then sleeps / screen-off / shuts down.
# Works with Netflix in Chrome/Edge or the Netflix app; never starts a paused app like Spotify.

# Single instance: launching again (shortcut / hotkey) just brings the open window to the front.
$createdNew = $false
$script:instanceMutex = New-Object System.Threading.Mutex($true, 'Local\NetflixSleepTimer', [ref]$createdNew)
if (-not $createdNew) {
    try { [void](New-Object -ComObject WScript.Shell).AppActivate('Netflix Sleep Timer') } catch {}
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace NetflixSleep {
    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        int f(); int g(); int h(); int i();
        int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
        int j();
        int GetMasterVolumeLevelScalar(out float pfLevel);
        int k(); int l(); int m(); int n();
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
        int GetMute(out bool pbMute);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid id, int clsCtx, IntPtr activationParams, out IAudioEndpointVolume aev);
    }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int f();
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    public static class Audio {
        static IAudioEndpointVolume Endpoint() {
            var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev;
            Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
            IAudioEndpointVolume epv;
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out epv));
            return epv;
        }
        public static float GetVolume() {
            float v;
            Marshal.ThrowExceptionForHR(Endpoint().GetMasterVolumeLevelScalar(out v));
            return v;
        }
        public static void SetVolume(float v) {
            if (v < 0f) v = 0f;
            if (v > 1f) v = 1f;
            Marshal.ThrowExceptionForHR(Endpoint().SetMasterVolumeLevelScalar(v, Guid.Empty));
        }
    }

    public static class Native {
        [DllImport("user32.dll")]
        static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("powrprof.dll", SetLastError = true)]
        static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
        [DllImport("user32.dll")]
        static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        // Fallback only. Stop (unlike Play/Pause) can never START a paused player such as Spotify.
        public static void MediaStop() {
            keybd_event(0xB2, 0, 1, UIntPtr.Zero);      // VK_MEDIA_STOP down (extended)
            keybd_event(0xB2, 0, 1 | 2, UIntPtr.Zero);  // up
        }
        public static bool Sleep() { return SetSuspendState(false, false, false); }
        public static void ScreenOff() {
            // HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
            PostMessage(new IntPtr(0xFFFF), 0x0112, new IntPtr(0xF170), new IntPtr(2));
        }
    }
}
"@

# ---------------- settings & state ----------------
$FadeSeconds = 60
$script:endTime = $null
$script:origVol = $null
$script:fading  = $false
$script:prompt  = $null
$script:promptLabel = $null

# ---------------- look ----------------
$bg    = [Drawing.Color]::FromArgb(20, 20, 20)
$panel = [Drawing.Color]::FromArgb(45, 45, 45)
$red   = [Drawing.Color]::FromArgb(229, 9, 20)
$white = [Drawing.Color]::White
$muted = [Drawing.Color]::FromArgb(170, 170, 170)

function New-Btn([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $color) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.SetBounds($x, $y, $w, $h)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    # A focused flat button still draws a 1px "default button" border; make it invisible.
    $b.FlatAppearance.BorderColor = $color
    $b.BackColor = $color
    $b.ForeColor = $white
    $b.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    return $b
}

function Format-Time([double]$secs) {
    $t = [TimeSpan]::FromSeconds([Math]::Ceiling([Math]::Max(0, $secs)))
    if ($t.TotalHours -ge 1) { return '{0}:{1:mm}:{1:ss}' -f [int][Math]::Floor($t.TotalHours), $t }
    return '{0:mm}:{0:ss}' -f $t
}

# ---------------- pausing playback ----------------
# Uses the Windows media sessions (System Media Transport Controls) to send PAUSE to every app
# that is actually playing (Netflix app, Netflix in Chrome/Edge, ...). The Play/Pause media key
# is not used: Windows routes it to the "current" session, which can be a paused Spotify,
# and that would start Spotify instead of stopping Netflix.
function Wait-WinRt($operation, [Type]$resultType) {
    if (-not $script:asTaskMethod) {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $script:asTaskMethod = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
    }
    $task = $script:asTaskMethod.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait(3000)) { throw 'Timed out waiting for Windows media sessions' }
    return $task.Result
}

function Suspend-Playback {
    try {
        $mgrType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
        $mgr = Wait-WinRt ($mgrType::RequestAsync()) $mgrType
        $paused = @()
        foreach ($s in $mgr.GetSessions()) {
            if ($s.GetPlaybackInfo().PlaybackStatus -eq 'Playing') {
                if (Wait-WinRt ($s.TryPauseAsync()) ([bool])) { $paused += $s.SourceAppUserModelId }
            }
        }
        return ,$paused
    } catch {
        [NetflixSleep.Native]::MediaStop()   # media sessions unavailable: Stop is safe, it never starts playback
        return ,@('media-stop-key')
    }
}

# ---------------- volume helpers ----------------
function Restore-Volume {
    if ($null -ne $script:origVol) {
        try { [NetflixSleep.Audio]::SetVolume($script:origVol) } catch {}
    }
    $script:origVol = $null
    $script:fading = $false
}

# ---------------- "still watching?" popup ----------------
function Show-Prompt {
    if ($script:prompt) { return }
    $p = New-Object Windows.Forms.Form
    $p.FormBorderStyle = 'None'
    $p.ShowInTaskbar = $false
    $p.TopMost = $true
    $p.BackColor = $bg
    $p.ClientSize = New-Object Drawing.Size(300, 110)
    $p.StartPosition = 'Manual'
    $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $p.Location = New-Object Drawing.Point(($wa.Right - 320), ($wa.Bottom - 130))

    $l = New-Object Windows.Forms.Label
    $l.SetBounds(15, 12, 270, 40)
    $l.ForeColor = $white
    $l.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
    $l.Text = 'Still watching?'
    $p.Controls.Add($l)

    $more = New-Btn '+15 min' 15 60 130 36 $red
    $more.Add_Click({ Add-Minutes 15 })
    $p.Controls.Add($more)

    $now = New-Btn 'Pause now' 155 60 130 36 $panel
    $now.Add_Click({ $script:endTime = [DateTime]::Now })
    $p.Controls.Add($now)

    $script:prompt = $p
    $script:promptLabel = $l
    $p.Show()
}

function Close-Prompt {
    if ($script:prompt) { $script:prompt.Close(); $script:prompt.Dispose() }
    $script:prompt = $null
    $script:promptLabel = $null
}

# ---------------- main window ----------------
$form = New-Object Windows.Forms.Form
$form.Text = 'Netflix Sleep Timer'
$form.ClientSize = New-Object Drawing.Size(370, 430)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$iconFile = Join-Path $PSScriptRoot 'NetflixSleepTimer.ico'
if (Test-Path $iconFile) { try { $form.Icon = New-Object Drawing.Icon $iconFile } catch {} }

$title = New-Object Windows.Forms.Label
$title.Text = 'SLEEP TIMER'
$title.SetBounds(25, 15, 320, 25)
$title.ForeColor = $red
$title.Font = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$form.Controls.Add($title)

$clock = New-Object Windows.Forms.Label
$clock.Text = '--:--'
$clock.SetBounds(25, 42, 320, 65)
$clock.ForeColor = $white
$clock.TextAlign = 'MiddleCenter'
$clock.Font = New-Object Drawing.Font('Segoe UI', 36, [Drawing.FontStyle]::Bold)
$form.Controls.Add($clock)

$status = New-Object Windows.Forms.Label
$status.Text = 'Pick a time to start'
$status.SetBounds(25, 108, 320, 22)
$status.ForeColor = $muted
$status.TextAlign = 'MiddleCenter'
$status.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.Controls.Add($status)

# preset buttons: one click starts the timer
$presets = 15, 30, 45, 60, 90, 120
for ($i = 0; $i -lt $presets.Count; $i++) {
    $m = $presets[$i]
    $x = 25 + ($i % 3) * 110
    $y = 140 + [Math]::Floor($i / 3) * 45
    $b = New-Btn "$m min" $x $y 100 38 $panel
    $b.Tag = $m
    $b.Add_Click({ Start-Timer ([int]$this.Tag) })
    $form.Controls.Add($b)
}

$customLbl = New-Object Windows.Forms.Label
$customLbl.Text = 'Custom (minutes)'
$customLbl.SetBounds(25, 238, 150, 24)
$customLbl.ForeColor = $muted
$customLbl.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.Controls.Add($customLbl)

$custom = New-Object Windows.Forms.NumericUpDown
$custom.SetBounds(245, 236, 100, 26)
$custom.Minimum = 1
$custom.Maximum = 600
$custom.Value = 40
$custom.BackColor = $panel
$custom.ForeColor = $white
$custom.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.Controls.Add($custom)

$actionLbl = New-Object Windows.Forms.Label
$actionLbl.Text = 'When it ends'
$actionLbl.SetBounds(25, 274, 150, 24)
$actionLbl.ForeColor = $muted
$actionLbl.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.Controls.Add($actionLbl)

$action = New-Object Windows.Forms.ComboBox
$action.DropDownStyle = 'DropDownList'
$action.SetBounds(165, 272, 180, 26)
$action.BackColor = $panel
$action.ForeColor = $white
$action.FlatStyle = 'Flat'
$action.Font = New-Object Drawing.Font('Segoe UI', 10)
# Owner-drawn so it follows the dark theme: a themed DropDownList ignores BackColor and
# its flat border clips the first letter of the text.
$action.DrawMode = 'OwnerDrawFixed'
$action.ItemHeight = 22
$action.Add_DrawItem({
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $isEdit = ($e.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
    $isSel  = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $back = if ($isSel -and -not $isEdit) { $red } else { $panel }
    $brush = New-Object Drawing.SolidBrush $back
    $e.Graphics.FillRectangle($brush, $e.Bounds)
    $brush.Dispose()
    $textRect = New-Object Drawing.Rectangle ($e.Bounds.X + 6), $e.Bounds.Y, ($e.Bounds.Width - 6), $e.Bounds.Height
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $textRect, $white,
        ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::Left -bor [Windows.Forms.TextFormatFlags]::NoPrefix))
})
[void]$action.Items.AddRange(@('Pause + sleep PC', 'Pause + screen off', 'Pause + shut down', 'Pause only'))
$action.SelectedIndex = 0
$form.Controls.Add($action)

$start = New-Btn 'Start' 25 315 320 42 $red
$start.Add_Click({ Start-Timer ([int]$custom.Value) })
$form.Controls.Add($start)

$plus = New-Btn '+10 min' 25 368 155 38 $panel
$plus.Add_Click({ Add-Minutes 10 })
$form.Controls.Add($plus)

$cancel = New-Btn 'Cancel' 190 368 155 38 $panel
$cancel.Add_Click({ Stop-Timer 'Cancelled' })
$form.Controls.Add($cancel)

# ---------------- timer logic ----------------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250

function Start-Timer([int]$minutes) {
    Close-Prompt
    Restore-Volume
    $script:endTime = [DateTime]::Now.AddMinutes($minutes)
    $status.Text = '{0} at {1:HH:mm}' -f $action.SelectedItem, $script:endTime
    $clock.Text = Format-Time ($minutes * 60)
    $timer.Start()
}

function Add-Minutes([int]$minutes) {
    if ($null -eq $script:endTime) { Start-Timer $minutes; return }
    $script:endTime = $script:endTime.AddMinutes($minutes)
    if (($script:endTime - [DateTime]::Now).TotalSeconds -gt $FadeSeconds) {
        Close-Prompt
        Restore-Volume
    }
    $status.Text = '{0} at {1:HH:mm}' -f $action.SelectedItem, $script:endTime
}

function Stop-Timer([string]$msg) {
    $timer.Stop()
    Close-Prompt
    Restore-Volume
    $script:endTime = $null
    $clock.Text = '--:--'
    $status.Text = $msg
}

function Complete-Timer {
    $timer.Stop()
    Close-Prompt
    [void](Suspend-Playback)
    Start-Sleep -Milliseconds 800
    Restore-Volume          # playback is paused, so it's silent; volume is normal when you wake
    $script:endTime = $null
    $clock.Text = '--:--'
    $choice = $action.SelectedIndex
    $status.Text = 'Paused at {0:HH:mm}. Goodnight.' -f [DateTime]::Now
    [Windows.Forms.Application]::DoEvents()
    switch ($choice) {
        0 { [void][NetflixSleep.Native]::Sleep() }
        1 { [NetflixSleep.Native]::ScreenOff() }
        2 { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s', '/t', '0' -WindowStyle Hidden }
        default { }
    }
}

$timer.Add_Tick({
    if ($null -eq $script:endTime) { return }
    $remaining = ($script:endTime - [DateTime]::Now).TotalSeconds
    if ($remaining -le 0) { Complete-Timer; return }

    $clock.Text = Format-Time $remaining

    if ($remaining -le $FadeSeconds) {
        if (-not $script:fading) {
            $script:fading = $true
            try { $script:origVol = [NetflixSleep.Audio]::GetVolume() } catch { $script:origVol = $null }
            Show-Prompt
        }
        if ($null -ne $script:origVol) {
            try { [NetflixSleep.Audio]::SetVolume([float]($script:origVol * ($remaining / $FadeSeconds))) } catch {}
        }
        if ($script:promptLabel) { $script:promptLabel.Text = 'Still watching?  Pausing in ' + (Format-Time $remaining) }
    }
})

$form.Add_FormClosing({
    $timer.Stop()
    Close-Prompt
    Restore-Volume
})

[void]$form.ShowDialog()
$script:instanceMutex.ReleaseMutex()
