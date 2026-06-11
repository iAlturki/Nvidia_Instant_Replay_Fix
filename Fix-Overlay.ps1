#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Repairs "There was a problem opening the overlay" caused by the on-disk
    patch having left _nvspcaps64.dll with a broken Authenticode signature
    (HashMismatch). Restores the original signed DLL from the .nirf.bak backup.

    Preserves the backup (does NOT delete it). Run from an ELEVATED PowerShell:
        cd C:\Users\Abood\Downloads\git\ShadowPlay_Patcher
        .\Fix-Overlay.ps1

    If the overlay still errors after this, the restored file (v11.0.7.247) is a
    version behind your installed NVIDIA App (v11.0.8.244) — reinstall the NVIDIA
    App from nvidia.com for the exact-version signed file (guaranteed fix).
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Continue'
$nvsp    = 'C:\Program Files\NVIDIA Corporation\NVIDIA app\ShadowPlay\NVSPCAPS\_nvspcaps64.dll'
$bak     = "$nvsp.nirf.bak"
$svcName = 'NvContainerLocalSystem'

function Sig($p) { if (Test-Path -LiteralPath $p) { (Get-AuthenticodeSignature -LiteralPath $p).Status } else { 'MISSING' } }

Write-Host ""
Write-Host "=== Overlay recovery: restore the signed _nvspcaps64.dll ===" -ForegroundColor Cyan
Write-Host ("  current DLL signature : {0}" -f (Sig $nvsp))
Write-Host ("  backup  signature     : {0}" -f (Sig $bak))

if (-not (Test-Path -LiteralPath $bak)) {
    Write-Host "  No .nirf.bak backup present. -> Reinstall the NVIDIA App to restore the file." -ForegroundColor Yellow
    return
}
if ((Sig $bak) -ne 'Valid') {
    Write-Host "  Backup is not validly signed. -> Reinstall the NVIDIA App instead." -ForegroundColor Yellow
    return
}

# 1. Stop our watchdog if it happens to be running.
Get-Process -Name 'Nvidia_Instant_Replay_Fix' -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "  stopping watchdog PID $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

# 2. Temporarily DISABLE + stop the container service so nvcontainer can't respawn
#    and keep the DLL locked while we replace it. Remember the original start type.
$origMode = (Get-CimInstance Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartMode
Write-Host "  disabling + stopping $svcName (orig start type: $origMode)..."
try { Set-Service -Name $svcName -StartupType Disabled -ErrorAction Stop } catch { Write-Warning "    $($_.Exception.Message)" }
try { Stop-Service -Name $svcName -Force -ErrorAction Stop }              catch { Write-Warning "    $($_.Exception.Message)" }
Get-Process -Name 'nvcontainer','NVIDIA Overlay','NVIDIA app' -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }

# 3. Wait for the DLL to become writable (no process holding it open).
$writable = $false
for ($i = 0; $i -lt 40; $i++) {
    try { $fs = [System.IO.File]::Open($nvsp, 'Open', 'ReadWrite', 'None'); $fs.Close(); $fs.Dispose(); $writable = $true; break }
    catch { Start-Sleep -Milliseconds 500 }
}
if (-not $writable) {
    Write-Host "  DLL still locked after 20s. Close the NVIDIA app fully (system tray) and re-run, or reinstall the App." -ForegroundColor Red
}

# 4. Restore the original signed DLL from the backup (KEEP the backup).
try {
    Copy-Item -LiteralPath $bak -Destination $nvsp -Force -ErrorAction Stop
    Write-Host "  restored _nvspcaps64.dll from backup." -ForegroundColor Green
} catch {
    Write-Host "  RESTORE FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  -> Reinstall the NVIDIA App from nvidia.com." -ForegroundColor Yellow
}

# 5. Re-enable + start the service (never leave it Disabled).
$restore = switch ($origMode) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } default { 'Automatic' } }
try { Set-Service -Name $svcName -StartupType $restore -ErrorAction Stop } catch { Write-Warning "    $($_.Exception.Message)" }
try { Start-Service -Name $svcName -ErrorAction Stop }                     catch { Write-Warning "    $($_.Exception.Message)" }

# 6. Verdict.
$now = Sig $nvsp
Write-Host ""
Write-Host ("=== Result: _nvspcaps64.dll signature = {0} ===" -f $now) -ForegroundColor $(if ($now -eq 'Valid') { 'Green' } else { 'Red' })
if ($now -eq 'Valid') {
    Write-Host "DONE. Open the overlay (Alt+Z) and toggle Instant Replay." -ForegroundColor Green
    Write-Host "If the overlay STILL errors, the restored file (v11.0.7.247) is older than your App" -ForegroundColor Yellow
    Write-Host "(v11.0.8.244) -> reinstall the NVIDIA App from nvidia.com for the exact-version file." -ForegroundColor Yellow
} else {
    Write-Host "Signature still not Valid -> reinstall the NVIDIA App from nvidia.com (guaranteed fix)." -ForegroundColor Yellow
}
