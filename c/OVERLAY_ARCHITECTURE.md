# NVIDIA Overlay + Instant Replay: End-to-End Architecture

This document synthesizes six component studies (process topology, capture/encode
pipeline, control plane, IPC, integrity model, and protected-content enforcement)
into one reference for the whole feature. It is intended to let a future engineer
understand how the NVIDIA App overlay and ShadowPlay Instant Replay (IR) work
end-to-end, and to ground the design decisions of this patcher project.

---

## 1. Top-Level Topology

NVIDIA splits the feature across two LocalSystem container services plus a
user-session CEF UI. Privilege isolation is the organizing principle: capture and
driver access run as SYSTEM, while the dashboard/overlay UI runs in the user
session.

```
services.exe (SYSTEM)
├── nvcontainer.exe (SYSTEM)  [NvContainerLocalSystem service]
│   │   -s NvContainerLocalSystem -d plugins\LocalSystem -p 30000 -ert
│   ├── nvcontainer.exe (SYSTEM)   [Session/Shared container]
│   │       Loads: NvMessageBusBroadcast.dll, NvCpl, NvTelemetry64.dll,
│   │              ShadowPlay\_nvspserviceplugin64.dll, Watchdog\NvPluginWatchdog.dll
│   └── nvcontainer.exe (USER)     [User-privilege container]
│           Loads: NvBackend64.dll, NVIDIA App user components
│           Loads (SPUser context): nvspcaps\_nvspcaps64.dll  <-- capture brain
│
└── NVDisplay.Container.exe (SYSTEM)  [NVDisplay.ContainerLocalSystem service]
    └── NVDisplay.Container.exe (SYSTEM)   [driver-level display plugins]

explorer.exe (USER)
└── NVIDIA App.exe (USER)         [CEF browser process — dashboard UI]
    ├── NVIDIA App.exe (USER)     [GPU process]
    ├── NVIDIA App.exe (USER)     [renderer]
    └── NVIDIA App.exe (USER)     [utility x N]

NVIDIA Overlay.exe (USER)         [separate CEF instance — in-game overlay UI]
```

Plugins are loaded dynamically from privilege-segregated directories via the
container's `-d` flag; every plugin must export `NvPluginGetInfo()` to be
enumerated:

| Directory      | Key module                              | Role |
|----------------|-----------------------------------------|------|
| `LocalSystem\` | `ShadowPlay\_nvspserviceplugin64.dll`   | service-side capture orchestration / IPC |
| `LocalSystem\` | `Watchdog\NvPluginWatchdog.dll`         | plugin health monitor |
| `SPUser\`      | `nvspcaps\_nvspcaps64.dll`              | **user-session capture brain** (sessions, detection, save) |
| `User\`        | `NvBackend\NvBackend64.dll`             | user-facing features |
| `Session\`     | `NvCpl\nvxdsyncplugin.dll`              | cross-domain sync |

The ShadowPlay capture DLL stack (`C:\Program Files\NVIDIA Corporation\NVIDIA app\ShadowPlay\`):

| DLL | Role | Notable export |
|-----|------|----------------|
| `_nvspserviceplugin64.dll` | service-side plugin host | `NvPluginGetInfo()` |
| `_nvspcaps64.dll` | user-session capture plugin | `NvPluginGetInfo()` |
| `nvspapi64.dll` | ShadowPlay API factory | `CreateShadowPlayApiInterface()`, `CreateOverlayApiInterface()` |
| `capcore64.dll` | core capture engine (NVENC) | `NvCreateCaptureCore()` |
| `NvFBC64.dll` | frame-buffer capture (GPU grab) | `NvFBCCore::CheckGrabInfo` |
| `nvmf64.dll` | MP4 muxer (AOSP MPEG4Writer port) | (internal) |
| `nvovapi64.dll` | overlay rendering API | `NvOverlayApi_CreateInterface()` |
| `ipccommon64.dll` | IPC bridge | `CreateIpcClient()`, `CreateIpcProxyInterface()` |

---

## 2. Capture → Encode → Save Pipeline

Instant Replay is a **continuous ring-buffer**: an N-minute rolling buffer of
encoded frames + audio is maintained at all times, and a hotkey retrospectively
commits the last N minutes to disk.

```
GPU framebuffer (DWM-composited)
   │  NvFBC64.dll
   ▼
Capture layer: NvFBCCore::CheckGrabInfo  (validates each grab; S_OK == ok)
   │  fallback: NvFBCCoprocHelper::doGdiDesktopCapture (GDI/BitBlt)
   ▼
