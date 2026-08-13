# marmot-asr-server

Local MLX ASR service. Keeps a Qwen3-ASR model warm and answers the HTTP contract in
`.flow/plan/2026-08-12-transcribe/reference-api-contract.md` on `127.0.0.1`.

Self-contained: this service knows nothing about MarmotIM. Installation, venv creation and the
LaunchAgent are **not** here — they belong to the installer.

**Status.** Complete. Every endpoint in the contract — `GET /health`, `POST /transcribe`,
`POST /reload` — is implemented, exercised against a real uvicorn process, and documented below.
`pytest tests` is green with no weights and no `mlx` installed (§8). §4 carries the measured
per-variant latency for a ~5 s utterance and the `context` A/B, which are the last things that
were open; nothing is outstanding.

Two results worth knowing without reading §4 in full: a 4.09 s utterance takes **0.44 s** on
`0.6B-bf16` and **1.08 s** on `1.7B-bf16`, and **`context` really does change the transcript** —
supplying rare proper nouns recovers words the model otherwise mangles, and supplying *wrong* ones
corrupts words it had right.

*(Sections below are the record of what was measured, not a plan. If a section and this
paragraph disagree, the section is right — it is closer to the experiment.)*

---

## 1. Library grounding — `qwen3-asr-mlx` 0.2.0

Measured against a scratch `python3.12 -m venv` with `pip install qwen3-asr-mlx`
(`/opt/homebrew/bin/python3.12`, Python 3.12.13). Latest published version is **0.2.0**
(0.1.0, 0.1.1 also exist). Everything below was read from the installed source or executed
against it — not from the PyPI page or the GitHub README, both of which are wrong in places.

### Resolved dependency tree

```
huggingface-hub>=1.0.0   mlx>=0.31.1   numpy>=1.26.4   soundfile>=0.13.1   tokenizers>=0.23.0
```

`sounddevice` is an optional `[audio]` extra; `pytest` a `[dev]` extra. **`pyannote` cannot enter
the tree** — it is not a dependency, optional or otherwise, and the package has no diarization
code at all. Actually installed: `mlx 0.32.0`, `mlx-metal 0.32.0`, `numpy 2.5.2`,
`tokenizers 0.23.1`, `huggingface-hub 1.27.0`, `soundfile 0.14.0`.

### The real API

There is **no module-level `transcribe()`**. The entry point is a class:

```python
from qwen3_asr_mlx import Qwen3ASR
model = Qwen3ASR.from_pretrained("mlx-community/Qwen3-ASR-1.7B-bf16")  # or a local dir
model.warm_up()                       # 0.5 s of silence, pre-compiles the MLX graph
result = model.transcribe(samples)    # samples: 1-D float32 numpy @ 16 kHz
result.text, result.language, result.duration
model.close()                         # frees encoder/decoder, gc, mx.clear_cache()
```

`from_pretrained` takes a local directory **or** a Hub repo id; a non-directory argument is passed
to `snapshot_download`. `Qwen3ASR.__init__(config, encoder, decoder, tokenizer)` is public, which
matters for the 8-bit workaround below.

Full signature of `transcribe`, with the defaults the library actually uses:

| Parameter | Default | Note |
|---|---|---|
| `audio` | — | `str`/`Path` **or** `np.ndarray`. Array path requires 1-D; it is `np.asarray(..., dtype=np.float32)`-cast in place. **No file is written.** |
| `language` | `None` | `None`/`"auto"`/`""` ⇒ auto-detect. Accepts ISO 639-1 or full name. |
| `temperature` | `0.0` | 0.0 ⇒ `argmax`, i.e. greedy. |
| `top_p` | `1.0` | disabled |
| `top_k` | `0` | disabled |
| `repetition_penalty` | **`1.2`** | note: `generate()`/`sample()` default to `1.0`; `transcribe()` overrides to 1.2 |
| `max_tokens` | `None` | auto ⇒ `max(256, int(duration * 50))` |
| `repetition_context_size` | `100` | |
| `chunk_duration` | **`1200.0`** | seconds |
| `context` | `None` | free-form hotword string |

### Contradictions with `exploration.md` and the published docs

1. **The parameter surface in `exploration.md` §7 does not exist.** There is no `diarize`,
   `draft_model`, `num_draft_tokens`, `dtype`, `return_timestamps`, `return_chunks`,
   `forced_aligner`, `verbose`, or `on_progress`. That signature belongs to some other package.
   Consequence: the brief's "keep `diarize` off, `return_timestamps`/`return_chunks` off, no
   `draft_model`" constraints are **vacuously satisfied** — there is nothing to switch off, and no
   way to switch it on.

