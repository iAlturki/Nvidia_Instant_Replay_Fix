# Nvidia_Instant_Replay_Fix

**Stops NVIDIA Instant Replay (ShadowPlay) from cutting out when a "protected" app — a DRM browser tab, Apple Music, Netflix — is on screen. Set it once; it runs itself.**

## Demo

![Setup](docs/install.gif)

Apple Music opens and NVIDIA's "protected app" toast fires — but Instant Replay keeps recording (it is **not** disabled):

![Apple Music opens, Instant Replay stays on](docs/applemusic-toast.gif)

![A clip saved while protected content was on screen](docs/after-fix.png)

## Install

Download **`Nvidia_Instant_Replay_Fix.ps1`** from the **[latest release](../../releases/latest)**, then run it:

```powershell
powershell -ExecutionPolicy Bypass -File .\Nvidia_Instant_Replay_Fix.ps1
```

That one file does everything — it downloads the engine, installs a hidden background task, and starts protecting Instant Replay. **No admin needed.** Record/save with your usual NVIDIA hotkey (default **Alt+F10**).

To remove it later, run the same file and choose **Uninstall**.

## Antivirus / "Virus detected"

Your browser, SmartScreen, or antivirus **will probably flag the download** — that's expected, and it's a **false positive**. The tool injects a few bytes into NVIDIA's `nvcontainer.exe` (`OpenProcess` + `WriteProcessMemory`), the same API pattern malware uses, so heuristic scanners raise a generic `HackTool` / `CodeInjector` flag. There is no network exfiltration, no hidden payload, and the only persistence is a scheduled task you can see and remove.

Don't take my word for it — **verify**:

- **VirusTotal:** [scan `Nvidia_Instant_Replay_Fix.exe`](https://www.virustotal.com/gui/file/1738ef7542b5de9ca18da4448a90c046676403f884e42fc86921242b568b19da) · `sha256 1738ef…b19da` — you'll see a few heuristic engines, not a real signature.
- **Read the source** — single-file C, all in this repo.
- **Build it yourself** — `cd c && build.bat`; a binary *you* compiled isn't download-flagged.

If you've verified it and trust it, choose **Keep** in the browser warning, or add a Windows Security exclusion for `%LOCALAPPDATA%\Nvidia_Instant_Replay_Fix\`. *(A code-signed build to remove the warning entirely is on the roadmap.)*

Open-source, runs as you (no admin), no telemetry; the only network call is fetching the engine from this repo's releases.

## Credits & license

Based on the approach pioneered by **[furyzenblade/ShadowPlay_Patcher](https://github.com/furyzenblade/ShadowPlay_Patcher)**.

MIT © 2026 **[iALTURKi](https://github.com/iALTURKi)** — see [LICENSE](LICENSE). Independent, unofficial tool; not affiliated with NVIDIA Corporation.
