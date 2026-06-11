#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Full restart of the NVIDIA App stack to clear any cached IR state.

.DESCRIPTION
    Stops:
      - Our watchdog patcher
      - NVIDIA app.exe (the main dashboard UI)
      - NVIDIA Overlay.exe (the gaming overlay - where IR settings live)
      - All nvcontainer.exe instances
    Then NVIDIA's container service auto-restarts everything cleanly.
    Wait ~10s, then re-open NVIDIA App or the overlay; toggle IR.
#>
[CmdletBinding()] param()

Write-Host '=== Stopping watchdog patcher ==='
Get-Process -Name 'Nvidia_Instant_Replay_Fix' -EA SilentlyContinue | ForEach-Object {
    Write-Host "  killing watchdog PID $($_.Id)"
    Stop-Process -Id $_.Id -Force
}

Write-Host ''
Write-Host '=== Stopping NVIDIA app UI + Overlay ==='
foreach ($name in 'NVIDIA app','NVIDIA Overlay','NVIDIA Web Helper.exe') {
    Get-Process | Where-Object { $_.Name -like "$name*" -or $_.Name -eq $name } | ForEach-Object {
        Write-Host "  killing $($_.Name) PID $($_.Id)"
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host '=== Stopping all nvcontainer.exe instances ==='
Get-Process -Name 'nvcontainer' -EA SilentlyContinue | ForEach-Object {
    Write-Host "  killing nvcontainer PID $($_.Id)"
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host '=== Waiting 10s for NVIDIA service to bring things back ==='
Start-Sleep -Seconds 10

Write-Host ''
Write-Host '=== Current state ==='
Get-Process | Where-Object { $_.Name -match 'nvcontainer|NVIDIA' } |
    Select-Object Id, Name, StartTime | Format-Table -AutoSize

Write-Host ''
Write-Host 'NEXT STEPS:'
Write-Host '  1. Press Alt+Z (Overlay) OR open NVIDIA App from Start menu.'
Write-Host '  2. Toggle Instant Replay ON.'
Write-Host '  3. Check NvFBC64.dll loads in nvcontainer (IR running) - run check below:'
Write-Host ''
Write-Host '  Get-Process -Name nvcontainer | ForEach-Object {'
Write-Host '      $hasFbc = ($_.Modules | Where-Object { $_.ModuleName -ieq ''NvFBC64.dll'' }) -ne $null'
Write-Host '      "PID $($_.Id)  NvFBC64 loaded = $hasFbc"'
Write-Host '  }'
Write-Host ''
Write-Host '  4. When IR is confirmed running, restart watchdog:'
Write-Host '     schtasks /Run /TN ''Nvidia_Instant_Replay_Fix'''
