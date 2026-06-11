# Related Work / Prior Art

Notes for maintainers of this project (the C patcher: locate the SPUser
`nvcontainer.exe`, apply ~17 in-memory byte hooks to `_nvspcaps64.dll` and
`NvFBC64.dll` via `OpenProcess`+`VirtualProtectEx`+`WriteProcessMemory`, plus an
event-driven registry watchdog using `RegNotifyChangeKeyValue` on
`HKCU\...\ShadowPlay\NVSPCAPS` that scrubs the protected-content flag and
re-enables the IR flags; runtime-only because on-disk patching breaks NVIDIA's
Authenticode load-time signature check and kills the overlay).

Scope of this document is strictly **keeping Instant Replay (IR) running** when
NVIDIA tries to disable/pause/refuse-save it. It deliberately **excludes**
anything about decrypting or un-blanking protected content — that is OS/DWM/kernel
enforced and out of scope for this project (see `OVERLAY_ARCHITECTURE.md` §6, §8).

All claims below come only from what each study actually reported. Gaps are
marked **(unknown / not tested)** rather than guessed.

---

## 1. Comparison table

| Repo | Stars | Language | Mechanism | Works on modern NVIDIA App? | Relevant |
|------|------:|----------|-----------|-----------------------------|----------|
| **furyzenblade/ShadowPlay_Patcher** (direct upstream) | 80 | C++ | Memory patch / API function-hooking (`GetWindowDisplayAffinity`, `Module32FirstW` → return-0 stub) | Yes | Yes |
| **Verpous/AlwaysShadow** | 1200 | C (mingw64) | Settings-toggle via Shadowplay local HTTP API + polling daemon + WMI process monitor | Unknown (not tested) | Yes |
| **piotrpdev/keep-instant-replay-on** | 28 | Rust (2024 ed.) | HTTP polling monitor; GET status + POST `{status:true}` to local IR API | Yes | Yes |
| **leosmsilvx/NVIDIA-InstantReplay-AutoStart** | 2 | PowerShell | Hotkey injection (`SendKeys`) + console.log string monitor | Partial (uncertain) | Yes |
| **codelao/nvidia-replays-auto-enable** | 2 | Python + Inno Setup | GUI automation: open overlay (Alt+Z), OpenCV image match, pixel-color toggle detect, click | Yes | Yes |
| **Abosmra/Instant-Replay-Patcher** | 0 | C++ | DLL-injection memory patch (`nvd3dumx.dll` + API hooks) + 1 s poll watcher | Yes | Yes |
| **NickEtlon/AutoRunShadowPlay_Patcher** (wrapper over furyzenblade) | 80 | Batch + C++ | Autorun wrapper; core is furyzenblade's memory patch | Unknown (not documented) | Yes |
| **Coldblackice/nvidia_instant_replay_patcher** | 0 | C++ | Memory patch of 20 KERNEL32/USER32 exports + `nvd3dumx.dll` signature patch; 100 ms poll | Unknown (not documented) | Yes |

---

## 2. Per-repo notes

**furyzenblade/ShadowPlay_Patcher.** The direct upstream of this project.
Targets the `nvcontainer.exe` whose command line contains `SPUser`, then hooks
two Windows API functions — `USER32!GetWindowDisplayAffinity` and
`KERNEL32!Module32FirstW` — by overwriting their prologues with a 5-byte
`JMP rel32` into a nearby allocated `xor rax,rax; ret` stub
(`allocateMemoryNearAddress`, `VirtualProtectEx` to `PAGE_EXECUTE_READWRITE`).
Those two APIs are how NVIDIA performs (1) invisible-window detection via window
display affinity and (2) protected-content detection by enumerating modules
(`widevinecdm.dll`) in browsers. Making both return immediately defeats the
*scans*. Runtime-only, re-apply after reboot; also packaged as a Windhawk mod
(`shadowplay-do-not-disable`) for auto start/stop without restart. Touches
`USER32.dll`, `KERNEL32.DLL`, observes `nvd3dumx.dll`. Does **not** touch
`_nvspcaps64.dll`/`NvFBC64.dll` and has **no** registry watchdog.

