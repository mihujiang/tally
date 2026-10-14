#!/usr/bin/env python3
"""Generate the end-to-end alignment golden (matrix A).

Ground truth is the reference implementation itself (`tiktoken`), run over its
own test corpus plus systematic coverage cases.

`tally`'s root package is deliberately IO-free and dependency-free, so the vocab
cannot be read from disk in a test. Instead we embed a *slice* of it: only the
entries the corpus can ever look up. That is sound because byte-level BPE only
ever merges adjacent spans of the input, so every key it consults is a substring
of the input; a slice containing all corpus substrings therefore behaves exactly
like the full vocab. This script verifies that claim entry by entry before it
writes anything.

Outputs
-------
  tests/golden/alignment_corpus.txt      human-readable corpus listing
  tally/cl100k_slice_wbtest.mbt          the embedded slice (tiktoken format)
  tally/alignment_golden_wbtest.mbt      corpus bytes + reference token ids
"""
from __future__ import annotations

import base64
import inspect
import pathlib
import re
import sys

import tiktoken
import tiktoken_ext.openai_public as tt_openai

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data" / "cl100k_base.tiktoken"
CORPUS_TXT = ROOT / "tests" / "golden" / "alignment_corpus.txt"
SLICE_MBT = ROOT / "cl100k_slice_wbtest.mbt"
GOLDEN_MBT = ROOT / "alignment_golden_wbtest.mbt"

SPECIALS = {
    "<|endoftext|>": 100257,
    "<|fim_prefix|>": 100258,
    "<|fim_middle|>": 100259,
    "<|fim_suffix|>": 100260,
    "<|endofprompt|>": 100276,
}

# ------------------------------------------------------------------ reference


def pat_str() -> str:
    """Read the pretokenization pattern straight out of the reference source."""
    src = inspect.getsource(tt_openai.cl100k_base)
    match = re.search(r'"pat_str":\s*r?"""(.*?)"""', src, re.S)
    if not match:
        raise SystemExit("could not extract pat_str from the reference")
    return match.group(1)


def load_ranks() -> dict[bytes, int]:
    if not DATA.exists():
        raise SystemExit(f"missing {DATA} -- run: python tools/fetch_vocab.py")
    ranks: dict[bytes, int] = {}
    for line in DATA.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        b64, rank = line.split()
        ranks[base64.b64decode(b64)] = int(rank)
    return ranks


def encoder(name: str, ranks: dict[bytes, int]) -> tiktoken.Encoding:
    return tiktoken.Encoding(
        name=name, pat_str=pat_str(), mergeable_ranks=ranks, special_tokens=SPECIALS
    )


# --------------------------------------------------------------------- corpus

# Literals lifted from the reference implementation's own test suite
# (tests/test_encoding.py in openai/tiktoken).
REFERENCE_LITERALS = [
    "hello world", "goodbye world", "hello", "hello ", "hello  ",
    " hello", " hello ", " hello  ", "hello world! 123",
    "rer", "'rer", "today\n ", "today\n \n", "today\n  \n", " \x850",
    "\u8bf7\u8003\u8bd5\u6211\u7684\u8f6f\u4ef6\uff0112345", "\U0001f44d",
    "<|endoftext|> hello <|fim_prefix|>", "",
    "0", "00", "000", "0000", "00000", "000000", "0000000", "00000000",
    "000000000", "0000000000", "00000000000", "000000000000",
    "0000000000000", "00000000000000", "000000000000000",
    "0000000000000000", "00000000000000000",
]

# The reference also round-trips long runs of a single character.
REPEAT_CHARS = ["^", "0", "a", "'s", " ", "\n"]

COVERAGE = [
    "\u4f60\u597d\u4e16\u754c", "\u65e5\u672c\u8a9e\u306e\u30c6\u30ad\u30b9\u30c8",
    "\ud55c\uad6d\uc5b4 \ud14d\uc2a4\ud2b8", "\u4e2d\u6587\uff0c\u6807\u70b9\u3002",
    "\U0001f44d", "\U0001f44d\U0001f3fd", "\U0001f1e8\U0001f1f3",
    "\U0001f468\u200d\U0001f469\u200d\U0001f467", "\U0001f642\U0001f643",
    "e\u0301", "a\u0301\u0327", "\u00f1", "\u00fc", "\ufb01le", "\u2460",
    "!!!???...", "\u2014\u2013", "\u201cquoted\u201d", "a\u2014b",
    "(a[b]{c})", "x=1+2;", "a\r\nb", "\r\n\r\n", "\r", "a\rb",
    "line1\nline2", "a\n\n\nb", "  \t\n\r ", "\n\n\n", "a \n b",
    "trailing \n ", " \n", "\t\t", "1234567890", "3.14159",
    "\u0661\u0662\u0663", "\u2167", "\u00bd", "2026-10-14",
    "don't", "it's", "we'll", "I'M", "D'S", "can't've", "'ll", "'ve",
    "'re", "'d", "'m", "'s",
    "Hello, \u4e16\u754c! \U0001f44b\n", "fn main() { println(1) }",
    "https://example.com/path?q=1&r=2", "a@b.com",
    "def f(x):\n    return x ** 2\n", "SELECT * FROM t WHERE a = 1;",
    '{"k": [1, 2, 3]}', "<html><body>x</body></html>",
    "    indented", "line\r\nbreak\r\n", "\u00a0nbsp\u00a0", "\u3000\u5168\u89d2",
    "ok", "OK", "Ok", "<|endoftext|>",
]

