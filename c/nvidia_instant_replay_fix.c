/*
 * Nvidia_Instant_Replay_Fix
 * Copyright (c) 2026 iALTURKi  <https://github.com/iALTURKi>
 * Licensed under the MIT License. See the LICENSE file in the project root.
 *
 * Project: https://github.com/iALTURKi/Nvidia_Instant_Replay_Fix
 *
 * Finds the nvcontainer.exe instance that runs the SPUser plugin (the one
 * doing the "protected content" / "invisible window" checks) and patches the
 * prologues of:
 *
 *   USER32!GetWindowDisplayAffinity   -> xor rax,rax ; ret  (invisible window check)
 *   KERNEL32!Module32FirstW           -> xor rax,rax ; ret  (DRM/Widevine module enumeration)
 *
 * Single translation unit, no STL, no C++ runtime. Links only against system
 * DLLs (kernel32, user32, ntdll via runtime LoadLibrary).
 *
 * Detection priority (multi-strategy, robust against driver/app updates):
 *   1. nvcontainer.exe whose command line contains "\plugins\SPUser"  (new NVIDIA App)
 *   2. nvcontainer.exe whose command line contains "SPUser"           (older GFE / fallback)
 *   3. nvcontainer.exe with module nvd3dumx.dll loaded                (original heuristic)
 *   4. nvcontainer.exe with module _nvspcaps64.dll loaded             (new NVIDIA App fallback)
 *
 * Re-running on an already-patched process is a no-op (we detect the 0xE9 byte).
 *
 * CLI:
 *   --no-wait-for-keypress     don't pause at the end
 *   --diagnose                 print everything we see and what we would target; don't patch
 *   --wait <seconds>           if target not found, retry every 2s for up to <seconds>
 *   --verbose                  print extra detection info during a normal run
 */

#ifndef UNICODE
#  define UNICODE
#endif
#ifndef _UNICODE
#  define _UNICODE
#endif

#include <windows.h>
#include <winternl.h>
#include <tlhelp32.h>
#include <conio.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <wchar.h>
#include <io.h>      /* _open_osfhandle, _dup2 */
#include <fcntl.h>
#include <errno.h>   /* errno for the freopen() failure path */

#define MAX_PIDS          256
#define CMDLINE_MAX_CHARS 4096
#define ALLOC_SIZE        0x1000
#define ALLOC_RANGE       (0x20000000 - 0x2000)
#define ALLOC_STEP        0x1000

/* PROCESSINFOCLASS value not in older SDK headers. */
#ifndef ProcessCommandLineInformation
#  define ProcessCommandLineInformation 60
#endif

typedef NTSTATUS (NTAPI *PFN_NQIP)(HANDLE, ULONG, PVOID, ULONG, PULONG);

/* ----------------------------------------------------------------------
 * Tiny string helpers
 * ---------------------------------------------------------------------- */

static int wieq(const wchar_t *a, const wchar_t *b) {
    return _wcsicmp(a, b) == 0;
}

static int wstr_icontains(const wchar_t *hay, const wchar_t *needle) {
    if (!hay || !needle) return 0;
    size_t nlen = wcslen(needle);
    if (nlen == 0) return 1;
    size_t hlen = wcslen(hay);
    if (nlen > hlen) return 0;
    for (size_t i = 0; i + nlen <= hlen; i++) {
        if (_wcsnicmp(hay + i, needle, nlen) == 0) return 1;
    }
    return 0;
}

/* ----------------------------------------------------------------------
 * Toolhelp wrappers
 * ---------------------------------------------------------------------- */