2. **`chunk_duration` defaults to 1200.0 s (20 minutes), not ~30 s** as `exploration.md` §10
   assumed. Chunking engages only when `duration > chunk_duration`. Hold-to-talk utterances run
   10–60 s and are bounded by a 120 s stuck-key guard, so the chunked path is **unreachable in
   normal operation**. Leaving the default untouched (as the brief requires) costs nothing.

3. **`max_new_tokens` does not exist** — the parameter is `max_tokens`, and its default is `None`
   (auto), not a fixed 256. §3 records how the contract's wire field maps onto it.

4. `temperature`, `top_p`, `top_k`, `repetition_penalty` **do** exist (the PyPI page was right and
   the GitHub README wrong); `repetition_penalty`'s effective default is 1.2, not 1.0.

5. `context` is real and is **not** a no-op: `Tokenizer.build_prompt` encodes it and splices the
   tokens into the system message between `<|im_start|>system\n` and `<|im_end|>`. This is the
   official Qwen3-ASR chat-template hotword mechanism, so the model card's "context biasing not
   supported" claim does not describe this package. It also *measurably* changes output — §4
   measures it on both variants, including a decoy list that proves the causal channel.

6. `language=None` leaves the assistant turn empty and the model emits
   `language {detected}<asr_text>{transcript}`, which `parse_language_and_output` splits. Passing a
   language instead pre-seeds that prefix. Auto-detect is therefore free.

### Concurrency, as built

`Qwen3ASR.transcribe` acquires an instance-level `threading.Lock` around the whole inference.
One-transcription-at-a-time is thus enforced by the library, not something the server must add.
The consequence for the server: the call is **blocking and long**, so it must be dispatched to a
worker thread and never awaited on the event loop, or `/health` will stall behind it.

### Empty / degenerate input

`len(samples) == 0` returns `TranscriptionResult(text="", language="Unknown", duration=0.0)`
without touching the model. A non-1-D array raises `ValueError`. Both shape the error taxonomy.

---

## 2. Model variants — only two of the three named in the brief can load

`load_encoder_weights` / `load_decoder_weights` do `mx.load("model.safetensors")`, keep keys under
the prefix `audio_tower.` / `model.` respectively, and call `load_weights(...)` — which is
**strict** by default. Nothing anywhere in the package reads the `quantization` block from
`config.json` or calls `mlx.nn.quantize`.

Verified by reading each repo's safetensors header over HTTP range requests and attempting a real
strict `load_weights` with correctly-shaped lazy arrays (no weight download):

| Repo | Key prefixes | Quantized tensors | Loads? |
|---|---|---|---|
| `mlx-community/Qwen3-ASR-1.7B-bf16` | `audio_tower.` / `model.` | none | **yes** — encoder 397 + decoder 310 tensors, clean |
| `mlx-community/Qwen3-ASR-0.6B-bf16` | `audio_tower.` / `model.` | none | **yes** (same layout; 782 M params) |
| `mlx-community/Qwen3-ASR-1.7B-8bit` | `audio_tower.` / `model.` | 197 `.scales` + 197 `.biases`, U32 | **no** — `ValueError: Received 394 parameters not in model: embed_tokens.biases, embed_tokens.scales, layers.0.mlp.down_proj.biases, …` |
| `Qwen/Qwen3-ASR-0.6B` | `thinker.` | none | **no** — every key is `thinker.`-prefixed, so both loaders match zero tensors |

Two consequences that change the plan:

- **The 8-bit checkpoint that `exploration.md` §1 and decision 3 build on is not loadable by this
  library.** Only the *decoder* is quantized in that repo (the encoder header matched cleanly and
  loaded fine); 197 quantized modules = 28 layers × 7 projections + `embed_tokens`, with `lm_head`
  tied. A shim is plausible — build the config, `mlx.nn.quantize(decoder, group_size=64, bits=8)`
  per the repo's `quantization` block, load weights, then hand the parts to the public
  `Qwen3ASR(config, encoder, decoder, tokenizer)` constructor — but it is **unverified** and would
  live in our code, not the library's. Flagged for a human decision, see §3.
- **The 0.6B variant must be `mlx-community/Qwen3-ASR-0.6B-bf16`**, not the `Qwen/Qwen3-ASR-0.6B`
  that the package's GitHub README names as its default model. The upstream Qwen repo uses the
  `thinker.`-prefixed Omni layout and cannot load here.

All three `mlx-community` repos ship `merges.txt` + `vocab.json` (no `tokenizer.json`), which is
the second branch `Tokenizer.__init__` supports. Fine.

---

## 3. Decisions taken

Both of §2's open questions were resolved by the human on 2026-08-12. Recorded here because they
fan out to `foundation`'s config defaults, `settings-ui`'s variant picker and `installer`'s
download step.

