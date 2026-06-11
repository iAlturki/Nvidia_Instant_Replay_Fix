# Persistent Off-Switch Hunt: Keep NVIDIA Instant Replay Alive Without a Watchdog

Date: 2026-06-10
Scope: A PERSISTENT, signature-safe edit (registry / file / profile setting) that keeps
Instant Replay (IR) enabled when an unrelated protected-content app appears — i.e. that
neutralizes the auto-disable decision — WITHOUT a resident watchdog daemon.
Strictly keep-alive. The protected-pixel freeze is explicitly OUT OF SCOPE (kernel/DWM, unreachable).

Synthesis of 16 reconnaissance surfaces (binary RE of `_nvspcaps64.dll` v11.0.8.244,
`NvFBC64.dll`, `capcore64.dll`, `nvspapi64.dll`; HKCU/HKLM enumeration; DRS inspection;
`nvlddmkm` service knobs; CEF/JSON config; environment variables; community/web search).

---

## VERDICT: NO persistent single-edit (or few-edit) off-switch exists.

Every candidate falls into exactly one of four buckets, none of which satisfies the goal:

1. **State OUTPUT, not control INPUT** — written by NVIDIA *after* the decision; setting it does nothing because the decision logic overwrites it (this is precisely why the project ships a watchdog).
2. **A coarse master gate** — turns the whole feature on/off; does not gate the protected-content branch.
3. **Hardcoded in signed code with no registry read before the branch** — only a byte patch changes it, which breaks Authenticode (out of scope).
4. **Kernel/driver-enforced or speculative/non-existent** (hypothetical value names, env vars, DRS settings) — no evidence the code reads them.

The decisive piece of evidence: the protected-content branch in
`CCaptureControl::ProcessGameEvents` ("EPC found, terminating captures!!") and
`CCaptureSession::IsCaptureAllowed` ("EPC found running!!!") is **hardcoded with no
conditional registry/env/config read preceding it**. Multiple independent surfaces
converged on this (high confidence). There is therefore nothing to set that "the code
actually reads before the disable decision."

---

## The candidate that LOOKS like an off-switch but is NOT: `{1B1D3DAA-601D-49E5-8508-81736CA28C6D}`

- Location: `HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS`, REG_BINARY (4-byte DWORD).
- This is the strongest-evidenced flag in the whole corpus, and the project's own watchdog
  targets it (`FORCE_ZERO_FLAGS[]`, `nvidia_instant_replay_fix.c` lines 1514-1516).
- BUT it is an **OUTPUT**: NVIDIA *writes* it to 1 the instant it detects protected content;
  it is the consequence of the decision, not an input to it. A static "set to 0" does not
  persist — NVIDIA re-writes it to 1 on the next detection event, then pauses IR.
- The reason it requires a watchdog is exactly this: you must *react* to NVIDIA setting it,
  you cannot *pre-empt* the decision with a one-time value. CONFIRMED behaviorally via
  `Debug-Monitor.ps1` (value flips live during Apple Music launch).
- Confidence: HIGH that it exists and is the active flag; HIGH that a persistent static set is useless.

---

## Ranked assessment of all candidate classes

### Class A — Real values, but OUTPUT/state (cannot pre-empt the decision)
| Candidate | Location | Why it fails |
|---|---|---|
| `{1B1D3DAA-...}` | HKCU `...\ShadowPlay\NVSPCAPS` | Output flag, re-written on detect (see above). |
| `IsShadowPlayEnabled` | HKCU `...\NVSPCAPS` | System/derived state; auto-set to 0 by detection. `IsShadowPlayEnabledUser`=1 is the user pref; the GAP between them IS the auto-disable. Setting the system flag to 1 is overwritten. Multiple surfaces agree (HIGH). |
| `RecEnabled`, `HLEnabled` | HKCU `...\NVSPCAPS` | Recorder/Highlights enable; checked *after* the protected check passes. Setting them does not gate detection (HIGH). |
| `ShadowPlayActive` | HKCU `...\ShadowPlay` | Pure status output read by community tools to *detect* the disable. Not an input (LOW/derived). |

