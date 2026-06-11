#Requires -Version 5.1
<#
.SYNOPSIS
    Nvidia_Instant_Replay_Fix - one-file installer + toolbox.

    Keeps NVIDIA Instant Replay (ShadowPlay) recording even when a "protected"
    app (a DRM browser tab, Apple Music, Netflix, etc.) is open, by installing a
    background startup task. Everything is in this one script.

.PARAMETER Uninstall        Remove the background task + installed files.
.PARAMETER Reapply          Push the hooks onto the running NVIDIA process now.
.PARAMETER Status           Show whether the task + watchdog are running.
.PARAMETER ReinstallNvidia  Open NVIDIA's download page (repair overlay/recording).
.PARAMETER Fast             Skip the slow intro animation.

.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1                 # install + menu
.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1 -Status
.EXAMPLE  .\Nvidia_Instant_Replay_Fix.ps1 -Uninstall

.NOTES
    Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
    Licensed under the MIT License.  Project: https://github.com/iALTURKi/Nvidia_Instant_Replay_Fix
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
$NIRF_GH  = 'https://github.com/iALTURKi/Nvidia_Instant_Replay_Fix'
$EYE_B64  = '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'
$ICON_B64 = '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'

# =====================================================================================
# UI library (bundled from Nirf-Ui.ps1)
# =====================================================================================
# Nvidia_Instant_Replay_Fix
# Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
# Licensed under the MIT License. See the LICENSE file in the project root.
#
# Nirf-Ui.ps1  -  eye-catchy terminal UI / animation library for Nvidia_Instant_Replay_Fix
# Dot-source it:   . .\Nirf-Ui.ps1   then call Show-NirfBanner, Write-NirfType, etc.
# Pure PowerShell, no dependencies. Uses 24-bit ANSI color (VT) with a graceful fallback.