static size_t find_pids_by_name(const wchar_t *name, DWORD *out, size_t cap) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W pe; pe.dwSize = sizeof(pe);
    size_t n = 0;
    if (Process32FirstW(snap, &pe)) {
        do {
            if (n < cap && wieq(pe.szExeFile, name)) out[n++] = pe.th32ProcessID;
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return n;
}

static BOOL pid_has_module(DWORD pid, const wchar_t *module_name) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    if (snap == INVALID_HANDLE_VALUE) return FALSE;
    MODULEENTRY32W me; me.dwSize = sizeof(me);
    BOOL hit = FALSE;
    if (Module32FirstW(snap, &me)) {
        do {
            if (wieq(me.szModule, module_name)) { hit = TRUE; break; }
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
    return hit;
}

static uintptr_t remote_module_base(HANDLE hProc, const wchar_t *module_name) {
    HANDLE snap = CreateToolhelp32Snapshot(
        TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetProcessId(hProc));
    if (snap == INVALID_HANDLE_VALUE) return 0;
    MODULEENTRY32W me; me.dwSize = sizeof(me);
    uintptr_t base = 0;
    if (Module32FirstW(snap, &me)) {
        do {
            if (wieq(me.szModule, module_name)) {
                base = (uintptr_t)me.modBaseAddr;
                break;
            }
        } while (Module32NextW(snap, &me));
    }
    CloseHandle(snap);
    return base;
}

/* ----------------------------------------------------------------------
 * Command-line reader (NtQueryInformationProcess / ProcessCommandLineInformation)
 *
 * Win 8.1+. Lets us read another process's CommandLine without elevating
 * and without parsing PEB structures by hand.
 * ---------------------------------------------------------------------- */

static PFN_NQIP load_NQIP(void) {
    static PFN_NQIP fn = NULL;
    static int tried = 0;
    if (!tried) {
        tried = 1;
        HMODULE m = GetModuleHandleW(L"ntdll.dll");
        if (!m) m = LoadLibraryW(L"ntdll.dll");
        if (m) fn = (PFN_NQIP)GetProcAddress(m, "NtQueryInformationProcess");
    }
    return fn;
}

/* Writes a NUL-terminated UTF-16 command line into out. Returns 0 on success. */
static int get_process_cmdline(DWORD pid, wchar_t *out, size_t cap) {
    if (cap == 0) return -1;
    out[0] = L'\0';

    PFN_NQIP NQIP = load_NQIP();
    if (!NQIP) return -1;

    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return -1;

    ULONG needed = 0;
    (void)NQIP(h, ProcessCommandLineInformation, NULL, 0, &needed);
    if (needed == 0) { CloseHandle(h); return -1; }

    UNICODE_STRING *us = (UNICODE_STRING*)malloc(needed);
    if (!us) { CloseHandle(h); return -1; }
    NTSTATUS s = NQIP(h, ProcessCommandLineInformation, us, needed, &needed);
    CloseHandle(h);
    if (s != 0 || us->Buffer == NULL) { free(us); return -1; }

    size_t chars = us->Length / sizeof(wchar_t);
    if (chars >= cap) chars = cap - 1;
    memcpy(out, us->Buffer, chars * sizeof(wchar_t));
    out[chars] = L'\0';
    free(us);
    return 0;
}

/* ----------------------------------------------------------------------
 * Memory primitives
 * ---------------------------------------------------------------------- */

static uintptr_t remote_export_addr(uintptr_t remote_base,
                                    const wchar_t *module_name,
                                    const char *func_name) {
    HMODULE h = LoadLibraryW(module_name);
    if (!h) return 0;
    FARPROC p = GetProcAddress(h, func_name);
    if (!p) { FreeLibrary(h); return 0; }
    uintptr_t off = (uintptr_t)p - (uintptr_t)h;
    FreeLibrary(h);
    return remote_base + off;
}

static uintptr_t alloc_near(HANDLE hProc, uintptr_t target, SIZE_T size) {
    uintptr_t lo = (target > (uintptr_t)ALLOC_RANGE) ? target - ALLOC_RANGE : 0;
    uintptr_t hi = target + ALLOC_RANGE;
    for (uintptr_t a = lo; a < hi; a += ALLOC_STEP) {
        void *p = VirtualAllocEx(hProc, (LPVOID)a, size,
                                 MEM_RESERVE | MEM_COMMIT,
                                 PAGE_EXECUTE_READWRITE);
        if (p) return (uintptr_t)p;
    }
    return 0;
}

static BOOL write_remote(HANDLE hProc, uintptr_t addr, const void *buf, SIZE_T size) {
    SIZE_T n = 0;
    return WriteProcessMemory(hProc, (LPVOID)addr, buf, size, &n) && n == size;
}

static BOOL read_remote(HANDLE hProc, uintptr_t addr, void *buf, SIZE_T size) {
    SIZE_T n = 0;
    return ReadProcessMemory(hProc, (LPCVOID)addr, buf, size, &n) && n == size;
}

static BOOL write_remote_protected(HANDLE hProc, uintptr_t addr,
                                   const void *buf, SIZE_T size) {
    DWORD old = 0;
    if (!VirtualProtectEx(hProc, (LPVOID)addr, size, PAGE_EXECUTE_READWRITE, &old))
        return FALSE;
    BOOL ok = write_remote(hProc, addr, buf, size);
    DWORD discard;
    VirtualProtectEx(hProc, (LPVOID)addr, size, old, &discard);
    return ok;
}

static BOOL asm_jmp_rel32(uint8_t out[5], uintptr_t src, uintptr_t dst) {
    int64_t disp = (int64_t)dst - (int64_t)(src + 5);
    if (disp > 0x7FFFFFFFLL || disp < -0x80000000LL) return FALSE;
    int32_t d32 = (int32_t)disp;
    out[0] = 0xE9;
    memcpy(out + 1, &d32, sizeof d32);
    return TRUE;
}

/* ===================== runtime hook resolver (self-healing) =====================
 * Locate the internal _nvspcaps64.dll patch sites at RUNTIME by stable anchors
 * (NVIDIA's own debug log-strings + the .pdata function table) instead of
 * hardcoded RVAs. Addresses move on every NVIDIA App update; the log-strings and
 * code shape do not. So we find each function by a string it references, bound it
 * via .pdata, and locate the exact patch site by a short local pattern. Falls
 * back per-hook to the last-known 11.0.8.244 offset, and never patches a site
 * whose opcode doesn't match (it skips rather than corrupt). This is the same
 * logic the c/*.py analysis scripts use, moved into the tool so it self-heals. */
typedef struct {
    uint8_t *img;                 /* local RVA-indexed copy of the remote image */
    DWORD    size;                /* SizeOfImage */
    DWORD    textVA, textEnd;
    DWORD    rdataVA, rdataEnd;
    DWORD    pdataVA, pdataEnd;
} mod_image_t;

static void free_mod_image(mod_image_t *mi) { if (mi->img) { free(mi->img); mi->img = NULL; } }

/* Read the remote module's PE image into a local RVA-indexed buffer. */
static int load_mod_image(HANDLE h, const wchar_t *name, mod_image_t *mi) {
    memset(mi, 0, sizeof *mi);
    uintptr_t base = remote_module_base(h, name);
    if (!base) return 0;
    uint8_t hdr[0x1000];
    if (!read_remote(h, base, hdr, sizeof hdr)) return 0;
    if (hdr[0] != 'M' || hdr[1] != 'Z') return 0;
    DWORD e_lfanew; memcpy(&e_lfanew, hdr + 0x3C, 4);
    if (e_lfanew + 0x108 > sizeof hdr) return 0;
    uint8_t *nt = hdr + e_lfanew;
    if (memcmp(nt, "PE\0\0", 4) != 0) return 0;
    WORD nsec, optsz; memcpy(&nsec, nt + 6, 2); memcpy(&optsz, nt + 20, 2);
    DWORD sizeImage; memcpy(&sizeImage, nt + 24 + 56, 4);   /* OptionalHeader.SizeOfImage (PE32+) */
    if (sizeImage == 0 || sizeImage > 96u * 1024u * 1024u) return 0;
    mi->img = (uint8_t *)calloc(1, sizeImage);
    if (!mi->img) return 0;
    mi->size = sizeImage;
    uint8_t *sec = nt + 24 + optsz;                          /* section table */
    for (WORD i = 0; i < nsec; i++) {
        uint8_t *s = sec + (size_t)i * 40;
        DWORD va, vsz, rsz; memcpy(&va, s + 12, 4); memcpy(&vsz, s + 8, 4); memcpy(&rsz, s + 16, 4);
        DWORD take = vsz > rsz ? vsz : rsz;
        if (va == 0 || va >= sizeImage) continue;
        if (va + take > sizeImage) take = sizeImage - va;
        read_remote(h, base + va, mi->img + va, take);       /* best-effort */
        char nm[9]; memcpy(nm, s, 8); nm[8] = 0;
        if      (!strcmp(nm, ".text"))  { mi->textVA = va;  mi->textEnd  = va + take; }
        else if (!strcmp(nm, ".rdata")) { mi->rdataVA = va; mi->rdataEnd = va + take; }
        else if (!strcmp(nm, ".pdata")) { mi->pdataVA = va; mi->pdataEnd = va + take; }
    }
    return (mi->textVA && mi->rdataVA && mi->pdataVA) ? 1 : 0;
}

/* RVA of the first occurrence of NUL-terminated ASCII string s within .rdata. */
static DWORD find_string_rva(mod_image_t *mi, const char *s) {
    size_t len = strlen(s);
    if (mi->rdataEnd <= mi->rdataVA + len) return 0;
    for (DWORD r = mi->rdataVA; r + len < mi->rdataEnd; r++)
        if (memcmp(mi->img + r, s, len) == 0) return r;
    return 0;
}

/* RVA of a `lea reg,[rip+disp32]` in .text whose target == targetRVA. */
static DWORD find_lea_target(mod_image_t *mi, DWORD targetRVA) {
    if (mi->textEnd < 7) return 0;
    for (DWORD i = mi->textVA; i + 7 < mi->textEnd; i++) {
        uint8_t b0 = mi->img[i], b1 = mi->img[i + 1], b2 = mi->img[i + 2];
        if ((b0 == 0x48 || b0 == 0x4C) && b1 == 0x8D && (b2 & 0xC7) == 0x05) {
            int32_t disp; memcpy(&disp, mi->img + i + 3, 4);
            if ((DWORD)(i + 7 + disp) == targetRVA) return i;
        }
    }
    return 0;
}

/* Function [start,end) from the .pdata RUNTIME_FUNCTION table containing rva. */
static int find_func_range(mod_image_t *mi, DWORD rva, DWORD *start, DWORD *end) {
    for (DWORD p = mi->pdataVA; p + 12 <= mi->pdataEnd; p += 12) {
        DWORD b, e; memcpy(&b, mi->img + p, 4); memcpy(&e, mi->img + p + 4, 4);
        if (b && e && b <= rva && rva < e) { *start = b; *end = e; return 1; }
    }
    return 0;
}

/* Function START whose body references log-string `anchor`. 0 if not found. */
static DWORD anchor_func_start(mod_image_t *mi, const char *anchor) {
    DWORD str = find_string_rva(mi, anchor); if (!str) return 0;
    DWORD lea = find_lea_target(mi, str);    if (!lea) return 0;
    DWORD s, e; return find_func_range(mi, lea, &s, &e) ? s : 0;
}

/* Pattern search in [start,end): mask 'x'=match, '?'=wildcard. RVA or 0. */
static DWORD find_pattern(mod_image_t *mi, DWORD start, DWORD end,
                          const uint8_t *pat, const char *mask, int n) {
    if (end > mi->size) end = mi->size;
    for (DWORD i = start; i + (DWORD)n <= end; i++) {
        int ok = 1;
        for (int j = 0; j < n; j++)
            if (mask[j] == 'x' && mi->img[i + j] != pat[j]) { ok = 0; break; }
        if (ok) return i;
    }
    return 0;
}

/* Patch a resolved site: verify opcode (or that it's already patched), then write
 * repl. Returns 0 fresh, 2 already, 1 skipped (not located / opcode mismatch / IO). */
static int patch_at(HANDLE h, uintptr_t base, DWORD rva, uint8_t opcode,
                    const uint8_t *repl, SIZE_T len, const char *label, int quiet) {
    if (!rva) { if (!quiet) fprintf(stderr, "Info: %s: not located, skipping\n", label); return 1; }
    uint8_t cur[16];
    if (len > sizeof cur) return 1;
    if (!read_remote(h, base + rva, cur, len)) { if (!quiet) fprintf(stderr, "Info: %s: read failed\n", label); return 1; }
    if (memcmp(cur, repl, len) == 0) { if (!quiet) printf("Info: %s @ +0x%lx already patched. Skipping.\n", label, (unsigned long)rva); return 2; }
    if (cur[0] == 0xE9 && opcode != 0xE9) { if (!quiet) printf("Info: %s @ +0x%lx already redirected (legacy trampoline). Skipping.\n", label, (unsigned long)rva); return 2; }
    if (cur[0] != opcode) { if (!quiet) fprintf(stderr, "Info: %s @ +0x%lx: opcode 0x%02x != expected 0x%02x, skipping (run the re-derive workflow)\n", label, (unsigned long)rva, cur[0], opcode); return 1; }
    if (!write_remote_protected(h, base + rva, repl, len)) { if (!quiet) fprintf(stderr, "Info: %s: write failed\n", label); return 1; }
    if (!quiet) printf("Info: %s @ +0x%lx patched (%d bytes).\n", label, (unsigned long)rva, (int)len);
    return 0;
}

/* Apply the 8 internal _nvspcaps64 hooks (6,8,9,10,11a/b,13a/b), located by
 * runtime anchors with 11.0.8.244 fallbacks. Returns 1 if the module isn't
 * present (e.g. wrong target), else 0. */
static int apply_internal_nvsp_hooks(HANDLE h, int quiet) {
    uintptr_t base = remote_module_base(h, L"_nvspcaps64.dll");
    if (!base) { if (!quiet) fprintf(stderr, "Warn: _nvspcaps64.dll not loaded in target\n"); return 1; }

    /* Fallbacks: last-known-good offsets for 11.0.8.244. */
    DWORD rIsCap = 0xA69B0, rEpc = 0x98EEB, rTerm = 0xAB5B0, rDis = 0x93840;
    DWORD rGateA = 0xA90E0, rGateB = 0xA90F7, rRate = 0xA91F4, rSub = 0xA9206;
    int located = 0;

    mod_image_t mi;
    if (load_mod_image(h, L"_nvspcaps64.dll", &mi)) {
        DWORD r, s, e;
        if ((r = anchor_func_start(&mi, "CCaptureSession::IsCaptureAllowed: EPC found running")))       { rIsCap = r; located++; }
        if ((r = anchor_func_start(&mi, "CCaptureSession::TerminateCaptures: StopDVRCapture failed")))   { rTerm  = r; located++; }
        if ((r = anchor_func_start(&mi, "CCaptureControl::DisableIR: Auto-Disable IR Session")))         { rDis   = r; located++; }

        /* EPC je: from the "EPC found, terminating" lea, scan back for `test al,al; je rel8`. */
        DWORD estr = find_string_rva(&mi, "CCaptureControl::ProcessGameEvents: EPC found, terminating captures");
        DWORD elea = estr ? find_lea_target(&mi, estr) : 0;
        if (elea) {
            for (DWORD a = elea; a > mi.textVA && a + 0x40 > elea; a--)
                if (mi.img[a] == 0x84 && mi.img[a + 1] == 0xC0 && (mi.img[a + 2] == 0x74 || mi.img[a + 2] == 0xEB)) { rEpc = a + 2; located++; break; }
        }

        /* SaveInstantReplay gates + rate-limit/sub-state: confined to that function. */
        DWORD sir = anchor_func_start(&mi, "CCaptureSession::SaveInstantReplay: IN");
        if (!sir) sir = anchor_func_start(&mi, "CCaptureSession::SaveInstantReplay: Invalid Args");
        if (sir && find_func_range(&mi, sir, &s, &e)) {
            /* The je / 0F84 opcode bytes are wildcarded ('?') so each pattern matches
             * BOTH the original and the already-NOP/jmp form -> the watchdog can
             * re-locate even in a still-running, already-patched process. Searches
             * run sequentially (each starts just after the previous hit) so they stay
             * anchored to the right jump despite the wildcards. */
            static const uint8_t pGA[] = { 0x48,0x8B,0x8F, 0,0,0,0, 0x48,0x85,0xC9, 0,0 };  /* mov rcx,[rdi+d]; test rcx,rcx; je */
            static const uint8_t pGB[] = { 0x83,0xBF, 0,0,0,0, 0x00, 0,0 };                  /* cmp dword[rdi+d],0; je */
            static const uint8_t pRA[] = { 0x83,0xFA,0x01, 0 };                               /* cmp edx,1; je (rate-limit) */
            static const uint8_t pSB[] = { 0x80,0x78,0x01,0x00, 0 };                          /* cmp byte[rax+1],0; je (sub-state) */
            DWORD ga = find_pattern(&mi, s, e, pGA, "xxx????xxx??", 12); if (ga) { rGateA = ga + 10; located++; }
            DWORD gb = find_pattern(&mi, ga ? ga + 1 : s, e, pGB, "xx????x??", 9); if (gb) { rGateB = gb + 7; located++; }
            DWORD ra = find_pattern(&mi, gb ? gb + 1 : s, e, pRA, "xxx?", 4);      if (ra) { rRate  = ra + 3; located++; }
            DWORD sb = find_pattern(&mi, ra ? ra + 1 : s, e, pSB, "xxxx?", 5);     if (sb) { rSub   = sb + 4; located++; }
        }
        free_mod_image(&mi);
    } else if (!quiet) {
        fprintf(stderr, "Info: resolver could not map _nvspcaps64.dll image; using 11.0.8.244 fallback offsets\n");
    }
    if (!quiet) printf("Info: internal-hook resolver auto-located %d/8 sites (any misses use the 11.0.8.244 fallback).\n", located);

    static const uint8_t STUB_TRUE[] = { 0xB8,0x01,0x00,0x00,0x00,0xC3 };  /* mov eax,1; ret  */
    static const uint8_t STUB_SOK[]  = { 0x33,0xC0,0xC3 };                  /* xor eax,eax; ret */
    static const uint8_t JMP1[]      = { 0xEB };                            /* je -> jmp (byte 0 only) */
    static const uint8_t NOP6[]      = { 0x90,0x90,0x90,0x90,0x90,0x90 };
    static const uint8_t NOP2[]      = { 0x90,0x90 };

    patch_at(h, base, rIsCap, 0x48, STUB_TRUE, sizeof STUB_TRUE, "CCaptureSession::IsCaptureAllowed -> TRUE", quiet);
    patch_at(h, base, rEpc,   0x74, JMP1,      sizeof JMP1,      "CCaptureControl::ProcessGameEvents EPC je->jmp", quiet);
    patch_at(h, base, rTerm,  0x40, STUB_SOK,  sizeof STUB_SOK,  "CCaptureSession::TerminateCaptures stub", quiet);
    patch_at(h, base, rDis,   0x40, STUB_SOK,  sizeof STUB_SOK,  "CCaptureControl::DisableIR stub", quiet);
    patch_at(h, base, rGateA, 0x0F, NOP6,      sizeof NOP6,      "SaveInstantReplay gate A", quiet);
    patch_at(h, base, rGateB, 0x0F, NOP6,      sizeof NOP6,      "SaveInstantReplay gate B", quiet);
    patch_at(h, base, rRate,  0x74, NOP2,      sizeof NOP2,      "SaveInstantReplay rate-limit", quiet);
    patch_at(h, base, rSub,   0x74, NOP2,      sizeof NOP2,      "SaveInstantReplay sub-state gate", quiet);
    return 0;
}

/* ----------------------------------------------------------------------
 * Target selection
 * ---------------------------------------------------------------------- */

typedef struct {
    DWORD   pid;
    wchar_t cmdline[CMDLINE_MAX_CHARS];
    int     has_cmdline;
    int     has_nvd3dumx;
    int     has_nvspcaps64;
} Candidate;

static size_t collect_candidates(Candidate *c, size_t cap) {
    DWORD pids[MAX_PIDS];
    size_t n = find_pids_by_name(L"nvcontainer.exe", pids, MAX_PIDS);
    if (n > cap) n = cap;
    for (size_t i = 0; i < n; i++) {
        c[i].pid = pids[i];
        c[i].has_cmdline = (get_process_cmdline(pids[i], c[i].cmdline, CMDLINE_MAX_CHARS) == 0);
        if (!c[i].has_cmdline) c[i].cmdline[0] = L'\0';
        c[i].has_nvd3dumx   = pid_has_module(pids[i], L"nvd3dumx.dll");
        c[i].has_nvspcaps64 = pid_has_module(pids[i], L"_nvspcaps64.dll");
    }
    return n;
}

/* Returns target PID or 0. `reason` (if non-NULL) is filled with a short
 * string describing which strategy matched. */
static DWORD pick_target(const Candidate *c, size_t n, const char **reason) {
    static const struct { const wchar_t *needle; const char *desc; int loose; } strategies[] = {
        { L"\\plugins\\SPUser", "cmdline contains '\\plugins\\SPUser' (new NVIDIA App)", 0 },
        { L"SPUser",            "cmdline contains 'SPUser' (loose fallback)",            1 },
    };
    for (size_t s = 0; s < sizeof(strategies)/sizeof(strategies[0]); s++) {
        DWORD hit = 0; size_t matches = 0;
        for (size_t i = 0; i < n; i++) {
            if (c[i].has_cmdline && wstr_icontains(c[i].cmdline, strategies[s].needle)) {
                hit = c[i].pid; matches++;
            }
        }
        if (matches == 1) {
            if (reason) *reason = strategies[s].desc;
            return hit;
        }
        if (matches > 1) {
            if (reason) *reason = "ambiguous: multiple cmdline matches";
            return 0;
        }
    }
    /* Module-based fallbacks (original upstream heuristic + new-app variant) */
    {
        DWORD hit = 0; size_t matches = 0;
        for (size_t i = 0; i < n; i++) if (c[i].has_nvd3dumx) { hit = c[i].pid; matches++; }
        if (matches == 1) { if (reason) *reason = "module nvd3dumx.dll loaded"; return hit; }
    }
    {
        DWORD hit = 0; size_t matches = 0;
        for (size_t i = 0; i < n; i++) if (c[i].has_nvspcaps64) { hit = c[i].pid; matches++; }
        if (matches == 1) { if (reason) *reason = "module _nvspcaps64.dll loaded"; return hit; }
    }
    if (reason) *reason = "no strategy matched";
    return 0;
}

static void print_candidates(const Candidate *c, size_t n) {
    printf("Found %zu nvcontainer.exe process(es):\n", n);
    for (size_t i = 0; i < n; i++) {
        printf("  [%zu] PID %lu\n", i, (unsigned long)c[i].pid);
        if (c[i].has_cmdline) printf("       cmdline: %ls\n", c[i].cmdline);
        else                  printf("       cmdline: (access denied; likely SYSTEM-owned)\n");
        printf("       modules: nvd3dumx.dll=%s  _nvspcaps64.dll=%s\n",
               c[i].has_nvd3dumx ? "YES" : "no",
               c[i].has_nvspcaps64 ? "YES" : "no");
    }
}

/* ----------------------------------------------------------------------
 * Patching
 *
 * patch_function returns:
 *   0 if a fresh hook was placed and verified
 *   1 on hard error
 *   2 if the function was already patched (idempotent skip)
 *
 * The caller (and the watchdog) uses the (0 vs 2) distinction to keep idle
 * periodic re-runs quiet in the log.
 * ---------------------------------------------------------------------- */

static int patch_function(HANDLE hProc,
                          const wchar_t *module_name,
                          const char *func_name,
                          size_t overwrite_total,
                          int quiet) {
    uintptr_t base = remote_module_base(hProc, module_name);
    if (!base) { fprintf(stderr, "Error: could not get %ls base address\n", module_name); return 1; }
    if (!quiet) printf("Info: %ls base = 0x%llx\n", module_name, (unsigned long long)base);

    uintptr_t func = remote_export_addr(base, module_name, func_name);
    if (!func) { fprintf(stderr, "Error: could not resolve %s in %ls\n", func_name, module_name); return 1; }
    if (!quiet) printf("Info: %s = 0x%llx\n", func_name, (unsigned long long)func);

    uint8_t first = 0;
    if (read_remote(hProc, func, &first, 1) && first == 0xE9) {
        if (!quiet) printf("Info: %s already patched (JMP). Skipping.\n\n", func_name);
        return 2;
    }

    uintptr_t payload = alloc_near(hProc, func, ALLOC_SIZE);
    if (!payload) { fprintf(stderr, "Error: could not allocate near %s\n", func_name); return 1; }
    printf("Info: payload @ 0x%llx\n", (unsigned long long)payload);

    static const uint8_t PAYLOAD[] = { 0x48, 0x31, 0xC0, 0xC3 };  /* xor rax,rax ; ret */
    if (!write_remote_protected(hProc, payload, PAYLOAD, sizeof PAYLOAD)) {
        fprintf(stderr, "Error: could not write payload\n");
        return 1;
    }

    uint8_t hook[16] = {0};
    if (overwrite_total > sizeof hook) overwrite_total = sizeof hook;
    if (!asm_jmp_rel32(hook, func, payload)) {
        fprintf(stderr, "Error: payload too far for JMP rel32\n");
        return 1;
    }
    for (size_t i = 5; i < overwrite_total; ++i) hook[i] = 0x90;

    if (!write_remote_protected(hProc, func, hook, overwrite_total)) {
        fprintf(stderr, "Error: could not write hook at %s\n", func_name);
        return 1;
    }

    uint8_t verify[16] = {0};
    if (!read_remote(hProc, func, verify, overwrite_total) ||
        memcmp(verify, hook, overwrite_total) != 0) {
        fprintf(stderr, "Error: hook write at %s did not verify\n", func_name);
        return 1;
    }
    printf("Info: hook placed and verified at %s\n\n", func_name);
    return 0;
}

/* Hook an INTERNAL (non-exported) function inside a DLL loaded in a remote
 * process. RVA is the function's offset from its module base, identified
 * via string-xref analysis of the DLL's .text section.
 *
 * Payload makes the function immediately `return TRUE` (BOOL=1) — used to
 * neutralise NVIDIA's CCaptureSession::IsCaptureAllowed, which is the
 * decision function that returns FALSE when it sees "EPC" (Apple Music etc.)
 * or "MPC" running. Forcing TRUE means recording is always permitted.
 *
 * Verifies the function's actual prologue bytes match `expected_prologue`
 * before patching, so an NVIDIA driver/app update that shifts the function
 * gets refused rather than silently corrupting random code.
 *
 * Returns 0 on fresh hook, 2 if already patched, 1 on any error/mismatch. */
static int patch_internal_function_return_true(HANDLE hProc,
                                                const wchar_t *module_name,
                                                uintptr_t rva,
                                                const uint8_t *expected_prologue,
                                                size_t expected_len,
                                                size_t overwrite_total,
                                                const char *label,
                                                int quiet) {
    uintptr_t base = remote_module_base(hProc, module_name);
    if (!base) {
        if (!quiet) fprintf(stderr, "Error: could not find %ls in remote process\n", module_name);
        return 1;
    }
    uintptr_t func = base + rva;
    if (!quiet) printf("Info: %s @ %ls + 0x%llx = 0x%llx\n",
                       label, module_name, (unsigned long long)rva, (unsigned long long)func);

    uint8_t first[16] = {0};
    if (!read_remote(hProc, func, first, sizeof first)) {
        if (!quiet) fprintf(stderr, "Error: could not read %s prologue\n", label);
        return 1;
    }
    if (first[0] == 0xE9) {
        if (!quiet) printf("Info: %s already patched (JMP). Skipping.\n", label);
        return 2;
    }
    if (expected_len > 0 && memcmp(first, expected_prologue, expected_len) != 0) {
        if (!quiet) {
            fprintf(stderr, "Warn: %s prologue does NOT match expected bytes — refusing to patch.\n", label);
            fprintf(stderr, "  This likely means NVIDIA updated the DLL; the function may have moved.\n");
            fprintf(stderr, "  Expected: ");
            for (size_t i = 0; i < expected_len; i++) fprintf(stderr, "%02X ", expected_prologue[i]);
            fprintf(stderr, "\n  Actual:   ");
            for (size_t i = 0; i < expected_len; i++) fprintf(stderr, "%02X ", first[i]);
            fprintf(stderr, "\n");
        }
        return 1;
    }

    uintptr_t payload = alloc_near(hProc, func, ALLOC_SIZE);
    if (!payload) {
        if (!quiet) fprintf(stderr, "Error: could not allocate near %s\n", label);
        return 1;
    }

    /* mov eax, 1 ; ret  -> returns TRUE in BOOL (eax) */
    static const uint8_t PAYLOAD_TRUE[] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
    if (!write_remote_protected(hProc, payload, PAYLOAD_TRUE, sizeof PAYLOAD_TRUE)) {
        if (!quiet) fprintf(stderr, "Error: could not write TRUE payload for %s\n", label);
        return 1;
    }

    uint8_t hook[16] = {0};
    if (overwrite_total > sizeof hook) overwrite_total = sizeof hook;
    if (!asm_jmp_rel32(hook, func, payload)) {
        if (!quiet) fprintf(stderr, "Error: payload too far for JMP rel32 (%s)\n", label);
        return 1;
    }
    for (size_t i = 5; i < overwrite_total; i++) hook[i] = 0x90;

    if (!write_remote_protected(hProc, func, hook, overwrite_total)) {
        if (!quiet) fprintf(stderr, "Error: could not write hook at %s\n", label);
        return 1;
    }

    uint8_t verify[16] = {0};
    if (!read_remote(hProc, func, verify, overwrite_total) ||
        memcmp(verify, hook, overwrite_total) != 0) {
        if (!quiet) fprintf(stderr, "Error: %s hook did not verify\n", label);
        return 1;
    }
    printf("Info: %s hooked to always return TRUE.\n", label);
    return 0;
}

/* Replace N bytes at <module>+rva after verifying that a known signature
 * is present at that location. Variant of patch_byte_signature for cases
 * where we need to write more than one byte (e.g. overwriting a function
 * prologue with `xor eax,eax; ret`). new_len must be <= sig_len. */
static int patch_bytes_at_rva(HANDLE hProc,
                              const wchar_t *module_name,
                              uintptr_t rva,
                              const uint8_t *expected_sig, size_t sig_len,
                              const uint8_t *new_bytes, size_t new_len,
                              const char *label, int quiet) {
    uintptr_t base = remote_module_base(hProc, module_name);
    if (!base) {
        if (!quiet) fprintf(stderr, "Error: could not find %ls in remote process\n", module_name);
        return 1;
    }
    uintptr_t target = base + rva;
    if (!quiet) printf("Info: %s @ %ls + 0x%llx = 0x%llx\n",
                       label, module_name, (unsigned long long)rva, (unsigned long long)target);

    uint8_t found[64] = {0};
    if (sig_len > sizeof found) sig_len = sizeof found;
    if (new_len > sig_len)      new_len = sig_len;
    if (!read_remote(hProc, target, found, sig_len)) {
        if (!quiet) fprintf(stderr, "Error: could not read %s signature\n", label);
        return 1;
    }
    if (memcmp(found, new_bytes, new_len) == 0) {
        if (!quiet) printf("Info: %s already patched. Skipping.\n", label);
        return 2;
    }
    if (memcmp(found, expected_sig, sig_len) != 0) {
        if (!quiet) {
            fprintf(stderr, "Warn: %s signature mismatch - refusing to patch.\n", label);
            fprintf(stderr, "  Expected: ");
            for (size_t i = 0; i < sig_len; i++) fprintf(stderr, "%02X ", expected_sig[i]);
            fprintf(stderr, "\n  Actual:   ");
            for (size_t i = 0; i < sig_len; i++) fprintf(stderr, "%02X ", found[i]);
            fprintf(stderr, "\n");
        }
        return 1;
    }
    if (!write_remote_protected(hProc, target, new_bytes, new_len)) {
        if (!quiet) fprintf(stderr, "Error: could not write payload for %s\n", label);
        return 1;
    }
    uint8_t verify[64] = {0};
    if (!read_remote(hProc, target, verify, new_len) ||
        memcmp(verify, new_bytes, new_len) != 0) {
        if (!quiet) fprintf(stderr, "Error: %s patch did not verify\n", label);
        return 1;
    }
    printf("Info: %s patched (%zu bytes overwritten).\n", label, new_len);
    return 0;
}

/* Replace a single byte at <module>+rva after verifying that a known signature
 * is present at that location. Used for surgical "flip JCC to unconditional
 * JMP" patches where we just want to short-circuit a single conditional
 * without rewriting the function.
 *
 * Returns: 0 fresh patch, 2 already patched (byte already == new_byte),
 *          1 on error / signature mismatch. */
static int patch_byte_signature(HANDLE hProc,
                                 const wchar_t *module_name,
                                 uintptr_t rva,
                                 const uint8_t *expected_sig, size_t sig_len,
                                 uint8_t new_byte,
                                 const char *label,
                                 int quiet) {
    uintptr_t base = remote_module_base(hProc, module_name);
    if (!base) {
        if (!quiet) fprintf(stderr, "Error: could not find %ls in remote process\n", module_name);
        return 1;
    }
    uintptr_t target = base + rva;
    if (!quiet) printf("Info: %s @ %ls + 0x%llx = 0x%llx\n",
                       label, module_name, (unsigned long long)rva, (unsigned long long)target);

    uint8_t found[32] = {0};
    if (sig_len > sizeof found) sig_len = sizeof found;
    if (!read_remote(hProc, target, found, sig_len)) {
        if (!quiet) fprintf(stderr, "Error: could not read %s signature\n", label);
        return 1;
    }
    if (found[0] == new_byte) {
        if (!quiet) printf("Info: %s already patched (byte == 0x%02X). Skipping.\n", label, new_byte);
        return 2;
    }
    if (memcmp(found, expected_sig, sig_len) != 0) {
        if (!quiet) {
            fprintf(stderr, "Warn: %s signature mismatch - refusing to patch.\n", label);
            fprintf(stderr, "  Expected: ");
            for (size_t i = 0; i < sig_len; i++) fprintf(stderr, "%02X ", expected_sig[i]);
            fprintf(stderr, "\n  Actual:   ");
            for (size_t i = 0; i < sig_len; i++) fprintf(stderr, "%02X ", found[i]);
            fprintf(stderr, "\n");
        }
        return 1;
    }

    if (!write_remote_protected(hProc, target, &new_byte, 1)) {
        if (!quiet) fprintf(stderr, "Error: could not write byte for %s\n", label);
        return 1;
    }

    uint8_t verify = 0;
    if (!read_remote(hProc, target, &verify, 1) || verify != new_byte) {
        if (!quiet) fprintf(stderr, "Error: %s patch did not verify (read 0x%02X, want 0x%02X)\n",
                            label, verify, new_byte);
        return 1;
    }
    printf("Info: %s patched (0x%02X -> 0x%02X) — EPC teardown branch now skipped.\n",
           label, expected_sig[0], new_byte);
    return 0;
}

/* Apply both hooks to the SPUser nvcontainer. Returns:
 *   0 if at least one hook was freshly placed
 *   2 if both hooks were already present (idempotent quiet path)
 *   1 if anything failed
 * `quiet` suppresses info-level output (used by the watchdog periodic check). */
static int apply_spuser_hooks(int quiet) {
    Candidate *cands = (Candidate*)calloc(MAX_PIDS, sizeof(Candidate));
    if (!cands) return 1;
    size_t n = collect_candidates(cands, MAX_PIDS);
    const char *reason = NULL;
    DWORD target = pick_target(cands, n, &reason);
    free(cands);

    if (!target) {
        if (!quiet) fprintf(stderr, "Warn: SPUser nvcontainer not found (%s)\n", reason ? reason : "");
        return 1;
    }
    HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, target);
    if (!h) {
        if (!quiet) fprintf(stderr, "Warn: OpenProcess(PID=%lu) failed (0x%lx)\n",
                            (unsigned long)target, (unsigned long)GetLastError());
        return 1;
    }
    int r1 = patch_function(h, L"USER32.dll",   "GetWindowDisplayAffinity", 6, quiet);
    int r2 = (r1 == 1) ? 1
                       : patch_function(h, L"KERNEL32.DLL", "Module32FirstW",  7, quiet);
    int r3 = (r2 == 1) ? 1
                       : patch_function(h, L"KERNEL32.DLL", "Process32FirstW", 7, quiet);
    /* VerQueryValueW: confirmed by strings analysis of _nvspcaps64.dll - the
     * function WindowManager::GetProtectedContentAppDetails uses this Win32
     * API to read ProductName/CompanyName from a target app's PE version
     * info, then string-matches against a protected-app list (Apple Music,
     * Netflix UWP, etc.). Forcing it to return FALSE means NVIDIA can never
     * resolve any app's identity -> nothing matches the protected list ->
     * IR isn't paused. This is the fix for Apple Music. */
    int r4 = (r3 == 1) ? 1
                       : patch_function(h, L"VERSION.DLL", "VerQueryValueW",  6, quiet);
    /* IsImmersiveProcess: USER32 Win32 API that returns TRUE for UWP /
     * AppContainer processes. Confirmed by strings analysis - NVIDIA calls
     * this on every enumerated window's owning process. Apple Music is UWP,
     * so it returns TRUE -> NVIDIA flags it as protected -> IR pauses.
     * Force FALSE here and NVIDIA cannot identify Apple Music (or Netflix
     * UWP, Disney+, Hulu UWP, etc.) as a UWP app. */
    int r5 = (r4 == 1) ? 1
                       : patch_function(h, L"USER32.dll",  "IsImmersiveProcess", 6, quiet);

    /* SUSTAINABILITY: apply the internal _nvspcaps64.dll hooks via the runtime
     * resolver, which locates each function by a stable NVIDIA log-string anchor
     * (not a hardcoded RVA) and self-heals across NVIDIA App updates. The legacy
     * hardcoded patch_*() calls below are kept as a redundant secondary fallback:
     * once the resolver has patched a site, they see the changed bytes and skip on
     * signature-mismatch, so there is no double-patch. */
    apply_internal_nvsp_hooks(h, quiet);

    /* CCaptureSession::IsCaptureAllowed - internal function inside
     * _nvspcaps64.dll that returns BOOL. We located its RVA via string-xref
     * analysis of the EPC/MPC log strings. This is the actual decision
     * function NVIDIA calls before allowing a capture to proceed. Forcing
     * it to return TRUE means NVIDIA always permits recording regardless
     * of what its detection logic concluded.
     * Prologue check protects against blindly patching the wrong code if
     * NVIDIA updates the DLL. */
    static const uint8_t PROLOGUE_ISCAPTURE[] = {
        0x48, 0x89, 0x5C, 0x24, 0x08,   /* mov [rsp+8], rbx  */
        0x48, 0x89, 0x74, 0x24, 0x10    /* mov [rsp+10h], rsi */
    };
    int r6 = (r5 == 1) ? 1
                       : patch_internal_function_return_true(h, L"_nvspcaps64.dll",
                            0xA69B0, PROLOGUE_ISCAPTURE, sizeof PROLOGUE_ISCAPTURE,
                            6, "CCaptureSession::IsCaptureAllowed", quiet);
    /* Hook 7 (IsCaptureAllowedOld) was REMOVED in _nvspcaps64.dll 11.0.8.244 —
     * the function no longer exists (refactored/inlined; its log strings are now
     * unreferenced dead data). Mirror r6 so the chain is unaffected. */
    int r7 = r6;

    /* CCaptureControl::ProcessGameEvents EPC-branch nop.
     *
     * Identified by string-xref analysis: the function references the log
     * string "CCaptureControl::ProcessGameEvents: EPC found, terminating
     * captures!!" at +0x4F0 inside the function. The basic block that emits
     * that log line is gated by a single `je` at RVA 0x9832B:
     *
     *   98329: 84 C0          test al, al        ; al = "is EPC present?"
     *   9832B: 74 72          je   0x9839F       ; if !al, skip teardown
     *   9832D: ... log "EPC found, terminating captures!!"
     *   98364: e8 b9 19 f7 ff call <TerminateCaptures>   ; kills NVENC
     *
     * Flipping the `je` (0x74) to `jmp` (0xEB) makes the skip unconditional,
     * so the EPC teardown call is never reached regardless of the detector's
     * verdict. This is the surgical fix for Apple Music killing the encoder
     * 5 s after focus — debug-monitor logs proved that NVENC sessions drop
     * to 0 silently when this path runs, with NO registry writes our other
     * hooks could intercept. One byte at one address solves it.
     *
     * Signature (12 bytes from 0x9832B): 74 72 C7 05 79 EF 2B 00 06 00 00 00
     * — the je itself plus the unmistakable
     *   `mov dword [rip+0x2bef79], 6` (logging-level setup) that immediately
     * follows. Picked because it's a unique sequence inside _nvspcaps64.dll. */
    /* 11.0.8.244: the je is now at RVA 0x98EEB and the bytes after it differ
     * from .247, so the old 12-byte signature (with the mov dword [rip+..],6
     * tail) no longer matches. The verified site is the je itself (74 72); only
     * byte 0 is flipped to 0xEB, so a 2-byte signature is sufficient and safe. */
    static const uint8_t SIG_EPC_BRANCH[] = {
        0x74, 0x72                                      /* je rel8 +0x72  */
    };
    int r8 = (r7 == 1) ? 1
                       : patch_byte_signature(h, L"_nvspcaps64.dll",
                            0x98EEB, SIG_EPC_BRANCH, sizeof SIG_EPC_BRANCH,
                            0xEB, "CCaptureControl::ProcessGameEvents EPC-branch", quiet);

    /* CCaptureSession::TerminateCaptures stubbed to `xor eax, eax; ret`.
     *
     * Evidence that hook 8 alone is insufficient: deployment-and-test cycle
     * confirmed hook 8 stops the registry-flag write path (no more BLOCKED
     * events) AND stops the EPC log line, but NVENC sessions still drop to
     * 0 ~3 s after Apple Music gains focus. So there's a SECOND teardown
     * path that doesn't route through ProcessGameEvents::EPC.
     *
     * TerminateCaptures (identified via string-xref to "::TerminateCaptures"
     * + "StopDVRCapture" inside a 242-byte function) is the chokepoint —
     * every legitimate AND DRM-triggered teardown calls it eventually. By
     * overwriting its prologue with `33 C0 C3` (xor eax,eax; ret), every
     * call returns S_OK immediately and no NVENC encoder gets torn down.
     *
     * Tradeoff: user-initiated "disable IR" via the overlay toggle ALSO
     * routes through this and will silently fail (the registry write still
     * happens but the in-memory capture session never tears down). User can
     * still fully disable IR via the NVIDIA App settings page, which goes
     * through a different code path. For an always-on-IR setup this is the
     * correct trade.
     *
     * Signature (16 bytes from 0xAA990): 40 53 48 81 EC D0 08 00 00 48 8B
     *                                    D9 C7 44 24 20
     * — REX.W push rbx; sub rsp,0x8D0; mov rbx,rcx; mov dword [rsp+20],0 */
    static const uint8_t SIG_TERMCAPS[] = {
        0x40, 0x53,                                     /* push rbx        */
        0x48, 0x81, 0xEC, 0xD0, 0x08, 0x00, 0x00,       /* sub rsp, 0x8D0  */
        0x48, 0x8B, 0xD9,                               /* mov rbx, rcx    */
        0xC7, 0x44, 0x24, 0x20                          /* mov [rsp+20], … */
    };
    static const uint8_t PAYLOAD_RETURN_SOK[] = {
        0x33, 0xC0,                                     /* xor eax, eax    */
        0xC3                                            /* ret             */
    };
    int r9 = (r8 == 1) ? 1
                       : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                            0xAB5B0, SIG_TERMCAPS, sizeof SIG_TERMCAPS,
                            PAYLOAD_RETURN_SOK, sizeof PAYLOAD_RETURN_SOK,
                            "CCaptureSession::TerminateCaptures stub", quiet);

    /* CCaptureControl::DisableIR stubbed to `xor eax, eax; ret`.
     *
     * Hook 9 (TerminateCaptures) didn't stop NVENC from dropping when Apple
     * Music opens — verified via in-memory byte check + still seeing NVENC
     * sessions=0 within ~5s. Disassembly of _nvspcaps64.dll then turned up
     * a tiny 102-byte function named CCaptureControl::DisableIR whose log
     * string is LITERALLY "Auto-Disable IR Session". The body:
     *
     *     push rbx; sub rsp, 0x20
     *     [log "Auto-Disable IR Session"]
     *     mov rcx, [rbx + 0x88]      ; some sub-component pointer
     *     test rcx, rcx; je skip
     *     call <state-mutator>       ; flips state on the sub-component
     *   skip:
     *     mov edx, 0xCA              ; event code = 0xCA
     *     mov rcx, rbx
     *     call 0x9d22                ; dispatcher — same one the EPC branch used
     *     xor eax, eax; ret
     *
     * Whatever triggers protected-content detection (the periodic poll or
     * the LocalSystem-side IPC handler) eventually lands here. Patching
     * the prologue to "xor eax,eax; ret" makes every entry point that
     * leads to this function return S_OK without touching the encoder.
     *
     * Signature (16 bytes from 0x92CA0): 40 53 48 83 EC 20 83 3D 3F 47 2C
     *                                    00 06 48 8B D9
     * — push rbx; sub rsp,0x20; cmp dword [rip+0x2c473f],6; mov rbx,rcx */
    static const uint8_t SIG_DISABLEIR[] = {
        0x40, 0x53,                                     /* push rbx        */
        0x48, 0x83, 0xEC, 0x20,                         /* sub rsp, 0x20   */
        0x83, 0x3D, 0x9F, 0x6B, 0x2C, 0x00, 0x06,       /* cmp dword [rip+disp], 6  (disp updated for 11.0.8.244) */
        0x48, 0x8B, 0xD9                                /* mov rbx, rcx    */
    };
    int r10 = (r9 == 1) ? 1
                        : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                             0x93840, SIG_DISABLEIR, sizeof SIG_DISABLEIR,
                             PAYLOAD_RETURN_SOK, sizeof PAYLOAD_RETURN_SOK,
                             "CCaptureControl::DisableIR stub", quiet);

    /* SaveInstantReplay protection gates NOP-out.
     *
     * Hook 10 keeps IR alive when Apple Music opens, but Alt+F10 still
     * gets refused while the DRM app is in focus. Disassembly of
     * CCaptureSession::SaveInstantReplay (RVA 0xA83E0) reveals two
     * back-to-back guard conditionals immediately after the obvious
     * argument validation, just before the actual save work:
     *
     *   A84C6: 80 79 01 00      cmp byte [rcx+1], 0     ; rcx = this->m_pState
     *   A84CA: 0F 84 2B 02 ...  je 0xa86fb              ; bail (silent)
     *   A84D0: 83 BF E4 26 ...  cmp dword [rdi+0x26e4], 0  ; "IR active" flag
     *   A84D7: 0F 84 40 02 ...  je 0xa871d              ; bail w/ "IR not enabled" log
     *
     * NOPing both 6-byte JE instructions makes the save proceed even
     * when one or both of those flags are zero — the state NVIDIA puts
     * the session into when DRM is detected. The actual save logic
     * after them (resolve deltas, refresh settings, encode to file)
     * has its own NULL-pointer checks that aren't gated on protection. */
    static const uint8_t SIG_SAVEIR_GATE_A[] = { 0x0F, 0x84, 0x35, 0x02, 0x00, 0x00 };
    static const uint8_t SIG_SAVEIR_GATE_B[] = { 0x0F, 0x84, 0x40, 0x02, 0x00, 0x00 };
    static const uint8_t NOP6[]              = { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    int r11a = (r10 == 1) ? 1
                          : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                               0xA90E0, SIG_SAVEIR_GATE_A, sizeof SIG_SAVEIR_GATE_A,
                               NOP6, sizeof NOP6,
                               "SaveInstantReplay gate A (NULL-able state byte)", quiet);
    int r11b = (r11a == 1) ? 1
                           : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                                0xA90F7, SIG_SAVEIR_GATE_B, sizeof SIG_SAVEIR_GATE_B,
                                NOP6, sizeof NOP6,
                                "SaveInstantReplay gate B (IR not enabled)", quiet);

    /* NvFBCCore::CheckGrabInfo (NvFBC64.dll RVA 0x2AEA0) stubbed to return S_OK.
     *
     * The frame-freeze during Apple Music isn't in _nvspcaps64.dll — it's
     * one layer down in NvFBC, NVIDIA's low-level frame-buffer-capture DLL.
     * NvFBC grabs the frame from the GPU and CheckGrabInfo validates it.
     * When NVIDIA's kernel-mode driver flags the capture with grab-error
     * code 0xfbcb0001 ("protected content playback in progress"),
     * CheckGrabInfo logs the message and returns an error HRESULT. The
     * upstream capture loop in _nvspcaps64.dll then refuses to submit the
     * frame to NVENC, which keeps re-encoding its last input — that's the
     * frozen-screen-during-Apple-Music symptom.
     *
     * Forcing CheckGrabInfo to return 0 (S_OK) makes every grabbed frame
     * pass validation. Since NvFBC (unlike DXGI Desktop Duplication) reads
     * the GPU framebuffer directly without going through DWM's
     * protected-output blanking, the actual frame contents should make
     * it through to NVENC for real recording of Apple Music's UI.
     *
     * Signature (10 bytes from 0x2AEA0): 48 89 5C 24 18 55 56 57 41 54
     * — mov [rsp+18h], rbx; push rbp; push rsi; push rdi; push r12; push r13 */
    static const uint8_t SIG_CHECKGRAB[] = {
        0x48, 0x89, 0x5C, 0x24, 0x18,                   /* mov [rsp+18h], rbx */
        0x55, 0x56, 0x57,                               /* push rbp/rsi/rdi   */
        0x41, 0x54                                      /* push r12           */
    };
    int r12 = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"NvFBC64.dll",
                               0x2AEA0, SIG_CHECKGRAB, sizeof SIG_CHECKGRAB,
                               PAYLOAD_RETURN_SOK, sizeof PAYLOAD_RETURN_SOK,
                               "NvFBCCore::CheckGrabInfo stub", quiet);

    /* Hook 13: SaveInstantReplay second-save unlock.
     *
     * Hook 11 lets the first Alt+F10 during a DRM session succeed, but
     * subsequent saves in the same Apple Music session still fail.
     * Disasm past the hook-11 NOPs reveals two more skip-jumps just
     * before the actual save call (call 0x43AE at 0xA8616):
     *
     *   A85C0: movsxd rdx, [rdi + 0x26e4]   ; old "save active" state
     *   A85C7: mov dword [rdi + 0x26e4], 1  ; flag this save active
     *   A85D1: cmp edx, 1                   ; was it ALREADY 1?
     *   A85D4: 74 45  je 0xA861B            ; YES → skip save call (RATE LIMIT)
     *   A85D6: mov rax, [rdi + 0x2720]
     *   A85DD: test rax, rax; je ...        ; NULL ptr check — LEGIT, leave it
     *   A85E2: cmp byte [rax+1], 0
     *   A85E6: 74 33  je 0xA861B            ; sub-state byte == 0 → skip
     *   A85E8: ... (actual save call)
     *
     * NOPing the two je's removes both gates. The state writeback at
     * A85C7 still happens, but it no longer determines whether the save
     * runs. */
    static const uint8_t SIG_SAVEIR_RATELIMIT[] = { 0x74, 0x45 };   /* je rel8 +0x45 → 0xA861B */
    static const uint8_t SIG_SAVEIR_SUBSTATE[]  = { 0x74, 0x33 };   /* je rel8 +0x33 → 0xA861B */
    static const uint8_t NOP2[]                 = { 0x90, 0x90 };
    /* Gate on r11b (the last _nvspcaps64 hook), NOT r12: hooks 13a/13b live in
     * _nvspcaps64.dll and are independent of NvFBC64.dll. NvFBC64 only loads
     * while IR is actively recording, so gating 13 on the NvFBC64 hook (12)
     * silently skipped the SaveInstantReplay rate-limit/sub-state unlocks
     * whenever IR wasn't recording at patch time. */
    int r13a = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                               0xA91F4, SIG_SAVEIR_RATELIMIT, sizeof SIG_SAVEIR_RATELIMIT,
                               NOP2, sizeof NOP2,
                               "SaveInstantReplay rate-limit (one-shot per session)", quiet);
    int r13b = (r13a == 1) ? 1
                           : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                                0xA9206, SIG_SAVEIR_SUBSTATE, sizeof SIG_SAVEIR_SUBSTATE,
                                NOP2, sizeof NOP2,
                                "SaveInstantReplay sub-state byte gate", quiet);

    /* Hook 14: NvFBCCoprocHelper::doGdiDesktopCapture protected-branch flip.
     *
     * Long-shot frame-freeze fix. Disasm of this function (RVA 0x42400 in
     * NvFBC64.dll, 5937 bytes) shows the protected gate at +0x42AD3:
     *
     *   42ACA: cmp qword [rsp+0x4c8], 0   ; is protected-content flag set?
     *   42AD3: 74 40   je 0x42B15         ; if 0, skip protected branch → NORMAL CAPTURE
     *   42AD5: lea r8, "Protected content."
     *   42AE9: call <logger>
     *   42AF8: mov ebx, 0xFFFFFFFC        ; error return
     *   42B10: jmp 0x4398B                ; exit with error
     *   42B15: ... GDI desktop capture (BitBlt etc.) ...
     *
     * Flipping `je 0x42B15` (74 40) → `jmp 0x42B15` (EB 40) forces NvFBC to
     * always run the GDI capture path, regardless of the protected flag.
     *
     * Honest caveat: GDI's BitBlt on a desktop containing protected content
     * may still return blanked regions per Windows policy. If this works at
     * all, the recorded video will either show real Apple Music content
     * (jackpot) or black frames where the UI was (still better than frozen,
     * proves the path runs). */
    static const uint8_t SIG_GDI_PROTECTED[] = { 0x74, 0x40 };
    static const uint8_t SIG_GDI_JMP[]       = { 0xEB, 0x40 };
    /* Best-effort NvFBC64 hook, independent of the _nvspcaps64 save hooks.
     * Gate on r11b only so a missing/unloaded NvFBC64 never blocks anything. */
    int r14 = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"NvFBC64.dll",
                               0x42AD3, SIG_GDI_PROTECTED, sizeof SIG_GDI_PROTECTED,
                               SIG_GDI_JMP, sizeof SIG_GDI_JMP,
                               "doGdiDesktopCapture protected-branch je->jmp", quiet);

    CloseHandle(h);
    if (r1 == 1 || r2 == 1 || r3 == 1 || r4 == 1 || r5 == 1 || r6 == 1 || r7 == 1
        || r8 == 1 || r9 == 1 || r10 == 1 || r11a == 1 || r11b == 1 || r12 == 1
        || r13a == 1 || r13b == 1 || r14 == 1) return 1;
    if (r1 == 2 && r2 == 2 && r3 == 2 && r4 == 2 && r5 == 2 && r6 == 2 && r7 == 2
        && r8 == 2 && r9 == 2 && r10 == 2 && r11a == 2 && r11b == 2 && r12 == 2
        && r13a == 2 && r13b == 2 && r14 == 2) return 2;
    return 0;
}