### Class B — Coarse master gates (wrong altitude; would disable IR, the opposite of the goal)
| Candidate | Location | Why excluded |
|---|---|---|
| `IsShadowPlayEnabledUser`=0 | HKCU `...\NVSPCAPS` | Disables IR entirely. Counterproductive. |
| `NVFBCEnable`=0 | HKLM `...\Services\nvlddmkm[\Parameters]` | Kills ALL FBC capture, not the check. Sledgehammer. |
| `NvFBC_Enable`=0 (DLL export/flag) | n/a | Disables all NvFBC. Opposite of goal. |
| `DwmEnabled` / `DwmDvrEnabledV1` / `DwmEnabledUser` | HKCU `...\NVSPCAPS` | Capture-path selection. Protected check is upstream in `IsCaptureAllowed`/`EvaluateAutoDVRStart`, BEFORE the DWM-vs-FBC path is chosen. Toggling does not bypass detection; setting to 0 only removes a capture path. Conflicting "high confidence" claims that DWM "bypasses" the check are NOT supported by the call-order evidence. Do not rely on. |

### Class C — Hardcoded in signed code (only a byte patch changes it → Authenticode break → OUT OF SCOPE)
- `CCaptureControl::DisableIR` (RVA 0x2BA4E1, "Auto-Disable IR Session")
- `CCaptureSession::IsCaptureAllowed` / `ProcessGameEvents` EPC/MPC branch
- `CWindowManager::GetProtectedContentAppDetails` (RVA 0x2D8F10), `LogProtectedContentAppDetails`
- `CCaptureSession::IsDVRDisableRequired`, `EvaluateAutoDVRStart`
- These ARE the decision. Editing them is the project's runtime-hook approach (in-memory only).
  An ON-DISK edit makes `Get-AuthenticodeSignature` report HashMismatch and the NVIDIA App
  overlay then fails with "There was a problem opening the overlay" (VERIFIED 2026-05-28,
  see CLAUDE.md "Two delivery modes"). EXCLUDED — breaks overlay/signature.

### Class D — Driver/kernel-enforced or non-existent (no code reads them before the branch)
| Candidate | Verdict |
|---|---|
| `NVFBC_ERROR_PROTECTED_CONTENT` / `CheckGrabInfo` / `bProtectedContent` | Kernel-sourced via NvAPI MSHybrid; output-only. No user-mode/registry gate. See `NVFBC_PROTECTED_PATH.md`. Out of scope. |
| `OverridePRR` (HKLM `...\NVTweak`) | Pixel-blanking (PRR) control, not IR enable. Out of scope; also HKLM/elevation/HDCP side-effects. |
| `RMHdcpKeyglobZero` (GPU class key `{4d36e968-...}\0000`) | Disables HDCP on the OUTPUT — addresses one signal path (HDCP) only, NOT WDA/Widevine detection; breaks 4K DRM playback; reverts on driver update. Risky, partial, EXCLUDED. |
| `EnableRmTestOnlyCode`, `RmStressTest`, `RmDisableHdcp22`, etc. (HKLM `nvlddmkm`) | EXHAUSTIVELY TESTED, zero effect (CLAUDE.md "Hard limit"). EXCLUDED. |
| `SOFTWARE\...\ShadowPlay\Overrides` (key path string in DLL) | String present, but no value NAME extracted and DLL logs show NO successful read from it; no documented schema. Speculative (LOW). Creating guessed values is unsupported. |
| `...\NvApp\ShadowPlay\FTS` / `GetFTSFeatureValue` | FTS gates CODEC features (AV1/HEVC/240fps) only; no evidence it gates protected-content detection. Speculative for this purpose (LOW/MEDIUM). |
| `DisableProtectedContentDetection` / `BypassProtectedContentCheck` / `DisableEPCDetection` | DO NOT EXIST. No string evidence; the check is unconditional. Confirmed negative (HIGH). |
| `NVIDIA_DISABLE_PROTECTED_CONTENT_CHECK` / `NV_SKIP_PC_DETECT` env vars | No `GetEnvironmentVariable` reference for any such name. Do not exist (LOW/negative). |
| CEF/`ShareServer.json` flags | UI/IPC feature toggles; detection runs at CaptureSession level, not gated by overlay config (LOW). |
| Browser "disable hardware acceleration" | Real community workaround, but per-app, manual, drops streaming to 720p, and is a *source-side* mitigation — not a system-wide NVIDIA-side persistent edit. Not in scope as a registry/file off-switch. |

---

## Why a persistent off-switch is architecturally impossible here

