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
$script:NirfSub2 = 'event-driven  -  hands-free'

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
        $frames = 30
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
            Start-Sleep -Milliseconds 16
        }
        Start-Sleep -Milliseconds 130
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
    param([string[]]$Lines,[int]$Frames = 52,[double]$ColFreq = 9.0,[double]$Speed = 16.0,[switch]$SettleGreen)
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
        Start-Sleep -Milliseconds 32
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
            if (-not $Fast) { Start-Sleep -Milliseconds 18 }
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
            $frames = 66
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
                Start-Sleep -Milliseconds 20
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
    Write-NirfType ($pad1 + $script:NirfSub1) -Color @(190,255,90) -DelayMs $(if($Fast){0}else{14})
    Write-NirfType ($pad2 + $script:NirfSub2) -Color @(120,140,120) -DelayMs $(if($Fast){0}else{10})
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
        $c = switch ($Status) { 'ok'{@(118,185,0)} 'fail'{@(255,70,70)} 'warn'{@(255,190,0)} default{@(120,160,220)} }
        [Console]::Write((Get-NirfFg $c[0] $c[1] $c[2]) + "  $glyph " + (Get-NirfReset))
        Write-Host $Text
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

# If run directly (not dot-sourced), show a demo.
if ($MyInvocation.InvocationName -ne '.') {
    Enable-NirfVT
    Show-NirfBanner
    Show-NirfDivider gradient
    Show-NirfIcons
    Show-NirfDivider diamond
    Write-NirfStep 'VT / truecolor enabled' ok
    Write-NirfStep 'This is the animation library demo' info
    for ($p=0; $p -le 100; $p += 4) { Show-NirfProgress -Percent $p -Label 'demo'; Start-Sleep -Milliseconds 25 }
    Write-NirfStep 'Done' ok
}
