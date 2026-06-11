# Nvidia_Instant_Replay_Fix — C source

Single-file pure-C implementation. No STL, no C++ runtime, just system DLLs.

## Files

| File                              | Purpose |
|-----------------------------------|---------|
| `nvidia_instant_replay_fix.c`     | Everything — process discovery, remote module/export resolution, allocation, hook placement, registry watchdog. |
| `build.bat`                       | Auto-detecting build script. Produces `Nvidia_Instant_Replay_Fix.exe` next to itself. |

## Build

Just run it from any cmd prompt or by double-clicking — no developer command prompt needed:

```cmd
cd c
build.bat
```

`build.bat` auto-discovers, in this order of preference:

1. `cl.exe` already on PATH
2. `gcc.exe` already on PATH
3. MSYS2 / MinGW-w64 in known locations (`C:\msys64\mingw64\bin`, `\ucrt64\bin`, `\clang64\bin`, `C:\MinGW\bin`, `C:\TDM-GCC-64\bin`, scoop's mingw, chocolatey's mingw)
4. Visual Studio via `vswhere.exe`, in which case it calls `vcvarsall.bat x64` for you

To force a specific toolchain:

```cmd
build.bat gcc
build.bat msvc
```

Output: `c\Nvidia_Instant_Replay_Fix.exe` (x64). MSVC produces ~170 KB with `/MT` static CRT; MinGW produces ~270 KB with `-static`. Neither needs any redistributable installed on the target machine.

If you have neither toolchain, `build.bat` prints two one-liner install commands:

```cmd
winget install -e --id MSYS2.MSYS2
:: then in MSYS2 shell:  pacman -S --needed mingw-w64-x86_64-gcc

winget install -e --id Microsoft.VisualStudio.2022.Community --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --quiet"
```

## Run

```cmd
Nvidia_Instant_Replay_Fix.exe                          : default - patch once and pause for keypress
Nvidia_Instant_Replay_Fix.exe --watchdog               : apply hooks, then listen on the NVIDIA Instant Replay registry key forever
Nvidia_Instant_Replay_Fix.exe --diagnose               : list all nvcontainer.exe candidates, no patching
Nvidia_Instant_Replay_Fix.exe --wait 60                : if not running yet, retry every 2s for 60s
Nvidia_Instant_Replay_Fix.exe --log <path>             : redirect stdout/stderr to file and detach from console
Nvidia_Instant_Replay_Fix.exe --no-wait-for-keypress   : exit immediately when done
```

A successful one-shot run prints:

```
Info: target PID 7432 (matched: cmdline contains '\plugins\SPUser' (new NVIDIA App))

Info: USER32.dll base = 0x...
Info: GetWindowDisplayAffinity = 0x...
Info: payload @ 0x...
Info: hook placed and verified at GetWindowDisplayAffinity

Info: KERNEL32.DLL base = 0x...
Info: Module32FirstW = 0x...
Info: payload @ 0x...
Info: hook placed and verified at Module32FirstW
```

Re-run on the same nvcontainer instance and you get:

```
Info: GetWindowDisplayAffinity already patched (JMP). Skipping.
Info: Module32FirstW already patched (JMP). Skipping.
```

`--diagnose` is the recommended first step if it can't find the target:

```
Found 4 nvcontainer.exe process(es):
  [0] PID 5940
       cmdline: (access denied; likely SYSTEM-owned)
       modules: nvd3dumx.dll=no  _nvspcaps64.dll=no
  [2] PID 7432
       cmdline: "...\nvcontainer.exe" -d "...\plugins\SPUser" ...
       modules: nvd3dumx.dll=no  _nvspcaps64.dll=YES

Selection: PID 7432 (matched: cmdline contains '\plugins\SPUser' (new NVIDIA App))
```

## Detection strategies (priority order)

Falls through until exactly one match:

| # | Strategy                                | When it matches |
|---|-----------------------------------------|-----------------|
| 1 | Command-line contains `\plugins\SPUser` | New NVIDIA App, GFE — most reliable |
| 2 | Command-line contains `SPUser`          | Edge cases / older versions |
| 3 | Module `nvd3dumx.dll` loaded            | Older drivers |
| 4 | Module `_nvspcaps64.dll` loaded         | New NVIDIA App fallback if cmdline read fails |

Cmdline reading uses `NtQueryInformationProcess(ProcessCommandLineInformation)` (Windows 8.1+) and needs only `PROCESS_QUERY_LIMITED_INFORMATION` — no elevation.

## Watchdog mode

`--watchdog` keeps the process alive after applying hooks:

```c
loop forever:
    RegOpenKeyExW(HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS)
    RegNotifyChangeKeyValue(REG_NOTIFY_CHANGE_LAST_SET, event, ASYNC)
    WaitForSingleObject(event, 30_000_ms)
    if signaled:
        for each "enabled" flag:
            if value == 0:
                write value = 1                  // immediate reverse
    else (30 s safety timeout):
        re-verify in-memory hooks                // covers nvcontainer restart
```

`WaitForSingleObject` is a kernel-event wait — no polling, no CPU when idle.

## Persist via the installer

The persistence layer at the repo root picks up this binary automatically:

```powershell
.\Setup.bat                                           :: branded UI installer
.\Install-Persistence.ps1                             :: same logic, plain output
.\Install-Persistence.ps1 -ExePath .\c\Nvidia_Instant_Replay_Fix.exe
```

That registers a Scheduled Task that auto-runs the watchdog at logon and on every NvContainerLocalSystem service state change.