# ----------------------------------------------------------------------------------
# Enable Virtual Terminal (ANSI truecolor) + UTF-8 output so the block-art banner and
# gradients render correctly in both Windows Terminal and the legacy console host.
# ----------------------------------------------------------------------------------
$script:NirfVT = $false
$script:NirfConsole = $false
$script:NirfDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
function Enable-NirfVT {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    # Is there a real console buffer? (cursor repositioning fails on redirected output)
    try { $null = [Console]::CursorTop; $script:NirfConsole = $true } catch { $script:NirfConsole = $false }
    if (-not ('NirfCon.VT' -as [type])) {
        Add-Type -Namespace 'NirfCon' -Name 'VT' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@
    }
    try {
        $h = [NirfCon.VT]::GetStdHandle(-11)          # STD_OUTPUT_HANDLE
        $mode = 0
        if ([NirfCon.VT]::GetConsoleMode($h, [ref]$mode)) {
            [void][NirfCon.VT]::SetConsoleMode($h, $mode -bor 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
            $script:NirfVT = $true
        }
    } catch { $script:NirfVT = $false }
}

$script:ESC = [char]27

# Truecolor foreground escape (no-op text if VT unavailable -> callers fall back).
function Get-NirfFg { param([int]$R,[int]$G,[int]$B) "$script:ESC[38;2;$R;$G;${B}m" }
function Get-NirfReset { "$script:ESC[0m" }

# Linear interpolate between two RGB colors (t in 0..1) -> @(R,G,B)
function Get-NirfLerp {
    param([int[]]$From,[int[]]$To,[double]$T)
    @(
        [int][math]::Round($From[0] + ($To[0]-$From[0])*$T),
        [int][math]::Round($From[1] + ($To[1]-$From[1])*$T),
        [int][math]::Round($From[2] + ($To[2]-$From[2])*$T)
    )
}

# ----------------------------------------------------------------------------------
# The banner art (iALTURKI). Stored as an array of lines so we can sweep per-column.
# ----------------------------------------------------------------------------------
$script:NirfBannerLines = @(
    '   ██╗  █████╗  ██╗    ████████╗ ██╗   ██╗ ██████╗  ██╗  ██╗ ██╗',
    '   ██║ ██╔══██╗ ██║    ╚══██╔══╝ ██║   ██║ ██╔══██╗ ██║ ██╔╝ ██║',
    '   ██║ ███████║ ██║       ██║    ██║   ██║ ██████╔╝ █████╔╝  ██║',
    '   ██║ ██╔══██║ ██║       ██║    ██║   ██║ ██╔══██╗ ██╔═██╗  ██║',
    '   ██║ ██║  ██║ ███████╗  ██║    ╚██████╔╝ ██║  ██║ ██║  ██╗ ██║',
    '   ╚═╝ ╚═╝  ╚═╝ ╚══════╝  ╚═╝     ╚═════╝  ╚═╝  ╚═╝ ╚═╝  ╚═╝ ╚═╝'
)
$script:NirfSub1 = 'Nvidia_instant_replay_Fix'
$script:NirfSub2 = 'Instant Replay keep-alive'

# NVIDIA-green gradient endpoints (dark -> green -> bright -> white peak).
$script:NirfDark  = @(11,46,8)      # near-black green
$script:NirfGreen = @(118,185,0)    # NVIDIA green
$script:NirfBright= @(190,255,90)   # bright lime highlight
$script:NirfWhite = @(228,255,200)  # near-white peak (the shimmer crest)

# Sample a 4-stop gradient (dark->green->bright->white) at t in [0,1] -> @(R,G,B).
function Get-NirfGrad {
    param([double]$T)
    if ($T -lt 0) { $T = 0 } elseif ($T -gt 1) { $T = 1 }
    $stops = @($script:NirfDark, $script:NirfGreen, $script:NirfBright, $script:NirfWhite)
    $segs  = $stops.Count - 1
    $pos   = $T * $segs
    $i     = [int][math]::Floor($pos); if ($i -ge $segs) { $i = $segs - 1 }
    Get-NirfLerp $stops[$i] $stops[$i+1] ($pos - $i)
}

# ----------------------------------------------------------------------------------
# Show-NirfBloom : flood the WHOLE terminal with the gradient, radiating outward from
# the centered banner (the color "grows around the name and fills the screen"). The
# banner letters stay lit (white crest) at the origin as the bloom expands past them.
# Clears to black at the end so the caller can draw the settled banner + steps.
# ----------------------------------------------------------------------------------
function Show-NirfBloom {
    if (-not $script:NirfVT) { Enable-NirfVT }
    if (-not ($script:NirfVT -and $script:NirfConsole)) { return }
    $reset = Get-NirfReset
    $W = [Console]::WindowWidth
    $H = [Console]::WindowHeight - 1
    if ($W -lt 12 -or $H -lt 8) { return }

    $lines  = $script:NirfBannerLines
    $bCount = $lines.Count
    $bw     = ($lines | Measure-Object -Maximum -Property Length).Maximum
    $bx     = [math]::Max(0, [int](($W - $bw) / 2))
    $bTop   = [math]::Max(0, [int](($H - $bCount) / 2))
    $cx = $W / 2.0; $cy = $H / 2.0
    $maxR = [math]::Sqrt(($cx * $cx) + (($cy * 2.0) * ($cy * 2.0)))   # corner dist, aspect-corrected
    $whiteFg = Get-NirfFg 235 255 215

    try { [Console]::CursorVisible = $false } catch {}
    try {
        $frames = 16
        for ($fr = 0; $fr -le $frames; $fr++) {
            $R = $maxR * [math]::Pow($fr / [double]$frames, 0.80)    # ease-out expansion
            [Console]::SetCursorPosition(0, 0)
            $sb = New-Object System.Text.StringBuilder
            for ($y = 0; $y -lt $H; $y++) {
                $isB = ($y -ge $bTop -and $y -lt ($bTop + $bCount))
                $bl  = if ($isB) { $lines[$y - $bTop] } else { $null }
                $lastBg = ''
                for ($x = 0; $x -lt ($W - 1); $x++) {        # -1: never write last col (avoids wrap/scroll)
                    $dx = $x - $cx
                    $dy = ($y - $cy) * 2.0                    # cells are ~2x tall -> circular bloom
                    $d  = [math]::Sqrt($dx * $dx + $dy * $dy)
                    if ($d -le $R) {
                        $t   = 1.0 - [math]::Min(1.0, ($R - $d) / 10.0)   # bright at the wavefront
                        $rgb = Get-NirfGrad $t
                        $bg  = "$script:ESC[48;2;$($rgb[0]);$($rgb[1]);$($rgb[2])m"
                    } else {
                        $bg = "$script:ESC[48;2;0;0;0m"
                    }
                    if ($bg -ne $lastBg) { [void]$sb.Append($bg); $lastBg = $bg }
                    if ($isB -and $x -ge $bx -and ($x - $bx) -lt $bl.Length) {
                        $bch = $bl[$x - $bx]
                        if ($bch -ne ' ') { [void]$sb.Append($whiteFg).Append($bch).Append("$script:ESC[39m"); continue }
                    }
                    [void]$sb.Append(' ')
                }
                [void]$sb.Append($reset)
                if ($y -lt ($H - 1)) { [void]$sb.Append([Environment]::NewLine) }
            }
            [Console]::Write($sb.ToString())
            Start-Sleep -Milliseconds 9
        }
        Start-Sleep -Milliseconds 45
    } finally {
        [Console]::Write($reset)
        Clear-Host
        try { [Console]::CursorVisible = $true } catch {}
    }
}

# ----------------------------------------------------------------------------------
# HSV -> RGB (H 0..360, S/V 0..1) -> @(R,G,B). Used for the rainbow animation.
# ----------------------------------------------------------------------------------
function Get-NirfHsvRgb {
    param([double]$H,[double]$S,[double]$V)
    $H = $H % 360; if ($H -lt 0) { $H += 360 }
    $c = $V * $S
    $x = $c * (1 - [math]::Abs((($H / 60.0) % 2) - 1))
    $m = $V - $c
    switch ([int][math]::Floor($H / 60)) {
        0 { $r=$c; $g=$x; $b=0 }
        1 { $r=$x; $g=$c; $b=0 }
        2 { $r=0;  $g=$c; $b=$x }
        3 { $r=0;  $g=$x; $b=$c }
        4 { $r=$x; $g=0;  $b=$c }
        default { $r=$c; $g=0; $b=$x }
    }
    @([int][math]::Round(($r+$m)*255), [int][math]::Round(($g+$m)*255), [int][math]::Round(($b+$m)*255))
}

# ----------------------------------------------------------------------------------
# Show-NirfRainbow : a "rainbow bomb" - flow a full-spectrum rainbow across the given
# block of lines (e.g. the INSTALL COMPLETE box), then settle to NVIDIA green.
# ----------------------------------------------------------------------------------
function Show-NirfRainbow {
    param([string[]]$Lines,[int]$Frames = 26,[double]$ColFreq = 9.0,[double]$Speed = 16.0,[switch]$SettleGreen)
    if (-not $script:NirfVT) { Enable-NirfVT }
    $reset = Get-NirfReset
    if (-not ($script:NirfVT -and $script:NirfConsole)) {
        # Fallback: cycle a few console colors line-by-line so it's at least lively.
        $cyc = @('Red','Yellow','Green','Cyan','Magenta')
        for ($i=0; $i -lt $Lines.Count; $i++) { Write-Host $Lines[$i] -ForegroundColor $cyc[$i % $cyc.Count] }
        return
    }
    $count = $Lines.Count
    foreach ($l in $Lines) { Write-Host $l }                 # reserve the rows
    $top = [math]::Max(0, [Console]::CursorTop - $count)
    for ($f = 0; $f -lt $Frames; $f++) {
        $phase = $f * $Speed
        # brightness "bomb": punch up to full then ease to steady
        $v = 0.7 + 0.3 * [math]::Sin([math]::Min(1.0, $f / 10.0) * [math]::PI / 2)
        [Console]::SetCursorPosition(0, $top)
        $sb = New-Object System.Text.StringBuilder
        for ($li = 0; $li -lt $count; $li++) {
            $line = $Lines[$li]
            for ($c = 0; $c -lt $line.Length; $c++) {
                $ch = $line[$c]
                if ($ch -eq ' ') { [void]$sb.Append(' '); continue }
                $hue = (($c * $ColFreq) + ($li * 18) + $phase) % 360
                $rgb = Get-NirfHsvRgb $hue 1.0 $v
                [void]$sb.Append((Get-NirfFg $rgb[0] $rgb[1] $rgb[2])).Append($ch)
            }
            [void]$sb.Append($reset).Append([Environment]::NewLine)
        }
        [Console]::Write($sb.ToString())
        Start-Sleep -Milliseconds 17
    }
    if ($SettleGreen) {
        [Console]::SetCursorPosition(0, $top)
        foreach ($line in $Lines) {
            [Console]::Write((Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]) + $line + $reset + [Environment]::NewLine)
        }
    }
}