/* Auxiliary "protected-app" detection seen in the new NVIDIA App lives in the
 * UI process (NVIDIA Overlay.exe / NVIDIA App.exe / NVDisplay.Container.exe).
 * These call USER32!GetWindowDisplayAffinity directly on foreground windows
 * and pop up "A protected app is preventing desktop capture" when they see
 * WDA_MONITOR on apps like Apple Music or DRM Netflix.
 *
 * Hook *only* GetWindowDisplayAffinity in these processes — they legitimately
 * use Module32FirstW for their own module discovery (CEF child setup, plugin
 * loading, etc.), so we don't touch that one. Best-effort: silently skip
 * processes we can't access, and skip ones we've already patched. */
static const wchar_t *AUX_TARGET_NAMES[] = {
    L"NVIDIA Overlay.exe",
    L"NVIDIA app.exe",            /* lowercase 'app' in current builds */
    L"NVIDIA App.exe",            /* future-proof */
    L"NVDisplay.Container.exe",
};
static const size_t N_AUX_TARGETS = sizeof(AUX_TARGET_NAMES)/sizeof(AUX_TARGET_NAMES[0]);

/* Returns: count of processes freshly patched (0 means nothing changed). */
static int apply_aux_hooks(int quiet) {
    int fresh = 0;
    DWORD pids[MAX_PIDS];
    for (size_t t = 0; t < N_AUX_TARGETS; t++) {
        size_t n = find_pids_by_name(AUX_TARGET_NAMES[t], pids, MAX_PIDS);
        for (size_t i = 0; i < n; i++) {
            HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pids[i]);
            if (!h) continue;  /* SYSTEM-owned, sandboxed CEF child, etc. */
            int r = patch_function(h, L"USER32.dll", "GetWindowDisplayAffinity", 6, quiet);
            CloseHandle(h);
            if (r == 0) {
                fresh++;
                if (!quiet) printf("Info: aux hook placed in %ls (PID %lu)\n",
                                   AUX_TARGET_NAMES[t], (unsigned long)pids[i]);
            }
        }
    }
    return fresh;
}

