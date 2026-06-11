# Antivirus & the `Sabsik.FL.A!ml` false positive

Microsoft Defender flags the release exe as **`Trojan:Win32/Sabsik.FL.A!ml`**.

The **`!ml`** suffix is the whole story: it's a **machine-learning *guess***, not a
signature match to real malware. `Sabsik.FL.A!ml` is Defender's catch-all ML
bucket that fires on huge numbers of legitimate **unsigned, brand-new,
low-reputation** executables — especially ones that touch other processes. This
tool injects a few bytes into `nvcontainer.exe` (its whole job), is unsigned, and
has near-zero download reputation, so it lands squarely in that bucket. The
source is open and auditable; it is a false positive.

There are exactly **two** real fixes, and both require the **project owner's
identity** (no automation/script can do them for you — by design):

## 1. Report it to Microsoft — clears it for everyone (~1 day, free)

1. **Get the file back from quarantine** (needs admin):
   Windows Security → *Virus & threat protection* → *Protection history* → the
   `Nvidia_Instant_Replay_Fix.exe` item → *Actions* → **Restore**.
   (or, from an **elevated** PowerShell: `& "$env:ProgramFiles\Windows Defender\MpCmdRun.exe" -Restore -All`)
2. Go to **https://www.microsoft.com/en-us/wdsi/filesubmission** and **sign in**.
3. Product family: **Microsoft Defender**. Upload the `.exe`.
   Detection name: `Trojan:Win32/Sabsik.FL.A!ml`.
   Reason: **"I believe this file is clean / incorrectly detected"**, and tick
   that you're the **software developer**. Paste the repo URL.
4. Microsoft's analysts review and clear the hash, usually within a day. Each new
   release build is a new hash, so re-submit per release — *or sign it* (below) so
   it stops permanently.

## 2. Code signing — the permanent cure (free for open source)

`!ml` is heavily weighted by reputation + signature. A binary signed by a known
publisher essentially **stops** Sabsik-class false positives. Free via
**[SignPath.io](https://signpath.io/)** for OSS:

1. Create a SignPath.io account → apply for the free **OSS** plan → link this repo.
2. SignPath gives you an **Organization ID**, a **Project**, and a **Signing
   Policy** slug, plus an **API token**. Add the token as the repo secret
   **`SIGNPATH_API_TOKEN`** (Settings → Secrets and variables → Actions).
3. In `.github/workflows/release_on_tag.yml`, after the build artifact is
   available and before the release is attached, add:

   ```yaml
   - name: Sign exe (SignPath OSS)
     uses: signpath/github-action-submit-signing-request@v1
     with:
       api-token: ${{ secrets.SIGNPATH_API_TOKEN }}
       organization-id: <YOUR_SIGNPATH_ORG_ID>
       project-slug: nvidia-instant-replay-fix
       signing-policy-slug: release-signing
       artifact-configuration-slug: exe
       wait-for-completion: true
       output-artifact-directory: ./signed
   # then attach ./signed/Nvidia_Instant_Replay_Fix.exe to the release
   ```

Once signing is live, downloads stop tripping Defender and the SmartScreen
"unknown publisher" warning goes away as reputation accrues.

---

Until then, the README tells users to verify on VirusTotal and use the
**Keep**/exclusion path — standard for open-source tools that do process
injection (e.g. Cheat Engine, Process Hacker, many game mods all carry the same
heuristic flags).
