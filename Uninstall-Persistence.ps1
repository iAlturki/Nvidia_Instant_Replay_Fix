#Requires -Version 5.1
<#
.SYNOPSIS
    Removes the Nvidia_Instant_Replay_Fix scheduled task and (optionally) its
    install folder. Also cleans up any legacy ShadowPlay_Patcher install.

.PARAMETER KeepFiles
    Keep the installed exe and log files; only remove the scheduled task.

.PARAMETER InstallDir
    Override the install folder. Defaults to %LOCALAPPDATA%\Nvidia_Instant_Replay_Fix.

.NOTES
    This only stops the patcher from auto-running on the next logon. Patches
    already written into the currently-running nvcontainer.exe stay until that
    process restarts (e.g. reboot or NVIDIA service restart).

    by iALTURKi
#>
[CmdletBinding()]
param(
    [switch]$KeepFiles,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix')
)

$ErrorActionPreference = 'Stop'

$TaskNames    = @('Nvidia_Instant_Replay_Fix', 'ShadowPlay_Patcher')  # current + legacy
$LegacyDirs   = @((Join-Path $env:LOCALAPPDATA 'ShadowPlay_Patcher'))
$ProcessNames = @('Nvidia_Instant_Replay_Fix', 'ShadowPlay_Patcher')

function Write-Step($msg) { Write-Host "[+] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "[--] $msg" -ForegroundColor DarkGray }

# --- Stop any running watchdog processes (current + legacy)
foreach ($n in $ProcessNames) {
    $procs = Get-Process -Name $n -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        try { $p | Stop-Process -Force -ErrorAction Stop; Write-Step "Stopped $n (PID $($p.Id))" } catch { }
    }
}

# --- Unregister scheduled tasks (current + legacy)
$removed = $false
foreach ($t in $TaskNames) {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Write-Step "Removing scheduled task '$t'"
        Unregister-ScheduledTask -TaskName $t -Confirm:$false
        $removed = $true
    }
}
if (-not $removed) { Write-Skip "No scheduled task to remove." }

# --- Remove install dir (current + legacy)
$dirs = @($InstallDir) + $LegacyDirs | Select-Object -Unique
foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    if ($KeepFiles -and $d -eq $InstallDir) {
        Write-Ok "Kept files at $d (per -KeepFiles)."
        continue
    }
    Write-Step "Removing folder $d"
    Remove-Item -LiteralPath $d -Recurse -Force
}

Write-Host ""
Write-Ok "Uninstall complete. Reboot (or restart NvContainerLocalSystem) to fully revert the in-process hooks."