/* Hook 15: MFRequireProtectedEnvironment in Apple Music.
 *
 * Frame-freeze fix attempt that targets the SOURCE of the protected-content
 * tag, not the consumer side. When Apple Music starts a song it asks
 * MediaFoundation whether the topology contains protected content via
 * mfcore!MFRequireProtectedEnvironment, which returns:
 *   S_OK     (0x00000000) -> protected, MF spawns the PMP host
 *   S_FALSE  (0x00000001) -> not protected, normal pipeline, no surface tag
 *
 * If we force S_FALSE inside Apple Music's own address space, MF never
 * enables PMP for this topology. No PMP -> no protected surface tag ->
 * DWM doesn't tell the kernel to blank the region -> NvFBC sees real
 * pixels.
 *
 * Caveat: Apple Music's DRM server may decline to deliver unprotected
 * playback, in which case the song simply won't play. Reversible: undo
 * the 6-byte patch and PMP is back on. We patch the function body
 * (not the export thunk) at mfcore.dll RVA 0x6EC80; the exported symbol
 * MFRequireProtectedEnvironment sits at 0x5DED0 as a jmp into 0x6EC80.
 *
 * Apple Music is a UWP AppContainer process but is NOT a Protected
 * Process Light, so OpenProcess(PROCESS_ALL_ACCESS) from our elevated
 * patcher works the same way it does for nvcontainer. mfcore.dll is
 * lazy-loaded on first playback, so this hook may report "not loaded"
 * at idle - the watchdog loop will retry on every 30s tick. */
