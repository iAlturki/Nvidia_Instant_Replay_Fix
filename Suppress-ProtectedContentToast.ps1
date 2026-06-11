#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Suppresses the "A protected app is preventing desktop capture" toast
    by blanking the two relevant i18n strings in NVIDIA Overlay's
    localization JSONs.

.DESCRIPTION
    Backs up each affected JSON to <file>.original before patching.
    To revert: copy the .original files back over the patched ones.

    Affected files:
        C:\Program Files\NVIDIA Corporation\NVIDIA app\osc\assets\i18n\en_US.json
        C:\Program Files\NVIDIA Corporation\NVIDIA app\osc\assets\i18n\en_GB.json

    Affected keys:
        notification.ProtectedContentApp        -> blanked
        notification.ProtectedContentGeneric    -> blanked

    NVIDIA Overlay re-reads these on next launch. After running this,
    close the NVIDIA Overlay window (or restart the NVIDIA App) for the
    change to take effect.

.PARAMETER Revert
    Restores the original JSON content from the .original backups.
#>
[CmdletBinding()]
param(
    [switch]$Revert
)

$jsonFiles = @(
    'C:\Program Files\NVIDIA Corporation\NVIDIA app\osc\assets\i18n\en_US.json',
    'C:\Program Files\NVIDIA Corporation\NVIDIA app\osc\assets\i18n\en_GB.json'
)

foreach ($file in $jsonFiles) {
    if (-not (Test-Path -LiteralPath $file)) {
        Write-Warning "missing: $file"
        continue
    }
    $backup = "$file.original"

    if ($Revert) {
        if (Test-Path -LiteralPath $backup) {
            Copy-Item -LiteralPath $backup -Destination $file -Force
            Write-Host "[reverted] $file" -ForegroundColor Yellow
        } else {
            Write-Warning "no backup to revert from: $backup"
        }
        continue
    }

    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $file -Destination $backup
        Write-Host "[backup created] $backup" -ForegroundColor Gray
    } else {
        Write-Host "[backup exists] $backup" -ForegroundColor Gray
    }

    $content = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    $patched = $content
    $patched = $patched -replace '"\{\{arg1\}\} is preventing desktop capture, close the app or disable desktop capture and try again\."', '" "'
    $patched = $patched -replace '"A protected app"', '" "'

    if ($patched -ne $content) {
        [System.IO.File]::WriteAllText($file, $patched, [System.Text.UTF8Encoding]::new($false))
        Write-Host "[patched] $file" -ForegroundColor Green
    } else {
        Write-Host "[unchanged] $file (already patched or strings already differ)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Done. To take effect, close NVIDIA Overlay (Alt+Z, then close), then re-open it."
if (-not $Revert) {
    Write-Host "To revert later: .\Suppress-ProtectedContentToast.ps1 -Revert"
}
