# tally

English | [中文](./README.md)

> **A context-budget engine for MoonBit** — squeeze arbitrarily long context into a token
> budget, and say exactly what was dropped, truncated, and why.

Context overflow is an event that happens before *every* agent call, not an edge case. The
usual fix is "characters ÷ 4" and then a hard cut — which lands in the middle of a JSON
object or a tool call, and leaves you unable to explain afterwards why one chunk survived.

`tally` does six things, and every one of them is checkable:

1. **Exact counting** — byte-level BPE of cl100k shape; 2,935 corpus cases aligned
   token-by-token against `tiktoken 0.14.0`, zero differences.
2. **Explainable assembly** — pack segments into a window by `Priority`; `Pinned` is never
   cut; the report says which segment was dropped, how many tokens, and why.
3. **Reproducible** — vocabularies and reports are canonical text, pinned byte for byte by
   `FORMAT.lock`. Change one byte and the test goes red.
4. **Verifiable** — a report can ship with a `tally-digest v1` sidecar: one sha256 for the
   report bytes, one per segment. `verify` first cross-checks the two files, then — given the
   vocabulary and the input — **re-assembles the plan** and compares both files byte for byte.
   "The report says this fit" becomes something a third party can check.
5. **Accountable** (0.6.1) — the digest can be sealed with a shared key into `tally-seal v1`;
   `verify --seal --key` checks in one pass that the digest was not swapped and that someone
   vouched for it. It proves *a holder of the key signed it*, **not who signed it**: a symmetric
   key carries no identity, and that is stated in the format rather than buried in docs.
6. **Three finer moves for "it still does not fit"** (1.0) — **per-pool quotas** (tool
   definitions and history each get their own allowance; a pool that runs over borrows from a
   pool with spare, in declaration order, and the report records `borrowed` / `lent` per pool),
   **score-based sacrifice inside a priority** (a retrieval score is no longer squeezed into
   three priority buckets), and **placeholder compression** (the cut tail becomes a fixed marker
   that names how many tokens were omitted, so the model knows something is there).

```moonbit
let segments = [
  @tally.pinned("system", "you are a helpful assistant."),   // never cut
  @tally.oldest("history", "...previous 50 turns..."),       // sacrificed first
  @tally.newest("user", "the current question"),
]
// window 8192, 1024 reserved for the reply -> input budget 7168; keep the tail on overflow
let cfg = @tally.fit_config(@tally.cl100k(v), 8192L)
  .with_reserve(1024L)
  .with_strategy(@tally.truncate_head())
let plan = @tally.fit_with(cfg, segments)
println(plan.render())   // kept / truncated / dropped, with reasons
```

`fit_with` raises only when the *configuration* is contradictory (`reserve >= window`).
"Does not fit" is not an error — it goes into the report. If you would rather not depend on
the error type name, use `fit_with_result`:

```moonbit
match @tally.fit_with_result(cfg, segments) {
  Ok(plan) => println(plan.render())
  Err((reserve, window)) => println("reserve \{reserve} ate the window \{window}")
}
```

`fit(v, segments, limit)` still works: it means "whole window available, no reserve,
drop whole segments", identical to earlier versions (including `limit <= 0`: everything is
dropped, Pinned overflow is reported, nothing is raised).

Tokenization (`encode` / `decode` / `count`) is the **foundation**: it guarantees the budget
layer works with exact numbers instead of estimates.

## Seven questions, one engine