**Verpous/AlwaysShadow.** The philosophical opposite: zero memory patching, zero
injection. A polling daemon (10 s, backing off to 800+ s during conflicts) reads
`HKCU\...\ShadowPlay\NVSPCAPS\{1B1D3DAA-601D-49E5-8508-81736CA28C6D}` to detect
whether IR was disabled. When off (and no whitelisted app is running) it
discovers Shadowplay's **local HTTP REST API** — port + auth secret read from a
named file mapping `{8BA1E16C-FC54-4595-9782-E370A5FBE8DA}` — and sends a
`POST .../ShadowPlay/v.1.0/InstantReplay/Enable` with `{status:true}`. Falls back
to keyboard-shortcut simulation if HTTP fails. Uses WMI `Win32_Process` queries
for a whitelist so it *respects* content-protection apps (Netflix etc.). All
registry access is **read-only**; it never writes protected keys. GPL, latest
commit 2024. NVIDIA App compatibility **(unknown / not tested)**, though the
local API is Shadowplay's own and likely durable.

**piotrpdev/keep-instant-replay-on.** A lean Rust re-implementation of the
AlwaysShadow HTTP idea. Reads the same named file mapping
`{8BA1E16C-...}` (`OpenFileMappingA`/`MapViewOfFile`/`VirtualQuery`) to get the
local server port and `X_LOCAL_SECURITY_COOKIE`, then every ~5 s does a GET to
`/ShadowPlay/v.1.0/InstantReplay/Enable` to check status and a POST
`{status:true}` to re-enable when disabled. No registry access, no injection, no
hooks. Cites `NvShadowPlayAPI.cs` (BetterExperience), AlwaysShadow's `fixer.c`,
and FiveM's `DisableNVSP.cpp`. Confirmed working on modern NVIDIA infrastructure.

**leosmsilvx/NVIDIA-InstantReplay-AutoStart.** Pure user-mode PowerShell. A
logon Scheduled Task runs `nvidia.ps1`, which uses `wscript.shell` `SendKeys` to
press the configured IR toggle hotkey (Alt+Shift+F10) and, if the NVIDIA Overlay
`console.log` (`$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA Overlay\console.log`)
contains the string `ShadowPlayService IR Disabled`, re-sends the hotkey after
1 s. Logs actions to `log.txt`. No memory/registry/DLL access at all. Modern
NVIDIA App compatibility **partial / uncertain** — hotkey binding, log path, and
the log message format may have changed; fails silently if no hotkey is
configured.

**codelao/nvidia-replays-auto-enable.** GUI automation. An Inno Setup installer
registers a startup task that runs a Python script using PyAutoGUI + OpenCV: open
the overlay with Alt+Z, locate the Replays toggle by image match
(`overlay marker.png`, plus a "shrinked overlay" variant), read the toggle's
pixel color (RGB 118,185,0 = enabled), and click it if disabled. Requires exactly
1920×1080. No memory/registry/DLL access. Confirmed on the post-2024 NVIDIA App
overlay.

**Abosmra/Instant-Replay-Patcher.** A memory-patch sibling that injects a
temporary `ir_hook.dll` (`VirtualAllocEx`+`CreateRemoteThread`+`WriteProcessMemory`)
into the running SPUser `nvcontainer.exe`. Hooks `GetWindowDisplayAffinity`
(→ `WDA_NONE`), `Module32FirstW` (→ FALSE), and `LoadLibraryExW` (to auto-patch on
load), plus two 8–10-byte in-memory patches in **`nvd3dumx.dll`** to bypass a
Widevine L1 capability check. A watcher thread polls every 1 s (up to 5 min) for
`nvd3dumx.dll` to appear, then patches. Persistence via `schtasks` **and** an HKCU
`...\Run` value. No registry watchdog. Critical limitation it documents: IR must
already be recording before the patch lands (injects into a live process, not
on-disk), so it does nothing if IR is off.

