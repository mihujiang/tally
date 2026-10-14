#!/usr/bin/env python3
"""Download and verify the public vocab files used as alignment ground truth.

The files are large third-party data, so they are NOT committed (see .gitignore:
/data/*.tiktoken). This script pins them by sha256, so an alignment golden can be
recomputed exactly.

Usage:
    python tools/fetch_vocab.py            # download what is missing
    python tools/fetch_vocab.py --print    # print sha256 of what is on disk
"""
from __future__ import annotations

import argparse
import hashlib
import pathlib
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

# sha256 is filled in after the first successful download and then frozen.
FILES = {
    "cl100k_base.tiktoken": {
        "url": "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken",
        "sha256": "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7",
        "size": 1681126,
    },
}

CHUNK = 1 << 16


def sha256_of(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def download(url: str, dest: pathlib.Path, tries: int = 6) -> bool:
    for attempt in range(1, tries + 1):
        try:
            tmp = dest.with_suffix(dest.suffix + ".part")
            with urllib.request.urlopen(url, timeout=30) as resp, tmp.open("wb") as out:
                while True:
                    block = resp.read(CHUNK)
                    if not block:
                        break
                    out.write(block)
            tmp.replace(dest)
            return True
        except Exception as exc:  # noqa: BLE001
            print(f"  attempt {attempt}/{tries} failed: {exc}", file=sys.stderr)
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--print", action="store_true", dest="print_only")
    args = parser.parse_args()

    DATA.mkdir(parents=True, exist_ok=True)
    status = 0
    for name, spec in FILES.items():
        path = DATA / name
        if args.print_only:
            if path.exists():
                print(name, sha256_of(path), path.stat().st_size)
            else:
                print(name, "MISSING")
                status = 1
            continue

        want = spec["sha256"]
        if path.exists() and want and sha256_of(path) == want:
            print(f"{name}: verified (sha256 match)")
            continue
        if path.exists() and not want:
            print(f"{name}: present ({path.stat().st_size} bytes, sha256 {sha256_of(path)})")
            continue

        print(f"{name}: downloading {spec['url']}")
        if not download(spec["url"], path):
            print(f"{name}: DOWNLOAD FAILED", file=sys.stderr)
            status = 1
            continue
        got = sha256_of(path)
        size = path.stat().st_size
        ok = want is None or got == want
        print(f"{name}: {size} bytes sha256={got} {'OK' if ok else 'MISMATCH'}")
        if not ok:
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
