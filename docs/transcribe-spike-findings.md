# transcribe spike — findings

Measurements, not research. Four questions gated the whole transcribe feature. **All four were
answered on 2026-08-12 and all four PASS** — see §5, which is the section downstream goals read.

| # | Question | Status |
|---|---|---|
| Q1 | Does an `LSBackgroundOnly` + `LSUIElement` IMK process get a microphone TCC prompt, and can it be granted? | **PASS** (§5) |
| Q2 | Does `AVAudioEngine` capture actually deliver buffers in that process? | **PASS** (§5) |
| Q3 | Does a global `flagsChanged` monitor there see right-Command press *and* release as distinct events, separable from left? | **PASS** (§5) — and needs **no** Accessibility grant |
| Q4 | Does the mic grant survive an ad-hoc re-sign + reinstall? | **PASS** (§5) |

Every question needed a human at the keyboard (sudo, clicking **允许**, pressing a physical key),
so §3 is the procedure that was run and §5 records its output. The harness that produced these
lines has since been deleted (§2) — §5 is now the only surviving record, so do not paraphrase it
away.

**The feature is viable and needs exactly one TCC grant: the microphone.** The one thing §5 leaves
open is a design question for `hotkey-audio`, not a measurement — see Q3.

---

## 1. Signing and entitlements — answered, no operator needed

Measured on 2026-08-12 with `codesign -dv --entitlements -` against both artifacts:

| | `build/MarmotIM.app` (what Xcode produces) | `/Library/Input Methods/MarmotIM.app` (what actually runs) |
|---|---|---|
| Signature | `Apple Development: …`, TeamIdentifier `6R7CZ58K47` | `Signature=adhoc`, TeamIdentifier **not set** |
| CodeDirectory flags | `0x10000(runtime)` | `0x2(adhoc)` — **no hardened runtime** |
| Entitlements | 5 keys (`application-identifier`, both iCloud keys, `team-identifier`, `get-task-allow`) | **none — the block is empty** |

The cause is one line. Xcode signs with
`--sign … -o runtime --entitlements …/MarmotIM.app.xcent`, and then `scripts/quick_update.sh:84`
runs `sudo codesign --force --deep --sign -` with no `--entitlements` and no
`--preserve-metadata`, which discards both the runtime flag and every entitlement.

**Is `com.apple.security.device.audio-input` required?** No — not on this app, and not on the
dev-install path at all:

- It is an **App Sandbox** resource-access key. MarmotIM is not sandboxed
  (`com.apple.security.app-sandbox` is absent from `MarmotIM/MarmotIM.entitlements`, which holds
  only the two iCloud keys), so there is no sandbox to punch a hole in.
- The Hardened Runtime honours the same key, and the Xcode build does set
  `ENABLE_HARDENED_RUNTIME=YES` — but the **installed** binary is re-signed ad-hoc with no
  runtime flag, so hardened-runtime enforcement does not apply to the process that runs.
- For a non-sandboxed process, microphone access is gated by **TCC + `NSMicrophoneUsageDescription`**,
  and nothing else. The usage string is now present in `MarmotIM/Info.plist` and survives plist
  processing into both `build/MarmotIM.app` and the DerivedData bundle (verified with `PlistBuddy`).

So: **do not add the entitlement now.** It would be inert on the dev install and is the wrong
lever. Two consequences belong to other goals:

- **`installer`** — if MarmotIM is ever shipped Developer-ID-signed and notarized (retaining
  `-o runtime`), revisit this, and fix the install re-sign so it stops throwing entitlements away.
  Today the installed app has *no* iCloud entitlements either; sync works by other means, but that
  is a latent bug independent of transcribe.
- **Q4 is a direct consequence of the same line.** `--sign -` produces a fresh cdhash on every
  build, and an ad-hoc binary has no stable designated requirement for TCC to match on, so the
  hypothesis under test is that the grant is lost on every reinstall. §5/Q4 records what actually
  happens.

## 2. The harness — **removed**