**NickEtlon/AutoRunShadowPlay_Patcher.** A batch wrapper that auto-runs
furyzenblade's exe at startup. Adds no new technique; same core patches
(`GetWindowDisplayAffinity`, `Module32FirstW`). NVIDIA App compatibility not
documented.

**Coldblackice/nvidia_instant_replay_patcher.** An expanded furyzenblade-style
patcher. A background thread polls for `nvcontainer.exe` every **100 ms** and
re-applies prologue patches to **20 KERNEL32/USER32 exports** (the `Module32*`,
`Process32*`, `K32EnumProcessModules`, `GetModuleHandle*`/`GetModuleFileName*`
family, plus `EnumWindows`/`GetWindowInfo`/`GetWindowDisplayAffinity`) returning
RET/FALSE/TRUE, and patches the internal `nvd3dumx.dll` `NvD3DUmx_BrowserDetect`
function (signature `4C 8B DC 55 53 49 8D AB 68 FF`) with a single `0xC3` RET.
Has a GUI and INI config. No registry watchdog (only an HKCU `...\Run` startup
entry). Signature-based scanning of `nvd3dumx.dll` is acknowledged as
driver-version fragile. Modern NVIDIA App compatibility **(unknown / not
documented)**.

---

## 3. The two ancestors in depth

### furyzenblade/ShadowPlay_Patcher — the direct upstream

**Philosophy:** neutralize NVIDIA's *detection scans* at the Windows-API boundary
and stop there. furyzenblade picks the smallest possible cut: two exported
functions (`GetWindowDisplayAffinity`, `Module32FirstW`) that every protection
path must call. Replace their entry points with return-immediately stubs and the
two documented checks (invisible-window detection, browser/Widevine module
enumeration) can never report "protected." It is elegant precisely because it
ignores NVIDIA's internal implementation: it touches only Microsoft-owned, stable
APIs, so it is largely immune to NVIDIA driver updates that move internal bytes.

**Contrast with ours.** We inherit furyzenblade's prologue-hook primitive
(`patch_function` is the same `JMP rel32` → near `xor rax,rax; ret` trick) and its
SPUser targeting idea, but we go deeper. Where furyzenblade stops at the two API
scans, this project also patches the *decision and execution* sites **inside**
`_nvspcaps64.dll` (`IsCaptureAllowed`→TRUE, `ProcessGameEvents` EPC branch
`je`→`jmp`, `TerminateCaptures`/`DisableIR` stubs, `SaveInstantReplay` gate NOPs)
and `NvFBC64.dll` (`CheckGrabInfo`→S_OK, `doGdiDesktopCapture` branch flip), then
adds a registry watchdog. The cost is exactly what furyzenblade avoided: those
internal RVAs are driver-version specific, which is why we gate every internal
patch behind a unique byte signature that refuses to patch (rather than corrupt)
when the bytes move. Trade-off: furyzenblade is more update-robust but cannot stop
the registry-write and internal-teardown disable paths; we cover those paths but
must re-anchor signatures on driver updates.

### Verpous/AlwaysShadow — monitor-and-reenable

**Philosophy:** never touch NVIDIA's code or protected state at all. AlwaysShadow
treats IR as a black box with an official control surface: detect "IR turned off"
by *reading* the registry flag, then turn it back on through Shadowplay's own
**local HTTP API** (the same channel the NVIDIA UI uses), with a hotkey fallback.
It is deliberately polite — WMI whitelist monitoring means it leaves IR off while
a genuinely protected app is foreground, and it self-throttles to 800+ s when it
detects a toggle war with another controller. It writes nothing to protected
registry keys and injects nothing.

