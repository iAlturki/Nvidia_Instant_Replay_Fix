"""Render the three feature icons (NVIDIA eye | ShadowPlay record/replay | GitHub
octocat) as ONE half-block truecolor ANSI strip the terminal UI can print.
NVIDIA + GitHub come from real images; the record/replay icon is drawn."""
import math
from PIL import Image, ImageDraw

A   = r"C:\Users\Abood\Downloads\git\ShadowPlay_Patcher\assets"
NV  = A + r"\nvidia_src.png"
GH  = A + r"\github_src.png"
OUT = A + r"\nvidia_icons.ans"

GREEN = (118, 185, 0); RED = (232, 48, 48); GREY = (236, 238, 241)
TILE = 14; GAP = 4
ESC = chr(27)

def contain(img, size):
    img = img.copy(); img.thumbnail((size, size), Image.LANCZOS)
    t = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    t.paste(img, ((size - img.width) // 2, (size - img.height) // 2), img)
    return t

# --- NVIDIA eye: crop green from the logo, key out white ---
nv = Image.open(NV).convert("RGB"); W, H = nv.size; p = nv.load()
def isg(r, g, b): return g > 90 and g >= r and g >= b - 10
ymax = int(H * 0.62); minx, miny, maxx, maxy = W, H, 0, 0
for y in range(ymax):
    for x in range(W):
        r, g, b = p[x, y]
        if isg(r, g, b): minx, maxx = min(minx, x), max(maxx, x); miny, maxy = min(miny, y), max(maxy, y)
eye = nv.crop((minx, miny, maxx, maxy)).convert("RGBA"); ep = eye.load()
for y in range(eye.height):
    for x in range(eye.width):
        r, g, b, a = ep[x, y]
        if r > 200 and g > 200 and b > 200: ep[x, y] = (0, 0, 0, 0)
nv_tile = contain(eye, TILE)

# --- GitHub octocat: favicon alpha -> grey silhouette ---
gh = Image.open(GH).convert("RGBA"); gp = gh.load()
gout = Image.new("RGBA", gh.size, (0, 0, 0, 0)); go = gout.load()
for y in range(gh.height):
    for x in range(gh.width):
        a = gp[x, y][3]
        if a > 60: go[x, y] = (GREY[0], GREY[1], GREY[2], a)
gh_tile = contain(gout, TILE)

# --- Record / replay: green rewind ring (with gap + arrowhead) + red record dot ---
S = 220; rec = Image.new("RGBA", (S, S), (0, 0, 0, 0)); d = ImageDraw.Draw(rec)
m = 26; bb = [m, m, S - m, S - m]
d.arc(bb, start=310, end=205, fill=GREEN + (255,), width=22)      # ring, gap at top-right
def pt(ang, rad): a = math.radians(ang); return (S / 2 + rad * math.cos(a), S / 2 + rad * math.sin(a))
hx, hy = pt(205, (S - 2 * m) / 2)                                  # arrowhead at the arc's leading end
d.polygon([(hx - 4, hy - 30), (hx + 26, hy - 2), (hx - 20, hy + 16)], fill=GREEN + (255,))
rr = 52; d.ellipse([S / 2 - rr, S / 2 - rr, S / 2 + rr, S / 2 + rr], fill=RED + (255,))
rec_tile = contain(rec, TILE)

# --- compose the row on a transparent canvas ---
canvas = Image.new("RGBA", (TILE * 3 + GAP * 2, TILE), (0, 0, 0, 0))
for i, t in enumerate([nv_tile, rec_tile, gh_tile]):
    canvas.paste(t, (i * (TILE + GAP), 0), t)

# --- half-block render ---
cp = canvas.load(); CW, CH = canvas.size
lines, shape = [], []
for y in range(0, CH, 2):
    s, sh = "", ""
    for x in range(CW):
        r1, g1, b1, a1 = cp[x, y]
        r2, g2, b2, a2 = cp[x, y + 1] if y + 1 < CH else (0, 0, 0, 0)
        tb, bbg = a1 < 60, a2 < 60
        if tb and bbg: s += ESC + "[0m "; sh += " "
        elif not tb and not bbg: s += f"{ESC}[38;2;{r1};{g1};{b1}m{ESC}[48;2;{r2};{g2};{b2}m▀"; sh += "#"
        elif not tb: s += f"{ESC}[0m{ESC}[38;2;{r1};{g1};{b1}m▀"; sh += "^"
        else: s += f"{ESC}[0m{ESC}[38;2;{r2};{g2};{b2}m▄"; sh += "v"
    s += ESC + "[0m"; lines.append(s); shape.append(sh)

open(OUT, "w", encoding="utf-8").write("\n".join(lines))
print(f"wrote {OUT}  ({CW} cells x {CH // 2} rows)")
print("--- shape: NVIDIA eye | record/replay | GitHub ---")
print("\n".join(shape))