- **No 8-bit, and no `nn.quantize` shim.** Variant switching covers exactly the two repos proven
  loadable — `mlx-community/Qwen3-ASR-1.7B-bf16` (**default**) and
  `mlx-community/Qwen3-ASR-0.6B-bf16`. 8-bit is **unsupported by `qwen3-asr-mlx` 0.2.0**; the
  verbatim failure is `ValueError: Received 394 parameters not in model: embed_tokens.biases,
  embed_tokens.scales, layers.0.mlp.down_proj.biases, …`. This supersedes decisions 6 and 8, which
  name `1.7B-8bit` as the default — that checkpoint cannot be loaded by the chosen library. The
  shim was rejected as unverified code living on our side of the boundary; it is additive to add
  back later if a human wants the ~1.6 GB of resident memory it would save.
- **`max_tokens` stays `None`** (library auto = `max(256, duration*50)`). The brief's literal
  `max_new_tokens=256` is not a real parameter of this library, and pinning its nearest equivalent
  to 256 would silently truncate anything past ~5 s. `KNOWN_MODELS` in `config.py` is the single
  source of truth for the variant list.

### The `max_new_tokens` wire field (locked, both sides)

The contract keeps the field name `max_new_tokens`; the library's parameter is `max_tokens`. The
mapping is fixed so the Swift client and this server cannot drift:

| Request | Passed to the library | Effect |
|---|---|---|
| key absent | `max_tokens=None` | auto cap `max(256, int(duration*50))` — **the normal path** |
| `"max_new_tokens": null` | `max_tokens=None` | identical to absent |
| `"max_new_tokens": 900` | `max_tokens=900` | **verbatim**: no clamping, no floor at 256 |

Absent and explicit `null` behave identically because the pydantic field is `Optional[int] = None`,
which accepts both spellings. Which one the Swift client actually sends was re-derived by
`foundation` by compiling and running the real type: the synthesized `Codable` encoder uses
`encodeIfPresent`, so a nil `Int?` **omits the key entirely** — the earlier claim here that
`JSONEncoder` emits `null` was wrong. The server still accepts both, because a hand-written
`encode(to:)` or any non-Swift client may send `null`, and a wire format whose meaning turns on
which of two equivalent spellings arrives is a trap. A value that is present is the caller asking
for a cap and gets exactly that — a field the server accepts and silently ignores would show up in the
settings UI as a working knob that does nothing.

Not validated, deliberately: values `<= 0` are forwarded as given, because inventing a floor would
be the clamping this rule forbids. The open worry was that `<= 0` might wedge an inference slot;
**it does not.** Measured on real `0.6B-bf16` weights against the 4.10 s clip:

| `max_new_tokens` | result |
|---|---|
| `0` | `200` in 0.35 s — `{"text": "language", "language": "English"}` |
| `-1` | `200` in 0.11 s — identical body |
| `1` | `200` in 0.09 s — identical body |

So a caller who sets a nonsense cap gets a fast, degenerate transcript rather than a hang or an
error: it returns early with only the model's `language ` prefix decoded, before any
`<asr_text>` marker. No server-side guard is needed and none was added.

### Endpoint decisions not spelled out by the contract

- **Validation order is payload-first, readiness-second.** A request that is both malformed *and*
  arrives during a load gets `bad_audio`, not `model_not_ready`: the former is permanent and tells
  the client to stop, the latter invites a retry that would fail forever. Verified (§7).
- **Schema violations collapse into `bad_audio` (400).** FastAPI's stock answer is a 422 whose
  body is a list under `detail` — a status the contract never lists and a shape `asr-client`
  cannot decode. A body that is not JSON, or is missing `audio_base64`, is an undecodable payload
  by any reading, so it takes the taxonomy's existing code. This keeps the error set closed at
  five codes.
- **Unknown request fields are ignored, not rejected** (`extra="ignore"`), so a newer client
  cannot be broken by an older server.
- **A second concurrent transcribe waits** rather than being rejected — the taxonomy has no
  `busy` code, and the client's 15 s timeout is the backstop.
- **`MARMOT_ASR_LANGUAGE` is only a fallback** for a request that specifies nothing. `null` and
  `""` in the request both mean auto-detect; since the env var's own default is unset, the
  out-of-the-box behaviour is the contract's auto-detect either way.
- **No temp files, and no copy of the audio beyond one.** `base64.b64decode` →
  `np.frombuffer(dtype="<f4").copy()` → the model. The single `.copy()` exists because
  `frombuffer` aliases an immutable `bytes` and the library casts the array in place; it is a
  few-MB memcpy, not a re-encode.
- **NaN/infinity in the PCM is `bad_audio`.** It would otherwise poison the mel front end and
  produce plausible-looking garbage instead of an error.

## 4. Measurements

### `/health` latency — including with a transcription in flight

Real uvicorn, **real `0.6B-bf16` weights** on 127.0.0.1:58480, `/health` polled over one
keep-alive `httpx.Client` while a transcribe runs on a separate connection. The idle row is taken
on the same connection immediately before, so the rows differ only in whether a decode is running.