Session mgmt: _nvspcaps64.dll
   CCaptureControl::EvaluateAutoDVRStart  -> starts rolling buffer on game launch
   CCaptureCoreDll::StartDVRCapture       -> pre-allocates ring (RecDuration)
   CCaptureSession (per-session ring state); eSPCaptureState_t state machine
   │
   ▼
Encode: capcore64.dll + NvFBC64.dll
   CVideoCapture{Fbc,Dda,Sch}  -> frame source backends
   CH264EncodeVideo / CH265EncodeVideo / CAV1EncodeVideo
   CNVHWEncWrapper -> nvEncOpenEncodeSession, nvEncEncodePicture,
                      nvEncLockBitstream, nvEncReconfigureEncoder
   Audio: AudioCapture (AudioOff/Game/Mic/Both) -> AACEncoder
   │
   ▼  ring buffer: AVCirularBufferToFileCommiter  (sic — misspelled in binary)
   ▼
SAVE (Alt+F10):
   CCaptureSession::SaveInstantReplay (RVA 0xA83E0)
   CCaptureCoreDll::SaveDVRCapture    -> extract [T-N .. T] window from ring
   AVCirularBufferToFileCommiter::CommitTo -> validate I-frame boundary
   │
   ▼  Mux: nvmf64.dll
   CNvMediaMuxSink / CMediaStream
   AddVideoTrackToMux(codec,bitrate,fps,w,h,SPS/PPS) + AddAudioTrackToMux(...)
   WriteSampleToMux -> android::MPEG4Writer (ftyp/moov/mdat atoms)
   muxer->Finalize() -> closes MP4
```

Key gates inside `SaveInstantReplay` (these matter for §5):

- **Gate A** (RVA `0xA84CA`): `cmp byte [rcx+1],0; je skip` — session-state byte.
- **Gate B** (RVA `0xA84D7`): `cmp dword [rdi+0x26e4],0; je skip` — "IR enabled" flag.
- **Gate C** (RVA `0xA85D4`): one-shot rate limit (`cmp edx,1; je skip`).
- **Gate D** (RVA `0xA85E6`): sub-state byte.

Diagnostic strings worth knowing: `CommitTo Failed ! hr=%#X buffer: %s empty, %s IFrame`,
`Failed to Create Audio Media Type`, `Failed to get Encoded Data`.

---

## 3. Control Plane (Registry + Hotkeys + UI Propagation)

State lives in the registry; the UI writes user preferences; the SPUser plugin
writes runtime/derived flags; both feed the capture state machine.

**Registry root:** `HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS`
(all values `REG_BINARY`, 4-byte little-endian DWORD).

| Value | Meaning |
|-------|---------|
| `IsShadowPlayEnabled` | master runtime enable (SPUser may force 0) |
| `IsShadowPlayEnabledUser` | persistent user preference (UI toggle) |
| `DwmEnabled` / `DwmEnabledUser` | desktop-composition capture enable |
| `DwmDvrEnabledV1` | desktop DVR active |
| `RecEnabled` | recording-to-buffer active |
| `HLEnabled` | hardware-accelerated encode |
| `RecDuration` / `DVRBufferLen` | ring-buffer length |
| `{1B1D3DAA-601D-49E5-8508-81736CA28C6D}` | **protected-content flag** (1 = pause/freeze/refuse-save) |

**Hotkeys** are stored as `<modifier><scancode>` LE DWORD arrays. NVIDIA encodes
"Alt+F10" oddly: byte0 modifier (`0x12`=LCTRL, `0x10`=SHIFT, `0x11`=LALT),
byte1 scancode (`0x79`=F12-scan, `0x70`=F1, `0x5A`=Z, `0x4D`=M):

- `DVRHKey[0..1]` — save clip.
- `IRToggleHKey[0..2]` — toggle IR on/off.
- `GFEOverlayHKeyV2[0..1]` — open overlay.
- `ScreenshotHKey[0..1]` — screenshot.

**Toggle propagation (user clicks "Instant Replay"):**
CEF widget → JS handler writes `IsShadowPlayEnabledUser` → IPC to SPUser plugin →
SPUser reads flag → enables/disables capture buffer (`RecEnabled`, `DVRBufferLen`)
→ frame submission to NVENC starts/stops.

**Auto-disable propagation (protected content detected):**
SPUser scan → sets `{1B1D3DAA…}=1`, `IsShadowPlayEnabled=0`, `DwmDvrEnabledV1=0`
→ overlay still shows "On" but no frames captured (silent pause).

---

## 4. IPC: CEF Overlay ↔ Native Backend

The overlay UI (CEF/Chromium) and the native capture backend communicate over a
custom **MessageBus** with named-pipe transport and protobuf-serialized messages.

