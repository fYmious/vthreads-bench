#!/usr/bin/env python3
"""Достаёт ключевые метрики из файла k6 --summary-export.

Печатает одну строку CSV из 10 полей:
requests,rps,failed_pct,avg_ms,med_ms,p90_ms,p95_ms,p99_ms,max_ms,dropped
Понимает и старый (плоский), и новый (с вложенным "values") формат экспорта.
"""
import json
import sys


def values(metric):
    if not isinstance(metric, dict):
        return {}
    inner = metric.get("values")
    return inner if isinstance(inner, dict) else metric


def fmt(x, digits=3):
    return "" if x is None else f"{x:.{digits}f}"


def main(path):
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    m = data.get("metrics", {})
    reqs = values(m.get("http_reqs"))
    dur = values(m.get("http_req_duration"))
    failed = values(m.get("http_req_failed"))
    dropped = values(m.get("dropped_iterations"))

    rate = failed.get("rate", failed.get("value"))
    out = [
        fmt(reqs.get("count")),
        fmt(reqs.get("rate")),
        fmt(None if rate is None else rate * 100),
        fmt(dur.get("avg")),
        fmt(dur.get("med")),
        fmt(dur.get("p(90)")),
        fmt(dur.get("p(95)")),
        fmt(dur.get("p(99)")),
        fmt(dur.get("max")),
        fmt(dropped.get("count", 0), 0),  # метрика есть только в открытой модели
    ]
    print(",".join(out))


if __name__ == "__main__":
    try:
        main(sys.argv[1])
    except Exception as exc:  # noqa: BLE001
        print(f"parse_k6: {exc}", file=sys.stderr)
        sys.exit(1)