| # | Question | tally's answer |
|---|---|---|
| 1 | How many tokens is this input? | `Counter`: exact (`cl100k`) or explicitly marked estimate (`estimate`); the report records which one was used |
| 2 | The window is 128k — can all of it go to input? | `window = reserve_output + input_limit`; if the reserve does not fit, you get an explicit error instead of a silent negative budget |
| 3 | What gets sacrificed? | `Priority`: `Oldest` → `Middle` → `Newest`; then `score` (higher survives), then lower index first |
| 4 | Dropping whole segments wastes space — can we cut instead? | `TruncateStrategy`: `KeepPrefix` / `KeepSuffix` / `Compress`; the cut point is found by binary search over `Counter` and backed off to a UTF-8 boundary |
| 5 | What must never move? | `Pinned` (system prompt, tool definitions) is preserved first; if it still does not fit, the plan is explicitly `overflow` with actionable advice |
| 6 | Do tool definitions and history each get an allowance? | `PoolQuota`: per-pool quotas plus borrowing in declaration order; the report records quota / demand / used / borrowed / lent for every pool |
| 7 | Why this result? Can I reproduce it? | `Plan::render()`: canonical `tally-plan v3` text, one line per segment, covered by the `FORMAT.lock` fingerprint |

## 1.0: three finer moves for when it still does not fit

### Per-pool quotas and borrowing

`PoolQuota` gives a class of content its own allowance (tool definitions, multi-turn history,
retrieved chunks), and `Segment::with_pool(name)` files a segment under a pool. Assembly runs in
**two rounds**:

1. the first round packs against the global budget as before, `Pinned` first;
2. the second round checks pools one by one: a pool over its quota first **borrows**, in
   declaration order, from pools with spare (`spare = quota − used − lent`); if it is still over,
   it keeps cutting inside the pool.

Borrowing only raises the borrower's *available* allowance; no segment changes owner, so `used`
never moves. In the report, `borrowed` and the other side's `lent` are the two ends of one
transfer, and the books balance by construction. Cutting only happens when borrowing fails, and
it still follows priority → score → index.

### Score-based sacrifice inside a priority

`Segment::with_score(s)` attaches a score. Victim selection is a three-level total order:
**lowest priority weight → lowest score → lowest index**, and it applies inside a priority too.
"Keep the retrieval chunk scored 92, drop the one scored 41" therefore does not require mapping
scores onto priority buckets — a mapping erases the ordering between scores and leaves three
classes.

### Placeholder compression

`TruncateStrategy::Compress` (facade: `truncate_compress()`) keeps the head and replaces the cut
tail with a **deterministic marker**:

```text
…[tally: 1491 tokens omitted]…
```

The marker itself costs tokens and is counted in the budget, so "kept content + marker" always
fits; at most three rounds converge (the marker changes how much room is left). The report's
`omitted=1491` and the number inside the marker are the same number: whatever was said to be
omitted is written into the content.

## What it is

Four layers, one package each, dependencies point one way:

| Layer | Package | Responsibility | Depends on |
|---|---|---|---|
| Algorithm core | `bpe` | Vocabulary-agnostic byte-level BPE, pre-tokenization scanner, Unicode tables | `core` only |
| Vocabulary | `vocab` | Vocab model, loading (incl. hand-written base64), canonical export, reproducible BPE training | `bpe` + `core` |
| **Budget (the product)** | `budget` | **Pluggable `Counter`, window model, priority assembly and truncation, explainable and freezable reports** | `bpe` |
| Facade | `tally` (root) | Shortest path to `fit_with` / `fit` / `encode` / `count` | all of the above |
| Tools & examples | `cmd/main`, `cmd/examples` | CLI and runnable examples (the only place with IO) | `x/fs` |

**Core packages have zero third-party dependencies**; `moonbitlang/x` is used by `cmd/*`
only, for file IO.

## Division of labour with `tokenizers-moonbit`

Not substitutes — different axes:

| | `tokenizers-moonbit` | tally |
|---|---|---|
| Axis | Breadth: 5 algorithms, 39 models, HF interop | Depth: one fixed cl100k shape, budget done properly |
| Reference implementation | Python `tokenizers` 0.22.2 | `tiktoken` 0.14.0 |
| Training | BPE / WordPiece / Unigram (HF semantics) | BPE only, total-order tie-break, byte-identical re-runs |
| Budget layer | none | `Priority` / `Pinned` / drop report / frozen format |
| Good for | many models, WordPiece, Unigram, native | "fit it into the window and explain it" |

