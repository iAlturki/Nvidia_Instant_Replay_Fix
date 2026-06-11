#Requires -Version 5.1
<#
.SYNOPSIS
    Disables the Chromium "Hardware secure decryption" experiment so it stops
    triggering the "Chrome is preventing desktop capture" popup that the
    NVIDIA App shows even when ShadowPlay_Patcher is active.

.DESCRIPTION
    Every Chromium-based browser (Chrome, Edge, Brave, Vivaldi, Opera, Yandex,
    ...) stores the chrome://flags state in a JSON file named "Local State".
    The relevant key is browser.enabled_labs_experiments, which is an array of
    strings of the form "<flag-name>@<choice-index>". For binary flags:
        @0 = Default     @1 = Enabled     @2 = Disabled

    This script:
      1. Locates the Local State file of every installed Chromium browser
      2. If the browser is running, closes it (with -Force) or skips it
         depending on the -CloseRunning switch
      3. Reads the JSON, adds "enable-hardware-secure-decryption-experiment@2"
         to enabled_labs_experiments if it's not already in the right state,
         writes the file back
      4. Reports what it did

    The change persists across browser restarts. Re-running the script is a
    no-op once the flag is already set.

.PARAMETER CloseRunning
    Close any running browsers before patching their Local State. Without this
    flag, running browsers are reported and skipped (because they would just
    overwrite our edit on exit).

.PARAMETER Revert
    Remove the override instead of adding it, returning the flag to Default.

.EXAMPLE
    .\Fix-ChromeFlag.ps1
    # patches all browsers that aren't running; reports the rest

.EXAMPLE
    .\Fix-ChromeFlag.ps1 -CloseRunning
    # closes any running Chromium browsers, then patches them

.EXAMPLE
    .\Fix-ChromeFlag.ps1 -Revert
    # restore the flag to Default
#>
[CmdletBinding()]
param(
    [switch]$CloseRunning,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'
$FlagName = 'enable-hardware-secure-decryption-experiment'
$FlagDisabled = "$FlagName@2"

# Display name, Local State path, list of process names to close.
$Browsers = @(
    @{ Name = 'Chrome';   Path = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Local State';                Processes = @('chrome') },
    @{ Name = 'Edge';     Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Local State';               Processes = @('msedge') },
    @{ Name = 'Brave';    Path = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data\Local State';  Processes = @('brave') },
    @{ Name = 'Vivaldi';  Path = Join-Path $env:LOCALAPPDATA 'Vivaldi\User Data\Local State';                      Processes = @('vivaldi') },
    @{ Name = 'Opera';    Path = Join-Path $env:APPDATA      'Opera Software\Opera Stable\Local State';            Processes = @('opera') },
    @{ Name = 'OperaGX';  Path = Join-Path $env:APPDATA      'Opera Software\Opera GX Stable\Local State';         Processes = @('opera') },
    @{ Name = 'Yandex';   Path = Join-Path $env:LOCALAPPDATA 'Yandex\YandexBrowser\User Data\Local State';         Processes = @('browser','yandex') },
    @{ Name = 'Chromium'; Path = Join-Path $env:LOCALAPPDATA 'Chromium\User Data\Local State';                     Processes = @('chromium') }
)

function Write-Step($m){ Write-Host "[+] $m" -ForegroundColor Cyan }
function Write-Ok($m)  { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Skip($m){ Write-Host "[--] $m" -ForegroundColor DarkGray }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err($m) { Write-Host "[ERR] $m" -ForegroundColor Red }

$found = 0
$patched = 0
$skipped = 0

foreach ($b in $Browsers) {
    if (-not (Test-Path -LiteralPath $b.Path)) {
        continue
    }
    $found++
    Write-Step "$($b.Name): $($b.Path)"

    # Browser running?
    $running = @()
    foreach ($n in $b.Processes) {
        $running += Get-Process -Name $n -ErrorAction SilentlyContinue
    }
    if ($running) {
        if ($CloseRunning) {
            Write-Warn2 "  $($b.Name) is running ($($running.Count) processes). Closing..."
            try {
                $running | ForEach-Object { $_.CloseMainWindow() | Out-Null }
                Start-Sleep -Seconds 2
                Get-Process -Name $b.Processes -ErrorAction SilentlyContinue | Stop-Process -Force
                Start-Sleep -Seconds 1
            } catch {
                Write-Err "  Could not close $($b.Name): $($_.Exception.Message)"
                $skipped++; continue
            }
        } else {
            Write-Warn2 "  $($b.Name) is running. Skipping (re-run with -CloseRunning to apply anyway)."
            $skipped++; continue
        }
    }

    # Backup
    $backup = "$($b.Path).bak"
    if (-not (Test-Path -LiteralPath $backup)) {
        Copy-Item -LiteralPath $b.Path -Destination $backup -Force
        Write-Host "  backup -> $backup"
    }

    # Read JSON
    try {
        $raw  = Get-Content -LiteralPath $b.Path -Raw -Encoding UTF8
        $json = $raw | ConvertFrom-Json
    } catch {
        Write-Err "  Could not parse Local State JSON: $($_.Exception.Message)"
        $skipped++; continue
    }

    # Ensure structure
    if (-not $json.browser) {
        $json | Add-Member -NotePropertyName browser -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not $json.browser.enabled_labs_experiments) {
        $json.browser | Add-Member -NotePropertyName enabled_labs_experiments -NotePropertyValue @() -Force
    }

    [System.Collections.ArrayList]$exp = @($json.browser.enabled_labs_experiments)

    # Remove any pre-existing override of this flag (any @N)
    $before = $exp.Count
    $exp = @($exp | Where-Object { $_ -notlike "$FlagName@*" })
    $removed = $before - $exp.Count

    if (-not $Revert) {
        $exp += $FlagDisabled
        Write-Ok "  set: $FlagDisabled (was: $(if($removed){'overriding previous value'}else{'no prior override'}))"
    } else {
        if ($removed) {
            Write-Ok "  reverted: removed prior override of $FlagName"
        } else {
            Write-Skip "  nothing to revert (flag wasn't overridden)"
            $skipped++; continue
        }
    }

    $json.browser.enabled_labs_experiments = $exp

    # Chrome writes Local State as compact JSON (no pretty-printing).
    # We do the same so our edit is indistinguishable from Chrome's own writes.
    $serialized = $json | ConvertTo-Json -Depth 100 -Compress

    # ConvertTo-Json escapes some characters Chrome doesn't escape (and vice versa).
    # For the field we care about that's fine. We write UTF-8 *without* BOM,
    # which is what Chrome expects.
    [System.IO.File]::WriteAllText($b.Path, $serialized, (New-Object System.Text.UTF8Encoding $false))
    $patched++
}

Write-Host ""
if ($found -eq 0) {
    Write-Warn2 "No Chromium-based browsers found in the usual locations."
    Write-Host  "If your browser is portable or installed elsewhere, edit the Local State"
    Write-Host  "file manually and add `"$FlagDisabled`" to browser.enabled_labs_experiments."
    exit 1
}

Write-Ok "Done. found=$found patched=$patched skipped=$skipped"
if ($skipped -gt 0 -and -not $CloseRunning -and -not $Revert) {
    Write-Warn2 "Re-run with -CloseRunning to also handle browsers that are currently open."
}
if (-not $Revert) {
    Write-Host ""
    Write-Host "The 'Chrome is preventing desktop capture' popup should no longer appear"
    Write-Host "for the patched browsers next time you open them."
}
