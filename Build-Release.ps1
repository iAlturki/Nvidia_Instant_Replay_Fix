#Requires -Version 5.1
<#
.SYNOPSIS
    Build-Release.ps1 - bundle the modular source into ONE self-contained
    release script: Nvidia_Instant_Replay_Fix.ps1

    Reuses the tested modules (Nirf-Ui.ps1 + Install-Persistence.ps1) and embeds
    the UI art as base64, then adds the download + dispatcher glue. Re-run this
    after editing any module to regenerate the single-file release.

.NOTES
    Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
    Licensed under the MIT License.
#>
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$GH   = 'https://github.com/iALTURKi/Nvidia_Instant_Replay_Fix'

# --- 1. UI library: strip the trailing "run directly = demo" block ---
$ui = Get-Content (Join-Path $root 'Nirf-Ui.ps1') -Raw -Encoding UTF8
$ui = [regex]::Replace($ui, '(?s)\r?\n# If run directly.*$', "`r`n")

# --- 2. Install library: take the constants + functions, drop param + standalone main ---
$ipRaw = Get-Content (Join-Path $root 'Install-Persistence.ps1') -Raw -Encoding UTF8
$m = [regex]::Match($ipRaw, '(?s)(\$Script:NIRF_TaskName\b.*?)\r?\n# =+\r?\n# Standalone main')
if (-not $m.Success) { throw 'could not extract install library from Install-Persistence.ps1' }
$installLib = $m.Groups[1].Value

# --- 3. embed the UI art as base64 ---
$eyeB64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'assets\nvidia_eye.ans')))
$iconB64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'assets\nvidia_icons.ans')))

# --- 4. the release template (single-quoted: $vars and @@tokens@@ are literal until .Replace) ---
$tpl = @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Nvidia_Instant_Replay_Fix - one-file installer + toolbox.

    Keeps NVIDIA Instant Replay (ShadowPlay) recording even when a "protected"
    app (a DRM browser tab, Apple Music, Netflix, etc.) is open, by installing a
    tiny hands-free background task. Everything is in this one script.

.PARAMETER Uninstall        Remove the background task + installed files.
.PARAMETER Reapply          Push the hooks onto the running NVIDIA process now.
.PARAMETER Status           Show whether the task + watchdog are running.
.PARAMETER ReinstallNvidia  Open NVIDIA's download page (repair overlay/recording).
.PARAMETER Fast             Skip the slow intro animation.

.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1                 # install (animated) + menu
.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1 -Status
.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1 -Uninstall

.NOTES
    Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
    Licensed under the MIT License.  Project: @@GH@@
    Independent, unofficial tool - not affiliated with NVIDIA Corporation.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$Reapply,
    [switch]$Status,
    [switch]$ReinstallNvidia,
    [switch]$Fast
)
$ErrorActionPreference = 'Stop'
$NIRF_GH  = '@@GH@@'
$EYE_B64  = '@@EYE@@'
$ICON_B64 = '@@ICON@@'

# =====================================================================================
# UI library (bundled from Nirf-Ui.ps1)
# =====================================================================================
@@UI@@
# =====================================================================================
# end UI library
# =====================================================================================

# Decode the embedded art to a cache dir so the UI can render the NVIDIA eye + icons.
try {
    $script:NirfDir = Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix\ui'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:NirfDir 'assets') -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllBytes((Join-Path $script:NirfDir 'assets\nvidia_eye.ans'),   [Convert]::FromBase64String($EYE_B64))
    [System.IO.File]::WriteAllBytes((Join-Path $script:NirfDir 'assets\nvidia_icons.ans'), [Convert]::FromBase64String($ICON_B64))
} catch {}

# =====================================================================================
# Install library (bundled from Install-Persistence.ps1)
# =====================================================================================
@@INSTALLLIB@@
# =====================================================================================
# end install library
# =====================================================================================

# Get the engine exe: prefer a local build (dev), else download the latest release.
function Get-NirfSourceExe {
    param([Parameter(Mandatory)][string]$Staging)
    $local = Join-Path $PSScriptRoot 'c\Nvidia_Instant_Replay_Fix.exe'
    if (Test-Path -LiteralPath $local) { return $local }
    New-Item -ItemType Directory -Force -Path $Staging | Out-Null
    $base = "$NIRF_GH/releases/latest/download"
    $exe  = Join-Path $Staging 'Nvidia_Instant_Replay_Fix.exe'
    Invoke-WebRequest -Uri "$base/Nvidia_Instant_Replay_Fix.exe" -OutFile $exe -UseBasicParsing -ErrorAction Stop
    try { Invoke-WebRequest -Uri "$base/neuter_wda.dll" -OutFile (Join-Path $Staging 'neuter_wda.dll') -UseBasicParsing -ErrorAction Stop } catch {}
    return $exe
}

