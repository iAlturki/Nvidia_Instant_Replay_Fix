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

## Is it safe?

Open-source. Runs as you (no admin), no telemetry; the only network call is fetching the engine from this repo's releases. Antivirus may flag it heuristically — it patches NVIDIA's process in memory, the same API pattern malware uses — so the full source is here to read, and the download is checksummed.

## Credits & license

Based on the approach pioneered by **[furyzenblade/ShadowPlay_Patcher](https://github.com/furyzenblade/ShadowPlay_Patcher)**.

MIT © 2026 **[iALTURKi](https://github.com/iALTURKi)** — see [LICENSE](LICENSE). Independent, unofficial tool; not affiliated with NVIDIA Corporation.
