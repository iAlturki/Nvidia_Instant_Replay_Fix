#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Nvidia_Instant_Replay_Fix as a hidden Scheduled Task.

.DESCRIPTION
    Acts in two modes:

      1. Library mode (-AsLibrary)
         Defines installer functions but does not run anything. Setup.ps1
         dot-sources this file and calls the functions itself, one per
         visible step in the UI.

      2. Standalone mode (default)
         Runs the whole pipeline:
           - look up the current user's SID
           - copy the exe into %LOCALAPPDATA%\Nvidia_Instant_Replay_Fix\
           - generate the Scheduled Task XML
           - register the task
           - start the watchdog
           - confirm it's running

    The Scheduled Task action launches the exe directly (no cmd.exe wrapper).
    The exe self-redirects stdout/stderr to patcher.log and detaches from any
    inherited console, so no visible window is created.

    Logs at %LOCALAPPDATA%\Nvidia_Instant_Replay_Fix\:
        install.log    install trace
        task.xml       the registered task XML
        patcher.log    watchdog runtime log

.PARAMETER ExePath
    Path to Nvidia_Instant_Replay_Fix.exe. Auto-detects .\c\Nvidia_Instant_Replay_Fix.exe.

.PARAMETER InstallDir
    Where to copy the exe. Defaults to "$env:LOCALAPPDATA\Nvidia_Instant_Replay_Fix".

.PARAMETER DelaySeconds
    Logon-trigger delay in seconds. Default 30.

.PARAMETER Mode
    'Watchdog' (default) - event-driven daemon, runs forever.
    'Periodic'           - one-shot patcher fired every PeriodicMinutes minutes.

.PARAMETER PeriodicMinutes
    Periodic re-run interval (only used when -Mode Periodic). Default 5.

.PARAMETER DryRun
    Generate task.xml and install.log but do not register the task.

.PARAMETER SkipHashCheck
    Skip the VirusTotal hint after install.

.PARAMETER AsLibrary
    Define functions only; do not execute the installer pipeline. Used by Setup.ps1.

.NOTES
    by iALTURKi
#>
[CmdletBinding()]
param(
    [string]$ExePath,
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Nvidia_Instant_Replay_Fix'),
    [int]$DelaySeconds = 30,
    [ValidateSet('Watchdog','Periodic')][string]$Mode = 'Watchdog',
    [int]$PeriodicMinutes = 5,
    [switch]$DryRun,
    [switch]$SkipHashCheck,
    [switch]$AsLibrary
)

# ============================================================================
# Constants
# ============================================================================
$Script:NIRF_TaskName      = 'Nvidia_Instant_Replay_Fix'
$Script:NIRF_ExeName       = 'Nvidia_Instant_Replay_Fix.exe'
$Script:NIRF_LegacyTasks   = @('ShadowPlay_Patcher')
$Script:NIRF_LegacyDirs    = @('ShadowPlay_Patcher')
$Script:NIRF_LegacyExeNames= @('ShadowPlay_Patcher')

# ============================================================================
# Functions (library surface used by Setup.ps1)
# ============================================================================

function Get-NIRFSID {
    [CmdletBinding()] param()
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    [pscustomobject]@{
        SID  = $id.User.Value
        Name = $id.Name
    }
}

function Get-NIRFInstallPaths {
    [CmdletBinding()] param([string]$InstallDir)
    [pscustomobject]@{
        InstallDir = $InstallDir
        ExePath    = Join-Path $InstallDir $Script:NIRF_ExeName
        LogFile    = Join-Path $InstallDir 'install.log'
        XmlFile    = Join-Path $InstallDir 'task.xml'
        RunLog     = Join-Path $InstallDir 'patcher.log'
    }
}