**Contrast with ours.** This is the opposite of our model in two ways. (1) *Re-enable
path:* AlwaysShadow asks NVIDIA nicely (HTTP `{status:true}`); we *prevent* the
disable by patching the code that decides to disable, and our watchdog *forces*
the registry flags back rather than going through the API. (2) *Intent:*
AlwaysShadow re-enables IR after NVIDIA legitimately turned it off (e.g. a crash,
or a settings reset) and explicitly steps aside for protected content; our project
specifically defeats the protected-content disable so an unrelated DRM app can't
kill *your* gameplay recording. AlwaysShadow's approach cannot keep IR running
*through* a protected-content event because it respects that event by design;
ours can. Conversely AlwaysShadow is far more robust to NVIDIA updates (no RVAs,
no signatures) and is the cleaner long-term control surface.

---

## 4. Ideas worth borrowing (keep-alive only)

Concrete techniques these projects use that this project does not yet. All are
strictly about keeping the feature **working**; none touch decrypting/un-blanking
protected content.

1. **Shadowplay local HTTP API as a re-enable path** (AlwaysShadow,
   keep-instant-replay-on). Today our watchdog forces registry flags back to 1.
   The local REST endpoint (`POST /ShadowPlay/v.1.0/InstantReplay/Enable` with
   `{status:true}`, port + `X_LOCAL_SECURITY_COOKIE` read from named file mapping
   `{8BA1E16C-FC54-4595-9782-E370A5FBE8DA}`) is NVIDIA's *own* enable path and may
   succeed where a raw registry write is ignored or re-overwritten. Worth adding as
   a **fallback re-enable** when the registry scrub doesn't stick — strictly
   additive, used only to turn our own IR back on.

2. **Keyboard/hotkey fallback** (AlwaysShadow, leosmsilvx). A last-resort
   re-enable that drives NVIDIA's configured IR toggle hotkey via input simulation
   when both the registry write and the HTTP call fail. AlwaysShadow's note about
   Alt+Shift+F10 causing IME/language switching (prefer Ctrl+Shift+F10) is a
   useful caveat to carry.

3. **Log-string disable detection** (leosmsilvx). The NVIDIA Overlay
   `console.log` emits `ShadowPlayService IR Disabled`. A cheap, code-free signal
   that IR was turned off, usable as a cross-check alongside our registry-change
   event (e.g. to distinguish a disable from an unrelated NVSPCAPS write).

4. **Toggle-war conflict detection + self-throttling** (AlwaysShadow). If our
   watchdog and another controller (or NVIDIA itself) fight over the flag, detect
   the oscillation and back off the re-write frequency instead of hammering. A
   robustness trick that prevents a busy-loop and reduces the chance of NVIDIA
   flagging the behavior.

5. **WMI / process-aware gating** (AlwaysShadow). `Win32_Process` queries to know
   *what* triggered a disable. We could log/condition our re-enable on which app is
   foreground — useful diagnostics and an optional "leave it off for app X"
   safety, without changing the default always-on behavior.

6. **`LoadLibraryExW` hook to auto-patch a lazy-loaded DLL on load** (Abosmra).
   `NvFBC64.dll` is lazy-loaded only while IR is recording (per our own CLAUDE.md).
   Abosmra hooks `LoadLibraryExW` so the DLL is patched the instant it loads,
   instead of polling for the module. This is a cleaner alternative to our 30 s
   timeout re-verify for catching late module loads — event-driven rather than
   timed.

7. **Citing the reference API source files** (keep-instant-replay-on). It points
   at `NvShadowPlayAPI.cs` (BetterExperience), `fixer.c` (AlwaysShadow), and
   `DisableNVSP.cpp` (FiveM) as the canonical sources for the HTTP API + named
   file mapping protocol. If we adopt idea (1), these are the spec to copy from.

8. **Signature-anchored internal patches as a documented norm** (Coldblackice
   patches `nvd3dumx.dll` by the signature `4C 8B DC 55 53 49 8D AB 68 FF`). We
   already do signature-gated patching; Coldblackice is corroborating prior art for
   the technique and a reminder that `nvd3dumx.dll`'s `NvD3DUmx_BrowserDetect`
   (single `0xC3` RET) is another known disable site we do not currently target.

