#!/usr/bin/env python3
"""Сводит results.csv: медиана по повторам для каждой пары (вариант, число клиентов).

Использование: aggregate.py results.csv summary.csv
"""
import csv
import statistics
import sys

METRICS = [
    "rps", "failed_pct", "avg_ms", "med_ms", "p90_ms", "p95_ms", "p99_ms",
    "max_ms", "cpu_cores_avg", "rss_max_mb", "threads_max", "startup_s",
]


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
        groups.setdefault((int(r["vus"]), r["variant"]), []).append(r)

    header = ["variant", "vus", "n"]
    for k in METRICS:
        header.append(f"{k}_median")
    header += ["rps_min", "rps_max"]

    out_rows = []
    for (vus, variant), rs in sorted(groups.items()):
        row = {"variant": variant, "vus": vus, "n": len(rs)}
        for k in METRICS:
            vals = [v for v in (num(r[k]) for r in rs) if v is not None]
            row[f"{k}_median"] = round(statistics.median(vals), 2) if vals else ""
        rps = [v for v in (num(r["rps"]) for r in rs) if v is not None]
        row["rps_min"] = round(min(rps), 1) if rps else ""
        row["rps_max"] = round(max(rps), 1) if rps else ""
        out_rows.append(row)

    with open(dst, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=header, lineterminator="\n")
        w.writeheader()
        w.writerows(out_rows)

    cols = ["variant", "vus", "n", "rps_median", "p95_ms_median", "p99_ms_median",
            "failed_pct_median", "cpu_cores_avg_median", "rss_max_mb_median", "threads_max_median"]
    print("  ".join(f"{c:>14}" for c in cols))
    for r in out_rows:
        print("  ".join(f"{str(r[c]):>14}" for c in cols))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: aggregate.py results.csv summary.csv")
    main(sys.argv[1], sys.argv[2])