`MarmotIM/Services/TranscribeSpike.swift` was throwaway and is **gone**: deleted 2026-08-12 once
§5 was complete, along with its four `TRANSCRIBESPIKE_*` `project.pbxproj` entries and the one
`runIfEnabled()` call in `AppDelegate.swift`. Nothing in the tree references it any more, and the
`MarmotIMTranscribeSpike` user default that armed it is dead — the host also ran
`defaults delete …` after the session.

`hotkey-audio` starts from its own stubs (`AudioRecorder.swift`, `TranscribeHotKey.swift`). The
harness was never a prototype of them, which is why it was removed rather than handed over: a
second global `flagsChanged` monitor and a second `AVAudioEngine` living in the same process would
surface later as a phantom double-fire nobody could reproduce.

For the record, what it did while it existed: gated inert behind the user default, it requested mic
access, started an `AVAudioEngine` tap, installed global + local `flagsChanged` monitors, and tore
everything down after 60 s.

**Where the evidence landed — a durable fact about this machine, worth keeping after the harness.**
Measured 2026-08-12: every MarmotIM `NSLog` payload renders as
`<private>` in the unified log on this stock macOS 26 machine, so `log show … CONTAINS "SPIKE"`
returns nothing even when the harness has demonstrably run. Turning that off needs
`sudo log config --mode private_data:on`, a system-wide privacy change we are not requiring.
So the harness routes **every** line through one helper (`TranscribeSpike.log`) that writes to
*both* `NSLog` (kept — repo convention) and a plain file, verbatim and unredacted:

    /tmp/marmotim-spike.log

The file is truncated at spike START, its path is echoed in the START line, and it is `fflush`ed
after every line so a crash still leaves partial evidence. **The file is the surface to read**;
the unified log is not usable for this.

## 3. Operator procedure — **executed 2026-08-12 (two passes); results in §5**

Kept verbatim as the record of how §5 was obtained. **Steps 0–7 and 9 must not be run again** — the
harness they drive no longer exists (§2), so step 1a would now fail by construction and the rest
would produce nothing. Read §5 instead. **Step 8 is the exception: it is still outstanding, needs
no harness, and is the last thing this goal is waiting on.**

Two details below are superseded by what was actually measured: step 6 predicted
`AXIsProcessTrusted=YES`, and it came back `NO` with the events still delivered (§5/Q3); and
`scripts/quick_update.sh` has since been renamed to `scripts/build_and_install.sh` (the old name is
a shim, so the commands still work).

Run top to bottom. Two terminals: **T1** for commands, **T2** tailing the evidence file.

> **Use `/usr/bin/log`, never bare `log`.** In this user's zsh, `log` is shadowed by a shell
> function that errors *"too many arguments"*, so a bare `log stream` / `log show` silently
> produces nothing and reads as "the harness never ran". (The same defect exists in the two other
> `log`-using tips in this repo — `scripts/quick_update.sh:115` and `docs/icloud-setup.md:163`;
> *not* `README.md`, which contains no `log` invocation at all. Neither file is this goal's to
> edit; flagged, not fixed. **`quick_update.sh` prints its tip on screen at the end of step 1 —
> ignore it**, it is doubly broken here: bare `log`, and MarmotIM's lines are `<private>`
> regardless.) Even with the
> absolute path the unified log is only a secondary check: MarmotIM's
> lines come back `<private>`. Read `/tmp/marmotim-spike.log` instead — see §2.

**Step 0 — record the pre-state.**
```sh
cd ~/Developer/MarmotIM
codesign -dv --entitlements - "/Library/Input Methods/MarmotIM.app" 2>&1 | head -8
```
> The bundle installed at 16:17 on 2026-08-12 already carries `NSMicrophoneUsageDescription`
> (`Info.plist entries=34`, was 33) and the mic grant was made against *it*.

**Step 1 — build + install. This one is not optional.**
```sh
bash scripts/quick_update.sh          # asks for sudo
```
> **Skipping this makes the whole run unreadable.** The installed bundle predates the
> file-logging fix: measured 2026-08-12, its binary (mtime 16:18) contains 15 `SPIKE` strings and
> **zero** occurrences of `marmotim-spike.log`, against a source of 16:47. So the currently
> installed harness logs only via `NSLog`, and `NSLog` is `<private>` here (§2) — run it and
> `tail -F` in step 2 follows a file that is never created. That is indistinguishable from *the
> harness never ran*, and this run has already lost a wave to exactly that false reading.
> Secondary: step 1 also produces a fresh cdhash, which is what makes Q4 measurable.