# Probe local builds and fall back to upstream-style location.
function Resolve-NIRFSourceExe {
    [CmdletBinding()] param([string]$ScriptRoot)
    $candidates = @(
        (Join-Path $ScriptRoot 'c\Nvidia_Instant_Replay_Fix.exe'),
        (Join-Path $ScriptRoot 'c\ShadowPlay_Patcher.exe')     # legacy build output
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return $null
}

function Initialize-NIRFInstallDir {
    [CmdletBinding()] param([string]$InstallDir)
    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
}

function Install-NIRFBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceExe,
        [Parameter(Mandatory)][string]$DestExe
    )
    if (-not (Test-Path -LiteralPath $SourceExe)) {
        throw "source exe does not exist: $SourceExe"
    }

    # The destination exe may still be locked by a watchdog instance that was just
    # killed (Stop-Process is asynchronous - the file handle lingers briefly), so
    # copying immediately can fail with "being used by another process". Make sure
    # no instance is running, wait for the handle to release, and retry the copy.
    if (Test-Path -LiteralPath $DestExe) {
        Get-Process -Name ([System.IO.Path]::GetFileNameWithoutExtension($DestExe)) -ErrorAction SilentlyContinue |
            ForEach-Object { try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {} }
        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            try { $fs = [System.IO.File]::Open($DestExe, 'Open', 'ReadWrite', 'None'); $fs.Close(); $fs.Dispose(); break }
            catch { Start-Sleep -Milliseconds 400 }
        }
    }
    $copied = $false
    for ($attempt = 1; $attempt -le 5 -and -not $copied; $attempt++) {
        try { Copy-Item -LiteralPath $SourceExe -Destination $DestExe -Force -ErrorAction Stop; $copied = $true }
        catch { if ($attempt -eq 5) { throw } ; Start-Sleep -Milliseconds 500 }
    }
    try { Unblock-File -LiteralPath $DestExe -ErrorAction Stop } catch { }

    # Also copy neuter_wda.dll alongside the exe if present. The patcher
    # injects this DLL into Apple Music (and similar protected apps) to
    # neutralize SetWindowDisplayAffinity. Missing DLL just disables
    # hook 17; the patcher logs a warning and continues.
    $sourceDll = Join-Path (Split-Path -Parent $SourceExe) 'neuter_wda.dll'
    if (Test-Path -LiteralPath $sourceDll) {
        $destDll = Join-Path (Split-Path -Parent $DestExe) 'neuter_wda.dll'
        Copy-Item -LiteralPath $sourceDll -Destination $destDll -Force
        try { Unblock-File -LiteralPath $destDll -ErrorAction Stop } catch { }
    } else {
        Write-Warning "neuter_wda.dll not found next to source exe; hook 17 (WDA neuter) will be disabled until the DLL is built and copied to the install dir."
    }
}

function Get-NIRFBinaryInfo {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $f = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Path   = $Path
        Bytes  = $f.Length
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
    }
}

# Remove the current task plus any legacy variants. Also stop any running
# watchdog process (current or legacy) and optionally wipe legacy install dirs.
function Remove-NIRFPreviousInstall {
    [CmdletBinding()]
    param(
        [switch]$WipeLegacyDirs
    )
    $report = [ordered]@{
        TasksRemoved      = @()
        ProcessesKilled   = @()
        LegacyDirsRemoved = @()
    }

    $allTaskNames = @($Script:NIRF_TaskName) + $Script:NIRF_LegacyTasks
    foreach ($n in $allTaskNames) {
        if (Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue) {
            try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop; $report.TasksRemoved += $n }
            catch { }
        }
    }

    $allExeNames = @([io.path]::GetFileNameWithoutExtension($Script:NIRF_ExeName)) + $Script:NIRF_LegacyExeNames
    foreach ($exe in $allExeNames) {
        $procs = Get-Process -Name $exe -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            try { $p | Stop-Process -Force -ErrorAction Stop; $report.ProcessesKilled += "$exe(PID $($p.Id))" } catch { }
        }
    }

    if ($WipeLegacyDirs) {
        foreach ($name in $Script:NIRF_LegacyDirs) {
            $p = Join-Path $env:LOCALAPPDATA $name
            if (Test-Path -LiteralPath $p) {
                try { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; $report.LegacyDirsRemoved += $p } catch { }
            }
        }
    }

    return [pscustomobject]$report
}

# Build the complete task XML.
function New-NIRFTaskXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$SID,
        [ValidateSet('Watchdog','Periodic')][string]$Mode = 'Watchdog',
        [int]$DelaySeconds = 30,
        [int]$PeriodicMinutes = 5
    )

    function _Esc([string]$s) {
        if ($null -eq $s) { return '' }
        $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&apos;')
    }

    $exeArgs = if ($Mode -eq 'Watchdog') { '--watchdog --log "{0}"' -f $LogPath }
               else                       { '--wait 60 --log "{0}"'  -f $LogPath }

    $cmdPath    = _Esc $ExePath
    $argEscaped = _Esc $exeArgs

    $delayIso   = "PT${DelaySeconds}S"
    $periodIso  = "PT${PeriodicMinutes}M"
    $startBoundary = (Get-Date).AddSeconds([math]::Max($DelaySeconds, 30)).ToString('yyyy-MM-ddTHH:mm:ss')

    $periodicTriggerXml = ''
    if ($Mode -eq 'Periodic' -and $PeriodicMinutes -gt 0) {
        $periodicTriggerXml = @"
    <TimeTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$periodIso</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
"@
    }

    $eventSubscription = @'
<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name='Service Control Manager'] and EventID=7036]] and *[EventData[Data and (Data='NvContainerLocalSystem' or Data='NVIDIA LocalSystem Container')]]</Select></Query></QueryList>
'@
    $eventSubEscaped = _Esc $eventSubscription

    if ($Mode -eq 'Watchdog') {
        $desc = "Nvidia_Instant_Replay_Fix watchdog. Applies hooks then listens for NVIDIA registry-based disable attempts, reversing them in real time. Started at logon (delay $DelaySeconds s) and on NvContainerLocalSystem service state changes; auto-restarts on failure."
        $executionTimeLimit = 'PT0S'
        $restartOnFailureXml = @'
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
'@
    } else {
        $desc = "Nvidia_Instant_Replay_Fix periodic re-runner. Fires at logon (delay $DelaySeconds s)"
        if ($PeriodicMinutes -gt 0) { $desc += ", every $PeriodicMinutes min" }
        $desc += ", and on NvContainerLocalSystem service state changes."
        $executionTimeLimit = 'PT5M'
        $restartOnFailureXml = ''
    }

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$(_Esc $desc)</Description>
    <URI>\$($Script:NIRF_TaskName)</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>$delayIso</Delay>
      <UserId>$SID</UserId>
    </LogonTrigger>
