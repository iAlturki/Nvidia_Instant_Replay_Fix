#Requires -Version 5.1
<#  Reads the byte at _nvspcaps64.dll+0x9832B in every nvcontainer.exe
    that has _nvspcaps64.dll loaded, and tells us whether hook 8 is
    actually in place. 0xEB = patched, 0x74 = unpatched, anything else
    = "something else has happened" (DLL update, wrong RVA, etc.). #>

if (-not ('HookCheck.NT' -as [type])) {
Add-Type -Namespace 'HookCheck' -Name 'NT' -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr OpenProcess(uint access, bool inherit, int pid);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(System.IntPtr h);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool ReadProcessMemory(System.IntPtr h, System.IntPtr addr, byte[] buf, System.UIntPtr size, out System.UIntPtr read);
[DllImport("psapi.dll", SetLastError = true)]
public static extern bool EnumProcessModulesEx(System.IntPtr h, System.IntPtr[] mods, uint cb, out uint needed, uint filter);
[DllImport("psapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetModuleBaseNameW(System.IntPtr h, System.IntPtr mod, System.Text.StringBuilder name, uint cap);
[DllImport("psapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetModuleFileNameExW(System.IntPtr h, System.IntPtr mod, System.Text.StringBuilder name, uint cap);
'@
}

$PROCESS_QUERY_INFORMATION = 0x0400
$PROCESS_VM_READ          = 0x0010
$LIST_MODULES_64BIT       = 0x02

# Targets to verify in _nvspcaps64.dll (RVAs are for version 11.0.8.244):
#  Hook 8: ProcessGameEvents EPC-branch  - byte at 0x98EEB should be 0xEB (was 0x74)
#  Hook 9: TerminateCaptures stub        - first 3 bytes at 0xAB5B0 should be 33 C0 C3 (was 40 53 48)
$CHECKS = @(
    @{ Module = '_nvspcaps64.dll'; Rva = 0x98EEB; Len = 3; Name = 'hook 8 (ProcessGameEvents EPC je->jmp)';
       Match = @{ Patched = @(0xEB);             Unpatched = @(0x74) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0xAB5B0; Len = 3; Name = 'hook 9 (TerminateCaptures stub)';
       Match = @{ Patched = @(0x33, 0xC0, 0xC3); Unpatched = @(0x40, 0x53, 0x48) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0x93840; Len = 3; Name = 'hook 10 (DisableIR stub)';
       Match = @{ Patched = @(0x33, 0xC0, 0xC3); Unpatched = @(0x40, 0x53, 0x48) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0xA90E0; Len = 6; Name = 'hook 11a (SaveIR gate A NOPped)';
       Match = @{ Patched = @(0x90, 0x90, 0x90, 0x90, 0x90, 0x90);
                  Unpatched = @(0x0F, 0x84, 0x35, 0x02, 0x00, 0x00) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0xA90F7; Len = 6; Name = 'hook 11b (SaveIR gate B NOPped)';
       Match = @{ Patched = @(0x90, 0x90, 0x90, 0x90, 0x90, 0x90);
                  Unpatched = @(0x0F, 0x84, 0x40, 0x02, 0x00, 0x00) } },
    @{ Module = 'NvFBC64.dll';     Rva = 0x2AEA0; Len = 3; Name = 'hook 12 (CheckGrabInfo stub)';
       Match = @{ Patched = @(0x33, 0xC0, 0xC3); Unpatched = @(0x48, 0x89, 0x5C) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0xA91F4; Len = 2; Name = 'hook 13a (SaveIR rate-limit NOP)';
       Match = @{ Patched = @(0x90, 0x90);       Unpatched = @(0x74, 0x45) } },
    @{ Module = '_nvspcaps64.dll'; Rva = 0xA9206; Len = 2; Name = 'hook 13b (SaveIR sub-state NOP)';
       Match = @{ Patched = @(0x90, 0x90);       Unpatched = @(0x74, 0x33) } },
    @{ Module = 'NvFBC64.dll';     Rva = 0x42AD3; Len = 2; Name = 'hook 14 (GDI protected je->jmp)';
       Match = @{ Patched = @(0xEB, 0x40);       Unpatched = @(0x74, 0x40) } }
)

foreach ($p in (Get-Process -Name nvcontainer -ErrorAction SilentlyContinue)) {
    $h = [HookCheck.NT]::OpenProcess($PROCESS_QUERY_INFORMATION -bor $PROCESS_VM_READ, $false, $p.Id)
    if ($h -eq [IntPtr]::Zero) {
        Write-Host "PID $($p.Id): OpenProcess failed (LastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))" -ForegroundColor DarkGray
        continue
    }
    try {
        $arr   = New-Object IntPtr[] 1024
        $size  = 1024 * [IntPtr]::Size
        $need  = 0
        $ok    = [HookCheck.NT]::EnumProcessModulesEx($h, $arr, $size, [ref]$need, $LIST_MODULES_64BIT)
        if (-not $ok) {
            Write-Host "PID $($p.Id): EnumProcessModulesEx failed" -ForegroundColor DarkGray
            continue
        }
        $count = [int]($need / [IntPtr]::Size)
        # Build module-name -> base-address map for this process
        $modBase = @{}
        for ($i = 0; $i -lt $count; $i++) {
            $name = New-Object System.Text.StringBuilder 260
            [void][HookCheck.NT]::GetModuleBaseNameW($h, $arr[$i], $name, $name.Capacity)
            $modBase[$name.ToString().ToLowerInvariant()] = [Int64]$arr[$i]
        }
        if (-not $modBase.ContainsKey('_nvspcaps64.dll')) {
            Write-Host "PID $($p.Id): _nvspcaps64.dll not loaded in this nvcontainer" -ForegroundColor DarkGray
            continue
        }
        Write-Host ("PID {0,-6}  modules loaded for hook checks" -f $p.Id) -ForegroundColor Cyan
        foreach ($chk in $CHECKS) {
            $modKey = $chk.Module.ToLowerInvariant()
            if (-not $modBase.ContainsKey($modKey)) {
                Write-Host ("   {0,-50}  module '{1}' NOT loaded in this PID" -f $chk.Name, $chk.Module) -ForegroundColor DarkYellow
                continue
            }
            $base = $modBase[$modKey]
            $tgt  = [IntPtr]($base + $chk.Rva)
            $buf  = New-Object byte[] $chk.Len
            $read = [UIntPtr]::Zero
            $rok  = [HookCheck.NT]::ReadProcessMemory($h, $tgt, $buf, [UIntPtr]::new($chk.Len), [ref]$read)
            if (-not $rok) {
                Write-Host ("   {0,-50}  ReadProcessMemory failed" -f $chk.Name) -ForegroundColor Red
                continue
            }
            $hex = ($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $isPatched   = $true
            $isUnpatched = $true
            for ($j = 0; $j -lt $chk.Match.Patched.Count;   $j++) { if ($buf[$j] -ne $chk.Match.Patched[$j])   { $isPatched   = $false } }
            for ($j = 0; $j -lt $chk.Match.Unpatched.Count; $j++) { if ($buf[$j] -ne $chk.Match.Unpatched[$j]) { $isUnpatched = $false } }
            if     ($isPatched)   { $verdict = 'APPLIED'      ; $color = 'Green'  }
            elseif ($isUnpatched) { $verdict = 'NOT APPLIED'  ; $color = 'Red'    }
            else                  { $verdict = 'UNEXPECTED'   ; $color = 'Yellow' }
            Write-Host ("   {0,-50}  {1}+0x{2:X6}  bytes=[{3,-17}]  -> {4}" -f $chk.Name, $chk.Module, $chk.Rva, $hex, $verdict) -ForegroundColor $color
        }
    } finally {
        [void][HookCheck.NT]::CloseHandle($h)
    }
}