# ----------------------------------------------------------------------------------
# Show-NirfBanner : bloom the color out to fill the terminal, then settle the banner
# with a flowing shimmer, then type the subtitle. Pass -Fast to skip all animation.
# ----------------------------------------------------------------------------------
function Show-NirfBanner {
    param([switch]$Fast)
    if (-not $script:NirfVT) { Enable-NirfVT }
    $reset = Get-NirfReset

    # Intro: bloom the color outward from the name to flood the whole terminal.
    $didBloom = $false
    if (-not $Fast -and $script:NirfVT -and $script:NirfConsole) { Show-NirfBloom; $didBloom = $true }

    Write-Host ""
    Show-NirfNvMark        # the NVIDIA swirl mark crowns the banner
    Write-Host ""

    $maxLen = ($script:NirfBannerLines | Measure-Object -Maximum -Property Length).Maximum

    if ($script:NirfVT -and $script:NirfConsole) {
        # 1) Scan reveal (skipped when the bloom already revealed the banner).
        $step = if ($Fast) { 6 } else { 2 }
        if (-not $didBloom) {
        for ($front = 0; $front -le $maxLen; $front += $step) {
            [Console]::SetCursorPosition(0, [Console]::CursorTop) | Out-Null
            # Re-draw all banner lines up to the wavefront.
            $out = New-Object System.Text.StringBuilder
            foreach ($line in $script:NirfBannerLines) {
                for ($c = 0; $c -lt $line.Length; $c++) {
                    $ch = $line[$c]
                    if ($c -le $front) {
                        $dist = $front - $c
                        if ($dist -lt 3) { $rgb = $script:NirfBright }       # leading edge glow
                        else             { $rgb = $script:NirfGreen }        # settled green
                        [void]$out.Append((Get-NirfFg $rgb[0] $rgb[1] $rgb[2])).Append($ch)
                    } else {
                        [void]$out.Append(' ')
                    }
                }
                [void]$out.Append($reset).Append([Environment]::NewLine)
            }
            # Move cursor back up so each frame overwrites the previous.
            [Console]::Write($out.ToString())
            if ($front -le $maxLen) {
                [Console]::SetCursorPosition(0, [math]::Max(0, [Console]::CursorTop - $script:NirfBannerLines.Count))
            }
            if (-not $Fast) { Start-Sleep -Milliseconds 10 }
        }
        }
        # Settle: redraw fully green (cursor is at top of banner block).
        foreach ($line in $script:NirfBannerLines) {
            [Console]::Write((Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]))
            [Console]::Write($line); [Console]::Write($reset); [Console]::Write([Environment]::NewLine)
        }

        # 2) SHIMMER: a bright crest flows diagonally across the letters, like the
        #    "ultracode" effort band. Each column's color is sampled from the 4-stop
        #    gradient at a phase that advances every frame, so the highlight sweeps.
        if (-not $Fast) {
            $count = $script:NirfBannerLines.Count
            $top   = [math]::Max(0, [Console]::CursorTop - $count)
            $k     = 0.40      # spatial frequency (radians/column) - tighter = more bands
            $skew  = 0.85      # per-line phase offset -> diagonal flow
            $speed = 0.42      # phase advance per frame -> flow speed
            $frames = 28
            for ($frame = 0; $frame -lt $frames; $frame++) {
                $phase = $frame * $speed
                # ease the crest sharpness up then back down so it "breathes" in and out
                $env = [math]::Sin([math]::Min(1.0, $frame / [double]$frames) * [math]::PI)  # 0..1..0
                $sharp = 1.2 + 2.3 * $env
                [Console]::SetCursorPosition(0, $top)
                $out = New-Object System.Text.StringBuilder
                for ($li = 0; $li -lt $count; $li++) {
                    $line = $script:NirfBannerLines[$li]
                    for ($c = 0; $c -lt $line.Length; $c++) {
                        $ch = $line[$c]
                        if ($ch -eq ' ') { [void]$out.Append(' '); continue }
                        $w = 0.5 + 0.5 * [math]::Sin($c * $k + $li * $skew - $phase)
                        $t = [math]::Pow($w, $sharp)        # sharpen -> punchy crest
                        $rgb = Get-NirfGrad $t
                        [void]$out.Append((Get-NirfFg $rgb[0] $rgb[1] $rgb[2])).Append($ch)
                    }
                    [void]$out.Append($reset).Append([Environment]::NewLine)
                }
                [Console]::Write($out.ToString())
                Start-Sleep -Milliseconds 12
            }
            # settle back to steady NVIDIA green
            [Console]::SetCursorPosition(0, $top)
            foreach ($line in $script:NirfBannerLines) {
                [Console]::Write((Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]))
                [Console]::Write($line); [Console]::Write($reset); [Console]::Write([Environment]::NewLine)
            }
        }
    } elseif ($script:NirfVT) {
        # Truecolor but no console buffer (redirected): static green, no cursor moves.
        foreach ($line in $script:NirfBannerLines) {
            [Console]::Write((Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]) + $line + (Get-NirfReset) + [Environment]::NewLine)
        }
    } else {
        # Fallback: 16-color, line-by-line reveal.
        foreach ($line in $script:NirfBannerLines) {
            Write-Host $line -ForegroundColor Green
            if (-not $Fast) { Start-Sleep -Milliseconds 40 }
        }
    }

    # 3) Subtitle, centered-ish, typed.
    Write-Host ""
    $pad1 = ' ' * [math]::Max(0, [int](($maxLen - $script:NirfSub1.Length)/2))
    $pad2 = ' ' * [math]::Max(0, [int](($maxLen - $script:NirfSub2.Length)/2))
    Write-NirfType ($pad1 + $script:NirfSub1) -Color @(190,255,90) -DelayMs $(if($Fast){0}else{6})
    Write-NirfType ($pad2 + $script:NirfSub2) -Color @(120,140,120) -DelayMs $(if($Fast){0}else{4})
    Write-Host ""
}

