#!/usr/bin/env python3
"""逐字节核对示例输出。

每个用例在仓库根目录执行一条命令，把 stdout 与入库的期望文件比较；
默认 `--check`，`--update` 重写期望文件。

为什么不用 MoonBit 测试：示例在 `cmd/`（唯一允许 IO 的地方），它们的价值就是
**打印出来的报告**；报告是规范文本，所以断言可以直接落在字节上——和
`FORMAT.lock` 同一个思路。

用法：
    python tools/check_examples.py            # 校验
    python tools/check_examples.py --update   # 重新生成期望文件
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# (名字, 命令, 期望文件相对路径)
CASES = [
    (
        "examples-all",
        ["moon", "run", "cmd/examples", "--target", "js", "--", "all"],
        "examples/expected/examples-all.txt",
    ),
    (
        "cli-fit",
        [
            "moon",
            "run",
            "cmd/main",
            "--target",
            "js",
            "--",
            "fit",
            "--vocab",
            "tests/golden/sample-vocab.txt",
            "--limit",
            "30",
            "--reserve",
            "4",
            "--truncate",
            "tail",
            "--text",
            "hello world hello world",
        ],
        "examples/expected/cli-fit.txt",
    ),
]


def run(cmd: list[str]) -> str:
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        sys.stderr.write(proc.stdout.decode("utf-8", "replace"))
        raise SystemExit(f"命令失败（{proc.returncode}）：{' '.join(cmd)}")
    # Windows 下 println 会带 CRLF；报告格式以 LF 为准，统一后再比较。
    return proc.stdout.decode("utf-8", "replace").replace("\r\n", "\n")


def first_difference(actual: str, expected: str) -> str:
    for i, (a, b) in enumerate(zip(actual.splitlines(), expected.splitlines()), 1):
        if a != b:
            return f"  第 {i} 行\n    实际: {a}\n    期望: {b}"
    return f"  行数不同：实际 {len(actual.splitlines())} / 期望 {len(expected.splitlines())}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true", help="重写期望文件")
    args = parser.parse_args()

    failures = 0
    for name, cmd, rel in CASES:
        actual = run(cmd)
        path = ROOT / rel
        if args.update:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(actual.encode("utf-8"))
            print(f"updated {rel}")
            continue
        if not path.exists():
            print(f"FAIL {name}: 缺少期望文件 {rel}（先跑 --update 并提交）")
            failures += 1
            continue
        expected = path.read_bytes().decode("utf-8")
        if actual == expected:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name}: {rel}")
            print(first_difference(actual, expected))
            failures += 1

    if args.update:
        return 0
    if failures:
        print(f"\n{failures} 个示例输出与期望不符")
        return 1
    print(f"\n{len(CASES)} 个用例输出逐字节一致")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