$periodicTriggerXml
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>$eventSubEscaped</Subscription>
    </EventTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$SID</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>true</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$executionTimeLimit</ExecutionTimeLimit>
$restartOnFailureXml
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmdPath</Command>
      <Arguments>$argEscaped</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    return $taskXml
}

function Save-NIRFTaskXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Xml, [Parameter(Mandatory)][string]$Path)
    [System.IO.File]::WriteAllText($Path, $Xml, [System.Text.Encoding]::Unicode)
}

function Register-NIRFTaskFromXml {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Xml, [string]$TaskName = $Script:NIRF_TaskName)
    Register-ScheduledTask -TaskName $TaskName -Xml $Xml -ErrorAction Stop | Out-Null
}

function Start-NIRFTask {
    [CmdletBinding()] param([string]$TaskName = $Script:NIRF_TaskName)
    Start-ScheduledTask -TaskName $TaskName
}

# Returns $true if a process with our exe name is alive after up to $TimeoutSec seconds.
function Test-NIRFAlive {
    [CmdletBinding()]
    param([int]$TimeoutSec = 10)
    $name = [io.path]::GetFileNameWithoutExtension($Script:NIRF_ExeName)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

# ============================================================================
# Standalone main (skipped when -AsLibrary)
# ============================================================================
if ($AsLibrary) { return }

# --- Working dirs / log
Initialize-NIRFInstallDir -InstallDir $InstallDir
$paths = Get-NIRFInstallPaths -InstallDir $InstallDir

function _LogLine([string]$lvl,[string]$msg){
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "$ts [$lvl] $msg"
    Write-Host $line
    Add-Content -LiteralPath $paths.LogFile -Value $line -Encoding UTF8
}

Add-Content -LiteralPath $paths.LogFile -Value ('=' * 70) -Encoding UTF8
_LogLine 'STEP' "Install run starting (PID $PID, PowerShell $($PSVersionTable.PSVersion))"

# --- Identity
$ident = Get-NIRFSID
_LogLine 'DBG' "Identity Name='$($ident.Name)' SID='$($ident.SID)'"

# --- Resolve source exe
if (-not $ExePath) {
    $ExePath = Resolve-NIRFSourceExe -ScriptRoot $PSScriptRoot
}
if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
    _LogLine 'ERR' "No exe found. Build it first via .\c\build.bat or pass -ExePath."
    exit 2
}

# --- Migrate legacy + install binary
$report = Remove-NIRFPreviousInstall -WipeLegacyDirs
foreach ($t in $report.TasksRemoved)      { _LogLine 'STEP' "Removed previous task: $t" }
foreach ($p in $report.ProcessesKilled)   { _LogLine 'STEP' "Killed running process: $p" }
foreach ($d in $report.LegacyDirsRemoved) { _LogLine 'STEP' "Removed legacy dir: $d" }

Install-NIRFBinary -SourceExe $ExePath -DestExe $paths.ExePath
$info = Get-NIRFBinaryInfo -Path $paths.ExePath
_LogLine 'OK' ("Installed exe: {0} ({1} bytes)" -f $paths.ExePath, $info.Bytes)
_LogLine 'DBG' "SHA256: $($info.SHA256)"
if (-not $SkipHashCheck) {
    _LogLine 'INFO' "VirusTotal: https://www.virustotal.com/gui/file/$($info.SHA256)"
}

# --- Build + save XML
$xml = New-NIRFTaskXml -ExePath $paths.ExePath -LogPath $paths.RunLog -SID $ident.SID `
                       -Mode $Mode -DelaySeconds $DelaySeconds -PeriodicMinutes $PeriodicMinutes
Save-NIRFTaskXml -Xml $xml -Path $paths.XmlFile
_LogLine 'STEP' "Wrote task XML: $($paths.XmlFile)"

if ($DryRun) {
    _LogLine 'OK' "DryRun set; not registering."
    return
}

# --- Register + start
Register-NIRFTaskFromXml -Xml $xml -TaskName $Script:NIRF_TaskName
_LogLine 'OK' "Task '$($Script:NIRF_TaskName)' registered."

Start-NIRFTask -TaskName $Script:NIRF_TaskName
_LogLine 'STEP' "Triggered task."

if (Test-NIRFAlive -TimeoutSec 8) {
    _LogLine 'OK' "Watchdog is alive."
} else {
    _LogLine 'WARN' "Watchdog did not appear within 8s. Check $($paths.RunLog)"
}