| condition | n | median | p95 | p99 | max |
|---|---|---|---|---|---|
| idle, model `ready` | 200 | 0.24 ms | 0.29 ms | 0.34 ms | 0.39 ms |
| **25 × 4.10 s utterances back-to-back** (the realistic client load) | 546 | 0.66 ms | 1.69 ms | **3.07 ms** | 3.86 ms |
| one 286.6 s utterance — run A | 529 | 0.84 ms | 2.10 ms | **12.89 ms** | 90.10 ms |
| one 286.6 s utterance — run B | 560 | 0.76 ms | 2.02 ms | **13.00 ms** | 39.33 ms |

**The done-criterion holds.** p99 is inside 50 ms in every condition, by 4× at the audio ceiling
and by 16× under the load the client actually generates.

Two things the numbers say that the design argument could not:

- **GIL contention is real but small.** The in-flight median is ~3× the idle median, which is the
  library's Python-level decode loop taking interpreter time — exactly the effect `async def` does
  *not* insulate against. It costs sub-millisecond, so no mitigation (`sys.setswitchinterval`, a
  separate interpreter) is warranted.
- **The tail is not in the decode loop.** Logging each sample's offset from the start of the
  transcribe puts every slow request in the first ~0.4 s — the mel front end and encoder pass,
  where one MLX op holds the GIL for tens of milliseconds without a yield point. It therefore
  scales with utterance length, not decode length: **the single 90 ms sample in run A is a 286 s
  utterance**, 2.4× the client's own 120 s guard and 57× a normal one. The same experiment on a
  4.10 s utterance never exceeds 3.9 ms. If a future client ever submits minutes-long audio and
  needs a hard bound, the fix is chunking the front end, not touching `/health`.

Run-to-run spread on that tail is wide (90.10 ms vs 39.33 ms for the identical experiment), which
is why both runs are tabulated rather than the better one.

### `/reload` across both variants, with real weights

One live server on 58490, four swaps, no restart. `0.6B-bf16` → `1.7B-bf16` → `0.6B-bf16` and
back, with the second swap issued **while a real 49.1 s decode was running**:

| Step | Result |
|---|---|
| startup, `0.6B-bf16` | `ready` in 1.3 s (1.1 s load + 0.2 s `warm_up`; warm page cache) |
| `/reload` → `1.7B-bf16`, idle | 202 + `loading` body; `ready` 1.1 s later; transitions observed `loading`→`ready` |
| transcribe on the new model | 200, 1.02 s — the swap really took effect |
| `/reload` → `0.6B-bf16` **during a 49.1 s decode** | 202 returned in **1 ms**; the in-flight transcribe still completed **200** in 10.3 s with its full transcript; `ready` 0.9 s after it released |
| `/reload` → `1.7B-8bit` | 400 `bad_model`, and `/health` still `ready` on the live model |

The process survived all of it (RSS 1.77 GB afterwards — one model, not two, which is the
close-first design working) with nothing logged above `info`. That the mid-flight swap did not
abort is the point: a `FakeModel.close()` firing early only sets a flag, whereas `Qwen3ASR.close()`
frees encoder/decoder arrays and calls `mx.clear_cache()` — get the ordering wrong and the process
crashes rather than failing an assertion. Hence real weights for this one.

**A reload makes `/health`'s tail worse than a transcription does**, and it is worth stating
because it is the one number here that is not comfortably inside the criterion:

| condition (286.6 s utterance, `1.7B-bf16`) | n | median | p99 | max | where the max sits |
|---|---|---|---|---|---|
| transcribe alone | 2237 | 1.04 ms | 4.73 ms | 287.5 ms | 0.08 s in — the encoder pass |
| transcribe **with a `/reload` pending** | 4571 | 0.77 ms | 3.61 ms | **613.5 ms** | at the instant the decode released |

The control run is what makes the second row interpretable. Without a reload the tail is at the
front (the mel/encoder pass, as milestone 4 found) and nothing later than 3 s exceeds 24 ms. With
a reload pending, one sample spanned the moment the inference lock was released — that is
`close()` on a displaced 1.7B model, freeing ~3.5 GB and clearing the Metal cache, holding the GIL
for ~0.6 s. There is no cheap fix: `close()` is the library's and MLX frees are GIL-holding.
It is bounded, rare (a user-initiated variant switch), and does not affect typing (decision 20).

Also note the encoder-pass tail **scales with model size**: 90 ms on `0.6B-bf16` for this same
286.6 s clip, 287 ms on `1.7B-bf16`. For the ~5 s utterances the client actually sends, the worst
observed remains 3.9 ms.

### A bug this measurement found: the close-wait timeout