# ----------------------------------------------------------------------------------
# Write-NirfType : typewriter effect for a single line.
# ----------------------------------------------------------------------------------
function Write-NirfType {
    param([string]$Text,[int[]]$Color = @(118,185,0),[int]$DelayMs = 14)
    if ($script:NirfVT) {
        $fg = Get-NirfFg $Color[0] $Color[1] $Color[2]; $reset = Get-NirfReset
        foreach ($ch in $Text.ToCharArray()) {
            [Console]::Write($fg + $ch + $reset)
            if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
        }
        [Console]::Write([Environment]::NewLine)
    } else {
        if ($DelayMs -gt 0) {
            foreach ($ch in $Text.ToCharArray()) { Write-Host -NoNewline $ch -ForegroundColor Green; Start-Sleep -Milliseconds $DelayMs }
            Write-Host ""
        } else { Write-Host $Text -ForegroundColor Green }
    }
}

# ----------------------------------------------------------------------------------
# Spinner : run a scriptblock while a braille spinner animates; returns the result.
#   $r = Invoke-NirfSpinner -Text "Building..." -Action { .\build.bat }
# ----------------------------------------------------------------------------------
function Invoke-NirfSpinner {
    param([string]$Text,[scriptblock]$Action)
    $frames = '⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    $g = if ($script:NirfVT) { Get-NirfFg 118 185 0 } else { '' }
    $reset = if ($script:NirfVT) { Get-NirfReset } else { '' }
    while ($job.State -eq 'Running') {
        $f = $frames[$i % $frames.Count]
        [Console]::Write("`r$g$f$reset $Text   ")
        Start-Sleep -Milliseconds 80
        $i++
    }
    $result = Receive-Job $job; Remove-Job $job
    $ok = $job.State -ne 'Failed'
    $mark = if ($ok) { if($script:NirfVT){"$(Get-NirfFg 118 185 0)✓$reset"}else{'OK'} } else { if($script:NirfVT){"$script:ESC[38;2;255;70;70m✗$reset"}else{'X'} }
    [Console]::Write("`r$mark $Text            ")
    Write-Host ""
    return $result
}

