#!/usr/bin/env python3
"""跑 `cmd/perf` 的两项基准，与 `tests/bench/baseline.json` 比，退化超阈值即失败。

基准只防退化，不设优化目标（ROADMAP V0.7）。CI 与本地机器不同，阈值默认 2.0，
这是为机器差异留的余量，不是性能承诺。

用法：
  python tools/check_bench.py            # 跑并与基线比
  python tools/check_bench.py --write    # 用当前结果重写基线（记录机器与时间）
  python tools/check_bench.py --from-file report.txt   # 不重跑，解析已有输出
"""

from __future__ import annotations

import argparse
import datetime
import json
import locale
import platform
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / "tests" / "bench" / "baseline.json"

UNIT_MS = {"ns": 1e-6, "µs": 1e-3, "us": 1e-3, "ms": 1.0, "s": 1000.0}
ROW = re.compile(
    r"^(?P<name>[A-Za-z][\w\-]*)\s+(?P<value>\d+(?:\.\d+)?)\s*"
    r"(?P<unit>ns|µs|us|ms|s)\s*±"
)


def run_bench(target: str, release: bool) -> str:
    cmd = ["moon", "bench", "-p", "cmd/perf", "--target", target]
    if release:
        cmd.append("--release")
    print("$ " + " ".join(cmd), flush=True)
    proc = subprocess.run(
        cmd,
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    # 控制台可能是 GBK，µ 直接打印会抛 UnicodeEncodeError
    sys.stdout.write(proc.stdout.replace("\u00b5", "u"))
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        sys.exit("bench 运行失败（退出码 %d）" % proc.returncode)
    return proc.stdout


def parse(text: str) -> dict[str, float]:
    results: dict[str, float] = {}
    for line in text.splitlines():
        m = ROW.match(line.strip())
        if not m:
            continue
        ms = float(m.group("value")) * UNIT_MS[m.group("unit")]
        results[m.group("name")] = ms
    if not results:
        sys.exit("没有解析到任何基准行，输出格式可能变了")
    return results


def machine() -> dict[str, str]:
    return {
        "platform": platform.platform(),
        "processor": platform.processor() or "unknown",
        "python": platform.python_version(),
        "encoding": locale.getpreferredencoding(False),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="wasm-gc")
    ap.add_argument("--debug", action="store_true", help="不做 --release 构建")
    ap.add_argument("--max-ratio", type=float, default=2.0)
    ap.add_argument("--write", action="store_true", help="把当前结果写成新基线")
    ap.add_argument("--from-file", type=Path, help="解析已有输出而不是重跑")
    args = ap.parse_args()

    text = args.from_file.read_text(encoding="utf-8") if args.from_file else run_bench(
        args.target, not args.debug
    )
    current = parse(text)
    print()

    if args.write:
        BASELINE.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "target": args.target,
            "mode": "debug" if args.debug else "release",
            "recorded_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "machine": machine(),
            "note": "基准只防退化，不设优化目标；阈值 2x 为跨机器差异留余量",
            "results": {k: {"median_ms": round(v, 6)} for k, v in current.items()},
        }
        BASELINE.write_text(
            json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
        )
        print("已写入基线 %s" % BASELINE.relative_to(ROOT))
        for k, v in current.items():
            print("  %-14s %8.3f ms" % (k, v))
        return 0

    if not BASELINE.exists():
        sys.exit("基线不存在：%s（先跑 --write）" % BASELINE)
    base = json.loads(BASELINE.read_text(encoding="utf-8"))
    print(
        "基线：%s %s，记录于 %s"
        % (base["target"], base["mode"], base["recorded_at"])
    )
    print("阈值：当前 ≤ %.1fx 基线\n" % args.max_ratio)

    fails: list[str] = []
    for name, ms in current.items():
        entry = base["results"].get(name)
        if entry is None:
            fails.append("%s: 基线里没有这一项" % name)
            print("FAIL  %-14s 基线缺失" % name)
            continue
        base_ms = entry["median_ms"]
        ratio = ms / base_ms if base_ms > 0 else float("inf")
        ok = ratio <= args.max_ratio
        if not ok:
            fails.append("%s: %.3f ms 是基线的 %.2fx" % (name, ms, ratio))
        print(
            "%s  %-14s %8.3f ms  基线 %8.3f ms  %.2fx"
            % ("OK  " if ok else "FAIL", name, ms, base_ms, ratio)
        )

    for name in base["results"]:
        if name not in current:
            fails.append("%s: 基线有、本次没跑到" % name)
            print("FAIL  %-14s 本次未运行" % name)

    print()
    if fails:
        print("基准失败 %d 项：" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("基准通过（%d 项）" % len(current))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