`_CLOSE_WAIT_SECONDS = 60.0` was justified in a comment as "generous: a 300 s utterance is the
server's own ceiling" — which conflates the audio's *duration* with its *decode time*. Measured
here: 286.6 s of audio takes **55.8 s** of server-side decode on `1.7B-bf16`. So one max-length
request came within ~4 s of the timeout, and a second queued behind it would blow through it —
leaking a ~3.5 GB model while the replacement loaded on top of it, which is precisely the double
residency close-first exists to prevent.

Now two constants with different justifications: the swap path waits **600 s** (it runs on a
daemon loader thread, so waiting there cannot keep the process alive), and shutdown keeps **60 s**
(it runs on the lifespan thread, where a wedged inference must not make the process un-exitable).

### One transcription at a time — verified

Three concurrent `POST /transcribe` of the same ~16.4 s clip against a server whose solo `elapsed`
for that clip is 0.89 s: server-reported `elapsed` came back **0.97 s / 1.90 s / 2.75 s**, each
step one solo inference apart, total wall 2.81 s ≈ 3 × solo. They queue on `_inference_lock` and
are served in full, not rejected — `elapsed` is measured from endpoint entry, so it includes the
wait, which is what the client's 15 s timeout is budgeting against.

### Transcription latency — the headline figure, per variant

The utterance a hold-to-talk client actually sends. One live server on 58495, both variants
measured in the same process (`0.6B-bf16` at startup, `1.7B-bf16` after a `/reload`), warm model,
12 repetitions of the same 4.09 s clip. `elapsed` is the server's own figure and covers the whole
handler including base64 decoding; client wall time is given alongside to show the HTTP path adds
nothing.

| variant | server `elapsed` (median of 12) | min–max | client wall (median) | vs. real time |
|---|---|---|---|---|
| `0.6B-bf16` | **0.435 s** | 0.424–0.488 s | 0.441 s | 9.4× |
| `1.7B-bf16` | **1.077 s** | 0.964–1.109 s | 1.085 s | 3.8× |

**This is the done-criterion's latency figure.** Both are far inside the client's 15 s transcribe
timeout; the 1.7B default costs ~2.5× the 0.6B for the same audio. Spread across repetitions is
tight (≤ 15 % of the median), so one number per variant is honest here. The client wall time runs
6–8 ms above the server's `elapsed` — base64 over loopback is not a cost worth thinking about.

Two cross-checks against figures taken earlier in this file: the 0.6B median reproduces the
milestone-4 spot figure (0.44 s for a 4.10 s clip) to within 5 ms, and the 1.7B short-utterance
ratio (3.8×) is *worse* than its 286.6 s stress ratio (5.1×), which is the expected direction —
fixed per-request overhead is amortised over a longer clip.

Startup, same run: `0.6B-bf16` cold-to-`ready` in **1.3 s** with a warm page cache (3.3 s load +
1.8 s `warm_up()` = 5.1 s when cold, from milestone 4); `/reload` to `1.7B-bf16` returned 202 in
13 ms and reached `ready` **1.8 s** later.

### The `context` A/B — measured, and the answer is yes

**`context` measurably changes the transcript, reproducibly, in both directions.** §1 point 5
established that the mechanism is real (`build_prompt` splices the tokens into the system message);
this is the measurement of whether it *does* anything, and it does.

Design: the 4.09 s utterance "I met Quilter and Aphra near the wubi pinyin desk yesterday
afternoon" (synthesised with `say -o out.wav --data-format=LEF32@16000`), transcribed under three
conditions × 3 repetitions × both variants. `temperature=0.0` is greedy, and **all six cells came
back 3/3 identical**, so every difference below is caused by the context string and not by
sampling noise.

The third condition is the one that makes the result interpretable. A *decoy* list of near-homophone
misspellings is a sensitivity control: if the correct list alone had changed nothing, that could
mean either "context does nothing" or "the model didn't need help". Strings that appear **only**
because a wrong list asked for them settle it.

| condition | `0.6B-bf16` | `1.7B-bf16` |
|---|---|---|
| `context=None` | I met Quilter, **an afro** near the **Wooby Pinion** desk… | I met Quilter and **Afren** near the **Wubby Pinion** desk… |
| `context="Vocabulary: Quilter, Aphra, wubi, pinyin."` | I met Quilter **and Aphra** near the **Wooby Pinion** desk… | I met Quilter **and Aphra** near the **Wubi Pinion** desk… |
| decoy `"Vocabulary: Quiller, Afra, Woobie, Ping Ying."` | I met **Quiller** and **Afra** near the Wooby Pinion desk… | I met Quilter and **Afra** near the **Woobie** Pinion desk… |

Reading the four target words (Quilter / Aphra / wubi / pinyin) as the score:

- **The correct list helps, and the win is real rather than cosmetic.** Unaided, both variants
  mangle *Aphra* — 0.6B into "an afro", which also breaks the sentence's grammar, and 1.7B into
  "Afren". Both recover it exactly with the vocabulary supplied. 1.7B additionally goes
  "Wubby" → "Wubi". Score 1/4 → 2/4 on 0.6B and 1/4 → **3/4** on 1.7B.
- **The decoy proves the causal channel.** "Quiller", "Afra" and "Woobie" are not plausible
  mishearings the model produced on its own — they are the exact spellings the wrong list asked
  for, and they appear only when it is supplied.
- **It is a bias, not an override.** *pinyin* renders as "Pinion" in all six cells: the correct
  list does not fix it and the decoy's "Ping Ying" does not move it either. Where the acoustics are
  decisive enough, context loses.
- **A wrong hotword list actively hurts.** On 0.6B the decoy turned "Quilter" — which the model had
  gotten *right* with no help at all — into "Quiller". This is the finding a settings UI most needs:
  a hotword box is not a free win, and a stale or careless list degrades words that were fine.

**For `settings-ui`:** a hotword text box is justified — the feature works and the effect is
visible on ordinary rare proper nouns. Label it honestly as a bias rather than a guarantee (it
fixed 1 of 3 wrong words on 0.6B and 2 of 3 on 1.7B, and could not fix *pinyin* at all), and note
that entering wrong words can make output worse. The server passes `context` through verbatim after
a `.strip()`; empty and absent both mean "no context".

*(The `max_tokens <= 0` question this section used to list is closed — §3 carries the measurement.)*

### Weight download throughput (for `installer`)

Both variants are resident in the shared HF cache (`~/.cache/huggingface/hub`, so `installer` and
`e2e-docs` inherit them) — `0.6B-bf16` 1.5 GB, `1.7B-bf16` 3.8 GB.

Throughput matters to `installer`, so it has now been measured three times and the figure keeps
moving: plain-HTTP range GETs managed **~0.64 MB/s**, `snapshot_download` with
`HF_HUB_DISABLE_XET=1` and `max_workers=2` sustained **~2.3 MB/s**, and the resume measured over a
30 s window on the same settings ran at **~3.8 MB/s**. Quote a range to users, not a point
estimate — 0.6–4 MB/s unauthenticated, i.e. anywhere from 15 to 100 minutes for the 1.7B weights.
**Always set `HF_HUB_DISABLE_XET=1`** — the Xet backend sat at 0 bytes of the weights blob for
five minutes before being killed. Unauthenticated requests are rate-limited (`huggingface_hub`
warns about it); an `HF_TOKEN` would likely do better still.

## 5. Things that are not options

- **Streaming is unreachable.** The Qwen3-ASR model card's streaming mode is vLLM-backend only;
  vLLM is CUDA/Linux and does not run against MLX on Apple Silicon. This service is offline-only
  and ships no mode toggle.
- **Python 3.12.** `qwen3-asr-mlx` supports 3.10–3.13; this machine's `python3` is 3.14.3 and
  cannot run it.
- **Binding anywhere but loopback.** `resolve_loopback_host()` raises `ConfigError` and the
  process refuses to start. There is no env var that widens the bind — the service is
  unauthenticated by design, so a reachable bind would publish an open transcription endpoint.
  Adding auth is the prerequisite for ever changing this, per the contract.

---

## 6. Running it by hand (debugging)

The installer owns the real venv and the LaunchAgent. To drive the service yourself:

```bash
python3.12 -m venv /tmp/asr-venv                      # 3.12 exactly; 3.14 will not work
/tmp/asr-venv/bin/pip install -r server/requirements.txt
export HF_HUB_DISABLE_XET=1                           # see §4 -- the Xet backend stalls here
cd server && /tmp/asr-venv/bin/python app.py
```

`app.py`'s `main()` reads the config, configures logging and calls `uvicorn.run`. Running it as a
module instead (`uvicorn app:app`) works too but bypasses `main()`, so the host/port come from
uvicorn's own flags rather than from the environment — prefer `python app.py`.

First start downloads ~4.1 GB of weights into `~/.cache/huggingface/hub` and reports
`{"status":"loading"}` throughout. Subsequent starts reach `ready` in the time it takes to read
the weights off disk plus `warm_up()`.

```bash
curl -s http://127.0.0.1:58471/health | python3 -m json.tool
```

### Configuration — environment variables

All optional; every one is read once at startup by `Config.from_env()` in `config.py`.