The auto-disable is **event-driven and re-evaluated continuously**. NVIDIA does not consult a
"should I check for protected content?" gate; it unconditionally runs the EPC/MPC/WDA/Widevine
scan and, on a hit, writes the state flags + calls `DisableIR`. A static registry value cannot
sit "in front of" an unconditional code path. The only persistent options are:
(a) change the code (on-disk patch → breaks signature), or
(b) react to the state write (watchdog), or
(c) prevent the *source* signal (e.g. neuter WDA via in-memory hook / browser flag).

All three are runtime, not a persisted setting. There is no value the code reads that would tell
it to skip the branch.

---

## Recommended no-daemon fallback (NOT a resident watchdog)

Since no persisted value works, the minimal non-watchdog approach is a **run-once-at-event
trampoline**: a Scheduled Task that fires the existing one-shot patcher (`Nvidia_Instant_Replay_Fix.exe`
with NO `--watchdog`) and exits. This applies the in-memory hooks (which DO defeat the decision:
`IsCaptureAllowed`→TRUE, EPC `je`→`jmp`, `DisableIR`→stub) and then the process terminates — it is
NOT resident, has no steady-state footprint, and leaves the signed DLL on disk pristine (load-time
integrity passes; only the in-memory copy is edited, so the overlay still opens).

Concrete fallback (already supported by `Install-Persistence.ps1 -Mode Periodic`):
- LogonTrigger (delay 30s) + EventTrigger on `NvContainerLocalSystem` service state change
  (Service Control Manager EventID 7036) — covers driver/app updates that restart the host.
- Optionally a low-frequency TimeTrigger (e.g. every few minutes) to re-apply after an
  nvcontainer restart, since the one-shot cannot react to mid-session registry writes.
- `ExecutionTimeLimit` short (PT5M); the process exits on its own. No `WaitForSingleObject` loop.

Trade-off vs. the watchdog: the one-shot CANNOT instantly reverse a registry-based disable that
happens *between* runs (the watchdog's `RegNotifyChangeKeyValue` does). If the deployment goal is
strictly "no resident process," the event-triggered one-shot is the correct minimal answer; if
instant reversal of the `{1B1D3DAA-...}` write is required, only the watchdog provides it.

---

## What to try FIRST (smallest, safest experiment) and how to test it

There is no safe persistent registry edit to recommend as a primary fix — every persisted value
is either output-state, a coarse kill, or non-existent. So the smallest safe action is a
**confirmation experiment**, not a fix:

1. **Smallest safe edit to verify the negative**: in `HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS`,
   set `{1B1D3DAA-601D-49E5-8508-81736CA28C6D}` (REG_BINARY) to `00 00 00 00` and
   `IsShadowPlayEnabled` to `01 00 00 00` WITHOUT the watchdog running. Then launch a protected app
   (e.g. Apple Music / Netflix in browser). Risk: NONE (HKCU, user-writable, reversible, no signature touched).
   - Test via `Debug-Monitor.ps1`: observe the flag. **Expected result: NVIDIA re-writes
     `{1B1D3DAA-...}` back to 1 within ~1s and IR pauses** — proving it is output-only and that no
     persistent set works. This reproduces the project's existing finding and closes the question.
2. **If a no-daemon deployment is wanted**, switch the installer to the event-triggered one-shot:
   `Install-Persistence.ps1 -Mode Periodic` (already implemented). Verify with `check_hook8.ps1`
   (reads the live nvcontainer memory and reports each hook APPLIED/NOT APPLIED) right after a trigger
   fires, then confirm IR survives a protected-app launch for the interval. This is the safe,
   signature-clean, non-resident path.

Do NOT: patch the DLL on disk (breaks overlay), touch `nvlddmkm` RM knobs (tested, useless),
set `NVFBCEnable`=0 or `IsShadowPlayEnabledUser`=0 (disables IR), or create guessed
`Overrides`/`FTS` value names (unsupported, no read evidence).

---

## Bottom line

No persistent single- or few-edit off-switch exists. The only value with strong "code reads/writes
it" evidence (`{1B1D3DAA-...}`) is an output the engine overwrites, which is exactly why this is a
watchdog problem and not a settings problem. The disable decision is unconditional signed code; the
only persistent way to defeat it is the in-memory hook set, delivered either by the resident watchdog
(instant reversal) or — if "no daemon" is mandatory — by an event-triggered run-once one-shot Scheduled
Task, which is NOT a resident watchdog. Start by confirming the negative with the zero/one HKCU set
above; expect NVIDIA to re-write it, validating that the one-shot/watchdog runtime hook is the real fix.