Since 0.4.0 the budget layer only knows the `Counter` interface
(`name` + `exact` + `count_bytes: (Bytes) -> Int64`). Since 0.4.1 the cl100k adapter also
lives in the facade, so `budget`'s package-level dependency is `core` only — importing
`weopqrst/tally/budget` does not drag the vocabulary in. Wrap your tokenizer's counts in a
`Counter` and you can count and truncate with our engine:

```moonbit
// no impl needed for the foreign type
let counter : @tally.Counter = {
  name: "tokenizers-moonbit/cl100k",
  exact: true,
  count_bytes: fn(bytes) { their_tokenizer.count(bytes) },
}
let plan = @tally.fit_with(@tally.fit_config(counter, 8192L), segments)
```

## Quick start

### As a library

```powershell
moon add weopqrst/tally
```

That path is measured, not assumed: before this release an empty temporary project ran
`moon add weopqrst/tally` (registry `0.7.0`), built a program that only touches the facade, and
produced a report on both `js` and `wasm-gc`. The packaged artifact
(`weopqrst-tally-0.8.0.zip`) was also unzipped and `moon check`ed server side by
`moon publish --dry-run`. "Someone else can depend on it" is verified, not claimed.

```moonbit
fn demo(vocab_text : String) -> Unit raise {
  let v = @tally.load(vocab_text)

  // 1) budget assembly: the main path
  let segments = [
    @tally.pinned("system", "you are a helpful assistant."),
    @tally.oldest("history", "hello world hello world"),
    @tally.newest("user", "hello there token"),
  ]
  let plan = @tally.fit(v, segments, 4096L)
  println(plan.render())

  // 2) window + reserve + truncation
  let cfg = @tally.fit_config(@tally.cl100k(v), 8192L)
    .with_reserve(1024L)
    .with_strategy(@tally.truncate_head())
  println(@tally.fit_with(cfg, segments).render())

  // 3) exact counting
  println(@tally.count(v, "it's a test"))

  // 4) encode / decode round-trips any byte sequence
  let ids = @tally.encode(v, @utf8.encode("hello world"))
  println(@tally.decode(v, ids))

  // 5) per-piece detail: what eats tokens
  for piece in @tally.piece_counts(v, @utf8.encode("hello there token")) {
    println(piece)
  }

  // 6) 1.0: pool quotas + borrowing, placeholder compression, score inside a priority
  let pooled = [
    @tally.pinned("system", "you are a coding agent."),
    // tool definitions live in the `tools` pool; score 9 keeps it over its sibling
    @tally.with_score(@tally.with_pool(@tally.newest("tool", "read_file(path)"), "tools"), 9L),
    @tally.with_score(@tally.with_pool(@tally.newest("tool", "run_tests(args)"), "tools"), 4L),
    @tally.with_pool(@tally.oldest("history", "...previous 6 turns..."), "history"),
  ]
  // `tools` gets 20 and history has spare: borrowing in declaration order, recorded per pool
  let cfg2 = @tally.fit_config_pools(
    @tally.fit_config(@tally.cl100k(v), 1024L).with_strategy(@tally.truncate_compress()),
    [("tools", 20L), ("history", 512L)],
  )
  println(@tally.fit_with(cfg2, pooled).render())
}
```

You can also train a vocabulary (a **capability proof**, not the main line; two runs on the
same input are byte-identical):

```moonbit
fn train_demo() -> Unit raise {
  let corpus = [@utf8.encode("hello world"), @utf8.encode("hello 世界")]
  let result = @tally.train(corpus, 280, 1, ["<|endoftext|>"])
  println(result.to_text())
  let back = @tally.load_train(result.to_text())
  println(@tally.count(back.vocab, "hello world"))
}
```

### CLI

