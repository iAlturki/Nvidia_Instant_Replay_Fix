#Requires -Version 5.1
<#
.SYNOPSIS
    Nvidia_Instant_Replay_Fix - hands-free installer.
.DESCRIPTION
    Invoked by Setup.bat. Builds the C source if needed, installs the
    Scheduled Task that runs the watchdog hidden, and optionally disables
    the Chromium hardware-secure-decryption flag in every installed
    Chromium-based browser.

    Each step is reported individually so it's obvious what's happening.
.NOTES
    Nvidia_Instant_Replay_Fix
    Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
    Licensed under the MIT License. See the LICENSE file in the project root.
#>
[CmdletBinding()]
param()

# UTF-8 console output for banner glyphs.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Stop'
$Repo       = $PSScriptRoot
$CDir       = Join-Path $Repo 'c'
$BuildBat   = Join-Path $CDir 'build.bat'
$Installer  = Join-Path $Repo 'Install-Persistence.ps1'
$ChromeFix  = Join-Path $Repo 'Fix-ChromeFlag.ps1'

# Load Install-Persistence.ps1 as a function library (no main).
. $Installer -AsLibrary

$Paths      = Get-NIRFInstallPaths -InstallDir (Join-Path $env:LOCALAPPDATA $Script:NIRF_TaskName)

# ----------------------------------------------------------------------------
# Tiny colour helpers.
# ----------------------------------------------------------------------------
function W   ($t,$c='Gray'){ Write-Host $t -ForegroundColor $c -NoNewline }
function WL  ($t,$c='Gray'){ Write-Host $t -ForegroundColor $c }
function NL  { Write-Host '' }
function Chip($t,$bg='DarkGreen'){ Write-Host " $t " -ForegroundColor Black -BackgroundColor $bg -NoNewline }

$Host.UI.RawUI.WindowTitle = 'Nvidia_Instant_Replay_Fix - Setup  |  by iALTURKi'
Clear-Host

# ----------------------------------------------------------------------------
# Banner: iALTURKi in ANSI Shadow block letters.
# ----------------------------------------------------------------------------
$banner = @(
    '   ██╗  █████╗  ██╗    ████████╗ ██╗   ██╗ ██████╗  ██╗  ██╗ ██╗',
    '   ██║ ██╔══██╗ ██║    ╚══██╔══╝ ██║   ██║ ██╔══██╗ ██║ ██╔╝ ██║',
    '   ██║ ███████║ ██║       ██║    ██║   ██║ ██████╔╝ █████╔╝  ██║',
    '   ██║ ██╔══██║ ██║       ██║    ██║   ██║ ██╔══██╗ ██╔═██╗  ██║',
    '   ██║ ██║  ██║ ███████╗  ██║    ╚██████╔╝ ██║  ██║ ██║  ██╗ ██║',
    '   ╚═╝ ╚═╝  ╚═╝ ╚══════╝  ╚═╝     ╚═════╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝'
)

# Animated banner (truecolor reveal + glow pulse + typed subtitle) from the shared
# UI library. Falls back to the static banner above if Nirf-Ui.ps1 is missing or VT
# is unavailable, so Setup never fails just because of cosmetics.
$NirfUi = Join-Path $Repo 'Nirf-Ui.ps1'
$bannerShown = $false
if (Test-Path $NirfUi) {
    try { . $NirfUi; Enable-NirfVT; Show-NirfBanner; $bannerShown = $true } catch { $bannerShown = $false }
}
if (-not $bannerShown) {
    NL
    $banner[0..2] | ForEach-Object { WL $_ Cyan }
    $banner[3..5] | ForEach-Object { WL $_ Magenta }
    NL
    WL '                   Nvidia_instant_replay_Fix'                  White
    WL '                  event-driven  -  hands-free'                 DarkGray
}
NL
WL '   ----------------------------------------------------------'  DarkGray
WL '                          by iALTURKi'                          Magenta
WL '   ----------------------------------------------------------'  DarkGray
NL

# Feature showcase: NVIDIA Overlay | ShadowPlay record | GitHub (from Nirf-Ui).
if (Get-Command Show-NirfIcons -ErrorAction SilentlyContinue) {
    Show-NirfDivider gradient
    Show-NirfIcons
    Show-NirfDivider diamond
    NL
}

