#!/usr/bin/env python3
"""逐字节核对示例输出。

每个用例在仓库根目录执行一串命令，把**最后一步**的 stdout 与入库的期望文件比较；
默认 `--check`，`--update` 重写期望文件。

为什么不用 MoonBit 测试：示例在 `cmd/`（唯一允许 IO 的地方），它们的价值就是
**打印出来的报告**；报告是规范文本，所以断言可以直接落在字节上——和
`FORMAT.lock` 同一个思路。

用例可以声明若干步骤：
* `{"write": {"name": ...}}` —— 在临时目录写一个输入文件；
* `{"capture": [命令...], "into": "文件名"}` —— 跑命令，把 stdout 落到临时目录里的文件，
  供后面的步骤当输入用（`fit` 写报告、`digest` 写摘要，再 `verify` 读回来）；
  命令里写 `{tmp}` 表示那个临时目录，避免把文件写进仓库；
* `{"run": [命令...], "allow_failure": bool}` —— 普通步骤，`allow_failure` 时非零退出也算数，
  因为"校验必须失败"本身就是被测行为。

用法：
    python tools/check_examples.py            # 校验
    python tools/check_examples.py --update   # 重新生成期望文件
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

VOCAB = "tests/golden/sample-vocab.txt"

# fit / digest / verify 用同一组参数，否则"复算"比较的就不是同一份计划。
FIT_ARGS = ["--limit", "30", "--reserve", "4", "--truncate", "tail"]


def cli(*args: str) -> list[str]:
    return ["moon", "run", "cmd/main", "--target", "js", "--", *args]


CASES = [
    {
        "name": "examples-all",
        "steps": [
            {"run": ["moon", "run", "cmd/examples", "--target", "js", "--", "all"]},
        ],
        "expected": "examples/expected/examples-all.txt",
    },
    {
        "name": "cli-fit",
        "steps": [
            {
                "run": cli(
                    "fit",
                    "--vocab",
                    VOCAB,
                    *FIT_ARGS,
                    "--text",
                    "hello world hello world",
                ),
            },
        ],
        "expected": "examples/expected/cli-fit.txt",
    },
    # 正向证明：报告与摘要由同一次装配产出，`verify` 既要自洽通过，
    # 也要在给齐 vocab + 输入时逐字节复算出同样的两个文件。
    {
        "name": "cli-verify-ok",
        "steps": [
            {"write": {"name": "payload.txt", "text": "hello world hello world"}},
            {
                "capture": cli(
                    "fit",
                    "--vocab",
                    VOCAB,
                    *FIT_ARGS,
                    "--file",
                    "{tmp}/payload.txt",
                ),
                "into": "report.txt",
            },
            {
                "capture": cli(
                    "digest",
                    "--vocab",
                    VOCAB,
                    *FIT_ARGS,
                    "--file",
                    "{tmp}/payload.txt",
                ),
                "into": "digest.txt",
            },
            {
                "run": cli(
                    "verify",
                    "--report",
                    "{tmp}/report.txt",
                    "--digest",
                    "{tmp}/digest.txt",
                    "--vocab",
                    VOCAB,
                    *FIT_ARGS,
                    "--file",
                    "{tmp}/payload.txt",
                ),
            },
        ],
        "expected": "examples/expected/cli-verify-ok.txt",
    },
    # 反向证明：拿两份**都真实存在**但不配对的样本，`verify` 必须指出是谁对不上，
    # 并把两个 sha256 都打出来（人不用再去算一遍）。
    {
        "name": "cli-verify-mismatch",
        "steps": [
            {
                "run": cli(
                    "verify",
                    "--report",
                    "tests/golden/sample-plan.txt",
                    "--digest",
                    "tests/golden/sample-digest-overflow.txt",
                ),
                "allow_failure": True,
            },
        ],
        "expected": "examples/expected/cli-verify-mismatch.txt",
    },
]


def expand(cmd: list[str], tmp: Path) -> list[str]:
    return [arg.replace("{tmp}", tmp.as_posix()) for arg in cmd]


def run(cmd: list[str], cwd: Path, allow_failure: bool = False) -> str:
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True)
    if proc.returncode != 0 and not allow_failure:
        sys.stderr.write(proc.stderr.decode("utf-8", "replace"))
        sys.stderr.write(proc.stdout.decode("utf-8", "replace"))
        raise SystemExit(f"命令失败（{proc.returncode}）：{' '.join(cmd)}")
    # Windows 下 println 会带 CRLF；报告格式以 LF 为准，统一后再比较。
    return proc.stdout.decode("utf-8", "replace").replace("\r\n", "\n")


def execute(case: dict) -> str:
    """跑完用例的全部步骤，返回最后一步的 stdout。"""
    with tempfile.TemporaryDirectory(prefix="tally-example-") as tmp:
        # 步骤里引用的相对路径既要在仓库根目录能找到（vocab / golden），
        # 又要能读到自己刚写出的文件：把临时目录放在 ROOT 下不现实，
        # 所以写文件时落到 temp，读时先看 temp 再看 ROOT。
        tmp_path = Path(tmp)
        last = ""
        for step in case["steps"]:
            if "write" in step:
                w = step["write"]
                (tmp_path / w["name"]).write_text(w["text"], encoding="utf-8", newline="\n")
                continue
            if "capture" in step:
                out = run(
                    expand(step["capture"], tmp_path),
                    ROOT,
                    step.get("allow_failure", False),
                )
                (tmp_path / step["into"]).write_bytes(out.encode("utf-8"))
                last = out
                continue
            last = run(
                expand(step["run"], tmp_path),
                ROOT,
                step.get("allow_failure", False),
            )
        return last


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
    for case in CASES:
        name = case["name"]
        actual = execute(case)
        path = ROOT / case["expected"]
        if args.update:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(actual.encode("utf-8"))
            print(f"updated {case['expected']}")
            continue
        if not path.exists():
            print(f"FAIL {name}: 缺少期望文件 {case['expected']}（先跑 --update 并提交）")
            failures += 1
            continue
        expected = path.read_bytes().decode("utf-8")
        if actual == expected:
            print(f"ok   {name}")
        else:
            print(f"FAIL {name}: {case['expected']}")
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
