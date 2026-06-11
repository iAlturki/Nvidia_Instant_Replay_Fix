<#
.SYNOPSIS
    Guided reinstall/repair of the NVIDIA App to restore clean, version-matched,
    signed ShadowPlay components (_nvspcaps64.dll etc.). Fixes:
      - "There was a problem opening the overlay" (HashMismatch from a bad patch)
      - a version-mismatched _nvspcaps64.dll that records nothing (NVENC idle)

    The NVIDIA App is NOT in winget (Microsoft blocked the submissions), and its
    direct installer URL is version-pinned, so this script opens NVIDIA's official
    download page and walks you through it, then verifies the result.

.PARAMETER Verify
    Skip the download flow; just check whether the current install is healthy
    (signed _nvspcaps64.dll, matched version, NVENC recording).

.EXAMPLE
    .\Reinstall-NvidiaApp.ps1            # stop our tooling, open the download page, guide
    .\Reinstall-NvidiaApp.ps1 -Verify    # after reinstalling, confirm the base is clean
#>
[CmdletBinding()]
param([switch]$Verify)

. (Join-Path $PSScriptRoot 'Nirf-Ui.ps1')
Enable-NirfVT

$nvsp        = 'C:\Program Files\NVIDIA Corporation\NVIDIA app\ShadowPlay\NVSPCAPS\_nvspcaps64.dll'
$downloadUrl = 'https://www.nvidia.com/en-us/software/nvidia-app/'
$nvSmi       = 'C:\Windows\System32\nvidia-smi.exe'

function Get-NvspInfo {
    if (-not (Test-Path $nvsp)) { return [pscustomobject]@{ Exists=$false } }
    $it = Get-Item $nvsp
    [pscustomobject]@{
        Exists  = $true
        Version = $it.VersionInfo.FileVersion
        Sig     = (Get-AuthenticodeSignature $nvsp).Status
    }
}

function Test-IRRecording {
    if (-not (Test-Path $nvSmi)) { return $null }
    $best = 0
    1..4 | ForEach-Object {
        $o = & $nvSmi --query-gpu=encoder.stats.sessionCount --format=csv,noheader,nounits 2>$null
        if ($o) { $n = [int]($o | Select-Object -First 1).Trim(); if ($n -gt $best) { $best = $n } }
        Start-Sleep -Milliseconds 600
    }
    return $best
}

Show-NirfBanner

# --------------------------------------------------------------------------------
if ($Verify) {
    Write-NirfStep 'Verifying the NVIDIA App / ShadowPlay base is clean...' info
    Write-Host ""
    $info = Get-NvspInfo
    if (-not $info.Exists) {
        Write-NirfStep "_nvspcaps64.dll not found - NVIDIA App not installed?" fail
        return
    }
    Write-NirfStep ("_nvspcaps64.dll  version {0}" -f $info.Version) info
    if ($info.Sig -eq 'Valid') { Write-NirfStep ("signature: {0}" -f $info.Sig) ok }
    else                       { Write-NirfStep ("signature: {0}  (NOT clean - reinstall)" -f $info.Sig) fail }

    Write-NirfStep 'Checking whether Instant Replay actually records (NVENC)...' info
    $sessions = Test-IRRecording
    if ($null -eq $sessions) {
        Write-NirfStep 'nvidia-smi not found; cannot check NVENC.' warn
    } elseif ($sessions -ge 1) {
        Write-NirfStep "NVENC active (sessions=$sessions) - IR is recording. Base is healthy." ok
    } else {
        Write-NirfStep 'NVENC idle (sessions=0). Toggle Instant Replay ON, do something on screen, then re-verify.' warn
    }

    Write-Host ""
    if ($info.Sig -eq 'Valid' -and $sessions -ge 1) {
        Write-NirfStep 'Foundation is clean and recording. You can now (optionally) apply the runtime keep-alive hooks.' ok
    } else {
        Write-NirfStep 'Not fully healthy yet - finish the reinstall and/or get IR recording before adding hooks.' warn
    }
    return
}

# --------------------------------------------------------------------------------
# Reinstall flow
$before = Get-NvspInfo
if ($before.Exists) {
    Write-NirfStep ("current _nvspcaps64.dll  v{0}  sig={1}" -f $before.Version, $before.Sig) $(if($before.Sig -eq 'Valid'){'ok'}else{'warn'})
}

Write-NirfStep 'Stopping our watchdog (if running) so it does not interfere with the reinstall...' info
$wd = Get-Process -Name 'Nvidia_Instant_Replay_Fix' -ErrorAction SilentlyContinue
if ($wd) { $wd | Stop-Process -Force -ErrorAction SilentlyContinue; Write-NirfStep 'watchdog stopped' ok }
else     { Write-NirfStep 'watchdog not running' ok }

Write-Host ""
for ($p = 0; $p -le 100; $p += 5) { Show-NirfProgress -Percent $p -Label 'opening NVIDIA download page'; Start-Sleep -Milliseconds 18 }

Start-Process $downloadUrl
Write-NirfStep "Opened: $downloadUrl" ok

Write-Host ""
Write-NirfType '  NEXT STEPS' @(190,255,90) 0
Write-NirfStep 'On the page, click "Download Now" to get the NVIDIA App installer.' info
Write-NirfStep 'Run the installer. It restores the correct signed ShadowPlay DLLs (e.g. 11.0.8.244),' info
Write-NirfStep 'repairing both the overlay and the recording pipeline.' info
Write-NirfStep 'After it finishes, open the overlay (Alt+Z) and toggle Instant Replay ON.' info
Write-Host ""
Write-NirfType '  Then confirm the base is clean:' @(120,160,220) 0
Write-NirfStep '.\Reinstall-NvidiaApp.ps1 -Verify' info
Write-Host ""
Write-NirfStep 'Only AFTER -Verify shows Valid signature + NVENC recording should you re-apply the keep-alive hooks.' warn