```powershell
# budget assembly (Pinned protected + drop report)
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 28 --text "hello world hello world"

# window 34 with 4 reserved -> input budget 30; keep the segment head, cut to 4 tokens
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# count / per-piece detail / encode
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello world"
moon run cmd/main --target js -- count --vocab tests/golden/sample-vocab.txt --text "hello there token" --explain
moon run cmd/main --target js -- encode --vocab tests/golden/sample-vocab.txt --text "hello world"

# placeholder compression: keep the head, replace the cut tail with a fixed marker
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 60 --truncate compress --text "hello world hello world"

# segments + pools: --segment <role>:<priority>:<path>, --pool <name>=<limit>,
# --segment-pool <role>=<name>, --segment-score <role>=<n>
moon run cmd/main --target js -- fit --vocab tests/golden/sample-vocab.txt --limit 400 `
  --segment system:pinned:system.txt --segment tools:newest:tools.txt --segment history:oldest:history.txt `
  --pool tools=10 --pool history=300 --segment-pool tools=tools --segment-pool history=history

# report + digest sidecar: the report is for humans, the digest is for machines
moon run cmd/main --target js -- digest --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# verify: cross-check the two files, then re-assemble and compare byte for byte
moon run cmd/main --target js -- verify --report report.txt --digest digest.txt --vocab tests/golden/sample-vocab.txt --limit 30 --reserve 4 --truncate tail --text "hello world hello world"

# seal: vouch for the digest with a shared key (the key never appears in output;
# use --key-file in production instead of --key, which lands in shell history)
moon run cmd/main --target js -- seal --digest digest.txt --key ci-key --key-id ci

# verify with a seal: self-consistency + seal + (given the input) end-to-end recompute
moon run cmd/main --target js -- verify --report report.txt --digest digest.txt --seal seal.txt --key ci-key
```

`--file <f>` replaces `--text <s>` and reads raw bytes (no UTF-8 assumption).
`--segment` / `--pool` / `--segment-pool` / `--segment-score` are all repeatable, and
`fit` / `digest` / `verify` accept the same set — so a pooled plan is still recomputable
end to end. Passing `--segment` replaces the default `system` + `payload` pair; roles and pool
names may not contain whitespace (they go into the report verbatim). Three kinds of silent
no-op are turned into errors: a mistyped role, a mistyped priority, and a `--segment-pool` that
names a pool with no `--pool` declaration.

A failed verification prints one `error:` line that names the position and both sha256 values:

```text
error: report sha256 mismatch: digest says 317c0e78…, file is d7dd9d5b…
```

**The exit code is part of the contract** (since 0.6.1): `0` on success, `1` on any failure, so
`tally verify` can go straight into CI instead of having its output grepped. Up to 0.6.0 it
printed `error: ...` and still exited `0`; both `tools/check_examples.py` and CI's
`verify (failure exits non-zero)` step now guard against that coming back.

## Examples (runnable, diffable)

Six scenarios live in `cmd/examples/`. Their output is canonical `tally-plan v3` text,
**committed byte for byte** under `examples/expected/` and re-checked by
`python tools/check_examples.py` — the examples are not pseudo-code in a doc.

```powershell
moon run cmd/examples --target js -- all          # all of them
moon run cmd/examples --target js -- big-input    # or one at a time
```

| Example | Scenario | What to look at |
|---|---|---|
| `big-input` | ~100k-token log into an 8192 window (1024 reserved) | the log segment is truncated to its **tail** at 7085 tokens; `used` is exactly 7168 |
| `multi-turn` | 12 turns + `Pinned` system prompt, 360 window / 40 reserved | the 4 oldest turns go first, then 5 middle ones; the 3 newest turns and the system prompt survive |
| `rag` | 6 retrieved chunks at the **same priority**, separated only by `score` | the 4 lowest-score chunks go first, the top two and the question survive — score is no longer flattened into a priority |
| `foreign-counter` | an external tokenizer (whitespace words) wrapped as `Counter` | no dependency added; a 31-word segment is still truncated to 11 words |
| `pools` | the same segments under two quota sets: A has spare, B is tight everywhere | A: `tools` borrows 50, `history` lends 50, nothing is cut; B: `tools` cuts its low-score tool inside the pool, `history` is truncated to its quota |
| `compress` | a 1520-token build log into a 60-token payload | head + placeholder marker, `omitted=1491`; the number inside the marker equals the report's `omitted=` |

