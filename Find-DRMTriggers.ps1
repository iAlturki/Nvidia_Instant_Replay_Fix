#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Find everything that could trip NVIDIA's "protected content detected"
    rejection of IR enable.
.DESCRIPTION
    Reports three classes of triggers:
      1. Windows with non-zero display affinity (top-level + best-effort
         child-window enumeration).
      2. Processes that have a known DRM module loaded (Widevine CDM,
         PlayReady, Apple FairPlay/CoreFP, Microsoft EME, mfcore PMP).
      3. Processes whose name matches a likely-DRM-app pattern.
#>
[CmdletBinding()] param()

# --- 1. Windows with display affinity != 0 (top-level + child) ---
if (-not ('FullScan.NT' -as [type])) {
Add-Type -Namespace 'FullScan' -Name 'NT' -MemberDefinition @'
public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc proc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumChildWindows(System.IntPtr parent, EnumWindowsProc proc, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool GetWindowDisplayAffinity(System.IntPtr hwnd, out uint affinity);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
'@
}

$global:protectedWindows = New-Object System.Collections.ArrayList
$cb = [FullScan.NT+EnumWindowsProc]{
    param([IntPtr]$h, [IntPtr]$l)
    $aff = 0
    if ([FullScan.NT]::GetWindowDisplayAffinity($h, [ref]$aff) -and $aff -ne 0) {
        $pid_ = 0; [void][FullScan.NT]::GetWindowThreadProcessId($h, [ref]$pid_)
        $sb = New-Object System.Text.StringBuilder 260
        [void][FullScan.NT]::GetWindowText($h, $sb, 260)
        $proc = (Get-Process -Id $pid_ -ErrorAction SilentlyContinue).ProcessName
        $name = if ($aff -eq 1) {'WDA_MONITOR'} elseif ($aff -eq 2) {'WDA_EXCLUDEFROMCAPTURE'} else {"unknown($aff)"}
        [void]$global:protectedWindows.Add([pscustomobject]@{
            HWND = '0x{0:X}' -f $h.ToInt64(); PID = $pid_; Process = $proc
            AffinityName = $name; Title = $sb.ToString()
        })
    }
    # recurse into children too
    [void][FullScan.NT]::EnumChildWindows($h, $cb, [IntPtr]::Zero)
    return $true
}
Write-Host '=== Scanning ALL windows (top-level + child) for display affinity ===' -ForegroundColor Cyan
[void][FullScan.NT]::EnumWindows($cb, [IntPtr]::Zero)
if ($global:protectedWindows.Count -eq 0) {
    Write-Host '  No windows with non-zero display affinity.' -ForegroundColor Green
} else {
    Write-Host "  Found $($global:protectedWindows.Count) protected window(s):" -ForegroundColor Yellow
    $global:protectedWindows | Format-Table -AutoSize Process, PID, AffinityName, HWND, Title
}

# --- 2. DRM module loaded in any process ---
Write-Host ''
Write-Host '=== Scanning all processes for DRM modules ===' -ForegroundColor Cyan
$drmPatterns = @(
    'widevinecdm', 'oemcrypto',
    'playready', 'msdrm',
    'corefp', 'fairplay',
    'mfprotectedstore', 'pmphost',
    'mfreadwrite'
)
$drmHits = @()
foreach ($p in Get-Process) {
    try {
        foreach ($m in $p.Modules) {
            $mname = $m.ModuleName.ToLower()
            foreach ($pat in $drmPatterns) {
                if ($mname -like "*$pat*") {
                    $drmHits += [pscustomobject]@{
                        Process = $p.ProcessName; PID = $p.Id; Module = $m.ModuleName
                    }
                    break
                }
            }
        }
    } catch { } # skip processes we can't open (PPL, SYSTEM)
}
if ($drmHits.Count -eq 0) {
    Write-Host '  No DRM modules loaded in any accessible process.' -ForegroundColor Green
} else {
    $unique = $drmHits | Sort-Object Process, Module -Unique
    Write-Host "  Found $($unique.Count) DRM-module hit(s):" -ForegroundColor Yellow
    $unique | Format-Table -AutoSize
}

# --- 3. Processes from known DRM-app list ---
Write-Host ''
Write-Host '=== Processes matching known DRM-app names ===' -ForegroundColor Cyan
$drmApps = 'AppleMusic','Spotify','Netflix','Disney','Hulu','Prime Video','Amazon Music','Tidal','PrimeVideo'
$found = @()
foreach ($name in $drmApps) {
    $p = Get-Process | Where-Object { $_.ProcessName -like "*$name*" }
    if ($p) { $found += $p }
}
if ($found.Count -eq 0) {
    Write-Host '  No known DRM apps running.' -ForegroundColor Green
} else {
    $found | Select-Object ProcessName, Id, Path | Format-Table -AutoSize
}

# --- 4. Quick summary ---
Write-Host ''
Write-Host '=== SUMMARY ===' -ForegroundColor Cyan
$total = $global:protectedWindows.Count + ($drmHits | Sort-Object Process,Module -Unique).Count + $found.Count
if ($total -eq 0) {
    Write-Host '  No obvious triggers found.' -ForegroundColor Yellow
    Write-Host '  IR refusal is from a less-obvious source. Possible next moves:'
    Write-Host '    - kill ALL browsers (Brave, Chrome, Edge) and retry'
    Write-Host '    - check what apps are minimized to the system tray'
    Write-Host '    - reboot Windows to clear any lingering driver state'
} else {
    Write-Host "  Total triggers found: $total" -ForegroundColor Yellow
    Write-Host '  Close/kill the apps listed above, then re-try IR toggle.'
}