```
CEF renderer (osc\*.js Angular UI)
   │  window.parent.postMessage / native binding
   ▼
NvAppIgoIpcProxy.dll  (Plugins\localuser\NvApp\)
   SendMessageViaProxy(clientId, JSON)   <- JS to backend
   IpcProxyMessageNotification           <- backend to JS (broadcast)
   ▼
MessageBusRouter.dll  (CEF\plugins\NVIDIA Overlay\)
   module "MessageBusRouter-IGO" / "MessageBusRouter-NvApp"
   CefJsonReceiver / MessageBusConnector  (JSON <-> protobuf BusMessage)
   ▼
NvMessageBus.dll  (MessageBus\)
   PipeTransport / PipeEndpoint over CreateNamedPipeW + IoCompletionPort
   BusMessage.proto: uniqueid, source_system/module, target_system/module,
                     source_session/target_session, domain, generic{type,data}, status
   MessageBusPort=1, LocalConnectionSuffix, PerSessionTransportDirectory
   ▼
ipccommon64.dll  (ShadowPlay\)
   IpcCommonInterface / IpcProxyInterface / CServerIpc
   IpcSyncCall() / IpcAsyncCall() / PostMessageAsync()
   ▼
_nvspcaps64.dll  (Shadowplay::ServicePlugin)
   targets: ShadowPlayApi_OSCUI, ShadowPlayApi_Overlay, ShadowPlayApi_Backend
```

System identities seen on the bus: `CrimsonNative` (UI), `Shadowplay` (capture),
`NvBackend`. Session fields keep user-session CEF isolated from the
SYSTEM/Local service side. Notably, message creation happens **downstream** of the
detection checks in §6 — so neutralizing the checks means the
"protected content" notification is never even built, and the toast never shows.

---

## 5. Component-Integrity Model

NVIDIA's core ShadowPlay DLLs are Authenticode-signed by **NVIDIA Corporation**
(CN=NVIDIA Corporation, OU=2008B9F). Integrity is enforced **at DLL load time**,
not at runtime.

Evidence: the pristine backup `_nvspcaps64.dll.nirf.bak` reports
`Get-AuthenticodeSignature` = `Valid`; a byte-modified on-disk copy reports
`HashMismatch`. Neither `nvcontainer.exe` nor `_nvspcaps64.dll` imports WinTrust
directly — Windows performs the verification automatically as part of the
`LoadLibraryExW` path that `nvcontainer.exe` uses to load plugins, and the NVIDIA
loader refuses to proceed when it fails.

### Why on-disk patching breaks the overlay but runtime patching does not

- **On-disk patch:** modifying `_nvspcaps64.dll` on disk changes its file hash.
  When `NVIDIA App.exe` / `NVIDIA Overlay.exe` initialize the overlay and trigger
  the load of the modified DLL, Windows Authenticode validation finds
  `file hash ≠ signed hash`, the load is rejected, and the overlay fails with a
  "problem opening the overlay" error. The signature is a **load-time seal**.

- **Runtime patch:** the on-disk file is left byte-for-byte intact, so its
  signature stays `Valid`. The DLL loads normally and passes verification. Only
  **after** it is resident in RAM does the patcher use
  `OpenProcess` + `WriteProcessMemory` to edit the in-memory image. The load-time
  gate never sees those edits — there is no re-verification of pages already
  mapped.

Defeating on-disk patching would require either re-signing with NVIDIA's private
key (impossible) or subverting Windows signature verification itself
(kernel-level). Therefore runtime patching is the only mode that respects the
integrity gate while achieving the goal.

---

## 6. Protected-Content Enforcement Across User-Mode / DWM / Kernel

Enforcement is layered. NVIDIA user-mode code makes **decisions** (pause, disable,
refuse save); the **actual pixel blanking is OS-enforced upstream** by DWM and the
kernel display driver, before NVIDIA capture code ever sees a frame.