| Variable | Default | Meaning |
|---|---|---|
| `MARMOT_ASR_HOST` | `127.0.0.1` | Must be a loopback literal (`127.0.0.0/8` or `::1`). `localhost` is accepted and pinned to `127.0.0.1`. Anything else is a startup failure. |
| `MARMOT_ASR_PORT` | `58471` | Contract default. |
| `MARMOT_ASR_MODEL` | `mlx-community/Qwen3-ASR-1.7B-bf16` | HF repo id or a local directory. See `KNOWN_MODELS`. |
| `MARMOT_ASR_LANGUAGE` | *(unset)* | Unset ⇒ auto-detect (decision 9). Otherwise `zh` / `en` / a full language name. |
| `MARMOT_ASR_PRELOAD` | `true` | `false` skips the startup load — tests only; `/health` then reports `loading` forever. |
| `MARMOT_ASR_MIN_AUDIO_SECONDS` | `0.2` | Below this ⇒ `audio_too_short` (400). |
| `MARMOT_ASR_MAX_AUDIO_SECONDS` | `300` | Above this ⇒ `audio_too_long` (400). Deliberately generous; the client already guards at 120 s. |
| `MARMOT_ASR_LOG_LEVEL` | `info` | Passed to `logging` and to uvicorn. Access logging is off. |

### Switching model variant — `POST /reload`

**`/reload`, not a restart.** This is the authoritative answer to the contract's "pick one and
document it": the settings page switches variants by calling `/reload`, and never tells the user
to restart the LaunchAgent.

```bash
curl -s -X POST http://127.0.0.1:58471/reload \
     -H 'content-type: application/json' \
     -d '{"model": "mlx-community/Qwen3-ASR-0.6B-bf16"}'
```

- **202** with the `/health` body (same five keys), so the client reuses one decoder. It reads
  `loading`; poll `/health` until `ready`.
- **400 `bad_model`** if the repo id is not in `KNOWN_MODELS`, *or* if the body is malformed.
  `bad_model` is not one of `/transcribe`'s five codes — that taxonomy is closed and none of it
  describes "unsupported model", and answering `bad_audio` on `/reload` would send the client
  looking at the microphone. `/reload`'s error surface is unspecified by the contract beyond its
  202, so it carries its own code.
- **Reloading the model already loaded is allowed**, and is the documented way back from `error`.

Two properties worth knowing before relying on it:

- **A failed swap leaves the process with no model** (`/health` → `error`, `/transcribe` → 503
  `model_not_ready`). The displaced model is closed *before* the replacement is loaded, so the two
  are never resident at once — 1.7B-bf16 + 0.6B-bf16 would be ~5.3 GB of unified memory. A
  visible, retryable `error` beats an allocation storm during a routine variant switch. The way
  out is another `/reload`. See `ModelManager.start_load`.
- **The allowlist applies to `/reload` and not to `MARMOT_ASR_MODEL`.** Deliberate: startup is
  human-driven and has no working model to destroy, so a human may point it at a local directory;
  `/reload` is GUI-driven and destructive, and a settings page offering the three variants the
  plan originally named would let one click on `1.7B-8bit` — which §2 proves cannot load — take a
  working server down. Adding a variant is a one-line edit to `KNOWN_MODELS` in `config.py`.

A reload arriving mid-transcription is the only place this server could use-after-free:
`Qwen3ASR.close()` takes no lock of the library's own, so freeing a displaced model under a
running decode would free the encoder out from underneath it. `ModelManager` holds its own
inference lock across the whole of `run_transcribe` and every teardown path acquires it before
calling `close()`. Verified both mocked (`tests/test_reload.py`) and against real weights (§4).

## 7. Verified startup behaviour

Real uvicorn process, `POST`-free, polled once a second with `curl` (loader stubbed to a 6 s sleep
so the transition is observable without waiting on a 4 GB read):

```
t=1s  {"status":"loading","model":"mlx-community/Qwen3-ASR-1.7B-bf16","model_loaded":false,"version":"1","detail":"loading mlx-community/Qwen3-ASR-1.7B-bf16"}
...
t=5s  {"status":"ready","model":"mlx-community/Qwen3-ASR-1.7B-bf16","model_loaded":true,"version":"1","detail":null}
```

Bind verified in the same run: `lsof -nP -iTCP -sTCP:LISTEN` showed exactly
`TCP 127.0.0.1:58471 (LISTEN)` — no `*:58471`, no IPv6 wildcard — and `curl` to this machine's LAN
address `10.149.48.27:58471` was refused (exit 7).

The third `/health` state, `error`, is reached when the loader raises: status becomes `error` and
`detail` carries `"{ExceptionType}: {message}"`. A failed load leaves the process up and answering,
which is what the contract wants — the client distinguishes "server down" (connection refused)
from "server up, model broken" (`error`).

### `POST /transcribe` — every contract case, over real HTTP

Same harness (real uvicorn, real `httpx` client), loader stubbed to a fake model that echoes the
arguments it was handed, so no weights are involved. Every row below was executed:

| Case | Result |
|---|---|
| 1 s tone, no `max_new_tokens` key | 200, model received `max_tokens=None` |
| explicit `"max_new_tokens": null` | 200, byte-identical to the row above |
| `"max_new_tokens": 7` | 200, model received `max_tokens=7` — unclamped |
| `language:"zh"`, `context:" 土拨鼠 五笔 "` | 200, model received `language="zh"`, `context="土拨鼠 五笔"` |
| `language:""`, `context:""` | 200, both forwarded as `None` (auto) |
| unknown field `future_knob` | 200, ignored |
| 0.1 s of audio | 400 `audio_too_short` |
| empty `audio_base64` | 400 `audio_too_short` (0.000 s) |
| 301 s of audio | 400 `audio_too_long` |
| `sample_rate: 44100` | 400 `bad_audio` |
| `audio_base64: "!!!not base64!!!"` | 400 `bad_audio` |
| 5-byte payload (not a float32 multiple) | 400 `bad_audio` |
| PCM containing a NaN | 400 `bad_audio` |
| `audio_base64` key missing | 400 `bad_audio`, `detail: "malformed request: audio_base64: Field required"` |
| body is not JSON | 400 `bad_audio`, `detail: "malformed request: JSON decode error"` |
| model raises | 500 `inference_failed`, `detail: "RuntimeError: synthetic decoder failure"` |
| valid request, `MARMOT_ASR_PRELOAD=false` | 503 `model_not_ready`, `detail: "model is loading: startup"` |
| **bad payload *and* model loading** | 400 `bad_audio` — payload-first ordering, as designed |

The transcript is returned exactly as produced, trailing space included; the server calls no
`strip()` (decision 5). `duration` is computed from the sample count, not from the model's own
figure, and `elapsed` covers the whole handler including base64 decoding.

---

## 8. The test suite

```bash
python3.12 -m venv /tmp/asr-venv
/tmp/asr-venv/bin/pip install -r server/requirements-dev.txt
cd server && /tmp/asr-venv/bin/python -m pytest tests -q      # 92 passed in ~5 s
```

**92 tests, no weights, no `mlx`.** The venv above genuinely does not have the model library
installed (`import mlx` → `ModuleNotFoundError`), which is the done-criterion taken literally
rather than "we mocked the calls". Two things make it hold, and `tests/test_no_weights.py`
asserts both rather than trusting them: `create_app(loader=...)` is injectable, and
`model.default_loader` is the only place `qwen3_asr_mlx` is named — imported lazily *inside* the
function. If anyone hoists that import to module scope the suite would still pass on a developer
machine that happens to have `mlx`, and fail on a clean one; so one test walks `sys.modules` after
collection and another checks the import is indented.

| File | What it covers |
|---|---|
| `test_bind.py` | Loopback-only, three layers: every non-loopback spelling is a `ConfigError`; `main()` really hands `cfg.host` to uvicorn; and a **live server is genuinely unreachable on this machine's LAN address** (`connect_ex` refused). |
| `test_config.py` | Env parsing, and that a bad value stops the process with a message naming the variable. Pins `KNOWN_MODELS` to the two repos §2 proved loadable. |
| `test_health.py` | The three states and the transition, including `loading` before the weights are up and `error` carrying a reason. |
| `test_transcribe.py` | README §7's table, executed on every run: the five error codes, the `max_new_tokens` → `max_tokens` mapping, verbatim transcripts, and that the request path writes no temp file. |
| `test_reload.py` | Variant swap, `bad_model`, the superseded-load race, the failed-swap `error` state and the way back — and that a reload never closes a model mid-transcription. |
| `test_concurrency.py` | `/health` is not queued behind an in-flight transcribe; three concurrent transcribes serialise, all 200, never two inside the model at once. |

Where a test needs real concurrency it runs a real uvicorn on an ephemeral loopback port rather
than an in-process ASGI transport — ported from the ad-hoc harness that produced §4's numbers,
which measured over loopback for the same reason: an in-process transport cannot show you a
request queueing behind a blocked worker.

**What the mocked suite deliberately does not claim.** A `FakeModel` that sleeps *releases* the
GIL, where a real MLX encoder pass holds it for tens of milliseconds. So `test_concurrency.py`'s
50 ms threshold is an assertion about *architecture* (`/health` on the event loop, `/transcribe`
in the threadpool, serialised on the inference lock) — the part that can silently regress in an
edit. The latency claims are §4's, and they were taken against real weights.

Both properties were checked by mutation rather than by passing: making `/transcribe` an
`async def` fails `test_concurrency.py` with `/health took 1501.4 ms with a transcribe in flight
(n=1, p99 1501.43 ms, idle median 0.49 ms)`, and removing `_inference_lock` from `run_transcribe`
fails with `two transcriptions were inside the model at once` **and** `the displaced model was
closed while a transcription was still inside it`. A test that cannot fail is not a test.
