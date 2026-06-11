# Demo media — what to record

The README embeds three files from this `docs/` folder. Record them once and
commit them; until then those images show as broken on the repo page.

Recommended tool: **[ScreenToGif](https://www.screentogif.com/)** (free) — it
records a screen region to GIF and has a built-in editor for drawing the arrow.

| File | What to capture |
|------|-----------------|
| `docs/install.gif` | Double-click `Run.bat` and record the whole animated installer: the color bloom, the iALTURKi banner shimmer, the NVIDIA eye + icon row, the steps going green, and the rainbow "INSTALL COMPLETE" box. Trim to ~5–10 s. |
| `docs/applemusic-toast.gif` | With Instant Replay **on**, open Apple Music (or a Netflix/DRM browser tab). Record NVIDIA's "a protected app is preventing desktop capture" toast appearing — **then draw an arrow** pointing at the Instant Replay indicator (overlay toggle still green / `nvidia-smi` encoder still active) to show it is **NOT** disabled. ScreenToGif → Editor → draw the arrow + a "still recording ✓" label. |
| `docs/after-fix.png` | A screenshot proving a clip saved while protected content was on screen — e.g. the NVIDIA Gallery showing the saved Instant Replay clip, or the overlay confirming the save. |

## Tips
- Use **Windows Terminal** for the install GIF so the truecolor + half-block art render fully.
- Keep GIFs reasonably small (a few MB) — crop tight, ~15 fps, limited length.
- Filenames must match exactly (`install.gif`, `applemusic-toast.gif`, `after-fix.png`); then `git add docs/ && git commit && git push`.
