# Nvidia_Instant_Replay_Fix

**Keeps NVIDIA Instant Replay (ShadowPlay) recording even when a "protected" app — a DRM browser tab, Apple Music, Netflix — is on screen, instead of letting NVIDIA pause it or refuse to save your clip.**

Set it once. A tiny hidden background task does the rest — hands-free, and it self-heals across NVIDIA driver/app updates.

## Demo

**Install — one double-click, fully animated:**

![Installer animation](docs/install.gif)

**Open Apple Music with Instant Replay on: NVIDIA's "protected app" toast fires — but Instant Replay keeps running (it is NOT disabled):**

![Apple Music opens, the protected-app toast shows, yet Instant Replay stays enabled](docs/applemusic-toast.gif)

**A clip saved while protected content was on screen:**

![Instant Replay recording/saving after the fix](docs/after-fix.png)

## Quick start

1. Grab **`Nvidia_Instant_Replay_Fix.ps1`** + **`Run.bat`** from the [latest release](../../releases/latest).
2. **Double-click `Run.bat`.** That's it — it installs a hidden logon task and starts protecting Instant Replay.

No admin needed. Record/save with your usual NVIDIA hotkey (default **Alt+F10**).

```
Nvidia_Instant_Replay_Fix.ps1             install (animated) + menu
Nvidia_Instant_Replay_Fix.ps1 -Status     check it's running
Nvidia_Instant_Replay_Fix.ps1 -Uninstall  remove it
```

## What it does

- Patches the checks inside NVIDIA's `nvcontainer.exe` that trigger the disable — located at runtime by **stable log-string anchors**, so it keeps working after NVIDIA updates instead of breaking on new versions.
- Runs a **zero-CPU watchdog** that instantly reverses any registry-based disable NVIDIA still slips through.
- Auto-starts at logon and when NVIDIA's service restarts; runs hidden.

> **It does not** un-blank the protected app's own pixels in the recording — Windows/DWM enforces that upstream of capture. The goal is "don't let an unrelated protected app kill *your* recording," and that's solved. Deep dive: [c/RESEARCH.md](c/RESEARCH.md), [c/OVERLAY_ARCHITECTURE.md](c/OVERLAY_ARCHITECTURE.md).

## Safety

Open-source, single-file C. No network, no telemetry, writes only under `%LOCALAPPDATA%\Nvidia_Instant_Replay_Fix\`, runs as you (no elevation). Antivirus may *heuristically* flag it — `OpenProcess`+`WriteProcessMemory` is also the pattern malware uses for injection. The source is short; audit it, and check the SHA256 on [VirusTotal](https://www.virustotal.com/).

## Credits & license

Based on the approach pioneered by **[furyzenblade/ShadowPlay_Patcher](https://github.com/furyzenblade/ShadowPlay_Patcher)**.

MIT © 2026 **[iALTURKi](https://github.com/iALTURKi)** — see [LICENSE](LICENSE). Independent, unofficial tool; not affiliated with NVIDIA Corporation.
