"""Disassemble the patch-site regions on 11.0.8.244 to design version-robust
patterns for the runtime resolver (anchor string -> function -> local pattern)."""
import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64

DLL = r"C:\Program Files\NVIDIA Corporation\NVIDIA app\ShadowPlay\NVSPCAPS\_nvspcaps64.dll"
pe = pefile.PE(DLL, fast_load=True)
img = pe.get_memory_mapped_image()
md = Cs(CS_ARCH_X86, CS_MODE_64)

def dis(start, end, title):
    print(f"\n===== {title}  [{start:#x}-{end:#x}] =====")
    code = bytes(img[start:end])
    for ins in md.disasm(code, start):
        b = " ".join(f"{x:02x}" for x in ins.bytes)
        print(f"  {ins.address:#08x}: {b:<24} {ins.mnemonic} {ins.op_str}")

# ProcessGameEvents: the EPC je just before the "EPC found, terminating" lea@0x98f00
dis(0x98ed0, 0x98f30, "ProcessGameEvents EPC branch region")

# SaveInstantReplay: gates near the top + the save/rate-limit region.
dis(0x0a90c0, 0x0a9120, "SaveInstantReplay gates A/B region")
dis(0x0a91d0, 0x0a9240, "SaveInstantReplay rate-limit / sub-state region (13a/13b)")
