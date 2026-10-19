#!/usr/bin/env python3
"""生成并校验 `FORMAT.lock`：三种规范文本格式的逐字节指纹。

冻结哪三种格式
--------------
1. `tally-vocab v1` —— 词表规范文本（`# tally-vocab v1` 头部 + `[specials]` +
   `[tokens]` 两个小节，每行 `id rank base64`）。
2. `tally-plan v2` —— 预算计划报告（`counter` / `window` / `reserve` /
   `input_limit` / `used` / `pinned` / `overflow` 七行 +
   `[kept]` + `[truncated]` + `[dropped]` 三节）。
3. `tally-train v1` —— 训练产物配方（`# key value` 头部 + `[merges]` +
   `[specials]`，每行 base64）。

怎么保证不漂移
--------------
* **内容断言**在 MoonBit 测试里（`vocab/format_lock_wbtest.mbt`、
  `format_lock_wbtest.mbt`、`vocab/train_lock_wbtest.mbt`）：改实现或改期望串，
  测试先红。
* **指纹清单**（本脚本产出的 `FORMAT.lock`）给人看、给 CI 比：
  样本文件或期望串被改动却没同步清单，`--check` 就失败。

计划与训练产物的真实值只有一个来源：对应 `*_lock_wbtest.mbt` 里的冻结串。
本脚本把它们抽出来落成可 diff 的样本文件，再算 sha256 —— 不做第二份真值。

Usage
-----
    python tools/gen_format_lock.py
    python tools/gen_format_lock.py --check
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = ROOT / "FORMAT.lock"
PLAN_SRC = ROOT / "format_lock_wbtest.mbt"
TRAIN_SRC = ROOT / "vocab" / "train_lock_wbtest.mbt"
VOCAB_SAMPLE = ROOT / "tests" / "golden" / "sample-vocab.txt"
PLAN_SAMPLE = ROOT / "tests" / "golden" / "sample-plan.txt"
PLAN_OVERFLOW_SAMPLE = ROOT / "tests" / "golden" / "sample-plan-overflow.txt"
PLAN_TRUNCATED_SAMPLE = ROOT / "tests" / "golden" / "sample-plan-truncated.txt"
TRAIN_SAMPLE = ROOT / "tests" / "golden" / "sample-train.txt"

GENERATOR = "tools/gen_format_lock.py"

HEADER = f"""\
# FORMAT.lock -- 规范文本格式的逐字节指纹。
#
# generator: {GENERATOR}
# 生成物，不要手改。校验：python tools/gen_format_lock.py --check
#
# 冻结的格式：
#   tally-vocab v1   词表规范文本，可 diff、可指纹（vocab/export.mbt）
#   tally-plan  v2   预算计划报告（budget/report.mbt）
#   tally-train v1   训练产物配方（vocab/train_format.mbt）
#
# 各字段：格式名 <TAB> 样本文件 <TAB> 字节数 <TAB> sha256
# 内容断言在 MoonBit 测试里，改实现先红的是测试，不是这张表。

[frozen]
"""


def extract_mbt_string(source: str, name: str, path: pathlib.Path) -> str:
    """从 `*_lock_wbtest.mbt` 里抽出 `let <name> : String = "..." + ...`。

    只认生成器自己写出来的形状：每行一个带引号的片段，末尾跟 `+`，
    最后一行不带 `+`。形状不对就报错，不猜。
    """
    chunks: list[str] = []
    started = False
    for line in source.split("\n"):
        stripped = line.strip()
        if not started:
            if stripped.startswith(f"let {name} : String ="):
                started = True
            continue
        if not stripped.startswith('"'):
            raise SystemExit(f"unexpected line while reading {name}: {line!r}")
        if stripped.endswith("+"):
            end = stripped.rfind('"', 0, len(stripped) - 1)
            if end < 0:
                raise SystemExit(f"malformed fragment in {name}: {line!r}")
            chunks.append(stripped[: end + 1])
            continue
        chunks.append(stripped)
        break
    if not chunks:
        raise SystemExit(f"cannot find {name} in {path}")
    # MoonBit 的字符串转义是 JSON 的子集，直接借 json 解析。
    return "".join(json.loads("[" + ",".join(chunks) + "]"))


def rows() -> list[tuple[str, pathlib.Path, str]]:
    plan_src = PLAN_SRC.read_text(encoding="utf-8")
    train_src = TRAIN_SRC.read_text(encoding="utf-8")
    mixed = extract_mbt_string(plan_src, "frozen_plan_mixed", PLAN_SRC)
    overflow = extract_mbt_string(plan_src, "frozen_plan_overflow", PLAN_SRC)
    truncated = extract_mbt_string(plan_src, "frozen_plan_truncated", PLAN_SRC)
    trained = extract_mbt_string(train_src, "frozen_train_artifact", TRAIN_SRC)
    if not VOCAB_SAMPLE.exists():
        raise SystemExit(f"missing {VOCAB_SAMPLE}; run tools/gen_sample_vocab.py first")
    return [
        (
            "tally-vocab v1",
            VOCAB_SAMPLE,
            VOCAB_SAMPLE.read_text(encoding="utf-8"),
        ),
        ("tally-plan v2", PLAN_SAMPLE, mixed),
        ("tally-plan v2", PLAN_OVERFLOW_SAMPLE, overflow),
        ("tally-plan v2", PLAN_TRUNCATED_SAMPLE, truncated),
        ("tally-train v1", TRAIN_SAMPLE, trained),
    ]


def render_lock(entries: list[tuple[str, pathlib.Path, str]]) -> str:
    lines = [HEADER]
    for fmt, path, content in entries:
        blob = content.encode("utf-8")
        rel = path.relative_to(ROOT).as_posix()
        lines.append(
            f"{fmt:<15}\t{rel:<32}\t{len(blob):>7}\t{hashlib.sha256(blob).hexdigest()}\n"
        )
    return "".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="fail on any drift")
    args = parser.parse_args()

    entries = rows()
    lock_text = render_lock(entries)

    if args.check:
        ok = True
        for _, path, content in entries:
            current = path.read_text(encoding="utf-8") if path.exists() else ""
            if current != content:
                print(f"{path} is stale", file=sys.stderr)
                ok = False
        current = LOCK.read_text(encoding="utf-8") if LOCK.exists() else ""
        if current != lock_text:
            print(f"{LOCK} is stale", file=sys.stderr)
            ok = False
        return 0 if ok else 1

    # 跳过词表样本：它是 gen_sample_vocab.py 的产物，这里只读不写。
    for _, path, content in entries[1:]:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8", newline="\n")
        print(f"wrote {path}")
    LOCK.write_text(lock_text, encoding="utf-8", newline="\n")
    print(f"wrote {LOCK}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