**Step 1a — precondition. Fails loudly if step 1 did not take.**
```sh
strings -a "/Library/Input Methods/MarmotIM.app/Contents/MacOS/MarmotIM" | grep -c marmotim-spike.log
# must print >= 1. If it prints 0, step 1 did not land — do not continue.
```
> Valid **only against the installed (Release) bundle**, where the code lives in the main
> executable. Do **not** run this check against the Debug product: in the Xcode Debug
> configuration `…/Build/Products/Debug/MarmotIM.app/Contents/MacOS/MarmotIM` is a ~59 KB stub
> that returns 0 matches while the real code sits in `MarmotIM.debug.dylib` beside it — a false
> negative that looks identical to a failed build.

**Step 2 — arm the spike and start tailing the evidence file.**
```sh
defaults write com.marmotim.inputmethod.MarmotIM MarmotIMTranscribeSpike -bool YES
```
In **T2** (the file is truncated and recreated at each spike START, so `-F` follows the new one):
```sh
tail -F /tmp/marmotim-spike.log
```
Secondary, and expect `<private>`:
```sh
/usr/bin/log stream --predicate 'process == "MarmotIM"' --info | grep SPIKE
```

**Step 3 — restart the IME so the harness runs.**
```sh
killall MarmotIM; sleep 1; open "/Library/Input Methods/MarmotIM.app"
```

**Step 4 — Q1 (already PASSed, see §5) and Q4 (this run answers it).** The very first line after
START is the one that matters now:
```
SPIKE/Q1: authorizationStatus BEFORE request = <authorized|notDetermined|denied>
SPIKE/Q1: requestAccess granted=YES status AFTER = authorized
```
Because the grant was made against the bundle installed at 16:17 and step 1 produced a **fresh
cdhash**, that BEFORE line *is* the Q4 answer — see step 7. If a prompt appears again, click
**允许 / Allow** and note that it appeared.

**Step 5 — Q2.** Speak for ~5 s immediately after the grant.
```
SPIKE/Q2: input format sampleRate=… channels=… commonFormat=… interleaved=…
SPIKE/Q2: engine started — SPEAK NOW for ~5s
SPIKE/Q2: buffer #1 frameLength=… peak=…
```
- **PASS** — `engine started`, buffers arrive with `frameLength > 0`, and `peak` is clearly
  non-zero while speaking (≫ 0.001). Copy the format line verbatim into §5 — `hotkey-audio` needs
  the real hardware sample rate to size its conversion to the contract's float32/16 kHz/mono.
- **FAIL** — `engine.start() threw`, `degenerate input format`, or every `peak` ≈ 0 (delivering
  silence = the grant is nominal only).

**Step 6 — Q3.** Hold **right** Command ~1 s, release. Then the same with **left** Command.
```
SPIKE/Q3: AXIsProcessTrusted=YES (NO new prompt expected …)
SPIKE/Q3: [global] keyCode=0x36 RIGHT-COMMAND DOWN rawFlags=0x…
SPIKE/Q3: [global] keyCode=0x36 RIGHT-COMMAND UP   rawFlags=0x…
SPIKE/Q3: [global] keyCode=0x37 LEFT-COMMAND  DOWN …
```
- **PASS** — right Command yields **two** lines, DOWN then UP; left Command is distinguishable by
  `keyCode`; `AXIsProcessTrusted=YES`; and **no new Accessibility prompt appears** (the existing
  `SelectionCapture` grant covers it).
- **FAIL** — only one line per press (no release event), both sides report the same `keyCode`, a
  new Accessibility prompt appears, or `globalNil=YES`. Note whether the `[local]` monitor behaves
  differently from `[global]` — `hotkey-audio` needs both.

**Step 7 — Q4, the re-sign survival test.** Step 1 already re-signed ad-hoc, so the step-4 BEFORE
line answers this and the reinstall below is only needed if you want a second data point. Either
way, do it **without touching System Settings**:
```sh
bash scripts/quick_update.sh
killall MarmotIM; sleep 1; open "/Library/Input Methods/MarmotIM.app"
```
- **PASS** — `SPIKE/Q1: authorizationStatus BEFORE request = authorized` on a run whose cdhash is
  newer than the grant: the grant survived a fresh cdhash.
