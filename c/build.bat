@echo off
setlocal EnableDelayedExpansion
rem ============================================================
rem Nvidia_Instant_Replay_Fix - C build script
rem
rem Auto-discovers a toolchain. You do NOT need to open a special
rem developer command prompt; this script will:
rem   1. Use cl or gcc if they're already on PATH
rem   2. Otherwise look for MSYS2 MinGW-w64 gcc in known locations
rem   3. Otherwise call vswhere to find Visual Studio and load vcvarsall.bat
rem
rem Force a specific toolchain with:
rem   build.bat msvc
rem   build.bat gcc
rem ============================================================

set "SCRIPT_DIR=%~dp0"
set "SRC=%SCRIPT_DIR%nvidia_instant_replay_fix.c"
set "OUT=%SCRIPT_DIR%Nvidia_Instant_Replay_Fix.exe"
set "DLL_SRC=%SCRIPT_DIR%neuter_wda.c"
set "DLL_OUT=%SCRIPT_DIR%neuter_wda.dll"
set "FORCE=%~1"

if not exist "%SRC%" (
    echo [ERR] Source not found: %SRC%
    exit /b 1
)

echo.
echo === Probing for compilers ===

set "CL_ONPATH="
set "GCC_ONPATH="
set "GCC_DIR="
set "VS_DIR="

where cl  >nul 2>nul && set "CL_ONPATH=1"
where gcc >nul 2>nul && set "GCC_ONPATH=1"

rem --- MSYS2 / MinGW probe ---
for %%D in (
    "C:\msys64\mingw64\bin"
    "C:\msys64\ucrt64\bin"
    "C:\msys64\clang64\bin"
    "C:\MinGW\bin"
    "C:\TDM-GCC-64\bin"
    "%USERPROFILE%\scoop\apps\mingw\current\bin"
    "%ChocolateyInstall%\lib\mingw\tools\install\mingw64\bin"
) do (
    if not defined GCC_DIR if exist "%%~D\gcc.exe" set "GCC_DIR=%%~D"
)

rem --- Visual Studio probe ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "%VSWHERE%" (
    for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do (
        set "VS_DIR=%%I"
    )
    if defined VS_DIR (
        if not exist "!VS_DIR!\VC\Auxiliary\Build\vcvarsall.bat" set "VS_DIR="
    )
)

if defined CL_ONPATH  echo Found: cl.exe on PATH
if defined GCC_ONPATH echo Found: gcc.exe on PATH
if defined GCC_DIR    echo Found: gcc.exe at !GCC_DIR!
if defined VS_DIR     echo Found: Visual Studio at !VS_DIR!

rem ============================================================
rem  Choose toolchain
rem ============================================================
set "USE="

if /I "%FORCE%"=="gcc" (
    if defined GCC_ONPATH set "USE=gcc-onpath"
    if not defined USE if defined GCC_DIR set "USE=gcc-probed"
    if not defined USE (echo [ERR] -gcc forced but no gcc available. & exit /b 1)
) else if /I "%FORCE%"=="msvc" (
    if defined CL_ONPATH set "USE=msvc-onpath"
    if not defined USE if defined VS_DIR set "USE=msvc-probed"
    if not defined USE (echo [ERR] -msvc forced but no MSVC available. & exit /b 1)
) else (
    rem Default preference: PATH-cl > PATH-gcc > probed-gcc > probed-VS
    if defined CL_ONPATH  set "USE=msvc-onpath"
    if not defined USE if defined GCC_ONPATH set "USE=gcc-onpath"
    if not defined USE if defined GCC_DIR    set "USE=gcc-probed"
    if not defined USE if defined VS_DIR     set "USE=msvc-probed"
)

if not defined USE goto :no_compiler
echo.
echo Selected: !USE!

if "!USE!"=="gcc-onpath"  goto :build_gcc
if "!USE!"=="gcc-probed"  goto :build_gcc
if "!USE!"=="msvc-onpath" goto :build_msvc
if "!USE!"=="msvc-probed" goto :load_vcvars
goto :no_compiler