# ----------------------------------------------------------------------------------
# Show-NirfProgress : an animated gradient block bar. Call repeatedly with -Percent.
# ----------------------------------------------------------------------------------
function Show-NirfProgress {
    param([int]$Percent,[string]$Label = '',[int]$Width = 40)
    $Percent = [math]::Max(0,[math]::Min(100,$Percent))
    $filled = [int]($Width * $Percent / 100)
    $bar = New-Object System.Text.StringBuilder
    if ($script:NirfVT) {
        for ($i=0; $i -lt $Width; $i++) {
            if ($i -lt $filled) {
                $t = if ($Width -gt 1) { $i / ($Width-1) } else { 0 }
                $rgb = Get-NirfLerp $script:NirfGreen $script:NirfBright $t
                [void]$bar.Append((Get-NirfFg $rgb[0] $rgb[1] $rgb[2])).Append([char]0x2588)
            } else {
                [void]$bar.Append("$script:ESC[38;2;40;50;40m").Append([char]0x2591)
            }
        }
        [Console]::Write("`r " + $bar.ToString() + (Get-NirfReset) + (" {0,3}%  {1}   " -f $Percent,$Label))
    } else {
        for ($i=0;$i -lt $Width;$i++){ [void]$bar.Append($(if($i -lt $filled){'#'}else{'-'})) }
        Write-Host -NoNewline ("`r [" + $bar.ToString() + ("] {0,3}%  {1}   " -f $Percent,$Label)) -ForegroundColor Green
    }
    if ($Percent -ge 100) { Write-Host "" }
}