function Show-NirfHeader {
    Enable-NirfVT
    Show-NirfBanner -Fast:$Fast
    if (Get-Command Show-NirfIcons -ErrorAction SilentlyContinue) {
        Show-NirfDivider gradient; Show-NirfIcons; Show-NirfDivider diamond; Write-Host ''
    }
}

function Show-NirfComplete {
    param($Paths)
    Write-Host ''
    $box = @(
        '   +========================================================+',
        '   |          INSTALL COMPLETE  -  watchdog is live         |',
        '   +========================================================+')
    if (Get-Command Show-NirfRainbow -ErrorAction SilentlyContinue) { Show-NirfRainbow -Lines $box -SettleGreen }
    else { $box | ForEach-Object { Write-Host $_ -ForegroundColor Green } }
    Write-Host ''
    Write-NirfStep 'It runs itself: a hidden task starts at logon and keeps Instant Replay' info
    Write-NirfStep 'alive even when a protected app (DRM browser tab, Apple Music) is open.' info
    Write-NirfStep 'Record / save with your usual NVIDIA hotkey (default Alt+F10).' info
    Write-Host ''
    Write-NirfStep ("Log    : {0}" -f $Paths.RunLog) info
    Write-NirfStep  'Status : .\Nvidia_Instant_Replay_Fix.ps1 -Status' info
    Write-NirfStep  'Remove : .\Nvidia_Instant_Replay_Fix.ps1 -Uninstall' info
}

function Invoke-NirfMenu {
    Write-Host ''
    Write-Host '   Anything else? (press Enter to finish)' -ForegroundColor White
    Write-Host '     [1] Re-apply the fix now' -ForegroundColor Gray
    Write-Host '     [2] Reinstall / repair the NVIDIA App' -ForegroundColor Gray
    Write-Host '     [3] Open the project on GitHub' -ForegroundColor Gray
    switch -Regex (Read-Host '   Choose [1/2/3/Enter]') {
        '^\s*1' { Invoke-NirfReapply }
        '^\s*2' { Invoke-NirfReinstallNvidia }
        '^\s*3' { try { Start-Process $NIRF_GH } catch {} }
        default { }
    }
}

# ------------------------------------------------------------------ actions
function Invoke-NirfInstall {
    Show-NirfHeader
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix'
    Initialize-NIRFInstallDir -InstallDir $InstallDir
    $paths = Get-NIRFInstallPaths -InstallDir $InstallDir

    Write-NirfStep 'Removing any previous install...' info
    [void](Remove-NIRFPreviousInstall -WipeLegacyDirs)

    Write-NirfStep 'Fetching the engine (local build, or latest GitHub release)...' info
    $staging = Join-Path $env:TEMP ('nirf_' + [guid]::NewGuid().ToString('N'))
    try { $src = Get-NirfSourceExe -Staging $staging }
    catch {
        Write-NirfStep "Could not get the engine: $($_.Exception.Message)" fail
        Write-NirfStep 'Publish a GitHub release containing Nvidia_Instant_Replay_Fix.exe,' warn
        Write-NirfStep 'or run this script from inside the repo (it will use c\...exe).' warn
        return
    }
    Install-NIRFBinary -SourceExe $src -DestExe $paths.ExePath
    Write-NirfStep ("Installed engine -> {0}" -f $paths.ExePath) ok

    Write-NirfStep 'Registering the hands-free background task...' info
    $sid = Get-NIRFSID
    $xml = New-NIRFTaskXml -ExePath $paths.ExePath -LogPath $paths.RunLog -SID $sid.SID -Mode Watchdog
    Save-NIRFTaskXml -Xml $xml -Path $paths.XmlFile
    Register-NIRFTaskFromXml -Xml $xml
    Start-NIRFTask
    if (Test-NIRFAlive -TimeoutSec 8) { Write-NirfStep 'Watchdog is live - keeping Instant Replay alive.' ok }
    else { Write-NirfStep 'Watchdog did not appear within 8s; check the log.' warn }

    Show-NirfComplete -Paths $paths
    Invoke-NirfMenu
}

