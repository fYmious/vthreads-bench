#!/usr/bin/env python3
"""Достаёт ключевые метрики из файла k6 --summary-export.

Печатает одну строку CSV:
requests,rps,failed_pct,avg_ms,med_ms,p90_ms,p95_ms,p99_ms,max_ms
Понимает и старый (плоский), и новый (с вложенным "values") формат экспорта.
"""
import json
import sys


def values(metric):
    if not isinstance(metric, dict):
        return {}
    inner = metric.get("values")
    return inner if isinstance(inner, dict) else metric


def main(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    m = data.get("metrics", {})
    reqs = values(m.get("http_reqs"))
    dur = values(m.get("http_req_duration"))
    failed = values(m.get("http_req_failed"))

    rate = failed.get("rate", failed.get("value"))
    out = [
        reqs.get("count"),
        reqs.get("rate"),
        None if rate is None else rate * 100,
        dur.get("avg"),
        dur.get("med"),
        dur.get("p(90)"),
        dur.get("p(95)"),
        dur.get("p(99)"),
        dur.get("max"),
    ]
    print(",".join("" if x is None else f"{x:.3f}" for x in out))


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Exception as exc:  # noqa: BLE001
        print(f"parse_k6: {exc}", file=sys.stderr)
        sys.exit(1)