- **FAIL** — `notDetermined` (re-prompts every rebuild) or `denied` (silently broken). Record
  *which*; `denied` is much worse than `notDetermined` because there is no prompt to re-accept and
  the user must clear it in System Settings → 隐私与安全性 → 麦克风.

**Step 8 — two extra checks that close item-0022. NOT YET DONE — this is the one part of the
procedure that is still outstanding, and it is the only part still worth running.** It needs the
real installed IME, which is why it is not a unit test. It does **not** need the harness, so it
survives §2's deletion; it takes about a minute.
> **Prerequisite:** MarmotIM must be among the enabled input sources for its menu-bar item to
> exist. As of 2026-08-12 it was not (only *U.S.* and CharacterPaletteIM were). Add it in
> System Settings → 键盘 → 输入法 → **+** first.
1. Open MarmotIM's settings from the input-method menu. **PASS** if a **转写** tab appears fourth
   (after 标点符号, before 主题) with a mic icon, and clicking it renders the stub view without
   crashing.
2. While the settings window is open, **toggle any setting** (e.g. flip a checkbox on 基本 and flip
   it back). Every control calls `SettingsViewModel.save()` → `AppConfig.save()`
   (`SettingsWindowController.swift:203`), which rewrites the *whole* config file including the new
   block. Then:
   ```sh
   python3 -m json.tool ~/Library/Application\ Support/MarmotIM/config.json | grep -A12 transcribe
   ```
   **PASS** if a `transcribe` block is present with `"enabled": false`, `"host": "127.0.0.1"`,
   `"port": 58471`, `"modelVariant": "mlx-community/Qwen3-ASR-1.7B-bf16"`,
   `"holdThresholdMilliseconds": 250`. `maxNewTokens` is **absent** — that is correct, not a bug
   (see §6). This proves the real `save()`/`load()` round-trip, not just `JSONEncoder`.
   > **Do not use `killall` as the trigger** — an earlier draft of this step did, on the assumption
   > that SIGTERM runs `applicationWillTerminate` and therefore `AppDelegate.swift:50`'s
   > `config.save()`. Measured 2026-08-12 17:00, after several IME restarts that day:
   > `config.json` was still dated **Jul 21 00:02** and contained no `transcribe` key. So the kill
   > path does not produce the write, and using it would have read as a config-schema failure when
   > nothing was wrong. A settings toggle is the reliable trigger.

**Step 9 — hand back the evidence, then disarm.**
```sh
cat /tmp/marmotim-spike.log          # paste this verbatim — it is the whole result
defaults delete com.marmotim.inputmethod.MarmotIM MarmotIMTranscribeSpike
killall MarmotIM; open "/Library/Input Methods/MarmotIM.app"
```

## 4. If Q1 fails outright — *moot, Q1 passed (§5). Kept as the standing rule for Q2/Q3.*

Stop. Do not add an entitlement, do not shell out to a helper app, do not try a bundled XPC
service. The plan's shape depends on the answer and a workaround invented here would be built on
an unmeasured assumption.

## 5. Results

| Q | Verdict | Evidence |
|---|---|---|
| Q1 | **PASS** | Operator-confirmed, 2026-08-12: the microphone prompt **appeared on its own** after restarting the freshly-installed bundle carrying `NSMicrophoneUsageDescription`, and the human clicked **允许**. |
| Q2 | **PASS** | 599 buffers delivered over ~60 s, `frameLength=4800`, input format **48000 Hz / 1 ch / float32 / non-interleaved** from the built-in *MacBook Air Microphone*. |
| Q3 | **PASS** | Both keys produced a distinct DOWN and UP: `keyCode=0x36 RIGHT-COMMAND` and `keyCode=0x37 LEFT-COMMAND`. Delivered by the **global** monitor with `AXIsProcessTrusted=NO`. |
| Q4 | **PASS** | `authorizationStatus BEFORE request = authorized` on a bundle reinstalled at 16:58 with a fresh cdhash — the grant survived the ad-hoc re-sign. |

