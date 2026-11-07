#!/usr/bin/env python3
"""Сводит results.csv: медиана по повторам для каждой комбинации условий.

Использование: aggregate.py results.csv summary.csv
Колонка status: ok, если все замеры прошли с живым приложением; иначе худший статус
(oom, dead, unresponsive, no_start). Строки с таким статусом нельзя читать как обычный результат.
"""
import csv
import statistics
import sys

KEY = ["mode", "ms", "calls", "heap", "variant", "load"]
METRICS = [
    "rps", "failed_pct", "avg_ms", "med_ms", "p90_ms", "p95_ms", "p99_ms", "max_ms", "dropped",
    "cpu_cores_avg", "rss_max_mb", "threads_max", "gc_pauses", "gc_pause_total_ms",
    "gc_pause_max_ms", "heap_after_gc_max_mb", "startup_s", "idle_rss_mb", "first_req_overhead_ms",
]
SEVERITY = {"ok": 0, "unresponsive": 1, "dead": 2, "oom": 3, "no_start": 4}


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def main(src, dst):
    with open(src, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        print("results.csv пуст, нечего считать")
        return

    groups = {}
    for r in rows:
        key = tuple(r[k] for k in KEY)
        groups.setdefault(key, []).append(r)

    def sort_key(item):
        mode, ms, calls, heap, variant, load = item[0]
        return (mode, int(ms), int(calls), heap, int(load), variant)

    header = KEY + ["n", "status"] + [f"{m}_median" for m in METRICS] + ["rps_min", "rps_max"]
    out_rows = []
    for key, rs in sorted(groups.items(), key=sort_key):
        row = dict(zip(KEY, key))
        real = [r for r in rs if r["repeat"] != "0"]
        row["n"] = len(real)
        # строки repeat=0 (приложение не пережило прогрев) учитываем, только если реальных замеров нет:
        # так дозапуск успешно сменяет прежний статус
        status_rows = real if real else rs
        row["status"] = max((r["status"] for r in status_rows), key=lambda s: SEVERITY.get(s, 9))
        for m in METRICS:
            vals = [v for v in (num(r[m]) for r in rs) if v is not None]
            row[f"{m}_median"] = round(statistics.median(vals), 2) if vals else ""
        rps = [v for v in (num(r["rps"]) for r in rs) if v is not None]
        row["rps_min"] = round(min(rps), 1) if rps else ""
        row["rps_max"] = round(max(rps), 1) if rps else ""
        out_rows.append(row)

    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(out_rows)

    cols = ["heap", "variant", "load", "n", "status", "rps_median", "p95_ms_median",
            "failed_pct_median", "cpu_cores_avg_median", "rss_max_mb_median",
            "threads_max_median", "gc_pause_total_ms_median"]
    short = {"rps_median": "rps", "p95_ms_median": "p95_ms", "failed_pct_median": "fail%",
             "cpu_cores_avg_median": "cpu", "rss_max_mb_median": "rss_mb",
             "threads_max_median": "threads", "gc_pause_total_ms_median": "gc_ms"}
    print("  ".join(f"{short.get(c, c):>12}" for c in cols))
    for r in out_rows:
        print("  ".join(f"{str(r[c]):>12}" for c in cols))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: aggregate.py results.csv summary.csv")
    main(sys.argv[1], sys.argv[2])