/* Helper: force-load a module by name into a remote process via
 * CreateRemoteThread(LoadLibraryW, name). The module must be findable
 * on the standard DLL search path of the target process (so this works
 * for any DLL the target would normally be able to LoadLibrary). Returns
 * 1 on success, 0 on failure. */
static int force_load_module_remote(HANDLE hProc, const wchar_t *module_name) {
    SIZE_T mod_bytes = (wcslen(module_name) + 1) * sizeof(wchar_t);
    LPVOID remote_str = VirtualAllocEx(hProc, NULL, mod_bytes,
                                       MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote_str) return 0;

    SIZE_T written = 0;
    if (!WriteProcessMemory(hProc, remote_str, module_name, mod_bytes, &written) ||
        written != mod_bytes) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }

    /* LoadLibraryW lives in kernel32 at the same address in every x64 process
     * on a given Windows session (ASLR randomizes kernel32 once per boot,
     * shared across all processes). */
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    LPTHREAD_START_ROUTINE pLLW =
        (LPTHREAD_START_ROUTINE)(uintptr_t)GetProcAddress(k32, "LoadLibraryW");
    if (!pLLW) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }

    HANDLE hThread = CreateRemoteThread(hProc, NULL, 0, pLLW, remote_str, 0, NULL);
    if (!hThread) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }
    WaitForSingleObject(hThread, 10000);  /* 10s ceiling */
    DWORD exit_code = 0;
    GetExitCodeThread(hThread, &exit_code);
    CloseHandle(hThread);
    VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
    /* LoadLibraryW returns HMODULE; non-zero == success. We ignore truncation
     * on 64-bit since DWORD vs HMODULE doesn't matter for the 0/non-0 check. */
    return exit_code != 0;
}