:load_vcvars
echo.
echo === Loading Visual Studio x64 environment ===
echo vcvarsall: "!VS_DIR!\VC\Auxiliary\Build\vcvarsall.bat"
call "!VS_DIR!\VC\Auxiliary\Build\vcvarsall.bat" x64 >nul
if errorlevel 1 (
    echo [ERR] vcvarsall.bat failed.
    exit /b 1
)
goto :build_msvc

:build_gcc
echo.
echo === Building with MinGW gcc ^(static, x64^) ===
if defined GCC_DIR set "PATH=!GCC_DIR!;%PATH%"
gcc --version | findstr /i "gcc"
gcc -O2 -Wall -Wextra -static ^
    -DUNICODE -D_UNICODE ^
    "%SRC%" -o "%OUT%" ^
    -lkernel32 -luser32 -ladvapi32
set "RC=!ERRORLEVEL!"
if not "!RC!"=="0" (
    echo [ERR] gcc build failed for exe ^(exit !RC!^)
    exit /b !RC!
)
echo.
echo === Building neuter_wda.dll with MinGW gcc ^(x64^) ===
gcc -O2 -Wall -Wextra -shared -static-libgcc -static-libstdc++ ^
    -DUNICODE -D_UNICODE ^
    "%DLL_SRC%" -o "%DLL_OUT%" ^
    -lkernel32 -luser32
set "RC=!ERRORLEVEL!"
if "!RC!"=="0" goto :done
echo [ERR] gcc DLL build failed ^(exit !RC!^)
exit /b !RC!

:build_msvc
echo.
echo === Building with MSVC ^(static CRT, x64^) ===
pushd "%SCRIPT_DIR%"
cl /nologo /W3 /O2 /MT /DUNICODE /D_UNICODE ^
   "%SRC%" /Fe"%OUT%" /Fo"%SCRIPT_DIR%nvidia_instant_replay_fix.obj" ^
   /link /SUBSYSTEM:CONSOLE user32.lib kernel32.lib advapi32.lib
set "RC=!ERRORLEVEL!"
del /q "%SCRIPT_DIR%nvidia_instant_replay_fix.obj" 2>nul
if not "!RC!"=="0" (
    popd
    echo [ERR] MSVC build failed for exe ^(exit !RC!^)
    exit /b !RC!
)
echo.
echo === Building neuter_wda.dll with MSVC ===
cl /nologo /W3 /O2 /MT /LD /DUNICODE /D_UNICODE ^
   "%DLL_SRC%" /Fe"%DLL_OUT%" /Fo"%SCRIPT_DIR%neuter_wda.obj" ^
   /link user32.lib kernel32.lib
set "RC=!ERRORLEVEL!"
del /q "%SCRIPT_DIR%neuter_wda.obj" "%SCRIPT_DIR%neuter_wda.exp" "%SCRIPT_DIR%neuter_wda.lib" 2>nul
popd
if "!RC!"=="0" goto :done
echo [ERR] MSVC DLL build failed ^(exit !RC!^)
exit /b !RC!

:no_compiler
echo.
echo [ERR] No compiler found.
echo.
echo Tried:
echo   - cl.exe / gcc.exe on PATH
echo   - MSYS2 MinGW-w64 dirs ^(C:\msys64\mingw64\bin etc.^)
echo   - Visual Studio via vswhere ^(needs the "Desktop development with C++" workload^)
echo.
echo One-shot install options:
echo   winget install -e --id MSYS2.MSYS2
echo     then in MSYS2 shell:  pacman -S --needed mingw-w64-x86_64-gcc
echo   winget install -e --id Microsoft.VisualStudio.2022.Community ^
                       --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --quiet"
exit /b 2

:done
echo.
echo === Build OK ===
echo Output exe: %OUT%
for %%I in ("%OUT%") do echo  Size: %%~zI bytes
if exist "%DLL_OUT%" (
    echo Output dll: %DLL_OUT%
    for %%I in ("%DLL_OUT%") do echo  Size: %%~zI bytes
)
echo.
echo Next:
echo   Run it directly:            "%OUT%"
echo   Install for auto-launch:    powershell -ExecutionPolicy Bypass -File "%SCRIPT_DIR%..\Install-Persistence.ps1" -ExePath "%OUT%"
endlocal
exit /b 0
