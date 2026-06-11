"""Convert the NVIDIA eye symbol (cropped from the logo PNG) into a half-block
truecolor ANSI art file the terminal UI can print. Half blocks (U+2580 top /
U+2584 bottom) give 2 vertical pixels per character cell, so the eye's spiral
actually reads. White background is keyed out to the terminal default."""
from PIL import Image

SRC = r"C:\Users\Abood\Downloads\git\ShadowPlay_Patcher\assets\nvidia_src.png"
OUT = r"C:\Users\Abood\Downloads\git\ShadowPlay_Patcher\assets\nvidia_eye.ans"
TARGET_W = 46      # output width in character cells (= pixels wide)
CENTER_IN = 64     # pad lines to center within the banner width
ESC = chr(27)

im = Image.open(SRC).convert("RGB")
W, H = im.size
px = im.load()

def is_bg(r, g, b):      # near-white background / spiral cut-out
    return r > 200 and g > 200 and b > 200
def is_green(r, g, b):   # the eye body
    return g > 90 and g >= r and g >= b - 10

# Bounding box of the eye = green pixels in the TOP ~62% (excludes the wordmark).
ymax = int(H * 0.62)
minx, miny, maxx, maxy = W, H, 0, 0
for y in range(ymax):
    for x in range(W):
        r, g, b = px[x, y]
        if is_green(r, g, b):
            minx, maxx = min(minx, x), max(maxx, x)
            miny, maxy = min(miny, y), max(maxy, y)
pad = 3
box = (max(0, minx - pad), max(0, miny - pad), min(W, maxx + pad), min(ymax, maxy + pad))
eye = im.crop(box)

ratio = TARGET_W / eye.width
nh = int(eye.height * ratio)
if nh % 2: nh += 1
eye = eye.resize((TARGET_W, nh), Image.LANCZOS)
ep = eye.load()

lead = " " * max(0, (CENTER_IN - TARGET_W) // 2)
lines, shape = [], []
for y in range(0, nh, 2):
    s, sh = lead, ""
    for x in range(TARGET_W):
        r1, g1, b1 = ep[x, y]
        r2, g2, b2 = ep[x, y + 1] if y + 1 < nh else (255, 255, 255)
        tbg, bbg = is_bg(r1, g1, b1), is_bg(r2, g2, b2)
        if tbg and bbg:
            s += ESC + "[0m "; sh += " "
        elif not tbg and not bbg:
            s += f"{ESC}[38;2;{r1};{g1};{b1}m{ESC}[48;2;{r2};{g2};{b2}m▀"; sh += "#"
        elif not tbg:
            s += f"{ESC}[0m{ESC}[38;2;{r1};{g1};{b1}m▀"; sh += "^"
        else:
            s += f"{ESC}[0m{ESC}[38;2;{r2};{g2};{b2}m▄"; sh += "v"
    s += ESC + "[0m"
    lines.append(s); shape.append(sh)

with open(OUT, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
print(f"wrote {OUT}  ({TARGET_W} cells x {nh // 2} rows)")
print("--- shape preview (verify it reads as the NVIDIA eye) ---")
print("\n".join(lead + r for r in shape))