# ----------------------------------------------------------------------------
# Step helper.
#   Prints "  [ * ] Label..." then runs the body. On success appends green OK.
#   On thrown exception appends red FAIL and the indented error.
#   Returns $true / $false.
# ----------------------------------------------------------------------------
function Step([string]$Label, [scriptblock]$Body) {
    $padded = $Label.PadRight(46)
    W   '   [ ' Cyan; W '*' Yellow; W ' ] ' Cyan
    W   $padded White
    try {
        $detail = & $Body
        WL ' OK' Green
        if ($null -ne $detail -and "$detail".Trim()) {
            foreach ($line in ($detail -split "`r?`n")) {
                WL ("           - $line") DarkGray
            }
        }
        return $true
    } catch {
        WL ' FAIL' Red
        foreach ($line in ($_.Exception.Message -split "`r?`n")) {
            WL ("           ! $line") DarkRed
        }
        return $false
    }
}

# Run a step that MUST succeed; abort the whole installer otherwise.
function Require($Label, $Body) {
    if (-not (Step $Label $Body)) { Fail-Install; exit 1 }
}

function Fail-Install {
    NL
    WL '   ╔════════════════════════════════════════════════════════╗' Red
    WL '   ║                  INSTALL FAILED                        ║' Red
    WL '   ╚════════════════════════════════════════════════════════╝' Red
    NL
    W  '   See: ' DarkGray; WL $Paths.LogFile Cyan
    W  '   And: ' DarkGray; WL $Paths.XmlFile Cyan
    NL
    Read-Host '   Press Enter to close' | Out-Null
}

# ============================================================================
# STEPS
# ============================================================================
$Script:ToolchainFound = ''
$Script:SourceExe       = ''
$Script:Identity        = $null
$Script:BinaryInfo      = $null
$Script:CleanupReport   = $null
$Script:TaskXml         = ''

# 1
Require 'Verifying environment' {
    if (-not (Test-Path -LiteralPath $BuildBat))  { throw "missing $BuildBat" }
    if (-not (Test-Path -LiteralPath $Installer)) { throw "missing $Installer" }
    if (-not (Test-Path -LiteralPath $ChromeFix)) { throw "missing $ChromeFix" }
    "$Repo"
}

# 2
Require 'Looking up user identity' {
    $Script:Identity = Get-NIRFSID
    "$($Script:Identity.Name)  ($($Script:Identity.SID))"
}

# 3
Require 'Detecting C toolchain' {
    $cl  = Get-Command cl  -ErrorAction SilentlyContinue
    $gcc = Get-Command gcc -ErrorAction SilentlyContinue
    $vsw = "$env:ProgramFiles(x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    $hasVs = (Test-Path -LiteralPath $vsw) -and `
             (((& $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath) | Select-Object -First 1))
    $msys = @('C:\msys64\mingw64\bin\gcc.exe','C:\msys64\ucrt64\bin\gcc.exe','C:\msys64\clang64\bin\gcc.exe') |
            Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $found = @()
    if ($cl)    { $found += 'MSVC (on PATH)' }
    if (-not $cl -and $hasVs)  { $found += 'Visual Studio (via vswhere)' }
    if ($gcc)   { $found += 'gcc (on PATH)' }
    if (-not $gcc -and $msys) { $found += "MinGW ($msys)" }
    if (-not $found) { throw "no compiler found; install MSYS2 (winget install MSYS2.MSYS2) or VS 2022 Build Tools" }
    $Script:ToolchainFound = $found[0]
    $Script:ToolchainFound
}

# 4
Require 'Building C source' {
    $exeAtBuildDir = Join-Path $CDir $Script:NIRF_ExeName
    # Always rebuild on fresh runs to pick up any source/exe rename.
    if (Test-Path -LiteralPath $exeAtBuildDir) {
        Remove-Item -LiteralPath $exeAtBuildDir -Force -ErrorAction SilentlyContinue
    }
    $log = Join-Path $env:TEMP 'nirf_build.log'
    cmd.exe /c "`"$BuildBat`" >`"$log`" 2>&1" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("build.bat exited $LASTEXITCODE`n" + (Get-Content $log -Raw))
    }
    if (-not (Test-Path -LiteralPath $exeAtBuildDir)) {
        throw "build succeeded but $exeAtBuildDir missing"
    }
    $Script:SourceExe = $exeAtBuildDir
    "{0:N0} bytes  ->  {1}" -f (Get-Item $exeAtBuildDir).Length, $exeAtBuildDir
}

# 5
Require 'Verifying binary' {
    $info = Get-NIRFBinaryInfo -Path $Script:SourceExe
    $Script:BinaryInfo = $info
    "SHA256: $($info.SHA256)"
}

# 6
Require 'Removing previous installation' {
    $r = Remove-NIRFPreviousInstall -WipeLegacyDirs
    $Script:CleanupReport = $r
    $bits = @()
    if ($r.TasksRemoved.Count)      { $bits += "tasks: $($r.TasksRemoved -join ', ')" }
    if ($r.ProcessesKilled.Count)   { $bits += "killed: $($r.ProcessesKilled -join ', ')" }
    if ($r.LegacyDirsRemoved.Count) { $bits += "wiped: $($r.LegacyDirsRemoved -join ', ')" }
    if (-not $bits) { return 'nothing to clean' }
    $bits -join '  |  '
}

# 7
Require 'Preparing install directory' {
    Initialize-NIRFInstallDir -InstallDir $Paths.InstallDir
    $Paths.InstallDir
}

# 8
Require 'Installing binary' {
    Install-NIRFBinary -SourceExe $Script:SourceExe -DestExe $Paths.ExePath
    "-> $($Paths.ExePath)"
}

# 9
Require 'Generating task definition' {
    $Script:TaskXml = New-NIRFTaskXml `
        -ExePath $Paths.ExePath `
        -LogPath $Paths.RunLog `
        -SID     $Script:Identity.SID `
        -Mode    'Watchdog' `
        -DelaySeconds 30
    Save-NIRFTaskXml -Xml $Script:TaskXml -Path $Paths.XmlFile
    "$([math]::Round((($Script:TaskXml.Length)/1024),1)) KB  ->  $($Paths.XmlFile)"
}

