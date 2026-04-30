#!/usr/bin/env python3
"""
CRLF(\\r\\n) -> LF(\\n) normalizer.

HGFS/Windows 공유 폴더에서 shell script가 CRLF로 저장되면 Linux bash에서
$'\\r': command not found / invalid option 등의 형태로 깨질 수 있다.

Usage:
  python3 scripts/normalize-crlf.py scripts/set-test-capacity-min1.sh scripts/set-test-capacity.sh
"""

from __future__ import annotations

import sys
from pathlib import Path


def normalize(path: Path) -> bool:
    if not path.exists() or not path.is_file():
        print(f"[skip] not a file: {path}", file=sys.stderr)
        return False
    data = path.read_bytes()
    new = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if new == data:
        print(f"[ok]   already lf: {path}")
        return True
    path.write_bytes(new)
    print(f"[fix]  crlf->lf: {path}")
    return True


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: normalize-crlf.py <file> [file...]", file=sys.stderr)
        return 2
    ok = True
    for s in argv[1:]:
        ok = normalize(Path(s)) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