**Q1 — a background-only IMK process can surface and be granted mic TCC.** This was the
stop-and-rethink risk in the brief, and it came back in the good direction: the feature is viable.

The detail that matters for downstream design: the prompt was **self-surfaced by the process**, not
granted by hand in System Settings → 隐私与安全性 → 麦克风. An `LSBackgroundOnly` + `LSUIElement`
process with no menu-bar presence *does* get TCC UI. Consequences:

- `settings-ui` does **not** need a System-Settings walkthrough as the first-run path — first-run
  dictation can simply call `requestAccess` and let the OS prompt.
- A **denied**-state affordance is still worth having (deep-link / instructions), because once the
  user denies, no further prompt is ever shown and only System Settings can undo it.

**Q2 — capture works in-process; the format `hotkey-audio` must convert from is 48 kHz mono float32.**
The input node reports `sampleRate=48000.0 channels=1 commonFormat=1 (pcmFormatFloat32)
interleaved=NO`, and 599 buffers of `frameLength=4800` (100 ms each) arrived over the 60 s window.
So `AudioRecorder` needs a **48 kHz → 16 kHz** conversion; it is already mono and already float32
non-interleaved, which is exactly the contract's wire format, so no channel mixdown or type
conversion is required — only resampling.

*Do not read the logged `peak` values as an input-level measurement.* The harness logs buffers 1–5
and then **every 50th**, i.e. one 100 ms sample every 5 s, so a 5 s utterance contributes about
**one** logged buffer. Observed peaks (0.005–0.026) are therefore a near-random sample of a 60 s
window that was mostly silence, not evidence of a quiet microphone. Levels were deliberately left
uncharacterised: `hotkey-audio` should measure properly if it wants to decide about gain
normalisation.

**Q3 — the hold-to-talk mechanism is confirmed, and it needs NO Accessibility permission.**
Right and left Command are cleanly separable, each delivering a distinct press and release:

```
[global] keyCode=0x37 LEFT-COMMAND  DOWN rawFlags=0x100108
[global] keyCode=0x37 LEFT-COMMAND  UP   rawFlags=0x100
[global] keyCode=0x36 RIGHT-COMMAND DOWN rawFlags=0x100110
[global] keyCode=0x36 RIGHT-COMMAND UP   rawFlags=0x100
```

Two independent discriminators are available, which is worth knowing if one ever proves unreliable:
the **`keyCode`** (`0x36` vs `0x37`) and the **device-dependent modifier bits** in `rawFlags`
(`0x10` right vs `0x08` left).

The significant finding: **`AXIsProcessTrusted=NO` across both passes, yet the global monitor
delivered every event.** MarmotIM does not currently hold Accessibility permission, so the plan's
assumption that the hotkey would ride on `SelectionCapture`'s existing grant is **wrong — and
wrong in the helpful direction**. A global `NSEvent` monitor for `.flagsChanged` (modifier-only
transitions) does not require Accessibility, unlike a `keyDown` monitor or a `CGEventTap`.
Consequences for `hotkey-audio`:

- Do **not** gate hotkey registration on `AXIsProcessTrusted()`, and do not prompt for
  Accessibility on behalf of dictation. It would be a permission request the feature does not need.
- Keep the observation scoped to `.flagsChanged`. Adding `.keyDown` to the same monitor would
  silently re-introduce the Accessibility requirement.

### Open design question — `hotkey-audio` owns this, the spike does not resolve it

**Decision 1's abort-on-any-other-key rule cannot be implemented with a `.flagsChanged` monitor
alone.** `.flagsChanged` fires only on modifier transitions; it structurally cannot observe a
letter, digit or arrow key being pressed while right Command is held, so there is no event to abort
on. The tradeoff, stated plainly so it is decided rather than stumbled into:

| Option | Cost |
|---|---|
| Add `.keyDown` to the global monitor | Re-introduces the Accessibility (`AXIsProcessTrusted`) requirement that Q3 just proved the feature does **not** otherwise need — a whole extra TCC grant and first-run walkthrough, bought for one guard rail. |
| Drop or weaken the abort rule | Decision 1 changes. A stray keystroke during a hold no longer cancels; the recording runs to its natural release or the `maxRecordingSeconds` guard. |
| Abort on a *modifier* only | Free (still `.flagsChanged`): e.g. pressing Shift/Control/Option, or the *other* Command, during a hold cancels. Covers the accidental-chord case, not the typed-a-letter case. |