```
APP LAYER     Browser+widevinecdm.dll | Apple Music (PMP) | UWP w/ WDA_MONITOR
   ▼
MEDIAFOUNDATION/OS  MFRequireProtectedEnvironment -> PMP topology; surfaces tagged "protected"
   ▼
USER-MODE DETECTION  nvcontainer.exe (SPUser) + _nvspcaps64.dll
   • USER32!GetWindowDisplayAffinity -> WDA_MONITOR => hard IR disable + toast
   • KERNEL32!Process32FirstW/Module32FirstW -> widevinecdm.dll in a browser
        => sets {1B1D3DAA…}=1 => SILENT pause
   • VerQueryValueW / IsImmersiveProcess -> UWP/app-name match
   • Decision gate: CCaptureSession::IsCaptureAllowed (RVA 0xA5D90) -> BOOL
   • Kill switches: CCaptureControl::ProcessGameEvents (EPC branch, RVA 0x9832B),
        CCaptureSession::TerminateCaptures (RVA 0xAA990, kills NVENC -> freeze),
        CCaptureControl::DisableIR (RVA 0x92CA0)
   ▼
NVIDIA CAPTURE  NvFBC64.dll
   • NvFBCCore::CheckGrabInfo (RVA 0x2AEA0): kernel sets grab-error 0xfbcb0001 ->
        returns failure HRESULT -> NVENC re-encodes last frame (frozen screen)
   • NvFBCCoprocHelper::doGdiDesktopCapture (RVA 0x42AD3): protected-branch gate
   ▼
DWM  dwm.exe  (Protected Process Light — cannot be injected/read even by SYSTEM)
   • Excludes WDA_MONITOR / PMP-tagged windows from the composited surface
   • The composited frame is ALREADY BLANK in the protected region
   ▼
KERNEL  nvlddmkm.sys
   • Enforces HDCP/DRM/PMP surface tags; emits grab-error 0xfbcb0001
   • Driver registry knobs (EnableRmTestOnlyCode, RmStressTest, RmDisableHdcp22)
     tested — NO effect on blanking => blanking is OS-enforced, not NVIDIA policy
   ▼
RECORDED MP4: protected region is black; blanking is upstream of all capture code.
```

| Behavior | Enforced by | Patchable in user mode? |
|----------|-------------|--------------------------|
| Detect protected app | nvcontainer SPUser scans | Yes |
| Pause/disable IR decision | `_nvspcaps64.dll` gates | Yes |
| Refuse Alt+F10 save | `SaveInstantReplay` guards | Yes |
| Freeze frame (re-encode last) | NvFBC grab-error + kernel | Partial (mask the error; pixels still blank) |
| Blank pixels in final video | DWM (PPL) + `nvlddmkm.sys` | **No — OS/kernel enforced** |

---

## 7. Patch Delivery: Runtime Watchdog

The patcher (`nvidia_instant_replay_fix.c`, 17 hooks) edits the loaded memory image
of the SPUser plugin and NvFBC, then runs an **event-driven watchdog** on the
registry. The watchdog uses `RegNotifyChangeKeyValue` (REG_NOTIFY_CHANGE_LAST_SET)
with a 30 s `WaitForSingleObject` timeout: on any change it re-scrubs
`{1B1D3DAA…}` back to 0 and restores the `*Enabled` flags to 1 (within ~10 ms,
0% steady-state CPU); on the 30 s timeout it re-applies hooks (idempotent: code 0
fresh, 1 error, 2 already-patched) to survive an nvcontainer restart.

Hook highlights: 1–5 neuter detection (`GetWindowDisplayAffinity`,
`Module32FirstW`, `VerQueryValueW`, `IsImmersiveProcess` → `xor rax,rax; ret`);
6–7 force `IsCaptureAllowed` → TRUE; 8 EPC `je`→`jmp`; 9–10 stub
`TerminateCaptures`/`DisableIR`; 11/13 NOP the `SaveInstantReplay` gates A–D;
12 force `CheckGrabInfo` → S_OK (`B8 01 00 00 00 C3`); 14 force the
`doGdiDesktopCapture` protected branch; 15–17 silence the overlay-side toast.

---

## 8. Implications for This Project

1. **Runtime watchdog is the only viable patch-delivery mode.** Edits must land in
   the in-memory image after load, paired with the registry watchdog to undo
   NVIDIA's out-of-band re-disabling. This respects the load-time integrity seal
   and survives driver/app updates because nothing on disk changes.

2. **On-disk patching is a dead end.** Authenticode verification at
   `LoadLibraryExW` rejects any modified `_nvspcaps64.dll` (`HashMismatch`), so the
   overlay refuses to open. Re-signing is impossible without NVIDIA's key. The
   on-disk path remains only as a reference/recovery tool, never a delivery mode.

3. **The protected-pixel freeze is OS/kernel-enforced and out of scope.** DWM
   (Protected Process Light) and `nvlddmkm.sys` blank protected regions upstream of
   NvFBC. User-mode hooks can defeat NVIDIA's *decisions* (don't pause, don't
   teardown, allow the save), but cannot recover blanked pixels. The achievable and
   legitimate goal — "don't let an unrelated protected app kill my recording" — is
   fully met; un-blanking protected content would require defeating OS-level DRM,
   which this project does not pursue.