# Longer, realistic text: a short-corpus-only matrix would never exercise the
# interaction between pretokenization and the merge loop over many pieces.
LONG_TEXTS = [
    "The quick brown fox jumps over the lazy dog. " * 4,
    "def encode(text: str) -> list[int]:\n    return enc.encode(text)\n",
    "\u81ea\u7136\u8bed\u8a00\u5904\u7406\uff08NLP\uff09\u662f\u4eba\u5de5\u667a\u80fd\u7684\u4e00\u4e2a\u91cd\u8981\u65b9\u5411\uff0c"
    "\u6d89\u53ca\u6587\u672c\u5206\u7c7b\u3001\u673a\u5668\u7ffb\u8bd1\u7b49\u4efb\u52a1\u3002",
    "Markdown:\n\n- item one\n- item two\n\n> quote\n\n```python\nx = 1\n```\n",
    '{"name": "tally", "version": "0.1.0", "tags": ["tokenizer", "bpe"]}',
    "0123456789" * 6,
    "a b\tc\rd\ne  f\r\n g",
    "\U0001f600" * 8,
]

# Invalid UTF-8 and other raw bytes: these exercise the "other" character class.
RAW_BYTES = [
    b"hello world", b" \xec\x8b\xa4\xed", b"\xff\xfe", b"a\xffb", b"\xc0\x80",
    b"\xed\xa0\x80", b"\x00", b"\x00\x01", b"a\x00b", b"\xf0\x9f\x91\x8d",
    b"\xf0\x9f\x91\x8d\xf0\x9f\x8f\xbd", b"\xe4\xb8\xad\xe6\x96\x87",
    b"a \n b", b"\n ", b" \n", b"\r\n", b"\t", b"  ", b"a\r\n",
]


def build_corpus() -> list[bytes]:
    texts = list(REFERENCE_LITERALS)
    for ch in REPEAT_CHARS:
        texts += [ch * 64, " " + ch * 64, ch * 64 + "\n", ch * 64 + " \n"]
    texts += COVERAGE

    texts += LONG_TEXTS

    # Pairwise junctions: pretokenization bugs live at piece boundaries, so
    # concatenating distinct seeds is where they show up.
    seeds = [t for t in texts if t]
    for left in seeds[:50]:
        for right in seeds[50:60]:
            texts.append(left + right)

    corpus = [t.encode("utf-8", errors="surrogatepass") for t in texts]
    return corpus + RAW_BYTES


# ---------------------------------------------------------------------- slice


def substrings_of(data: bytes) -> set[bytes]:
    out = set()
    n = len(data)
    for i in range(n):
        for j in range(i + 1, n + 1):
            out.add(data[i:j])
    return out


def slice_ranks(corpus: list[bytes], full: dict[bytes, int]) -> dict[bytes, int]:
    needed: set[bytes] = set(bytes([b]) for b in range(256))
    for item in corpus:
        needed |= substrings_of(item)
    return {key: rank for key, rank in full.items() if key in needed}


# --------------------------------------------------------------------- output


def mbt_bytes(data: bytes) -> str:
    parts = []
    for byte in data:
        if byte == 0x22:
            parts.append('\\"')
        elif byte == 0x5C:
            parts.append("\\\\")
        elif byte == 0x0A:
            parts.append("\\n")
        elif byte == 0x0D:
            parts.append("\\r")
        elif byte == 0x09:
            parts.append("\\t")
        elif 0x20 <= byte < 0x7F:
            parts.append(chr(byte))
        else:
            parts.append("\\x%02x" % byte)
    return 'b"' + "".join(parts) + '"'


def mbt_string_constant(text: str, size: int = 1600) -> str:
    """Emit a MoonBit string literal, chunked so no escape spans a chunk edge."""
    chunks = [text[i : i + size] for i in range(0, len(text), size)] or [""]
    parts = []
    for chunk in chunks:
        escaped = (
            chunk.replace("\\", "\\\\")
            .replace('"', '\\"')
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\t", "\\t")
        )
        parts.append('  "%s"' % escaped)
    return " +\n".join(parts)


def write_if_changed(path: pathlib.Path, content: str, check: bool) -> bool:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == content:
        return False
    if check:
        print(f"{path.name}: STALE", file=sys.stderr)
        return True
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    return True