# ----------------------------------------------------------------------------------
# Write-NirfStep : a single status line with a colored glyph.
# ----------------------------------------------------------------------------------
function Write-NirfStep {
    param([string]$Text,[ValidateSet('ok','fail','info','warn')][string]$Status='info')
    $glyph = @{ ok='✓'; fail='✗'; info='»'; warn='!' }[$Status]
    if ($script:NirfVT) {
        $c  = switch ($Status) { 'ok'{@(118,185,0)} 'fail'{@(255,70,70)} 'warn'{@(255,190,0)} default{@(120,160,220)} }
        $tc = switch ($Status) { 'ok'{@(200,235,170)} 'fail'{@(255,165,165)} 'warn'{@(255,220,150)} default{@(198,212,228)} }
        [Console]::Write((Get-NirfFg $c[0] $c[1] $c[2]) + "  $glyph " + (Get-NirfReset))
        [Console]::Write((Get-NirfFg $tc[0] $tc[1] $tc[2]) + $Text + (Get-NirfReset) + [Environment]::NewLine)
    } else {
        $fc = switch ($Status) { 'ok'{'Green'} 'fail'{'Red'} 'warn'{'Yellow'} default{'Cyan'} }
        Write-Host "  $glyph $Text" -ForegroundColor $fc
    }
}