Examples read the fixture vocabulary `tests/golden/sample-vocab.txt`; swap in the real one
with `--vocab data/cl100k_base.tiktoken` (`python tools/fetch_vocab.py` downloads it; `data/`
is not committed).

Nine CLI cases are committed the same way:

| Case | What it pins |
|---|---|
| `examples-all` | the combined output of all six examples stays diffable |
| `cli-fit` | the shape of a `fit` report |
| `cli-verify-ok` | `fit` → `digest` → `verify`: self-consistency, then a full recompute of both files |
| `cli-compress` | `--truncate compress`: the truncated line carries `omitted=`, and the report still parses |
| `cli-pools` | `--segment` + `--pool` + `--segment-pool`: the `[pools]` section records borrowing |
| `cli-verify-pools` | a **pooled** plan is recomputed end to end: one code path shared by fit / digest / verify |
| `cli-verify-mismatch` | two genuine but non-matching samples: verification must fail and print both sha256 values |
| `cli-seal` / `cli-verify-seal` | digest sealed with a shared key: self-consistency + seal in one pass |
| `cli-verify-seal-mismatch` | a different key: must fail and point at the `seal` line |

## Vocabulary format

Canonical text format `tally-vocab v1` — diffable, fingerprintable, `id` and `rank` kept
separate, `id` dense and ascending:

```text
# tally-vocab v1
# unicode 17.0.0
# tokens 277
[specials]
276 PHxlbmRvZnRleHR8Pg==
[tokens]
0 0 AA==
...
```

`load(to_text(v))` is equivalent to `v`, and exporting the same `v` twice is byte-identical.

Training output uses `tally-train v1` and stores the **recipe** (parameters + merge list);
the vocabulary format stores the expanded result. The 256 single bytes are an implicit base
and are not written; merges are dense by rank, ids ascend (merges first, then specials), so
the token table is fully reconstructible. `train -> to_text -> load_train` is a fixed point.

## Format lock (`FORMAT.lock`)

Five external text formats are pinned byte for byte:

| Format | Content | Pinned by |
|---|---|---|
| `tally-vocab v1` | vocabulary canonical text (`vocab/export.mbt`) | `vocab/format_lock_wbtest.mbt` + `tests/golden/sample-vocab.txt` |
| `tally-plan v3` | budget plan report, with the `[pools]` ledger and `omitted=` (`budget/report.mbt`) | `format_lock_wbtest.mbt` + `tests/golden/sample-plan{,-overflow,-truncated,-pools,-compressed}.txt` |
| `tally-train v1` | training recipe (`vocab/train_format.mbt`) | `vocab/train_lock_wbtest.mbt` + `tests/golden/sample-train.txt` |
| `tally-digest v1` | report digest sidecar (`budget/digest.mbt`) | `budget/digest_lock_wbtest.mbt` + `tests/golden/sample-digest{,-overflow,-truncated}.txt` |
| `tally-seal v1` | keyed seal over the digest (`budget/seal.mbt`) | `budget/seal_lock_wbtest.mbt` + `tests/golden/sample-seal.txt` |

`FORMAT.lock` records byte count and sha256 of every sample;
`python tools/gen_format_lock.py --check` fails on any drift. Changing the renderer turns the
MoonBit tests red first; changing a sample turns `--check` red first — neither can drift
quietly.

`tally-plan v3` has three format constraints (no escaping is introduced, so lines stay
space-splittable):

- `counter` names, segment roles, pool names and drop reasons must not contain spaces or
  newlines (the CLI validates `--segment` / `--pool` / `--segment-pool` up front);