/* Backwards-compatible shim. */
static int force_load_mfcore_remote(HANDLE hProc) {
    return force_load_module_remote(hProc, L"mfcore.dll");
}

/* Inject a DLL by absolute path into a remote process via
 * CreateRemoteThread(LoadLibraryW, full_path). The remote process's
 * loader maps the DLL and runs its DllMain (DLL_PROCESS_ATTACH).
 *
 * If the DLL is already loaded in the target, this is effectively a
 * no-op (LoadLibrary returns the existing HMODULE without re-running
 * DllMain), which makes it idempotent.
 *
 * Returns 1 on success, 0 on failure. */
static int inject_dll_by_path(HANDLE hProc, const wchar_t *full_dll_path) {
    SIZE_T path_bytes = (wcslen(full_dll_path) + 1) * sizeof(wchar_t);
    LPVOID remote_str = VirtualAllocEx(hProc, NULL, path_bytes,
                                       MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote_str) return 0;

    SIZE_T written = 0;
    if (!WriteProcessMemory(hProc, remote_str, full_dll_path, path_bytes, &written)
        || written != path_bytes) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }

    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    LPTHREAD_START_ROUTINE pLLW =
        (LPTHREAD_START_ROUTINE)(uintptr_t)GetProcAddress(k32, "LoadLibraryW");
    if (!pLLW) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }

    HANDLE hThread = CreateRemoteThread(hProc, NULL, 0, pLLW, remote_str, 0, NULL);
    if (!hThread) {
        VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
        return 0;
    }
    WaitForSingleObject(hThread, 10000);
    DWORD exit_code = 0;
    GetExitCodeThread(hThread, &exit_code);
    CloseHandle(hThread);
    VirtualFreeEx(hProc, remote_str, 0, MEM_RELEASE);
    return exit_code != 0;
}

/* Find neuter_wda.dll next to our own exe. Caller must free the
 * returned buffer. Returns NULL if not found. */
static wchar_t *find_neuter_wda_path(void) {
    wchar_t exe_path[MAX_PATH];
    DWORD n = GetModuleFileNameW(NULL, exe_path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return NULL;

    /* Strip the exe filename, append "neuter_wda.dll". */
    for (DWORD i = n; i > 0; i--) {
        if (exe_path[i-1] == L'\\' || exe_path[i-1] == L'/') {
            exe_path[i] = 0;
            break;
        }
    }
    static const wchar_t DLL_NAME[] = L"neuter_wda.dll";
    size_t need = wcslen(exe_path) + wcslen(DLL_NAME) + 1;
    wchar_t *full = (wchar_t*)malloc(need * sizeof(wchar_t));
    if (!full) return NULL;
    wcscpy(full, exe_path);
    wcscat(full, DLL_NAME);

    DWORD attrs = GetFileAttributesW(full);
    if (attrs == INVALID_FILE_ATTRIBUTES || (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
        free(full);
        return NULL;
    }
    return full;
}

/* Hook 17: inject neuter_wda.dll into every running AppleMusic.exe
 * (and any other process name the caller passes in). The DLL clears
 * existing display affinity on all top-level windows of the process,
 * then patches user32!SetWindowDisplayAffinity and
 * win32u!NtUserSetWindowDisplayAffinity to no-ops.
 *
 * Returns: count of PIDs we injected into this call. Idempotent —
 * re-injecting on a process that already has the DLL is harmless
 * (LoadLibrary returns the existing module without re-running
 * DllMain). */
static int inject_neuter_wda_into(const wchar_t *process_name, int quiet) {
    wchar_t *dll_path = find_neuter_wda_path();
    if (!dll_path) {
        if (!quiet) fprintf(stderr,
            "Warn: neuter_wda.dll not found next to patcher exe; skipping hook 17\n");
        return 0;
    }
    DWORD pids[MAX_PIDS];
    size_t n = find_pids_by_name(process_name, pids, MAX_PIDS);
    if (!quiet && n > 0) printf("Info: hook 17: found %zu %ls\n", n, process_name);
    int injected = 0;
    for (size_t i = 0; i < n; i++) {
        HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pids[i]);
        if (!h) {
            if (!quiet) fprintf(stderr,
                "Warn: %ls (PID %lu): OpenProcess failed (%lu)\n",
                process_name, (unsigned long)pids[i], GetLastError());
            continue;
        }
        if (inject_dll_by_path(h, dll_path)) {
            injected++;
            if (!quiet) printf("Info: hook 17: neuter_wda.dll injected into %ls (PID %lu)\n",
                               process_name, (unsigned long)pids[i]);
        } else {
            if (!quiet) fprintf(stderr,
                "Warn: hook 17: inject FAILED for %ls (PID %lu)\n",
                process_name, (unsigned long)pids[i]);
        }
        CloseHandle(h);
    }
    free(dll_path);
    return injected;
}

/* Like apply_apple_music_hook but also force-loads mfcore.dll first if
 * it's not already loaded. Use this in the autopilot pre-flight so the
 * patch is in place BEFORE Apple Music starts a song.
 *
 * Also applies hook 16: CoreMedia.dll!0xBFD290 (the
 * ExternalProtectionRequired getter in Apple's fpfsi subsystem). When
 * Apple Music plays protected content, CoreMedia calls this getter to
 * decide whether the OUTPUT needs to be protected. Returning 0 makes
 * the rest of the playback pipeline think no external protection is
 * required, which we hope prevents the surface from being tagged
 * protected at the DComp/DXGI layer.
 *
 * CoreMedia.dll is loaded by Apple Music's player startup, so unlike
 * mfcore.dll it should already be present in the process. We still
 * force-load if missing as a safety net. */
static int apply_apple_music_hook_force(int quiet) {
    DWORD pids[MAX_PIDS];
    size_t n = find_pids_by_name(L"AppleMusic.exe", pids, MAX_PIDS);
    if (!quiet) printf("Info: prep-applemusic: found %zu AppleMusic.exe\n", n);
    if (n == 0) return 0;
    int fresh = 0;

    /* Hook 15 payload */
    static const uint8_t SIG_MFREQ[] = { 0x40, 0x55, 0x53, 0x56, 0x57, 0x41 };
    static const uint8_t PAY_MFREQ[] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };

    /* Hook 16 payload — first 8 bytes of CoreMedia!0xBFD290
     * (push pattern with stack save). Replacement returns 0. */
    static const uint8_t SIG_FPFSI[] = {
        0x48, 0x89, 0x5C, 0x24, 0x18,    /* mov [rsp+0x18], rbx */
        0x55,                            /* push rbp            */
        0x56, 0x57                       /* push rsi; push rdi  */
    };
    /* mov eax, 0 ; ret ; nop ; nop  (8 bytes, same length as sig) */
    static const uint8_t PAY_FPFSI[] = {
        0xB8, 0x00, 0x00, 0x00, 0x00,    /* mov eax, 0  */
        0xC3,                            /* ret         */
        0x90, 0x90                       /* padding     */
    };

    for (size_t i = 0; i < n; i++) {
        HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pids[i]);
        if (!h) {
            if (!quiet) fprintf(stderr,
                "Warn: AppleMusic.exe (PID %lu): OpenProcess failed (%lu)\n",
                (unsigned long)pids[i], GetLastError());
            continue;
        }

        /* Hook 15 prep: force-load + patch mfcore.dll */
        if (!remote_module_base(h, L"mfcore.dll")) {
            if (!quiet) printf("Info: AppleMusic.exe (PID %lu): force-loading mfcore.dll...\n",
                               (unsigned long)pids[i]);
            if (!force_load_module_remote(h, L"mfcore.dll")) {
                if (!quiet) fprintf(stderr,
                    "Warn: AppleMusic.exe (PID %lu): force-load mfcore.dll FAILED\n",
                    (unsigned long)pids[i]);
            } else if (!quiet) {
                printf("Info: AppleMusic.exe (PID %lu): mfcore.dll loaded.\n",
                       (unsigned long)pids[i]);
            }
        }
        int r15 = patch_bytes_at_rva(h, L"mfcore.dll",
                                     0x6EC80,
                                     SIG_MFREQ, sizeof SIG_MFREQ,
                                     PAY_MFREQ, sizeof PAY_MFREQ,
                                     "hook 15: MFRequireProtectedEnvironment",
                                     quiet);
        if (r15 == 0) fresh++;

        /* Hook 16 (DISABLED 2026-05-23): patched
         * CoreMedia.dll!0xBFD290 (fpfsi ExternalProtectionRequired
         * getter) to return 0. Applied cleanly but caused NVIDIA to
         * REFUSE to save any IR clip while Apple Music was open
         * (previously: clip saved with frozen frames; with hook 16:
         * no clip at all). Wrong direction - this is app-side, and
         * the right approach is to make NVIDIA itself ignore all
         * protected-content signals universally. Left as code
         * reference; do not re-enable without rethinking. */
        (void)SIG_FPFSI; (void)PAY_FPFSI;

        CloseHandle(h);
    }

    /* Hook 17: inject neuter_wda.dll into every running AppleMusic.exe
     * so it neutralizes user32!SetWindowDisplayAffinity and clears
     * any affinity already set on existing top-level windows. Once
     * this lands, DWM stops blanking Apple Music's region during
     * composition and NvFBC can see real pixels. */
    fresh += inject_neuter_wda_into(L"AppleMusic.exe", quiet);
    return fresh;
}

static int apply_apple_music_hook(int quiet) {
    int fresh = 0;
    DWORD pids[MAX_PIDS];
    size_t n = find_pids_by_name(L"AppleMusic.exe", pids, MAX_PIDS);
    if (!quiet) printf("Info: hook 15 search: found %zu AppleMusic.exe process(es)\n", n);
    if (n == 0) return 0;

    /* Original prologue: push rbp; push rbx; push rsi; push rdi; push r14 */
    static const uint8_t SIG_MFREQPROT[] = {
        0x40, 0x55, 0x53, 0x56, 0x57, 0x41
    };
    /* mov eax, 1 (S_FALSE)  ;  ret  -> "no protected environment required" */
    static const uint8_t PAYLOAD_MFREQPROT[] = {
        0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3
    };

    for (size_t i = 0; i < n; i++) {
        HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, pids[i]);
        if (!h) {
            if (!quiet) fprintf(stderr,
                "Warn: AppleMusic.exe (PID %lu): OpenProcess failed (%lu)\n",
                (unsigned long)pids[i], GetLastError());
            continue;
        }

        /* mfcore.dll is lazy-loaded on first playback. Silently skip if
         * not loaded yet; the watchdog will retry. */
        if (!remote_module_base(h, L"mfcore.dll")) {
            if (!quiet) printf(
                "Info: AppleMusic.exe (PID %lu): mfcore.dll not loaded yet "
                "(start playback to trigger).\n", (unsigned long)pids[i]);
            CloseHandle(h);
            continue;
        }

        int r = patch_bytes_at_rva(h, L"mfcore.dll",
                                   0x6EC80,
                                   SIG_MFREQPROT, sizeof SIG_MFREQPROT,
                                   PAYLOAD_MFREQPROT, sizeof PAYLOAD_MFREQPROT,
                                   "MFRequireProtectedEnvironment (Apple Music)",
                                   quiet);
        CloseHandle(h);
        if (r == 0) {
            fresh++;
            if (!quiet) printf("Info: hook 15 placed in AppleMusic.exe (PID %lu)\n",
                               (unsigned long)pids[i]);
        }
    }
    return fresh;
}