# 10
Require 'Registering Scheduled Task' {
    Register-NIRFTaskFromXml -Xml $Script:TaskXml -TaskName $Script:NIRF_TaskName
    "name: $($Script:NIRF_TaskName)"
}

# 11
Require 'Starting watchdog' {
    Start-NIRFTask -TaskName $Script:NIRF_TaskName
    'task triggered'
}

# 12
Require 'Confirming watchdog is alive' {
    if (-not (Test-NIRFAlive -TimeoutSec 10)) {
        throw "no Nvidia_Instant_Replay_Fix process after 10 s"
    }
    $p = Get-Process -Name 'Nvidia_Instant_Replay_Fix' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { "PID $($p.Id), MainWindowHandle=$($p.MainWindowHandle) (0 = hidden, good)" } else { 'alive' }
}

# ----------------------------------------------------------------------------
# Optional Chrome flag fix.
# ----------------------------------------------------------------------------
NL
WL '   ----------------------------------------------------------'   DarkGray
WL '   Optional: silence the Chromium "protected app" popup'         White
WL '   ----------------------------------------------------------'   DarkGray
NL
$ans = Read-Host '   Apply Chrome/Edge/Brave flag fix? [Y/n]'
if ($ans -ne 'n' -and $ans -ne 'N') {
    $closeAns = Read-Host '   Close any running Chromium browsers to apply now? [y/N]'
    # Splat a HASHTABLE (not an array) so the switch binds by name. Array splatting
    # passes '-CloseRunning' as a positional value, which the script has no slot for.
    $closeArgs = @{}
    if ($closeAns -eq 'y' -or $closeAns -eq 'Y') { $closeArgs = @{ CloseRunning = $true } }
    Step 'Patching Chromium Local State' {
        & $ChromeFix @closeArgs *>&1 | Out-Null
        if ($LASTEXITCODE -gt 0) { throw "Fix-ChromeFlag.ps1 exited $LASTEXITCODE" }
        'done'
    } | Out-Null
}

# ----------------------------------------------------------------------------
# Success box.
# ----------------------------------------------------------------------------
NL
$completeBox = @(
    '   ╔════════════════════════════════════════════════════════╗',
    '   ║                                                        ║',
    '   ║         INSTALL COMPLETE  -  watchdog is live          ║',
    '   ║                                                        ║',
    '   ╚════════════════════════════════════════════════════════╝'
)
# Rainbow bomb on the success box (falls back to green if VT/UI unavailable).
if (Get-Command Show-NirfRainbow -ErrorAction SilentlyContinue) {
    Show-NirfRainbow -Lines $completeBox -SettleGreen
} else {
    $completeBox | ForEach-Object { WL $_ Green }
}
NL
WL '   What now?  Nothing - it runs itself.' White
WL '     - A hidden task starts at every logon and keeps Instant Replay alive' Gray
WL '       even when a "protected" app (a DRM browser tab, Apple Music, Netflix)' Gray
WL '       is open - the thing that normally makes NVIDIA pause or refuse to save.' Gray
WL '     - Just record/save with your usual NVIDIA hotkey (default Alt+F10).' Gray
WL '     - It survives NVIDIA driver/app updates and re-finds itself automatically.' Gray
NL
if (Get-Command Show-NirfDivider -ErrorAction SilentlyContinue) { Show-NirfDivider diamond } else { WL '   ----------------------------------------------------------' DarkGray }
W '   '; Write-Host '◈ QUICK REFERENCE' -ForegroundColor Green
NL
W '   '; Chip 'INSPECT' DarkCyan;  W '   '; WL $Paths.RunLog Cyan
WL '               the log of what the background task is doing - open it to troubleshoot.' DarkGray
W '   '; Chip 'STATUS ' DarkGreen; W '   '; WL "Get-ScheduledTask -TaskName $Script:NIRF_TaskName" White
WL '               paste this in PowerShell to confirm the task is installed and Running.' DarkGray
W '   '; Chip 'REMOVE ' DarkRed;   W '   '; WL (Join-Path $Repo 'Uninstall-Persistence.ps1') Cyan
WL '               run this script to fully uninstall (stops + deletes the task and files).' DarkGray
NL
$Script:NIRF_GitHub = 'https://github.com/iALTURKi/Nvidia_Instant_Replay_Fix'
WL '   github.com/iALTURKi/Nvidia_Instant_Replay_Fix' DarkGray
NL
WL '   Pressing Enter opens the project on GitHub, then a quick menu.' Yellow
Read-Host '   Press Enter' | Out-Null
try { Start-Process $Script:NIRF_GitHub } catch { }