- when `overflow = true`, a **sentinel** line is appended to `[dropped]`:
  `-1 pinned *overflow* <excess> <reason>`. It does not correspond to a segment; skip
  `index == -1` when reconciling (`Plan.excess` carries the same number);
- every `[truncated]` line ends with `omitted=<n>` (the original token count that was cut), and
  each `[pools]` line is `<pool> <quota> <demand> <used> <borrowed> <lent>` with five integers.

`[pools]` only exists in v3; with no pools it is an empty section right before `[kept]`. So a
pool-free plan from 0.x only gains one header line. `parse_report` reads both v2 and v3: old
reports still verify, and old digests are not turned into waste paper.

### Report digest format `tally-digest v1`

The report is for humans, the digest is for machines. The digest is a **separate file** rather
than an embedded section, so the report keeps describing only the plan, while the digest can be
shipped, replaced, and rejected on its own:

```text
tally-digest v1
report <sha256 of the report file>
plan <sha256 of the [segments] body>
[segments]
0 kept <sha256 of the bytes that actually entered the window>
1 dropped -
```

Rules (pinned by tests and `FORMAT.lock`):

- rows are sorted by `index`, independent of the report's kept→truncated→dropped sections;
- a `dropped` segment's sha is always `-`: it never entered the window;
- the overflow sentinel `-1` is listed and counted in the `plan` hash (an overflow must be
  auditable) but skipped by both sides during reconciliation;