/* Convenience: SPUser hooks + best-effort aux hooks.
 * Returns whatever apply_spuser_hooks returned (errors there matter; aux is
 * best-effort and shouldn't fail the run). */
static int apply_all_hooks(int quiet) {
    int sp = apply_spuser_hooks(quiet);
    (void)apply_aux_hooks(quiet);
    (void)apply_apple_music_hook(quiet);
    /* Hook 17: WDA-neuter DLL injection. Idempotent — re-injecting on
     * an Apple Music process that already has the DLL is a no-op. */
    (void)inject_neuter_wda_into(L"AppleMusic.exe", quiet);
    return sp;
}

/* ----------------------------------------------------------------------
 * Top-level flows
 * ---------------------------------------------------------------------- */

static int run_diagnose(void) {
    Candidate *cands = (Candidate*)calloc(MAX_PIDS, sizeof(Candidate));
    if (!cands) { fprintf(stderr, "Error: out of memory\n"); return 1; }
    size_t n = collect_candidates(cands, MAX_PIDS);
    print_candidates(cands, n);
    const char *reason = NULL;
    DWORD target = pick_target(cands, n, &reason);
    printf("\nSelection: ");
    if (target) printf("PID %lu (matched: %s)\n", (unsigned long)target, reason);
    else        printf("no target (%s)\n", reason ? reason : "");
    free(cands);
    return target ? 0 : 1;
}

static int run_patch(int wait_seconds, int verbose) {
    Candidate *cands = (Candidate*)calloc(MAX_PIDS, sizeof(Candidate));
    if (!cands) { fprintf(stderr, "Error: out of memory\n"); return 1; }
    size_t n = 0;
    DWORD target = 0;
    const char *reason = NULL;

    DWORD start = GetTickCount();
    for (;;) {
        n = collect_candidates(cands, MAX_PIDS);
        target = pick_target(cands, n, &reason);
        if (target || wait_seconds <= 0) break;
        if ((GetTickCount() - start) / 1000 >= (DWORD)wait_seconds) break;
        printf("Info: target not yet found (%s). Retrying in 2s...\n", reason ? reason : "");
        Sleep(2000);
    }

    if (verbose || !target) print_candidates(cands, n);

    if (!target) {
        fprintf(stderr, "\nError: could not identify the SPUser nvcontainer.exe instance (%s).\n",
                reason ? reason : "");
        fprintf(stderr,
                "Hints:\n"
                "  - Make sure NVIDIA App (or GFE) is running and Instant Replay/Overlay is enabled.\n"
                "  - If nvcontainer was just launched, retry with: --wait 60\n"
                "  - For full process info, run: Nvidia_Instant_Replay_Fix.exe --diagnose\n");
        free(cands);
        return 1;
    }

    printf("Info: target PID %lu (matched: %s)\n\n", (unsigned long)target, reason ? reason : "");
    free(cands);

    HANDLE h = OpenProcess(PROCESS_ALL_ACCESS, FALSE, target);
    if (!h) {
        fprintf(stderr, "Error: OpenProcess failed (GetLastError=0x%lx)\n",
                (unsigned long)GetLastError());
        return 1;
    }

    int r1 = patch_function(h, L"USER32.dll",   "GetWindowDisplayAffinity", 6, 0);
    int r2 = (r1 == 1) ? 1
                       : patch_function(h, L"KERNEL32.DLL", "Module32FirstW",  7, 0);
    int r3 = (r2 == 1) ? 1
                       : patch_function(h, L"KERNEL32.DLL", "Process32FirstW", 7, 0);
    int r4 = (r3 == 1) ? 1
                       : patch_function(h, L"VERSION.DLL",  "VerQueryValueW",     6, 0);
    int r5 = (r4 == 1) ? 1
                       : patch_function(h, L"USER32.dll",   "IsImmersiveProcess", 6, 0);

    /* SUSTAINABILITY: runtime resolver (anchor-string -> function -> patch site)
     * applies the internal _nvspcaps64.dll hooks and self-heals across NVIDIA App
     * updates. The legacy hardcoded calls below are a redundant secondary fallback. */
    apply_internal_nvsp_hooks(h, 0);

    /* CCaptureSession::IsCaptureAllowed (internal, by RVA) */
    static const uint8_t PROLOGUE_ISCAPTURE2[] = {
        0x48, 0x89, 0x5C, 0x24, 0x08,
        0x48, 0x89, 0x74, 0x24, 0x10
    };
    int r6 = (r5 == 1) ? 1
                       : patch_internal_function_return_true(h, L"_nvspcaps64.dll",
                            0xA69B0, PROLOGUE_ISCAPTURE2, sizeof PROLOGUE_ISCAPTURE2,
                            6, "CCaptureSession::IsCaptureAllowed", 0);
    /* Hook 7 (IsCaptureAllowedOld) was REMOVED in _nvspcaps64.dll 11.0.8.244.
     * Mirror r6 so the chain is unaffected (see apply_spuser_hooks notes). */
    int r7 = r6;

    /* CCaptureControl::ProcessGameEvents EPC-branch je->jmp flip.
     * See apply_spuser_hooks() for the full discovery write-up; in short:
     * one-byte patch at RVA 0x9832B turns the conditional "is EPC?" branch
     * into an unconditional skip, so the SP_EVENT that fires when Apple
     * Music goes to foreground never tears down the NVENC session. */
    static const uint8_t SIG_EPC_BRANCH2[] = {
        0x74, 0x72                                      /* je rel8 +0x72 (11.0.8.244 @ 0x98EEB) */
    };
    int r8 = (r7 == 1) ? 1
                       : patch_byte_signature(h, L"_nvspcaps64.dll",
                            0x98EEB, SIG_EPC_BRANCH2, sizeof SIG_EPC_BRANCH2,
                            0xEB, "CCaptureControl::ProcessGameEvents EPC-branch", 0);

    /* CCaptureSession::TerminateCaptures stub. See apply_spuser_hooks() for
     * the rationale and signature derivation. */
    static const uint8_t SIG_TERMCAPS2[] = {
        0x40, 0x53,
        0x48, 0x81, 0xEC, 0xD0, 0x08, 0x00, 0x00,
        0x48, 0x8B, 0xD9,
        0xC7, 0x44, 0x24, 0x20
    };
    static const uint8_t PAYLOAD_RETURN_SOK2[] = { 0x33, 0xC0, 0xC3 };
    int r9 = (r8 == 1) ? 1
                       : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                            0xAB5B0, SIG_TERMCAPS2, sizeof SIG_TERMCAPS2,
                            PAYLOAD_RETURN_SOK2, sizeof PAYLOAD_RETURN_SOK2,
                            "CCaptureSession::TerminateCaptures stub", 0);

    /* CCaptureControl::DisableIR stub. See apply_spuser_hooks() for
     * the rationale and signature derivation. */
    static const uint8_t SIG_DISABLEIR2[] = {
        0x40, 0x53, 0x48, 0x83, 0xEC, 0x20,
        0x83, 0x3D, 0x9F, 0x6B, 0x2C, 0x00, 0x06,       /* disp updated for 11.0.8.244 */
        0x48, 0x8B, 0xD9
    };
    int r10 = (r9 == 1) ? 1
                        : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                             0x93840, SIG_DISABLEIR2, sizeof SIG_DISABLEIR2,
                             PAYLOAD_RETURN_SOK2, sizeof PAYLOAD_RETURN_SOK2,
                             "CCaptureControl::DisableIR stub", 0);

    /* SaveInstantReplay gates. See apply_spuser_hooks() for full notes. */
    static const uint8_t SIG_SAVEIR_GATE_A2[] = { 0x0F, 0x84, 0x35, 0x02, 0x00, 0x00 };
    static const uint8_t SIG_SAVEIR_GATE_B2[] = { 0x0F, 0x84, 0x40, 0x02, 0x00, 0x00 };
    static const uint8_t NOP6_2[]             = { 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
    int r11a = (r10 == 1) ? 1
                          : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                               0xA90E0, SIG_SAVEIR_GATE_A2, sizeof SIG_SAVEIR_GATE_A2,
                               NOP6_2, sizeof NOP6_2,
                               "SaveInstantReplay gate A", 0);
    int r11b = (r11a == 1) ? 1
                           : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                                0xA90F7, SIG_SAVEIR_GATE_B2, sizeof SIG_SAVEIR_GATE_B2,
                                NOP6_2, sizeof NOP6_2,
                                "SaveInstantReplay gate B", 0);

    /* NvFBCCore::CheckGrabInfo stub — see apply_spuser_hooks() rationale. */
    static const uint8_t SIG_CHECKGRAB2[] = {
        0x48, 0x89, 0x5C, 0x24, 0x18,
        0x55, 0x56, 0x57,
        0x41, 0x54
    };
    int r12 = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"NvFBC64.dll",
                               0x2AEA0, SIG_CHECKGRAB2, sizeof SIG_CHECKGRAB2,
                               PAYLOAD_RETURN_SOK2, sizeof PAYLOAD_RETURN_SOK2,
                               "NvFBCCore::CheckGrabInfo stub", 0);

    /* SaveInstantReplay second-save unlocks. See apply_spuser_hooks() notes. */
    static const uint8_t SIG_RATE2[]    = { 0x74, 0x45 };
    static const uint8_t SIG_SUB2[]     = { 0x74, 0x33 };
    static const uint8_t NOP2_2[]       = { 0x90, 0x90 };
    /* Gate on r11b (the last _nvspcaps64 hook), NOT r12: hooks 13a/13b live in
     * _nvspcaps64.dll and are independent of NvFBC64.dll. NvFBC64 only loads
     * while IR is actively recording, so gating 13 on the NvFBC64 hook (12)
     * silently skipped the SaveInstantReplay rate-limit/sub-state unlocks
     * whenever IR wasn't recording at patch time. */
    int r13a = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                               0xA91F4, SIG_RATE2, sizeof SIG_RATE2,
                               NOP2_2, sizeof NOP2_2,
                               "SaveInstantReplay rate-limit", 0);
    int r13b = (r13a == 1) ? 1
                           : patch_bytes_at_rva(h, L"_nvspcaps64.dll",
                                0xA9206, SIG_SUB2, sizeof SIG_SUB2,
                                NOP2_2, sizeof NOP2_2,
                                "SaveInstantReplay sub-state gate", 0);

    /* doGdiDesktopCapture protected-branch je->jmp. See apply_spuser_hooks() notes. */
    static const uint8_t SIG_GDI_OFF[] = { 0x74, 0x40 };
    static const uint8_t SIG_GDI_ON[]  = { 0xEB, 0x40 };
    /* Best-effort NvFBC64 hook, independent of the _nvspcaps64 save hooks.
     * Gate on r11b only so a missing/unloaded NvFBC64 never blocks anything. */
    int r14 = (r11b == 1) ? 1
                          : patch_bytes_at_rva(h, L"NvFBC64.dll",
                               0x42AD3, SIG_GDI_OFF, sizeof SIG_GDI_OFF,
                               SIG_GDI_ON, sizeof SIG_GDI_ON,
                               "doGdiDesktopCapture protected->normal flip", 0);

    CloseHandle(h);

    /* Best-effort aux hooks (NVIDIA Overlay / App / DisplayContainer).
     * These kill the "protected app" detection in the UI layer that
     * pops up when Apple Music / DRM video apps are foregrounded. */
    int aux = apply_aux_hooks(0);
    if (aux > 0) printf("Info: also patched %d auxiliary process(es)\n", aux);

    /* Hook 15: best-effort patch of MFRequireProtectedEnvironment in any
     * running AppleMusic.exe. Silently skips if Apple Music isn't running
     * or mfcore.dll isn't loaded yet (will be retried on watchdog ticks). */
    int am = apply_apple_music_hook(0);
    if (am > 0) printf("Info: also patched %d AppleMusic.exe instance(s)\n", am);

    /* Hook 17: inject the WDA-neuter DLL into Apple Music. */
    int nuked = inject_neuter_wda_into(L"AppleMusic.exe", 0);
    if (nuked > 0) printf("Info: hook 17 injected into %d AppleMusic.exe instance(s)\n", nuked);

    return (r1 == 1 || r2 == 1 || r3 == 1 || r4 == 1 || r5 == 1 || r6 == 1 || r7 == 1
            || r8 == 1 || r9 == 1 || r10 == 1 || r11a == 1 || r11b == 1 || r12 == 1
            || r13a == 1 || r13b == 1 || r14 == 1) ? 1 : 0;
}