function Invoke-NirfUninstall {
    Show-NirfHeader
    Write-NirfStep 'Removing the background task + stopping the watchdog...' info
    [void](Remove-NIRFPreviousInstall -WipeLegacyDirs)
    $InstallDir = Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix'
    if (Test-Path -LiteralPath $InstallDir) {
        try { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop; Write-NirfStep "Deleted $InstallDir" ok }
        catch { Write-NirfStep "Could not fully delete $InstallDir ($($_.Exception.Message))" warn }
    }
    Write-NirfStep 'Uninstalled.' ok
}

function Invoke-NirfReapply {
    $exe = Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix\Nvidia_Instant_Replay_Fix.exe'
    if (-not (Test-Path -LiteralPath $exe)) { Write-NirfStep 'Not installed yet - run install first.' warn; return }
    Write-NirfStep 'Re-applying hooks to the running NVIDIA process...' info
    & $exe --no-wait-for-keypress *>&1 | Out-Null
    Write-NirfStep 'Hooks re-applied.' ok
}

function Invoke-NirfStatus {
    Show-NirfHeader
    $t = Get-ScheduledTask -TaskName $Script:NIRF_TaskName -ErrorAction SilentlyContinue
    if ($t) { Write-NirfStep ("Scheduled task : present  (State = {0})" -f $t.State) ok }
    else    { Write-NirfStep 'Scheduled task : NOT installed' warn }
    if (Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Script:NIRF_ExeName)) -ErrorAction SilentlyContinue) {
        Write-NirfStep 'Watchdog       : running' ok
    } else { Write-NirfStep 'Watchdog       : not running' warn }
    $exe = Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix\Nvidia_Instant_Replay_Fix.exe'
    if (Test-Path -LiteralPath $exe) { Write-NirfStep ("Engine         : {0}" -f $exe) info }
}

function Invoke-NirfReinstallNvidia {
    Show-NirfHeader
    Write-NirfStep 'Stopping our watchdog so it does not interfere...' info
    Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Script:NIRF_ExeName)) -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Process 'https://www.nvidia.com/en-us/software/nvidia-app/'
    Write-NirfStep 'Opened NVIDIA App download page. Reinstall it to repair the overlay /' info
    Write-NirfStep 'recording, then re-run this script with no arguments to re-install.' info
}

# ------------------------------------------------------------------ dispatch
# The memory patch needs no admin, but adding/removing the auto-start scheduled
# task does. For install/uninstall, re-launch elevated (one UAC prompt).
function Test-NirfAdmin {
    try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
    catch { $false }
}
$nirfNeedsAdmin = $Uninstall -or -not ($Reapply -or $Status -or $ReinstallNvidia)
if ($nirfNeedsAdmin -and -not (Test-NirfAdmin)) {
    $self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"{0}"' -f $self))
    if ($Uninstall) { $argList += '-Uninstall' }
    if ($Fast)      { $argList += '-Fast' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host ''
        Write-Host '  Administrator rights are needed to add/remove the startup task.' -ForegroundColor Yellow
        Write-Host '  Re-run and click Yes on the prompt (or right-click Run.bat > Run as administrator).' -ForegroundColor Yellow
        Read-Host '  Press Enter to close'
    }
    return
}
Enable-NirfVT
if     ($Uninstall)       { Invoke-NirfUninstall }
elseif ($Reapply)         { Invoke-NirfReapply }
elseif ($Status)          { Invoke-NirfStatus }
elseif ($ReinstallNvidia) { Invoke-NirfReinstallNvidia }
else                      { Invoke-NirfInstall }
'@

# --- 5. substitute + write the single-file release (UTF-8 BOM for the block art) ---
$tpl = $tpl.Replace('@@UI@@', $ui).Replace('@@INSTALLLIB@@', $installLib).Replace('@@EYE@@', $eyeB64).Replace('@@ICON@@', $iconB64).Replace('@@GH@@', $GH)
$outFile = Join-Path $root 'Nvidia_Instant_Replay_Fix.ps1'
[System.IO.File]::WriteAllText($outFile, $tpl, (New-Object System.Text.UTF8Encoding($true)))

$kb = [math]::Round((Get-Item $outFile).Length / 1KB, 1)
Write-Host "Built $outFile  ($kb KB)" -ForegroundColor Green