- input is normalized first (UTF-8 BOM dropped, CRLF→LF, trailing blank lines folded), so files
  written by a Windows console redirect or an editor verify the same way; UTF-16 (PowerShell
  5.1's default redirect encoding) is rejected with a "save as UTF-8" hint.

### Seal format `tally-seal v1`

The digest proves "the bytes did not change"; the seal proves "someone vouched for this digest".
Five lines, fixed order, pinned by `FORMAT.lock`:

```text
tally-seal v1
scheme hmac-sha256
key_id ci
digest <sha256 of the digest file>
seal <HMAC-SHA256 hex>
```

Rules:

- `seal` covers the **first four lines** (header included) and not itself — a signature cannot
  cover itself;
- `key_id` is signed too: editing the label without recomputing the mac fails (rotating keys
  means re-sealing);
- only `hmac-sha256`; any other `scheme` is refused instead of guessed;
- an empty key is refused: an empty key means anyone can seal;
- it is **symmetric**: it proves a holder of the same key vouched for it, **not who did**. Proving
  identity needs asymmetric signatures and key distribution — out of scope, see "Does not do";
- the key never appears in output: the seal file can be committed or pasted into a ticket, and
  the key is injected via `--key-file` (or your own secret manager), not `--key`, which ends up
  in shell history.

`verify` has three levels, and only the last one is end-to-end:

| Level | Input | What it proves |
|---|---|---|
| self-consistency | report + digest | the two files agree: report bytes unchanged, segment count/action/used all match, `input_limit == window - reserve` |
| seal | plus `--seal` and `--key`/`--key-file` | someone holding the key vouched for this digest: swapped digest, edited `key_id`, edited seal line, wrong key all fail |
| end-to-end recompute | plus `--vocab` and the input | re-assemble from the same vocabulary and input; the new report and digest must equal the old files byte for byte |

Only the last level rules out "both files were edited into a consistent lie". The seal checks a
different axis: not whether the content is right, but whether anyone vouched for that content.
CI runs all three.

## 1.0: API freeze

From this release on, the signatures and formats below take no incompatible changes. New
capability arrives as new functions, `with_*` builders for new fields, or a new format version:

> **About the version number**: mooncakes currently only accepts `0.x.y` (`moon package` rejects
> any `moon.mod` whose major version is not 0), so this ships as **`0.8.0`**. "1.0" names the
> **promise** (frozen API and five frozen formats), not the literal number; `1.0.0` follows when
> the platform allows a non-zero major.

| Surface | Frozen |
|---|---|
| Counting | `Counter` (`name` / `exact` / `count_bytes`), `cl100k`, `estimate` |
| Vocabulary | `load` / `to_text` / `encode` / `decode` / `count` / `piece_counts` / `train` / `load_train` |
| Assembly | `fit` / `fit_with` / `fit_with_result`, `FitConfig` (`with_reserve` / `with_strategy` / `with_pools`), `Segment` (`with_pool` / `with_score`), `Priority`, `TruncateStrategy` (`none` / `tail` / `head` / `compress`), `PoolQuota` |
| Report | `Plan` (`kept` / `truncated` / `dropped` / `pools` / `excess`), `PoolUsage`, `render` |
| Formats | `tally-vocab v1`, `tally-plan v3`, `tally-train v1`, `tally-digest v1`, `tally-seal v1`, all in `FORMAT.lock` |
| CLI | the six subcommands `fit` / `count` / `encode` / `digest` / `verify` / `seal` and the exit-code contract (0 on success, 1 on failure) |

There are only two backward-compatibility promises, both exercised by tests: `parse_report`
reads `v2` and `v3`; and the new `pool` / `score` fields default, so 0.x code that only calls
`Segment::new(role, priority, bytes)` compiles unchanged and behaves the same (no pool, score 0).

## Non-goals

- Not a general-purpose tokenizer: no `o200k` or any second encoding, no algorithms other
  than BPE (WordPiece / Unigram).
- Not a general regex engine — one fixed pre-tokenization pattern, hand-written scanner.
- No performance tuning: honest numbers only, no optimization targets.
- Not "library X, ported to MoonBit". Public vocabulary files are validation input only.
- No public-key signatures or identity: `tally-seal v1` is HMAC-SHA256 only. No Ed25519, no
  certificate chains, no "who signed it". It answers "did anyone vouch", not "who".
- No LLM client, no vector search, no GUI / docs site, no server.

## Known limits

| Limit | Note |
|---|---|
| Pre-tokenization | only the 7-branch cl100k shape; a different pattern needs a scanner change |
| Unicode version | tables are **17.0.0** (`unicode_version()`), exported from the same engine as the reference, so they agree codepoint by codepoint |
| `o200k`-style encodings | not provided |
| Truncation granularity | whole-segment drop, or cut until it just fits; BPE counts are not strictly monotonic in length, so the cut is not guaranteed to be the theoretically longest fit — but it never exceeds the budget and is reproducible |
| Truncation and character boundaries | the cut backs off to a UTF-8 character boundary; if not a single token remains, the segment is dropped whole |
| Compression granularity | the head only, plus a fixed marker — no "keep both ends", no semantic summary; the marker text is part of the format (changing it means v4) |
| Pool borrowing | allowances move, segments do not: a borrowed token still counts in the borrower's `used`; a pool without a lender cuts on its own, and pool quotas only tighten the global budget, never widen it |
| Window model | `window = reserve_output + input_limit`; `reserve >= window` is an explicit error (`fit_with_result` gives `Err((reserve, window))`); no adaptive reserve |
| Estimate counter | `estimate(n)` counts **characters** (codepoints) rounded up, never bytes (one Chinese character is 3 bytes; counting bytes inflates the budget 3×); always `exact=false` in reports |
| Backends | `wasm-gc` and `js` only; native is not guaranteed |
| Training | implemented (`vocab/train.mbt`), a capability proof, frozen; the fixture vocabulary is generated deterministically by `tools/gen_sample_vocab.py` |

## Performance (unoptimized)

Numbers only, no optimization target: neither `count` nor end-to-end fitting uses caching or
incremental tricks. Reproduce with:

```bash
moon bench -p cmd/perf --release --target wasm-gc   # the two benchmarks
python tools/check_bench.py                        # fails if 2x slower than the baseline
```

| Benchmark | Input | Unoptimized | First round | Second round (current) |
|---|---|---|---|---|
| `count-4kb` | 3,390 chars / 5,230 tokens | 0.399 ms | 0.257 ms | **0.101 ms** (~52 M tokens/s) |
| `fit-100k-8k` | 96 segments / 99,840 tokens → 8,192 window (256 reserved) | 7.08 ms | 4.90 ms | **1.89 ms** |

The first round was about doing less work: cache adjacent ranks while merging (only two positions
recomputed per merge), route `count` through an allocation-free counting path, filter special tokens by
their first byte, and reuse the last binary-search count when truncating.

The second round was about allocating less: pretokenization now decodes in one pass and classifies each
code point once (ASCII decided inline, first hit short-circuits); pieces of 1–3 bytes take a fast path
that allocates no arrays; and the vocab precomputes an `Int64` short-key table for tokens of ≤ 7 bytes,
so merging no longer builds a `Bytes` for every candidate.

Together that is 3.9x for `count` and 3.7x end to end, with **byte-identical output** — 2,935 corpus
cases, 160 tests on both backends, and 10 examples all agree. The second round's three fast paths have
their own guards: 300 randomized rounds against the original 0.6.1 algorithm, ASCII classification
checked point by point against the generated tables, and a disjointness scan over all 1.1M code points.

Machine and timestamp live in `tests/bench/baseline.json` (Windows 10 / Intel64 / Python 3.11).
CI runs the same benchmarks and only asserts "no worse than 2x the baseline" — a regression guard,
not a performance promise. The sample vocab has 277 tokens, so long text falls back to byte-level
tokens; throughput with a real cl100k vocab will differ. These numbers are this repository's own baseline.

## Development

```powershell
# both backends must be green and agree
moon check --target wasm-gc
moon check --target js
moon test  --target wasm-gc
moon test  --target js

# reference-toolchain pins for the generators (see requirements-dev.txt)
python -m pip install -r requirements-dev.txt
python tools/fetch_vocab.py           # reference vocabulary for the alignment golden (not committed)

# generated artefacts (regenerate and commit after changes)
python tools/gen_unicode.py
python tools/gen_sample_vocab.py
python tools/gen_pretoken_golden.py
python tools/gen_alignment_golden.py
python tools/gen_format_lock.py

# example output (use --update and review the diff)
python tools/check_examples.py
python tools/check_examples.py --update

# the same checks CI runs
python tools/gen_unicode.py --check
python tools/gen_sample_vocab.py --check
python tools/gen_pretoken_golden.py --check
python tools/gen_alignment_golden.py --check
python tools/gen_format_lock.py --check
python tools/check_examples.py
```

Current size: **8 packages, 160 tests** (8 of them black-box, public API only), green on both
`wasm-gc` and `js`; matrix A aligns **2,935 corpus cases** (16,273 tokens, zero differences)
against the reference implementation; matrix D (reproducible training) is byte-identical
across 5 parameter sets; matrix I (garbage input may only succeed or fail with a **named**
error) and matrix J (change one byte and verification must fail **with a position**) live in
`vocab/robustness_wbtest.mbt` and `budget/digest_wbtest.mbt`; HMAC is checked against six RFC
4231 vectors (`budget/hmac_wbtest.mbt`) and the frozen seal sample is cross-checked against
Python's `hmac`; **10 example cases** are committed byte for byte under `examples/expected/`,
two of which must fail (and assert a non-zero exit code); **2 benchmarks** (`cmd/perf`) have a
committed baseline and CI only asserts "no worse than 2x". All of it runs in
`.github/workflows/ci.yml`: `verify` self-consistency, seal, end-to-end recompute, a
regression step asserting a mismatched pair exits non-zero, and the benchmark guard.

## License

Apache-2.0, see [LICENSE](./LICENSE). Third-party dependencies, reference implementations and
the Unicode data license are listed in [NOTICE](./NOTICE).