# ----------------------------------------------------------------------------
# Post-install action menu.
# ----------------------------------------------------------------------------
NL
WL '   ----------------------------------------------------------'  DarkGray
WL '   Anything else? (all optional - press Enter to just finish)'  White
NL
W '     [1] ' Cyan; WL 'Re-apply the fix now' White
WL '         Pushes the hooks onto the running NVIDIA process immediately'   DarkGray
WL '         instead of waiting for the background task - handy right after'  DarkGray
WL '         an NVIDIA update, or if Instant Replay just got disabled.'       DarkGray
W '     [2] ' Cyan; WL 'Reinstall / repair the NVIDIA App' White
WL '         Opens NVIDIA''s download page - do this if the overlay breaks'   DarkGray
WL '         or recording/saving stops working (a version mismatch).'         DarkGray
W '     [3] ' Cyan; WL 'Install MicMute' White
WL '         Downloads + runs iALTURKi''s mic-mute hotkey tool from GitHub.'   DarkGray
W '     [Enter] ' DarkGray; WL "Finish - you're all set."                     Gray
NL
$choice = Read-Host '   Choose [1/2/3/Enter]'
switch -Regex ($choice) {
    '^\s*1' {
        Step 'Re-applying fix (one-shot)' {
            & $Paths.ExePath --no-wait-for-keypress *>&1 | Out-Null
            'hooks re-applied to the running nvcontainer'
        } | Out-Null
    }
    '^\s*2' {
        $reinstall = Join-Path $Repo 'Reinstall-NvidiaApp.ps1'
        if (Test-Path $reinstall) { & $reinstall }
        else { WL "   Missing $reinstall" Red }
    }
    '^\s*3' {
        $micDir = Join-Path $env:LOCALAPPDATA 'MicMute'
        $micExe = Join-Path $micDir 'iAlturki-MicMute.exe'
        $micUrl = 'https://github.com/iAlturki/MicMute/releases/latest/download/iAlturki-MicMute.exe'
        # Already installed? Don't re-download - just make sure it's running.
        if (Test-Path -LiteralPath $micExe) {
            Step 'MicMute already installed' {
                if (Get-Process -Name 'iAlturki-MicMute' -ErrorAction SilentlyContinue) { "running: $micExe" }
                else { Start-Process $micExe; "was not running - launched: $micExe" }
            } | Out-Null
        } else {
            Step 'Installing MicMute (latest release)' {
                New-Item -ItemType Directory -Force -Path $micDir | Out-Null
                try {
                    Invoke-WebRequest -Uri $micUrl -OutFile $micExe -UseBasicParsing -ErrorAction Stop
                    Start-Process $micExe
                    "downloaded + launched: $micExe"
                } catch {
                    Start-Process 'https://github.com/iAlturki/MicMute/releases'
                    throw "direct download failed ($($_.Exception.Message)); opened the Releases page instead"
                }
            } | Out-Null
        }
        NL
        WL '   MicMute - quick guide' White
        W  '     Mute / unmute  ' Gray; WL 'press F8   (right-click the tray icon to change the key)' Cyan
        W  '     See status     ' Gray; WL 'tray icon (red = muted, green dot = live) + a screen overlay' Cyan
        W  '     Uninstall      ' Gray; WL 'in MicMute settings turn OFF "Start with Windows",' Cyan
        WL '                    then right-click the tray icon > Exit, and delete the file:' DarkGray
        WL "                      $micExe" DarkGray
    }
    default { }
}
NL
WL '   Done. You can close this window.' DarkGray
exit 0
