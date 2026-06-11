# NvFBC Protected-Content Blanking: User-Mode Lever Synthesis

Date: 2026-06-10. Scope: can a USER-MODE change stop NvFBC from blanking content
that OBS/DXGI can still capture (the "NVIDIA stricter than the OS" case)?
Genuine hardware-DRM content stays black for everyone and is OUT OF SCOPE.

Binaries verified directly (clean/signed copies):
- `_nvspcaps64.dll.nirf.bak` (3,738,736 bytes, Apr 24)
- `NvFBC64.dll` (2,328,296 bytes, Mar 6) — `C:\Windows\System32\`
Tooling: pefile + capstone, disassembled at the exact RVAs the four angles cited.

## VERDICT: (b) confirmed driver/kernel-only. User-mode is dead, matching CheckGrabInfo.

Both "new" candidates dissolve under disassembly; the two correct angles converge
with the prior exhaustive result. No NEW user-mode patch target is real.

---

## 1. Session-creation flag controlling blanking? NO. The 0x600100c8 claim is FALSE.

The "NvFBC API flags" / "_nvspcaps64 setup call site" angle claimed a hardcoded
session flag `0x600100c8` at `_nvspcaps64.dll` RVA 0x27bff, written to `[rbp+0x130]`
then `call rbx` -> `NvFBC_CreateEx`, and proposed patching it.

**Disassembled the clean .bak at exactly RVA 0x27bb1-0x27c4d. That code does not exist there.**
RVA 0x27bff is:
```
0x027bf1: lea rdx, [rip + 0x287f08]    ; format-string ptr
0x027bf8: lea rcx, [rip + 0x32f6a1]    ; logger object
0x027bff: e8 f4 40 fe ff   call 0xbcf8 ; <-- logging helper, NOT NvFBC_CreateEx
```
Surrounded by `cmp dword [rip+...], 7` / `mov dword [rip+...], 7` log-level guards
and a `mov ebp, 0x80004005` (E_FAIL) error path. There is no `mov [rbp+0x130],
0x600100c8`, no `call rbx`, no NvFBC_CreateEx at this site. The flag value, the
"bit 16 = enforce protected content", the bit-field gloss, and the candidate
patch (0x000000c8 / 0x200000c8 alternatives) are all **hallucinated**. Do not patch
0x27bff — it is a log call.

Documented SDK structures agree: `NVFBC_CREATE_CAPTURE_SESSION_PARAMS` (v5/6) has
NO protected-content flag (eCaptureType/eTrackingType/captureBox/bWithCursor/
bPushModel/bAllowDirectCapture only). `NvFBCCreateParams` likewise. There is no
session-setup lever, fabricated or real.

## 2. Where does the blanking happen? Kernel-side. User-mode only READS status.

The accurate angles converge:
- Protection status is fetched at GRAB time via `NvAPI_DISP_GetMSHybridFBCCaptureState`
  (string present exactly once in NvFBC64, RVA 0x196226) — an NvAPI->kernel escape.
- `NvFBCFrameGrabInfo.bProtectedContent` is OUTPUT-ONLY, populated from that kernel call.
- Note: the "Blanking decision point" angle claimed `D3DKMTEscape` strings/dynamic
  resolution in NvFBC64. **FALSE** — `D3DKMTEscape` appears 0 times in the binary.
  The kernel crossing is the NvAPI MSHybrid call, not literal D3DKMTEscape. The
  angle's broad conclusion (kernel-sourced) is right; its specific evidence was wrong.

The 0xba72 function (verified byte-for-byte: `mov edx,[rcx+0x10]; test; ... or eax,edx;
and eax,0x15; or eax,2; mov [rcx+0x10],eax`) is an internal STATE-WORD update
(`or eax,2` set unconditionally), not a pixel gate. `[rcx+0x10]` is a status/flags
field, not a frame buffer. Forcing it to 0 changes how NvFBC *interprets* the frame;
it cannot regenerate pixels DWM/nvlddmkm already stripped before NvFBC sees the surface.

This matches our CheckGrabInfo result: we already forced `CheckGrabInfo`->S_OK
(neutralizing the `NVFBC_ERROR_PROTECTED_CONTENT` refusal). The session still
captures, but the protected region is already blank. The decision NvFBC makes is
patchable; the pixels are gone upstream.

## 3. Why OBS differs (in-scope litmus)

OBS via WGC/DXGI Desktop Duplication returns the frame with protected regions
black-masked and a `ProtectedContentMaskedOut` flag — OS policy ("if you can see it
locally you can capture it") with opt-in swap-chain protection. For content the OS
deems capturable, DXGI returns real pixels. NvFBC, fed by the same composited
surface, can be just as permissive ONCE its refusal is neutralized (we did that) —
but for anything the kernel/DWM actually blanked, both lose the pixels. The
remaining freeze is upstream of every user-mode surface (DWM is PPL; nvlddmkm is
kernel), confirmed by 15 hooks + injection + every nvlddmkm registry knob having
zero effect.

## 4. What to probe next (only if pursuing the in-scope OBS-capturable delta)

User-mode is exhausted. If the delta is real (OBS shows pixels NvFBC blanks for
OS-capturable content), the divergence is in the kernel path NvFBC requests, not
user-mode NvFBC. Probes, in order:
- Confirm the delta empirically: same window, side-by-side OBS-WGC vs NvFBC capture.
  If both black -> genuine DRM, out of scope, stop.
- If only NvFBC blacks: trace the MSHybrid/NvAPI return at runtime (hook NvAPI in
  NvFBC's import path, log the captured-state value) to see if user-mode could spoof
  the STATUS such that NvFBC doesn't request the blanked surface. Low confidence —
  the surface contents are decided kernel-side regardless of the status NvFBC reads.
- Otherwise it is the kernel driver / GSP path (out of user-mode scope), as already
  concluded for the DRM-freeze case.

## Bottom line
No session-creation flag; the 0x600100c8 candidate is fabricated. bProtectedContent
is kernel-sourced output, not a user-mode gate. The blanking is performed upstream
(DWM/nvlddmkm) before NvFBC's surface; user-mode code only reads and reports it.
Verdict (b): driver/kernel-only, user-mode dead — identical to the CheckGrabInfo
finding. Do not invest further user-mode RE in NvFBC for un-blanking pixels.