---

## 5. Where this project is ahead

Things this project does that none of the surveyed repos do:

1. **Modern NVIDIA App SPUser targeting with a fall-through detector.** We select
   the correct `nvcontainer.exe` via a four-strategy priority chain
   (cmdline `\plugins\SPUser` → `SPUser` → module `nvd3dumx.dll` → module
   `_nvspcaps64.dll`), reading command lines with
   `NtQueryInformationProcess(ProcessCommandLineInformation)` (no PEB walk, no
   elevation). furyzenblade matches only the bare `SPUser` string; the polling/GUI
   tools don't target a process at all. Our `--diagnose` mode enumerating every
   candidate is unique here.

2. **`_nvspcaps64.dll` and `NvFBC64.dll` internal-function hooks.** No surveyed
   project touches these. We patch the actual *decision/teardown/save* sites
   (`IsCaptureAllowed`, `ProcessGameEvents` EPC branch, `TerminateCaptures`,
   `DisableIR`, the `SaveInstantReplay` gates, `CheckGrabInfo`,
   `doGdiDesktopCapture`). The other memory-patch projects stop at Windows-API
   scans (furyzenblade, Coldblackice, NickEtlon) or `nvd3dumx.dll` only (Abosmra,
   Coldblackice). This lets us keep IR running *through* a protected-content
   event rather than only re-enabling after it.

3. **Event-driven registry watchdog (vs. polling).** Our `RegNotifyChangeKeyValue`
   + `WaitForSingleObject(30 s)` design reacts in ~10 ms with 0% steady-state CPU
   and reverses the disable that originates from a registry-write code path we
   don't hook. Every monitoring competitor here polls — AlwaysShadow at 10 s,
   keep-instant-replay-on at 5 s, codelao on overlay open, Coldblackice/Abosmra at
   100 ms/1 s. We are the only event-driven design, and the only one that
   *scrubs the protected-content flag* `{1B1D3DAA-...}` directly.

4. **Both detection-scan neutralization AND the registry reverse path in one
   tool.** furyzenblade does scans only; AlwaysShadow does registry-read +
   API-reenable only. We combine prologue hooks (the furyzenblade primitive),
   deep internal patches, and a registry watchdog — covering the API-scan path,
   the internal-decision path, *and* the out-of-band registry-write path
   simultaneously.

5. **Signature-gated internal patches with a fail-safe.** Each `module+RVA` edit
   is verified against a unique byte window and **refuses to patch on mismatch**
   rather than corrupting a moved function — so a driver update degrades to "hook
   skipped," not a crashed `nvcontainer`. Coldblackice/Abosmra signature-scan but
   do not document this refuse-rather-than-corrupt discipline.

6. **A written integrity model that explains why runtime-only is mandatory.**
   `OVERLAY_ARCHITECTURE.md` documents the Authenticode load-time seal
   (`_nvspcaps64.dll.nirf.bak` = `Valid`, byte-modified = `HashMismatch`),
   establishing that on-disk patching breaks the overlay and runtime patching is
   the only viable mode — and that the protected-pixel freeze is DWM(PPL)/kernel
   enforced and out of scope. No surveyed project ships this analysis; it is why we
   don't waste effort on an on-disk patcher or on un-blanking.

---

### Honest gaps in this survey

- NVIDIA App compatibility is **(unknown / not tested)** for AlwaysShadow,
  NickEtlon, and Coldblackice; **partial/uncertain** for leosmsilvx.
- The studies did not measure whether the Shadowplay HTTP API actually re-enables
  IR through a protected-content disable (AlwaysShadow steps aside for it by
  design), so idea (1)'s effectiveness in *our* always-on scenario is unverified.
- furyzenblade noted a Netflix-desktop playback failure during testing that later
  resolved in app updates; whether its two-API approach still suppresses all
  current disable paths on the latest NVIDIA App was not re-verified by the study.