def main() -> int:
    check = "--check" in sys.argv
    full = load_ranks()
    reference = encoder("cl100k_base", full)
    corpus = build_corpus()

    golden = [reference._encode_bytes(item) for item in corpus]

    sliced = slice_ranks(corpus, full)
    probe = encoder("cl100k_slice", sliced)
    mismatches = sum(
        1 for item, ids in zip(corpus, golden) if probe._encode_bytes(item) != ids
    )
    if mismatches:
        raise SystemExit(f"slice is NOT equivalent: {mismatches} mismatching entries")

    # The slice keeps the reference *ids* above (that is what the golden stores),
    # but the embedded vocab uses a *compact* id space 0..n-1 ordered by the
    # reference rank, because `load_tiktoken` requires contiguous ids and the
    # reference id space here is sparse (1118 entries spread over 0..99351).
    # BPE only ever compares ranks, and this renumbering is order-preserving, so
    # the slice still behaves exactly like the reference. `slice_real_id` maps a
    # compact id back to its reference id; the check below proves that the
    # round-trip reproduces every golden sequence, token for token.
    ordered = sorted(sliced.items(), key=lambda kv: kv[1])
    compact = {key: i for i, (key, _) in enumerate(ordered)}
    real_id = [rank for _, rank in ordered]
    compact_ranks = {key: i for key, i in compact.items()}
    probe_compact = encoder("cl100k_slice_compact", compact_ranks)
    round_trip_bad = sum(
        1
        for item, ids in zip(corpus, golden)
        if [real_id[i] for i in probe_compact._encode_bytes(item)] != ids
    )
    if round_trip_bad:
        raise SystemExit(
            f"compact slice is NOT equivalent: {round_trip_bad} mismatching entries"
        )

    slice_text = "".join(
        base64.b64encode(key).decode() + " " + str(compact[key]) + "\n"
        for key, _ in ordered
    )

    stale = False
    stale |= write_if_changed(
        CORPUS_TXT,
        "".join(mbt_bytes(item) + "\n" for item in corpus),
        check,
    )

    real_id_lines = "\n".join(
        "  " + ", ".join(str(v) for v in real_id[i : i + 16]) + ","
        for i in range(0, len(real_id), 16)
    )
    slice_header = (
        "// Generated by tools/gen_alignment_golden.py -- DO NOT EDIT.\n"
        "//\n"
        f"// {len(corpus)} corpus entries, {len(sliced)} of {len(full)} vocab entries.\n"
        "// This is a slice of cl100k_base covering every substring the corpus can\n"
        "// look up. The generator verifies that the slice reproduces the full vocab\n"
        "// token-for-token on this corpus before emitting it.\n"
        "//\n"
        "// The slice uses a *compact* id space (see the generator): reference ids are\n"
        "// sparse, `load_tiktoken` wants contiguous ids. `cl100k_slice_real_id` turns a\n"
        "// compact id back into the reference id, and the generator has verified that\n"
        "// this round-trip reproduces every `alignment_golden` entry token for token.\n"
        "\n"
        "///|\n"
        "/// cl100k_base 的语料切片（`.tiktoken` 文本格式，紧凑 id）。\n"
        "pub let cl100k_slice_text : String =\n"
        + mbt_string_constant(slice_text)
        + "\n"
        "\n"
        "///|\n"
        "/// 紧凑 id -> 参考实现 id（cl100k_base 的 rank），一一对应。\n"
        "pub let cl100k_slice_real_id : Array[Int] = [\n"
        + real_id_lines
        + "\n]\n"
    )
    stale |= write_if_changed(SLICE_MBT, slice_header, check)

    golden_header = (
        "// Generated by tools/gen_alignment_golden.py -- DO NOT EDIT.\n"
        "//\n"
        f"// Matrix A: {len(corpus)} entries, token ids from the reference\n"
        "// implementation (tiktoken 0.14.0, cl100k_base). This includes every\n"
        "// literal in the reference's own test suite (tests/test_encoding.py).\n"
        "\n"
        "///|\n"
        "/// 对齐语料，与 `alignment_golden` 一一对应。\n"
        "pub let alignment_corpus : Array[Bytes] = [\n"
        + "".join("  " + mbt_bytes(item) + ",\n" for item in corpus)
        + "]\n"
        "\n"
        "///|\n"
        "/// 参考实现给出的 token id 序列。\n"
        "pub let alignment_golden : Array[Array[Int]] = [\n"
        + "".join("  [" + ", ".join(str(i) for i in ids) + "],\n" for ids in golden)
        + "]\n"
    )
    stale |= write_if_changed(GOLDEN_MBT, golden_header, check)

    if check and stale:
        return 1
    print(
        f"corpus={len(corpus)} slice={len(sliced)}/{len(full)} "
        f"slice_text={len(slice_text)} bytes golden_tokens={sum(len(g) for g in golden)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
