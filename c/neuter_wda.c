/*
 * neuter_wda.dll  -  Display-affinity neutralizer payload
 * Part of Nvidia_Instant_Replay_Fix.
 *
 * Loaded into target processes (e.g. AppleMusic.exe) by the main
 * patcher via CreateRemoteThread(LoadLibraryW). DllMain spins a
 * worker thread that:
 *
 *   1. Saves a pointer to the real user32!SetWindowDisplayAffinity.
 *   2. Calls the REAL function with WDA_NONE on every top-level
 *      window owned by the current process, undoing any protection
 *      already in place when we got injected.
 *   3. Rewrites the prologue of user32!SetWindowDisplayAffinity to
 *      `mov eax, 1 ; ret` so future calls return TRUE without ever
 *      reaching win32k. The kernel never stores any affinity flag,
 *      so DWM never blanks the window when compositing the desktop,
 *      and NvFBC sees real pixels.
 *
 * No CRT, no STL. Links against kernel32 + user32 only.
 *
 * Why we don't bother restoring the original bytes on detach:
 *   This DLL is meant to stay loaded for the lifetime of the host
 *   process. There's nothing to "unhook" — the patch is exactly
 *   what we want for the entire run.
 */

#ifndef UNICODE
#  define UNICODE
#endif
#ifndef _UNICODE
#  define _UNICODE
#endif

#include <windows.h>
#include <stdint.h>

typedef BOOL (WINAPI *PFN_SWDA)(HWND, DWORD);

static PFN_SWDA g_original_swda = NULL;

#ifndef WDA_NONE
#  define WDA_NONE 0x00000000
#endif

static BOOL CALLBACK enum_clear_cb(HWND hwnd, LPARAM lparam) {
    (void)lparam;
    DWORD wnd_pid = 0;
    GetWindowThreadProcessId(hwnd, &wnd_pid);
    if (wnd_pid == GetCurrentProcessId() && g_original_swda) {
        /* If a previous SetWindowDisplayAffinity(WDA_MONITOR /
         * WDA_EXCLUDEFROMCAPTURE) was already in effect by the time
         * we got loaded, this resets it. Failures are silent on
         * purpose - some windows (children, message-only) reject
         * this call and that's fine. */
        g_original_swda(hwnd, WDA_NONE);
    }
    return TRUE;  /* keep enumerating */
}

/* Replace a function's prologue with `mov eax, 1 ; ret`. Idempotent. */
static void patch_to_return_true(void *fn) {
    static const BYTE PAYLOAD[6] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
    if (!fn) return;
    BYTE *p = (BYTE*)fn;
    DWORD old_prot = 0;
    if (!VirtualProtect(p, sizeof(PAYLOAD), PAGE_EXECUTE_READWRITE, &old_prot))
        return;
    if (p[0] != 0xB8 || p[5] != 0xC3) {
        memcpy(p, PAYLOAD, sizeof(PAYLOAD));
        FlushInstructionCache(GetCurrentProcess(), p, sizeof(PAYLOAD));
    }
    VirtualProtect(p, sizeof(PAYLOAD), old_prot, &old_prot);
}

static DWORD WINAPI worker(LPVOID param) {
    (void)param;

    HMODULE u32 = GetModuleHandleW(L"user32.dll");
    if (!u32) u32 = LoadLibraryW(L"user32.dll");

    PFN_SWDA pfn_user32 = u32
        ? (PFN_SWDA)(uintptr_t)GetProcAddress(u32, "SetWindowDisplayAffinity")
        : NULL;

    /* Step 1: stash the ORIGINAL user32 thunk so EnumWindows callback
     * below can call into the real implementation BEFORE we patch. */
    g_original_swda = pfn_user32;

    /* Step 2: clear protection on any windows already created by our
     * host process. After this returns, all top-level windows owned
     * by us have WDA_NONE. */
    if (pfn_user32) EnumWindows(enum_clear_cb, 0);

    /* Step 3a: patch the user32 thunk. Original prologue is a 6-byte
     * indirect jump to win32u!NtUserSetWindowDisplayAffinity via IAT
     * (ff 25 xx xx xx xx). Replace with mov eax,1 ; ret. */
    patch_to_return_true(pfn_user32);

    /* Step 3b: patch the win32u syscall thunk too. Catches the rare
     * app that calls NtUserSetWindowDisplayAffinity directly. The
     * thunk is 22 bytes (mov r10,rcx; mov eax,syscall#; test [SSDT];
     * jne; syscall; ret) - we overwrite only the first 6 bytes,
     * truncating the thunk into our return-TRUE stub. */
    HMODULE w32u = GetModuleHandleW(L"win32u.dll");
    if (w32u) {
        FARPROC pfn_w32u = GetProcAddress(w32u, "NtUserSetWindowDisplayAffinity");
        patch_to_return_true((void*)(uintptr_t)pfn_w32u);
    }

    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hInst, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hInst);
        /* DllMain loader lock prohibits a lot of work directly here
         * (synchronization primitives, COM, etc.). Spawn a worker
         * thread that runs after loader lock releases. */
        HANDLE h = CreateThread(NULL, 0, worker, NULL, 0, NULL);
        if (h) CloseHandle(h);
    }
    return TRUE;
}