The spike measured the constraint; it deliberately does not pick. `hotkey-audio` decides and flags
the choice if it lands on the Accessibility-requiring option, since that would change what
`installer` and `settings-ui` must say about permissions.

**Q4 — the mic grant survives an ad-hoc re-sign, so dev rebuilds do not re-prompt.**
The grant was made against the bundle installed at 16:17; the bundle was rebuilt and reinstalled at
16:58 (new cdhash, ad-hoc, entitlements stripped per §1), and the harness reported
`authorizationStatus BEFORE request = authorized` before issuing any `requestAccess`. The
TCC-churn risk recorded in `exploration.md` §5 does not materialise for the microphone on this
install path. No re-grant reminder is needed in the installer.

## 6. Correction to an earlier claim (`asr-client`, `asr-server`: read this)

A previous note said a nil Swift `Codable` optional encodes as an explicit `"max_new_tokens": null`
unless the client writes a custom `encode(to:)`. **That is wrong**, verified by compiling and
running the actual shape:

```
struct R { let audio: String; let maxNewTokens: Int? }   // CodingKey "max_new_tokens"
nil → {"audio":"x"}
512 → {"audio":"x","max_new_tokens":512}
```

Swift's synthesized encoder uses `encodeIfPresent` for optionals, so nil ⇒ the **key is omitted
entirely**, never `null`. Both spellings are legal under the locked semantics (absent/null ⇒ server
passes `max_tokens=None` ⇒ library auto-computes `max(256, duration*50)`), so nothing breaks — but
the server must not be written to *require* the key, and any test asserting a literal `null` on the
wire will fail.

## 7. Manual acceptance script — dictation end to end (`integration`, item-0024)

Everything below is verified automatically **except** what needs a real `IMKInputController`,
a real microphone and a real running server. These four cases are what a human must run once.
They are ordered so a failure in one does not invalidate the next.

**Preconditions.** MarmotIM installed and selected as the current input source; the ASR
LaunchAgent running (`launchctl list | grep com.marmotim.asr`); dictation enabled in
Settings → 语音转写.

1. **Happy path.** In TextEdit, hold **right Command**, say a sentence, release.
   Expect: `🎤 录音中` near the caret while held → `转写中…` on release → the text lands
   **at the caret**, not in a dialog and not via the clipboard.

2. **Mid-composition insertion — the case with a known cost.** Type `ceshi` so a candidate
   window is up and the code is still composing, then hold right Command and dictate.
   Expect: the pending code is **discarded** (candidate window closes, no `ceshi` left behind)
   and the dictated text is inserted. This is a deliberate trade — see the `integration` flag:
   the alternative was leaving the IME's composition state disagreeing with the client's, which
   does not self-heal. If the discard is judged wrong, refusing the insertion is the alternative.

3. **Inert hold — "nothing happened" is the feature.** Switch to another input source
   (e.g. ABC / 拼音), then hold right Command and speak.
   Expect: **nothing at all** — no HUD, no mic indicator in the menu bar, no text anywhere,
   and no clipboard fallback. `log show --predicate 'process == "MarmotIM"'` should carry the
   "不是当前输入源" line exactly **once per process**, not once per hold.
   This is the case most likely to be mis-filed as a bug; it is decision 3 working.

4. **Degraded mode — the never-break-typing guarantee.**
   `launchctl bootout gui/$UID/com.marmotim.asr` (or stop it however it was started), then:
   a. Type normally for a minute: candidates, ranking, selection, backspace, 中/英 toggle.
      Expect: **no difference of any kind** — this is the same property the byte-for-byte
      comparator asserts in `TranscribeDegradedModeTests`, checked here against the real IME.
   b. Hold right Command and speak. Expect: a brief `转写服务未运行` near the caret that
      dismisses itself, **no text inserted**, no dialog, no hang, no stuck HUD.
   c. Restart the agent and repeat case 1 — dictation recovers without restarting MarmotIM.
