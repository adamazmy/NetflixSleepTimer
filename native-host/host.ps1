# Netflix Sleep Timer - native messaging host for the browser extension.
# Chrome/Edge start this (via host.bat) and send one length-prefixed JSON message on stdin:
#   {"action": "ping" | "sleep" | "screenOff" | "shutdown"}
# It performs the action, then answers {"ok": true|false, ...} on stdout.
# The action runs BEFORE the reply: the browser may kill the host as soon as it has its answer.

$ErrorActionPreference = 'Stop'

function Read-Message {
    $stdin = [Console]::OpenStandardInput()
    $header = New-Object byte[] 4
    $read = 0
    while ($read -lt 4) {
        $n = $stdin.Read($header, $read, 4 - $read)
        if ($n -le 0) { return $null }
        $read += $n
    }
    $len = [BitConverter]::ToInt32($header, 0)
    if ($len -le 0 -or $len -gt 4096) { return $null }
    $body = New-Object byte[] $len
    $read = 0
    while ($read -lt $len) {
        $n = $stdin.Read($body, $read, $len - $read)
        if ($n -le 0) { return $null }
        $read += $n
    }
    return [Text.Encoding]::UTF8.GetString($body) | ConvertFrom-Json
}

function Write-Message($obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    $stdout = [Console]::OpenStandardOutput()
    $stdout.Write([BitConverter]::GetBytes([int32]$bytes.Length), 0, 4)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}

try {
    $msg = Read-Message
    $act = if ($msg) { [string]$msg.action } else { '' }
    switch ($act) {
        'ping' { }
        'sleep' {
            Add-Type -Namespace NetflixSleepHost -Name Power -MemberDefinition '[DllImport("powrprof.dll", SetLastError = true)] public static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);'
            # Blocks until the PC wakes up again; the reply is sent after that.
            [void][NetflixSleepHost.Power]::SetSuspendState($false, $false, $false)
        }
        'screenOff' {
            Add-Type -Namespace NetflixSleepHost -Name Monitor -MemberDefinition '[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);'
            # HWND_BROADCAST, WM_SYSCOMMAND, SC_MONITORPOWER, 2 = off
            [void][NetflixSleepHost.Monitor]::PostMessage([IntPtr]0xFFFF, 0x0112, [IntPtr]0xF170, [IntPtr]2)
        }
        'shutdown' {
            & "$env:SystemRoot\System32\shutdown.exe" /s /t 0
        }
        default {
            Write-Message @{ ok = $false; error = "Unknown action '$act'" }
            exit 1
        }
    }
    Write-Message @{ ok = $true; action = $act }
} catch {
    Write-Message @{ ok = $false; error = $_.Exception.Message }
    exit 1
}