# ----------------------------------------------------------------------------------
# Brand art: NVIDIA swirl mark, the overlay / ShadowPlay-record / GitHub icon row,
# and ornamental dividers. (Designed by the ASCII-artist agents.) Best in Windows
# Terminal — a few glyphs (◆ ● ◀) are ambiguous-width and need a real monospace font.
# ----------------------------------------------------------------------------------
$script:NirfNvMark = @(
    '      ▄▄▄▄▄▄▄▄▄▄        ',
    '    ▟███████████▙       ',
    '   ▟███▛▀▀▀▀▀▜████▙     ',
    '  ▐███▛  ▄▄▄  ▜████▌    ',
    '  ████  ▟███▙  ████▌    ',
    '  ████  ▜██▛   ████▌    ',
    '  ▜███▖  ▀▘   ▟███▛     ',
    '   ▜████▙▄▄▄▟████▛      ',
    '    ▀███████████▛       ',
    '      ▀▀▀▀▀▀▀▀▀▘        '
)
$script:NirfIcOverlay = @(
    '╔══════════════╗',
    '║   ▟██████▙   ║',
    '║  ██  ▄▄  ██  ║',
    '║  ██ ████ ██  ║',
    '║  ██  ▀▀  ██  ║',
    '║   ▜██████▛   ║',
    '╚══════════════╝'
)
$script:NirfIcRecord = @(
    '   ╭──────╮ ◀  ',
    '  ╱  ▄▄▄▄  ╲ ╲ ',
    ' │  ██████  │ │',
    ' │  ██████  │ │',
    '  ╲  ▀▀▀▀  ╱ ╱ ',
    '   ╰──────╯◀╯  ',
    '  rec ● replay '
)
$script:NirfIcGithub = @(
    '  ╭────────╮  ',
    ' ╱  ▟█  █▙  ╲ ',
    '│  ██ ◆◆ ██  │',
    '│  ████████  │',
    '│  ▜█▄██▄█▛  │',
    ' ╲  ▜█  █▛  ╱ ',
    '  ╰──╨──╨───╯ '
)

function Get-NirfCenterPad([int]$pieceWidth) {
    $w = ($script:NirfBannerLines | Measure-Object -Maximum -Property Length).Maximum
    ' ' * [math]::Max(0, [int](($w - $pieceWidth) / 2))
}

# Show-NirfNvMark : the glowing NVIDIA "eye" swirl, centered over the banner width.
function Show-NirfNvMark {
    if (-not $script:NirfVT) { Enable-NirfVT }
    $reset = Get-NirfReset
    # Preferred: high-fidelity half-block render of the REAL NVIDIA eye logo
    # (assets/nvidia_eye.ans, generated from the logo PNG by assets/make_eye.py).
    $ans = Join-Path $script:NirfDir 'assets\nvidia_eye.ans'
    if ($script:NirfVT -and (Test-Path -LiteralPath $ans)) {
        foreach ($l in (Get-Content -LiteralPath $ans -Encoding UTF8)) { [Console]::Write($l); [Console]::Write([Environment]::NewLine) }
        return
    }
    # Fallback: the hand-drawn block mark (no VT, or asset missing).
    $pad = Get-NirfCenterPad ($script:NirfNvMark[1].Length)
    for ($i = 0; $i -lt $script:NirfNvMark.Count; $i++) {
        $line = $script:NirfNvMark[$i]
        if ($script:NirfVT) {
            $rgb = if ($i -ge 3 -and $i -le 6) { $script:NirfBright } else { $script:NirfGreen }  # inner eye glows
            [Console]::Write($pad + (Get-NirfFg $rgb[0] $rgb[1] $rgb[2]) + $line + $reset + [Environment]::NewLine)
        } else { Write-Host ($pad + $line) -ForegroundColor Green }
    }
}

