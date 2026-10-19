# tally

English | [中文](./README.md)

> **A context-budget engine for MoonBit** — squeeze arbitrarily long context into a token
> budget, and say exactly what was dropped, truncated, and why.

Context overflow is an event that happens before *every* agent call, not an edge case. The
usual fix is "characters ÷ 4" and then a hard cut — which lands in the middle of a JSON
object or a tool call, and leaves you unable to explain afterwards why one chunk survived.

`tally` does three things, and every one of them is checkable:

1. **Exact counting** — byte-level BPE of cl100k shape; 2,935 corpus cases aligned
   token-by-token against `tiktoken 0.14.0`, zero differences.
2. **Explainable assembly** — pack segments into a window by `Priority`; `Pinned` is never
   cut; the report says which segment was dropped, how many tokens, and why.
3. **Reproducible** — vocabularies and reports are canonical text, pinned byte for byte by
   `FORMAT.lock`. Change one byte and the test goes red.

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

## Six questions, one engine

| # | Question | tally's answer |
|---|---|---|
| 1 | How many tokens is this input? | `Counter`: exact (`cl100k`) or explicitly marked estimate (`estimate`); the report records which one was used |
| 2 | The window is 128k — can all of it go to input? | `window = reserve_output + input_limit`; if the reserve does not fit, you get an explicit error instead of a silent negative budget |
| 3 | What gets sacrificed? | `Priority`: `Oldest` → `Middle` → `Newest`; ties drop older history first |
| 4 | Dropping whole segments wastes space — can we cut instead? | `TruncateStrategy`: `KeepPrefix` / `KeepSuffix`; the cut point is found by binary search over `Counter` and backed off to a UTF-8 boundary |
| 5 | What must never move? | `Pinned` (system prompt, tool definitions) is preserved first; if it still does not fit, the plan is explicitly `overflow` with actionable advice |
| 6 | Why this result? Can I reproduce it? | `Plan::render()`: canonical `tally-plan v2` text, one line per segment, covered by the `FORMAT.lock` fingerprint |

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
```

`--file <f>` replaces `--text <s>` and reads raw bytes (no UTF-8 assumption).

## Examples (runnable, diffable)

Four scenarios live in `cmd/examples/`. Their output is canonical `tally-plan v2` text,
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
| `rag` | 6 retrieved chunks + question, score mapped to `Priority` | low-score chunks are dropped whole (default strategy) |
| `foreign-counter` | an external tokenizer (whitespace words) wrapped as `Counter` | no dependency added; a 31-word segment is still truncated to 11 words |

Examples read the fixture vocabulary `tests/golden/sample-vocab.txt`; swap in the real one
with `--vocab data/cl100k_base.tiktoken` (`python tools/fetch_vocab.py` downloads it; `data/`
is not committed).

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

Three external text formats are pinned byte for byte:

| Format | Content | Pinned by |
|---|---|---|
| `tally-vocab v1` | vocabulary canonical text (`vocab/export.mbt`) | `vocab/format_lock_wbtest.mbt` + `tests/golden/sample-vocab.txt` |
| `tally-plan v2` | budget plan report (`budget/report.mbt`) | `format_lock_wbtest.mbt` + `tests/golden/sample-plan{,-overflow,-truncated}.txt` |
| `tally-train v1` | training recipe (`vocab/train_format.mbt`) | `vocab/train_lock_wbtest.mbt` + `tests/golden/sample-train.txt` |

`FORMAT.lock` records byte count and sha256 of every sample;
`python tools/gen_format_lock.py --check` fails on any drift. Changing the renderer turns the
MoonBit tests red first; changing a sample turns `--check` red first — neither can drift
quietly.

`tally-plan v2` has two format constraints (no escaping is introduced, so lines stay
space-splittable):

- `counter` names and segment `role` must not contain spaces or newlines;
- when `overflow = true`, a **sentinel** line is appended to `[dropped]`:
  `-1 pinned *overflow* <excess> <reason>`. It does not correspond to a segment; skip
  `index == -1` when reconciling (`Plan.excess` carries the same number).

## Non-goals

- Not a general-purpose tokenizer: no `o200k` or any second encoding, no algorithms other
  than BPE (WordPiece / Unigram).
- Not a general regex engine — one fixed pre-tokenization pattern, hand-written scanner.
- No performance tuning: honest numbers only, no optimization targets.
- Not "library X, ported to MoonBit". Public vocabulary files are validation input only.
- No LLM client, no vector search, no GUI / docs site, no server.

## Known limits

| Limit | Note |
|---|---|
| Pre-tokenization | only the 7-branch cl100k shape; a different pattern needs a scanner change |
| Unicode version | tables are **17.0.0** (`unicode_version()`), exported from the same engine as the reference, so they agree codepoint by codepoint |
| `o200k`-style encodings | not provided |
| Truncation granularity | whole-segment drop, or cut until it just fits; BPE counts are not strictly monotonic in length, so the cut is not guaranteed to be the theoretically longest fit — but it never exceeds the budget and is reproducible |
| Truncation and character boundaries | the cut backs off to a UTF-8 character boundary; if not a single token remains, the segment is dropped whole |
| Window model | `window = reserve_output + input_limit`; `reserve >= window` is an explicit error (`fit_with_result` gives `Err((reserve, window))`); no adaptive reserve |
| Estimate counter | `estimate(n)` counts **characters** (codepoints) rounded up, never bytes (one Chinese character is 3 bytes; counting bytes inflates the budget 3×); always `exact=false` in reports |
| Backends | `wasm-gc` and `js` only; native is not guaranteed |
| Training | implemented (`vocab/train.mbt`), a capability proof, frozen; the fixture vocabulary is generated deterministically by `tools/gen_sample_vocab.py` |

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

Current size: **7 packages, 87 tests** (6 of them black-box, public API only), green on both
`wasm-gc` and `js`; matrix A aligns **2,935 corpus cases** (16,273 tokens, zero differences)
against the reference implementation; matrix D (reproducible training) is byte-identical
across 5 parameter sets; **4 examples + 1 CLI case** are committed byte for byte under
`examples/expected/`. All of it runs in `.github/workflows/ci.yml`.

## License

Apache-2.0, see [LICENSE](./LICENSE). Third-party dependencies, reference implementations and
the Unicode data license are listed in [NOTICE](./NOTICE).
