#!/usr/bin/env python3
"""Статистика GC за окно строк лога (-Xlog:gc): строки (start, end].

Использование: gcstats.py <лог> <строка_до_замера> <строка_после_замера>
Печатает: pauses,pause_total_ms,pause_max_ms,heap_after_gc_max_mb
heap_after_gc_max_mb - максимальная занятость кучи сразу после сборки мусора,
то есть оценка объёма "живых" данных (по ней видно, сколько памяти реально нужно).
"""
import re
import sys

UNIT_MB = {"K": 1 / 1024, "M": 1.0, "G": 1024.0}
HEAP = re.compile(r"(\d+(?:[.,]\d+)?)([KMG])->(\d+(?:[.,]\d+)?)([KMG])\((\d+(?:[.,]\d+)?)([KMG])\)")
PAUSE_MS = re.compile(r"(\d+(?:[.,]\d+)?)ms\s*$")


def num(s):
    return float(s.replace(",", "."))


def main(path, start, end):
    pauses, total, longest, max_after = 0, 0.0, 0.0, 0.0
    with open(path, encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f, 1):
            if i <= start:
                continue
            if end and i > end:
                break
            h = HEAP.search(line)
            if h:
                max_after = max(max_after, num(h.group(3)) * UNIT_MB[h.group(4)])
            if "Pause" in line:
                t = PAUSE_MS.search(line)
                if t:
                    v = num(t.group(1))
                    pauses += 1
                    total += v
                    longest = max(longest, v)
    print(f"{pauses},{total:.1f},{longest:.1f},{max_after:.0f}")


if __name__ == "__main__":
    try:
        main(sys.argv[1], int(sys.argv[2]), int(sys.argv[3]))
    except Exception as exc:  # noqa: BLE001
        print(f"gcstats: {exc}", file=sys.stderr)
        sys.exit(1)