# Show-NirfIcons : NVIDIA eye | ShadowPlay record/replay | GitHub octocat.
function Show-NirfIcons {
    if (-not $script:NirfVT) { Enable-NirfVT }
    $reset = Get-NirfReset
    # Preferred: real half-block icons (assets/nvidia_icons.ans from make_icons.py).
    $ans = Join-Path $script:NirfDir 'assets\nvidia_icons.ans'
    if ($script:NirfVT -and (Test-Path -LiteralPath $ans)) {
        $lines = @(Get-Content -LiteralPath $ans -Encoding UTF8)
        $pat = "$([char]27)\[[0-9;]*m"
        $w = ($lines | ForEach-Object { ($_ -replace $pat, '').Length } | Measure-Object -Maximum).Maximum
        $lead = Get-NirfCenterPad $w       # align with the banner/dividers (content block), not the whole window
        foreach ($l in $lines) { [Console]::Write($lead + $l + [Environment]::NewLine) }
        # caption row: a label under each icon (the GitHub one credits the author).
        $seg = [int]($w / 3)
        $ctr = { param($s, $width) $p = [math]::Max(0, [int](($width - $s.Length) / 2)); (' ' * $p) + $s + (' ' * [math]::Max(0, $width - $p - $s.Length)) }
        $cN = Get-NirfFg 118 185 0; $cR = Get-NirfFg 185 185 185; $cA = Get-NirfFg 220 90 220
        [Console]::Write($lead +
            $cN + (& $ctr 'NVIDIA' $seg) + $reset +
            $cR + (& $ctr 'replay' $seg) + $reset +
            $cA + (& $ctr 'iALTURKi' ($w - 2 * $seg)) + $reset + [Environment]::NewLine)
        return
    }
    # Fallback: the stylized block icons.
    $gut = '    '
    $rowW = 16 + $gut.Length + 15 + $gut.Length + 14
    $lead = Get-NirfCenterPad $rowW
    $green = Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]
    $grey  = Get-NirfFg 235 237 240
    $red   = Get-NirfFg 235 60 60
    for ($i = 0; $i -lt 7; $i++) {
        $o = $script:NirfIcOverlay[$i].PadRight(16)
        $r = $script:NirfIcRecord[$i].PadRight(15)
        $g = $script:NirfIcGithub[$i].PadRight(14)
        if ($script:NirfVT) {
            $rc = if ($i -eq 2 -or $i -eq 3) { $red } else { $green }   # the ██ record dot rows in red
            [Console]::Write($lead + $green + $o + $reset + $gut + $rc + $r + $reset + $gut + $grey + $g + $reset + [Environment]::NewLine)
        } else {
            Write-Host ($lead + $o + $gut + $r + $gut + $g)
        }
    }
}

# Show-NirfDivider : ornamental section rule. -Style gradient | diamond.
function Show-NirfDivider {
    param([ValidateSet('gradient','diamond')][string]$Style = 'gradient')
    if (-not $script:NirfVT) { Enable-NirfVT }
    $reset = Get-NirfReset
    if ($Style -eq 'gradient') {
        $d = '░░▒▒▓▓████████████████████████████████████████████████▓▓▒▒░░'
        $pad = Get-NirfCenterPad $d.Length
        if ($script:NirfVT) { Write-Host ($pad + (Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]) + $d + $reset) }
        else { Write-Host ($pad + $d) -ForegroundColor DarkGreen }
    } else {
        $d = '╠═══════════════════════════ ◆ ════════════════════════════╣'
        $pad = Get-NirfCenterPad $d.Length
        if ($script:NirfVT) {
            $g = Get-NirfFg $script:NirfGreen[0] $script:NirfGreen[1] $script:NirfGreen[2]
            $d2 = $d -replace '◆', ((Get-NirfFg 190 255 90) + '◆' + $g)   # diamond pops lime
            Write-Host ($pad + $g + $d2 + $reset)
        } else { Write-Host ($pad + $d) -ForegroundColor DarkGreen }
    }
}


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
    Write-NirfStep 'It runs itself - a hidden task starts at logon and keeps Instant Replay' ok
    Write-NirfStep 'alive even when a protected app (DRM browser tab, Apple Music) is open.' ok
    Write-NirfStep 'Record / save with your usual NVIDIA hotkey (default Alt+F10).' ok

    Write-Host ''
    Write-Host '   Manage it ' -NoNewline -ForegroundColor Green
    Write-Host '- run any of these anytime (no admin for Status):' -ForegroundColor DarkGray
    Write-Host '     Status  ' -NoNewline -ForegroundColor Cyan
    Write-Host '.\Nvidia_Instant_Replay_Fix.ps1 -Status   ' -NoNewline -ForegroundColor Gray
    Write-Host 'is the watchdog running?' -ForegroundColor DarkGray
    Write-Host '     Remove  ' -NoNewline -ForegroundColor Cyan
    Write-Host '.\Nvidia_Instant_Replay_Fix.ps1 -Uninstall' -NoNewline -ForegroundColor Gray
    Write-Host '  uninstall it completely' -ForegroundColor DarkGray
    Write-Host '     Log     ' -NoNewline -ForegroundColor Cyan
    Write-Host $Paths.RunLog -NoNewline -ForegroundColor Gray
    Write-Host '   live activity log' -ForegroundColor DarkGray
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

    Write-NirfStep 'Registering the startup task (admin)...' info
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