# installer — operator checklist

For the steps `scripts/build_and_install.sh` cannot verify by itself: the three that need
`sudo`, and the two that can run for an hour. Everything else the script checks inline and
prints a PASS/FAIL line for.

Run each block, compare against **Expect**, and record PASS/FAIL. Where a block says
*paste this back*, the output is the evidence someone is waiting on — copy it verbatim.

Estimated: **§A ~4 min**, **§B cold 20–100 min / warm never timed (that is what B3 measures)**,
**§C ~10 min** (three blocks, each a full rebuild — see §C).

> **Execution status (2026-08-12).** Every block below was authored and reviewed, and the
> script behaviour they check was verified headlessly wherever that was possible without
> `sudo` and without downloading weights. **§A3 and §B2/§B3 have not been executed on this
> machine** — see the status notes on those sections. Nothing here is a recorded measurement
> unless it says so.

---

## §A — the privileged install (`sudo rm` / `sudo cp` / `sudo codesign`)

> **Not executed (2026-08-12).** No privileged install has been run since the `--entitlements`
> argument was added to the install re-sign, so **A3 is unverified on the real
> `/Library/Input Methods` path**. What *was* verified: the same re-sign command run against a
> copy of `build/MarmotIM.app` in `/tmp` produces both iCloud entitlement keys and a signature
> that satisfies its Designated Requirement. That is the argument working, not this path
> working. A3 remains the procedure for whoever runs it.

### A1. Before-state (30 s, no sudo)

```bash
cd ~/Developer/MarmotIM
stat -f '%Sm' "/Library/Input Methods/MarmotIM.app/Contents/MacOS/MarmotIM"
codesign -d --entitlements - "/Library/Input Methods/MarmotIM.app" 2>&1 | tail -5
```

**Expect:** a timestamp from the *previous* install, and — on any bundle installed before
this change — **no entitlements block at all**. Both are fine; this is the baseline you
will compare A3 against. If the app is not installed yet, `stat` errors: also fine.

**PASS/FAIL:** informational only, cannot fail.

### A2. Run the install (~3 min, prompts for your password once)

```bash
bash scripts/build_and_install.sh
```

A bare run is the input method only — ASR provisioning is opt-in behind `--all`, and §B
provisions it separately.

**Expect, in order:** dictionary build → `BUILD SUCCEEDED` → `Stopping old process...` →
one `Password:` prompt → `OK: installed binary is the one just built (mtime check passed).`
→ `Input method: INSTALLED` and `ASR server:   NOT INSTALLED  (pass --all to provision it)`.

**FAIL if:** `WARNING: installed binary appears older than the build output` — the `sudo cp`
did not take. Do not continue; the rest of the checklist would be measuring the old bundle.

**FAIL if:** the run stops at `ERROR: dict/dictionary.db was not produced` — the Python
dictionary build failed, and that is a `tools/build_dictionary.py` problem, not an install one.

### A3. After-state — **paste this back**

```bash
codesign -dv --entitlements - "/Library/Input Methods/MarmotIM.app"
```

**Expect:** `TeamIdentifier=6R7CZ58K47`, `flags=0x10000(runtime)`, and **six** entitlements:

| key | why it matters |
|---|---|
| `com.apple.application-identifier` | **no iCloud Drive without it** — the daemon refuses the process |
| `com.apple.developer.team-identifier` | stable TCC identity: 麦克风 / 辅助功能 grants survive reinstalls |
| `com.apple.developer.icloud-container-identifiers` | the container |
| `com.apple.developer.ubiquity-container-identifiers` | the container |
| `com.apple.security.device.audio-input` | microphone under hardened runtime |
| `com.apple.security.get-task-allow` | dev build only; must never reach a notarized build |

**PASS:** all six present. `scripts/build_and_install.sh` now checks this itself and refuses to
finish otherwise, so reaching the end of the script is already most of this check.

**FAIL:** three entitlements and no `application-identifier`. That exact set is what the
hand-maintained `MarmotIM/MarmotIM.entitlements` produces, i.e. step 4b signed with the source
file instead of Xcode's generated `.xcent`. iCloud sync is dead in that state, and silently:
the app keeps writing its JSON files into the container while nothing reaches the cloud.
The unified log is where it shows up —
`(CloudDocs) [ERROR] **** bundle <pid> is lacking the 'com.apple.application-identifier' …`

> **Corrected 2026-08-13.** This section previously expected `flags=0x2(adhoc)` and a key named
> `com.apple.developer.icloud-services`. Both were wrong: the ad-hoc re-sign was removed (it made
> TCC grants impossible to keep), and this project's `.xcent` has never contained
> `icloud-services`. As written, the old text would have passed a broken install and failed a
> correct one.

*Note `-o runtime` is deliberately absent, so no `runtime` flag in that output is correct,
not a defect.*

### A4. The input method actually works (~1 min, by hand)

Switch to MarmotIM in the input-menu, type `nihao` in any text field, pick a candidate.

**Expect:** candidates appear; the selected one commits.
**FAIL if:** MarmotIM is missing from the input menu (the install did not register), or it
is selectable but produces no candidates (the bundled dictionary did not ship — re-check A2).

**Microphone:** you should **not** need to re-grant it. Measured (spike Q4): an existing
grant survives the ad-hoc re-sign. Only a previously *denied* state needs System Settings.

---

## §B — ASR provisioning, cold then warm