/* ----------------------------------------------------------------------
 * Watchdog mode
 *
 * Listens with RegNotifyChangeKeyValue() for any write to the NVIDIA
 * ShadowPlay/Instant Replay registry key. If any of the "enabled" flags
 * are flipped to 0, immediately writes them back to 1. Also periodically
 * (every safety_timeout_ms) re-verifies the in-process hooks, so a
 * nvcontainer.exe restart mid-session gets re-patched within at most that
 * window.
 *
 * The wait blocks on a kernel event, not a polling Sleep(), so when nothing
 * is happening the watchdog is genuinely idle (no CPU).
 * ---------------------------------------------------------------------- */

static void log_ts(const char *prefix) {
    SYSTEMTIME st; GetLocalTime(&st);
    printf("%s [%04d-%02d-%02d %02d:%02d:%02d] ", prefix,
           st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

/* GUIDs (and any other exact-match names) that NVIDIA sets to 1 to indicate
 * "currently in protected-content state" and which drive Instant Replay to
 * pause + the "protected app preventing capture" popup. We force these back
 * to 0 the instant they flip on. Identified by capturing live registry
 * diffs while reproducing with Apple Music — see Debug-Monitor.ps1.
 *
 * Add new entries here (one per line, exact case-sensitive match) as users
 * report new GUIDs from their debug captures. */
static const wchar_t *FORCE_ZERO_FLAGS[] = {
    L"{1B1D3DAA-601D-49E5-8508-81736CA28C6D}",  /* Apple Music / PMP protected-content active */
};
static const size_t N_FORCE_ZERO = sizeof(FORCE_ZERO_FLAGS) / sizeof(FORCE_ZERO_FLAGS[0]);

static int is_force_zero_flag(const wchar_t *name) {
    if (!name) return 0;
    for (size_t i = 0; i < N_FORCE_ZERO; i++) {
        if (_wcsicmp(name, FORCE_ZERO_FLAGS[i]) == 0) return 1;
    }
    return 0;
}

/* Name-substring heuristic: "this looks like a 'currently enabled' flag".
 * Used by the watchdog when it encounters a 4-byte zero value to decide
 * whether to flip it back to 1 or just log it.
 * Matching is case-insensitive substring. Conservative — we'd rather skip
 * an unknown 0 than corrupt a legitimate setting. */
static int is_enabled_style_flag(const wchar_t *name) {
    if (!name || !*name) return 0;
    static const wchar_t *positive_substrings[] = {
        L"Enabled", L"Enable",
        L"RecEnabled", L"RecEnable",
        L"Dvr",
        L"Dwm",
        L"HL",          /* HLEnabled = hardware-accelerated, "should be on" */
        L"InstantReplay", L"DVR",
        L"ShadowPlay",
        L"Capture",
    };
    for (size_t i = 0; i < sizeof(positive_substrings)/sizeof(positive_substrings[0]); i++) {
        const wchar_t *p = positive_substrings[i];
        size_t plen = wcslen(p);
        size_t hlen = wcslen(name);
        if (plen > hlen) continue;
        for (size_t j = 0; j + plen <= hlen; j++) {
            if (_wcsnicmp(name + j, p, plen) == 0) return 1;
        }
    }
    return 0;
}

static int run_watchdog(void) {
    static const wchar_t *KEY_PATH =
        L"SOFTWARE\\NVIDIA Corporation\\Global\\ShadowPlay\\NVSPCAPS";

    const DWORD safety_timeout_ms = 30 * 1000;  /* periodic patch re-verify */

    log_ts("Watchdog");
    printf("starting. Will monitor HKCU\\%ls\n", KEY_PATH);
    fflush(stdout);

    /* Initial patch attempt — verbose so the user sees what target was hit. */
    (void)apply_all_hooks(0);
    fflush(stdout);

    DWORD last_apply = GetTickCount();

    for (;;) {
        HKEY hKey = NULL;
        LSTATUS s = RegOpenKeyExW(HKEY_CURRENT_USER, KEY_PATH, 0,
                                  KEY_NOTIFY | KEY_QUERY_VALUE | KEY_SET_VALUE,
                                  &hKey);
        if (s != ERROR_SUCCESS) {
            log_ts("Watchdog");
            printf("could not open NVSPCAPS (LSTATUS=%ld); retry in 10s\n", s);
            fflush(stdout);
            Sleep(10000);
            continue;
        }

        HANDLE hEvent = CreateEventW(NULL, FALSE /*auto-reset*/, FALSE, NULL);
        if (!hEvent) { RegCloseKey(hKey); Sleep(10000); continue; }

        s = RegNotifyChangeKeyValue(hKey, FALSE, REG_NOTIFY_CHANGE_LAST_SET, hEvent, TRUE);
        if (s != ERROR_SUCCESS) {
            CloseHandle(hEvent); RegCloseKey(hKey);
            log_ts("Watchdog");
            printf("RegNotifyChangeKeyValue failed (LSTATUS=%ld); retry in 10s\n", s);
            fflush(stdout);
            Sleep(10000); continue;
        }

        DWORD wr = WaitForSingleObject(hEvent, safety_timeout_ms);
        CloseHandle(hEvent);

        if (wr == WAIT_OBJECT_0) {
            /* Registry was modified. Enumerate ALL values in the key and:
             *  - Force any "protected-state" flag (FORCE_ZERO_FLAGS) back to 0
             *  - Force any "Enabled"-style flag that's currently 0 back to 1
             * Only log when we actually take action — diagnostic enumeration
             * of every value lives in Debug-Monitor.ps1 where the user can
             * run it explicitly to hunt for new disable mechanisms. */
            DWORD index = 0;
            for (;;) {
                wchar_t name[256];
                DWORD nameLen = (DWORD)(sizeof(name)/sizeof(name[0]));
                BYTE data[16] = {0};
                DWORD dataLen = sizeof(data);
                DWORD type = 0;
                LSTATUS r = RegEnumValueW(hKey, index, name, &nameLen,
                                          NULL, &type, data, &dataLen);
                if (r == ERROR_NO_MORE_ITEMS) break;
                if (r != ERROR_SUCCESS) { index++; continue; }
                index++;

                if (!(type == REG_BINARY || type == REG_DWORD)) continue;
                if (dataLen < 4) continue;

                BOOL is_zero = (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 0);

                if (is_force_zero_flag(name)) {
                    if (!is_zero) {
                        BYTE zero[4] = {0, 0, 0, 0};
                        LSTATUS w = RegSetValueExW(hKey, name, 0, type, zero, 4);
                        log_ts("Watchdog");
                        if (w == ERROR_SUCCESS)
                            printf("BLOCKED status-flag %ls : NVIDIA wrote 1 (protected-content-detected); we scrubbed back to 0. IR enable settings UNTOUCHED.\n", name);
                        else
                            printf("WARN: NVIDIA wrote %ls=1 but our scrub failed (LSTATUS=%ld)\n", name, w);
                        fflush(stdout);
                    }
                    continue;
                }

                if (is_zero && is_enabled_style_flag(name)) {
                    BYTE one[4] = {1, 0, 0, 0};
                    LSTATUS w = RegSetValueExW(hKey, name, 0, type, one, 4);
                    log_ts("Watchdog");
                    if (w == ERROR_SUCCESS)
                        printf("RESTORED IR setting %ls : NVIDIA wrote 0 (disable); we reset to 1 (enable).\n", name);
                    else
                        printf("WARN: NVIDIA wrote %ls=0 but our restore failed (LSTATUS=%ld)\n", name, w);
                    fflush(stdout);
                    continue;
                }
                /* otherwise: silent. Use Debug-Monitor.ps1 to investigate. */
            }
        } else if (wr == WAIT_TIMEOUT) {
            /* Periodic safety re-verify of in-process hooks.
             * Quiet so a steady state produces no log spam. */
            int r = apply_all_hooks(1);
            if (r == 0) {
                /* A real patch happened (nvcontainer must have restarted) */
                log_ts("Watchdog");
                printf("re-applied hooks (nvcontainer restart detected?)\n");
                fflush(stdout);
            } else if (r == 1) {
                /* Couldn't patch (SPUser not running?). Already logged once below. */
                if ((GetTickCount() - last_apply) > 5 * 60 * 1000) {
                    log_ts("Watchdog");
                    printf("hook re-verify failed (SPUser not running yet?); will keep trying\n");
                    fflush(stdout);
                    last_apply = GetTickCount();
                }
            }
            /* r == 2 means both hooks already in place; silent. */
        }

        RegCloseKey(hKey);
    }
    /* unreachable */
}

/* Redirect stdout/stderr to a file and detach from the console.
 *
 * This lets the watchdog be launched directly by Task Scheduler (no cmd.exe
 * wrapper) without leaving a visible console window: we own the redirect,
 * then call FreeConsole() so the inherited console window is released. */
static int redirect_to_log_and_detach(const wchar_t *log_path) {
    /* Previously: CreateFileW + SetStdHandle + _open_osfhandle + _dup2.
     * That worked on MSVC but silently failed under MinGW's CRT — the
     * dup'd descriptors didn't make it through to the FILE * stdout, so
     * subsequent printf()s went nowhere and patcher.log stayed at the
     * size left by the previous run. _wfreopen is the cleaner POSIX-style
     * approach and works under both toolchains. */
    if (!_wfreopen(log_path, L"a", stdout)) {
        /* If freopen fails we have no stdout anymore, so write to stderr
         * (which is still attached to the inherited console). */
        fwprintf(stderr, L"Error: could not freopen stdout to '%ls' (errno=%d)\n",
                 log_path, errno);
        return 1;
    }
    if (!_wfreopen(log_path, L"a", stderr)) {
        fwprintf(stdout, L"Error: could not freopen stderr to '%ls' (errno=%d)\n",
                 log_path, errno);
        return 1;
    }
    setvbuf(stdout, NULL, _IOLBF, 1024);  /* line-buffered so log writes flush */
    setvbuf(stderr, NULL, _IONBF, 0);

    /* Release the inherited console so its window goes away. Safe even if
     * we weren't given one (FreeConsole is a no-op then). */
    FreeConsole();
    return 0;
}

/* Convert ANSI argv[i] to a freshly-allocated wide string. Caller frees. */
static wchar_t* a2w(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (n <= 0) return NULL;
    wchar_t *w = (wchar_t*)malloc((size_t)n * sizeof(wchar_t));
    if (!w) return NULL;
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
    return w;
}

int main(int argc, char **argv) {
    int wait_for_key = 1;
    int verbose = 0;
    int diagnose = 0;
    int watchdog = 0;
    int prep_am = 0;
    int wait_seconds = 0;
    wchar_t *log_path = NULL;

    for (int i = 1; i < argc; i++) {
        if      (strcmp(argv[i], "--no-wait-for-keypress") == 0) wait_for_key = 0;
        else if (strcmp(argv[i], "--verbose")              == 0) verbose = 1;
        else if (strcmp(argv[i], "--diagnose")             == 0) diagnose = 1;
        else if (strcmp(argv[i], "--watchdog")             == 0) { watchdog = 1; wait_for_key = 0; }
        else if (strcmp(argv[i], "--prep-applemusic")      == 0) { prep_am = 1; wait_for_key = 0; }
        else if (strcmp(argv[i], "--wait") == 0 && i + 1 < argc) wait_seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], "--log")  == 0 && i + 1 < argc) {
            free(log_path);
            log_path = a2w(argv[++i]);
            wait_for_key = 0;
        }
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: Nvidia_Instant_Replay_Fix.exe [options]\n"
                   "  (default)                One-shot: apply hooks, exit.\n"
                   "  --watchdog               Apply hooks, then listen on the NVIDIA Instant\n"
                   "                            Replay registry key and instantly reverse any\n"
                   "                            disable attempts. Re-verifies hooks every 30 s.\n"
                   "                            Runs until killed.\n"
                   "  --diagnose               Show what we'd target and exit (no patching).\n"
                   "  --wait <seconds>         If target not running yet, retry up to N seconds.\n"
                   "  --log <path>             Redirect stdout/stderr to file and detach from\n"
                   "                            console (no visible window). Used by the\n"
                   "                            scheduled-task launcher.\n"
                   "  --no-wait-for-keypress   Exit immediately when done.\n"
                   "  --verbose                Print extra info during a normal run.\n"
                   "  --help, -h               This text.\n");
            free(log_path);
            return 0;
        }
    }

    if (log_path) {
        if (redirect_to_log_and_detach(log_path) != 0) {
            free(log_path);
            return 1;
        }
        free(log_path);
        log_path = NULL;
    }

    int rc;
    if      (watchdog) rc = run_watchdog();
    else if (diagnose) rc = run_diagnose();
    else if (prep_am) {
        int n = apply_apple_music_hook_force(0);
        printf("Info: prep-applemusic complete (%d patched).\n", n);
        rc = (n > 0) ? 0 : 1;
    }
    else               rc = run_patch(wait_seconds, verbose);

    if (wait_for_key) {
        printf("Press any key to exit...\n");
        (void)_getch();
    }
    return rc;
}
