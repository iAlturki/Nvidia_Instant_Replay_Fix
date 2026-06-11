"""Dump the ASCII strings each target function references, so the runtime
resolver can anchor on stable log-strings instead of hardcoded RVAs.

For each known function (bounds from the 11.0.8.244 re-derivation), scan its
bytes for `lea reg,[rip+disp32]`, resolve the target into .rdata, and print the
C-string there. We pick one unique anchor per function from this list."""
import pefile, sys

DLL = r"C:\Program Files\NVIDIA Corporation\NVIDIA app\ShadowPlay\NVSPCAPS\_nvspcaps64.dll"

pe = pefile.PE(DLL, fast_load=True)
image = pe.get_memory_mapped_image()

# section ranges (RVA)
sections = [(s.Name.rstrip(b"\x00").decode(errors="replace"),
             s.VirtualAddress, s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData))
            for s in pe.sections]
def sec_of(rva):
    for n, a, b in sections:
        if a <= rva < b:
            return n
    return "?"

def read_cstr(rva, maxlen=160):
    out = bytearray()
    for i in range(maxlen):
        try:
            c = image[rva + i]
        except IndexError:
            break
        if c == 0:
            break
        if 32 <= c < 127:
            out.append(c)
        else:
            return None  # not a clean ASCII string
    return out.decode(errors="replace") if len(out) >= 4 else None

# target functions: (label, start_rva, end_rva)
FUNCS = [
    ("IsCaptureAllowed (6)",  0x000a69b0, 0x000a6c34),
    ("ProcessGameEvents (8)", 0x00098a10, 0x00098f81),
    ("TerminateCaptures (9)", 0x000ab5b0, 0x000ab6a2),
    ("DisableIR (10)",        0x00093840, 0x000938a6),
    ("SaveInstantReplay (11/13a)", 0x000a9000, 0x000a937c),
    ("SaveIR-substate fn (13b)",   0x000a7cf0, 0x000a8435),
]

def lea_refs(start, end):
    """Yield (instr_rva, target_rva) for lea reg,[rip+disp32] in [start,end)."""
    i = start
    while i < end - 6:
        b0, b1, b2 = image[i], image[i + 1], image[i + 2]
        if b0 in (0x48, 0x4C) and b1 == 0x8D and (b2 & 0xC7) == 0x05:
            disp = int.from_bytes(image[i + 3:i + 7], "little", signed=True)
            tgt = i + 7 + disp
            yield i, tgt
            i += 7
        else:
            i += 1

for label, s, e in FUNCS:
    print(f"\n=== {label}   [{s:#x}-{e:#x}] ===")
    seen = set()
    for instr, tgt in lea_refs(s, e):
        if tgt in seen:
            continue
        seen.add(tgt)
        st = read_cstr(tgt)
        if st:
            print(f"  lea@{instr:#08x} -> {tgt:#08x} ({sec_of(tgt)}): {st!r}")