> **Not executed (2026-08-12).** The venv, the model and the LaunchAgent have never been
> provisioned on this machine, so **B2's cold wall-clock and B3's warm wall-clock do not
> exist** — the timings below are estimates derived from the work each step does, not
> measurements, and the "warm run" cost has never been timed end to end. What *was* verified
> headlessly: the Hub sizing call that feeds the free-disk check returns a real byte count,
> the offline path fails cleanly against a dead endpoint, a warm cache probe returns in
> ~0.14 s, and the `/health` gate writes its stamp only after a 200. B2/B3 remain the
> procedure for whoever runs them; record the `real` lines there.

### B1. Tear down (30 s) — **only if you want the cold path**

```bash
bash scripts/install_asr.sh --uninstall
rm -rf ~/Library/Application\ Support/MarmotIM/asr
# and, to force a re-download of ~4 GB:
rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3-ASR-1.7B-bf16
```

The last line is the expensive one — skip it and the cold run still rebuilds the venv and
reinstalls deps (~3 min) without re-downloading weights.

**Never** delete anything under `~/Library/Application Support/MarmotIM/` or the iCloud
container. Neither the installer nor this checklist touches user data.

### B2. Cold run — **record the wall-clock**

```bash
time bash scripts/install_asr.sh
```

**Expect:** `[asr]` lines for interpreter → venv → dependencies → free-disk check (it prints
`need … MB … free … MB`) → download with per-file progress → plist render → agent load →
`ASR server is up: {"status": …}`.

**Timings to expect:** deps 2–4 min; the download 15–100 min depending on the link. The
download resumes if interrupted, so re-running after a drop is cheap.

**FAIL if:** `not enough free disk` — that is the check working; free space and re-run.
**FAIL if:** `the agent is loaded but /health did not answer within 30s` — run the two
commands it prints (`tail -20` on the error log, `launchctl print`) and paste those instead.

**Paste back:** the `real` line from `time`, and the final `ASR server is up:` line.

### B3. Warm run — the idempotency claim

```bash
time bash scripts/install_asr.sh
```

**Expect:** `venv is present and is Python 3.12`, `Dependencies match …  — nothing to
install`, `Model … is already in the Hugging Face cache`, `… is already current`,
`Agent is loaded and current — leaving it running`, then `ASR server is up:`.

**PASS:** `real` under ~5 s and **no** download, no pip, no restart line.
**FAIL:** any of `Downloading`, `Installing server dependencies`, or `restarting the agent`
appearing on a run where nothing changed — that is a broken stamp, not a slow machine.

**Paste back:** the `real` line.

### B4. It survives a logout (~2 min)

Log out and back in, then:

```bash
launchctl print "gui/$UID/com.marmotim.asr" | head -5
curl -s http://127.0.0.1:58471/health
```

**Expect:** the job is listed, and `/health` returns JSON. `status` may be `loading`
immediately after login — that is correct, the weights take time to read. Re-run the `curl`
after a minute and it becomes `ready`.

**FAIL if:** `Could not find service` — `RunAtLoad`/`KeepAlive` did not survive, or the
plist points at a checkout that has since moved (it hardcodes this checkout's path).

### B5. Loopback only

```bash
lsof -nP -iTCP:58471 -sTCP:LISTEN
```

**Expect:** exactly one line, bound to `127.0.0.1:58471`.
**FAIL if:** it shows `*:58471` — the server would be reachable from the network, and this
service is unauthenticated by design.

---

## §C — the two flags, and ASR failure not breaking the IME

Each block here re-runs the **whole** script, so each costs a full rebuild (~3 min) and one
password prompt. Run them back to back rather than one per sitting.

### C1. a bare run touches nothing ASR-side

```bash
ls -ld ~/Library/LaunchAgents/com.marmotim.asr.plist
stat -f '%Sm' ~/Library/LaunchAgents/com.marmotim.asr.plist
bash scripts/build_and_install.sh
stat -f '%Sm' ~/Library/LaunchAgents/com.marmotim.asr.plist
```

**Expect:** the two `stat` timestamps are identical, and the run ends with
`ASR server:   NOT INSTALLED  (pass --all to provision it)`.
**FAIL if:** the timestamp moved — provisioning ran despite the flag.

### C2. `--reinstall-asr` forces the rebuild

```bash
bash scripts/build_and_install.sh --reinstall-asr
```

**Expect:** the ASR section shows `Creating the venv`, `Installing server dependencies`,
and `restarting the agent` even though the previous run left everything current — but still
`Model … is already in the Hugging Face cache`. `--reinstall-asr` rebuilds the environment;
it does not re-download 4 GB of weights, and it must not run the free-disk check.

**FAIL if:** it prints `is not cached — checking free disk` while the weights are present.

### C3. An ASR failure leaves the IME installed

Simulate it without breaking anything real:

```bash
mv scripts/install_asr.sh /tmp/install_asr.sh.bak
bash scripts/build_and_install.sh ; echo "exit=$?"
mv /tmp/install_asr.sh.bak scripts/install_asr.sh
```

**Expect:** `WARNING: scripts/install_asr.sh is missing`, then `Input method: INSTALLED`,
then `ASR server:   FAILED`, and **`exit=0`**.

**PASS:** exit 0 with the input method reported as installed. The exit status reports the
input-method install deliberately — that is this script's product, and dictation being
unavailable is not a reason to call the install failed.
**FAIL if:** the script exits non-zero, or stops before `Input method: INSTALLED`.

*(Do not forget the third line. Leaving `install_asr.sh` renamed makes every later run
report a false ASR failure.)*
