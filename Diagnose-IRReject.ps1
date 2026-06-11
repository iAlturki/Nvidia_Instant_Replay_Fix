#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Diagnoses why NVIDIA silently rejects an Instant Replay enable.

.DESCRIPTION
    Snapshots all top-level windows and their display affinity, then
    watches the registry for the "protected-content-detected" flag
    NVIDIA writes when it refuses IR. Run it, then toggle IR ON in
    the overlay - the script will print which window (if any) had
    WDA_MONITOR/WDA_EXCLUDEFROMCAPTURE set at the moment of refusal.
#>
[CmdletBinding()]
param([int]$WatchSeconds = 60)

if (-not ('Diag.NT' -as [type])) {
Add-Type -Namespace 'Diag' -Name 'NT' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool GetWindowDisplayAffinity(System.IntPtr hwnd, out uint affinity);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(System.IntPtr callback, System.IntPtr extraData);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hwnd);
'@
}

function Get-TopLevelProtected {
    # Enumerate ALL top-level windows and return ones with non-zero affinity
    $hits = [System.Collections.ArrayList]@()
    $delegate = {
        param([System.IntPtr]$hwnd, [System.IntPtr]$lparam)
        if ([Diag.NT]::IsWindowVisible($hwnd)) {
            $aff = 0
            $ok = [Diag.NT]::GetWindowDisplayAffinity($hwnd, [ref]$aff)
            if ($ok -and $aff -ne 0) {
                $pid_ = 0
                [void][Diag.NT]::GetWindowThreadProcessId($hwnd, [ref]$pid_)
                $titleLen = [Diag.NT]::GetWindowTextLength($hwnd)
                $sb = New-Object System.Text.StringBuilder ($titleLen + 1)
                if ($titleLen -gt 0) { [void][Diag.NT]::GetWindowText($hwnd, $sb, $titleLen + 1) }
                $procName = (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName
                [void]$hits.Add([pscustomobject]@{
                    HWND = "0x{0:X}" -f $hwnd.ToInt64()
                    PID = $pid_
                    Process = $procName
                    Title = $sb.ToString()
                    Affinity = $aff
                    AffinityName = switch ($aff) { 1 {'WDA_MONITOR'} 2 {'WDA_EXCLUDEFROMCAPTURE'} default {"unknown($aff)"} }
                })
            }
        }
        return $true
    }
    # Marshal a delegate to a native callback... PowerShell can't do this directly cleanly.
    # Easier alternative: iterate Process MainWindowHandles.
    foreach ($p in (Get-Process | Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })) {
        $aff = 0
        $ok = [Diag.NT]::GetWindowDisplayAffinity($p.MainWindowHandle, [ref]$aff)
        if ($ok -and $aff -ne 0) {
            [void]$hits.Add([pscustomobject]@{
                HWND = "0x{0:X}" -f $p.MainWindowHandle.ToInt64()
                PID = $p.Id
                Process = $p.ProcessName
                Title = $p.MainWindowTitle
                Affinity = $aff
                AffinityName = switch ($aff) { 1 {'WDA_MONITOR'} 2 {'WDA_EXCLUDEFROMCAPTURE'} default {"unknown($aff)"} }
            })
        }
    }
    return $hits
}

Write-Host "=== Scanning all top-level windows for display affinity ===" -ForegroundColor Cyan
$protected = Get-TopLevelProtected
if ($protected.Count -eq 0) {
    Write-Host "  No top-level windows have WDA_MONITOR or WDA_EXCLUDEFROMCAPTURE set." -ForegroundColor Green
    Write-Host "  (note: this only checks each process's main window, not child windows)"
} else {
    Write-Host "  Found $($protected.Count) window(s) with protection set:" -ForegroundColor Yellow
    $protected | Format-Table -AutoSize Process, PID, AffinityName, Title
}

Write-Host ""
Write-Host "=== Watching NVSPCAPS registry for protected-flag writes ===" -ForegroundColor Cyan
Write-Host "  Toggle IR ON in the overlay NOW. The script will print:"
Write-Host "    - which registry value NVIDIA writes (and what)"
Write-Host "    - what window/app is foregrounded at the moment of rejection"
Write-Host ""
Write-Host "  Watching for $WatchSeconds seconds..."

$regPath = 'HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS'
$initial = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
$snapshot = @{}
$initial.PSObject.Properties | ForEach-Object {
    if ($_.Value -is [byte[]]) { $snapshot[$_.Name] = ($_.Value -join ',') }
}

$deadline = (Get-Date).AddSeconds($WatchSeconds)
$lastForeground = ''
while ((Get-Date) -lt $deadline) {
    $cur = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    $changes = @()
    $cur.PSObject.Properties | ForEach-Object {
        if ($_.Value -is [byte[]]) {
            $newVal = ($_.Value -join ',')
            $oldVal = $snapshot[$_.Name]
            if ($oldVal -ne $null -and $newVal -ne $oldVal) {
                $changes += "$($_.Name): [$oldVal] -> [$newVal]"
            } elseif ($oldVal -eq $null) {
                $changes += "$($_.Name) (NEW): [$newVal]"
            }
            $snapshot[$_.Name] = $newVal
        }
    }
    if ($changes.Count -gt 0) {
        $stamp = (Get-Date).ToString('HH:mm:ss.fff')
        Write-Host "[$stamp] registry changed:" -ForegroundColor Yellow
        foreach ($c in $changes) { Write-Host "    $c" }
        $fg = [Diag.NT]::GetForegroundWindow()
        $pid_ = 0
        [void][Diag.NT]::GetWindowThreadProcessId($fg, [ref]$pid_)
        $p = Get-Process -Id $pid_ -ErrorAction SilentlyContinue
        Write-Host ("    Foreground at this moment: {0} (PID {1}) - '{2}'" -f $p.ProcessName, $pid_, $p.MainWindowTitle)
    }
    Start-Sleep -Milliseconds 250
}

Write-Host ""
Write-Host "=== Done ===" -ForegroundColor Cyan
