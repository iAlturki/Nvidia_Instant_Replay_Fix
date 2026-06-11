#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Recovers Instant Replay from the "UI says ON but NVENC is idle" state
    that can happen after our hooks run against a stale nvcontainer.

.DESCRIPTION
    Sequence:
      1. Stops the watchdog patcher (if running).
      2. Kills the SPUser nvcontainer instance so NVIDIA respawns it clean
         (without our hooks). NVIDIA's service auto-restarts it within ~5s.
      3. Waits for the user to physically toggle Instant Replay OFF then ON
         in NVIDIA Overlay (Alt+Z -> Instant Replay).
      4. Polls nvidia-smi until NVENC reports an active encoder session
         (sessions >= 1, fps > 0). Times out after 5 minutes.
      5. Re-enables the watchdog patcher via the scheduled task. The watchdog
         re-applies hooks to the running nvcontainer within ~30s without
         disturbing the live NVENC session.

    Safe to re-run. If anything is off, just run it again.
#>
[CmdletBinding()]
param(
    [int]$WaitForNvencSec = 300
)

function Write-Step($msg, $color = 'Cyan') { Write-Host "`n=== $msg ===" -ForegroundColor $color }
function Write-Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "  $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "  $msg" -ForegroundColor Red }

function Get-Nvenc {
    $out = & 'C:\Windows\System32\nvidia-smi.exe' --query-gpu=encoder.stats.sessionCount,encoder.stats.averageFps --format=csv,noheader,nounits 2>$null
    if (-not $out) { return [pscustomobject]@{ Sessions = -1; Fps = -1 } }
    $parts = ($out | Select-Object -First 1) -split ','
    [pscustomobject]@{ Sessions = [int]$parts[0].Trim(); Fps = [int]$parts[1].Trim() }
}

# IR-specific check: NvFBC64.dll is loaded in nvcontainer ONLY when IR is
# actively recording the desktop. NVENC alone can mean Discord/browser/etc.
function Test-IRActuallyRunning {
    $nvcs = Get-CimInstance Win32_Process -Filter "Name = 'nvcontainer.exe'" -ErrorAction SilentlyContinue
    foreach ($n in $nvcs) {
        try {
            $proc = Get-Process -Id $n.ProcessId -ErrorAction Stop
            $hasNvFBC = $proc.Modules | Where-Object { $_.ModuleName -ieq 'NvFBC64.dll' }
            if ($hasNvFBC) { return $true }
        } catch { }
    }
    return $false
}

# ----- Step 1 -----
Write-Step 'Step 1: stop the watchdog so it does not fight us'
$wd = Get-Process -Name 'Nvidia_Instant_Replay_Fix' -ErrorAction SilentlyContinue
if ($wd) {
    foreach ($p in $wd) { Stop-Process -Id $p.Id -Force; Write-Ok "killed watchdog PID $($p.Id)" }
} else {
    Write-Ok 'watchdog was not running'
}

# ----- Step 2 -----
Write-Step 'Step 2: kill the SPUser nvcontainer so NVIDIA respawns it WITHOUT our hooks'
$spu = Get-CimInstance Win32_Process -Filter "Name = 'nvcontainer.exe'" -ErrorAction SilentlyContinue |
       Where-Object { $_.CommandLine -match 'SPUser' }
if ($spu) {
    foreach ($p in $spu) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        Write-Ok "killed SPUser nvcontainer PID $($p.ProcessId)"
    }
    Start-Sleep -Seconds 5
    $newSpu = Get-CimInstance Win32_Process -Filter "Name = 'nvcontainer.exe'" -ErrorAction SilentlyContinue |
              Where-Object { $_.CommandLine -match 'SPUser' }
    if ($newSpu) { Write-Ok "fresh SPUser nvcontainer respawned as PID $($newSpu.ProcessId)" }
    else         { Write-Warn2 'not respawned yet - NVIDIA service will bring it back shortly' }
} else {
    Write-Warn2 'no SPUser nvcontainer found right now - skipping kill'
}

# ----- Step 3 -----
Write-Step 'Step 3: YOUR TURN'
Write-Host "  -> Open NVIDIA Overlay  (Alt+Z)" -ForegroundColor White
Write-Host "  -> Go to Instant Replay settings" -ForegroundColor White
Write-Host "  -> Toggle Instant Replay OFF, then back ON" -ForegroundColor White
Write-Host "  (don't press Enter here; this script auto-detects NVENC starting up)" -ForegroundColor DarkGray

# ----- Step 4 -----
Write-Step 'Step 4: polling for IR specifically (NvFBC64.dll loaded in nvcontainer)...'
Write-Host '  NOTE: I am NOT just looking for NVENC sessions - Discord/browser create those too.' -ForegroundColor DarkGray
Write-Host '  IR is detected by NvFBC64.dll appearing in nvcontainer (it only loads when IR records).' -ForegroundColor DarkGray
$deadline = (Get-Date).AddSeconds($WaitForNvencSec)
$running = $false
while ((Get-Date) -lt $deadline) {
    $s = Get-Nvenc
    $irLive = Test-IRActuallyRunning
    $stamp = (Get-Date).ToString('HH:mm:ss')
    Write-Host ("    [{0}] NVENC sessions={1} fps={2}  |  IR-specific (NvFBC64 loaded): {3}" -f $stamp, $s.Sessions, $s.Fps, $irLive) -ForegroundColor DarkGray
    if ($irLive) {
        Write-Ok "IR is actively recording (NvFBC64.dll loaded in nvcontainer, NVENC fps=$($s.Fps))"
        $running = $true; break
    }
    Start-Sleep -Seconds 2
}
if (-not $running) {
    Write-Bad "timed out waiting for IR to start. The toggle did not actually engage."
    Write-Bad "Symptoms to check:"
    Write-Bad "  - Is the IR toggle showing as ON in the Overlay (green slider)?"
    Write-Bad "  - Does NVIDIA App show any error?"
    Write-Bad "  - Try toggling Instant Replay in NVIDIA App settings instead of Overlay."
    exit 1
}

# ----- Step 5 -----
Write-Step 'Step 5: re-enable the watchdog'
schtasks /Run /TN 'Nvidia_Instant_Replay_Fix' 2>&1 | Out-Null
Start-Sleep -Seconds 3
$wd2 = Get-Process -Name 'Nvidia_Instant_Replay_Fix' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($wd2) {
    Write-Ok "watchdog UP: PID $($wd2.Id)"
    Write-Ok 'hooks will be re-applied to the live nvcontainer within ~30s'
} else {
    Write-Warn2 'watchdog did not show up - run manually:  schtasks /Run /TN ''Nvidia_Instant_Replay_Fix'''
}

Write-Step 'DONE' 'Green'
Write-Host "  Instant Replay is recording. Hooks coming back online shortly." -ForegroundColor Green
Write-Host "  You can now run .\autopilot-test.ps1 to verify the save flow." -ForegroundColor Green
