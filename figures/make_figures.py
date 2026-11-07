#!/usr/bin/env python3
"""Рисунки для статьи из all_summary.csv.

Использование: python3 make_figures.py <каталог сессии> [каталог для рисунков]

Размеры подогнаны под требования к статье: ширина 165 мм (полоса набора), высота не более
половины страницы, весь текст на рисунках 12 пт. Шрифт берётся первый доступный из
Times New Roman / Liberation Serif / Tinos / DejaVu Serif.
Подписей и заголовков внутри рисунков нет: подпись "Рис. N. ..." пишется в тексте статьи.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager

SESSION = sys.argv[1]
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(SESSION, "figures")
os.makedirs(OUT, exist_ok=True)

available = {f.name for f in font_manager.fontManager.ttflist}
for name in ["Times New Roman", "Liberation Serif", "Tinos", "DejaVu Serif"]:
    if name in available:
        FONT = name
        break
plt.rcParams.update({
    "font.family": FONT, "font.size": 12, "axes.labelsize": 12, "xtick.labelsize": 12,
    "ytick.labelsize": 12, "legend.fontsize": 12, "axes.linewidth": 0.8,
    "figure.dpi": 100, "savefig.dpi": 300, "axes.grid": True, "grid.alpha": 0.3,
})
W, H = 6.4, 3.3  # дюймы: 6.4 in = 163 мм, 3.3 in = 84 мм (< 0,5 страницы)

rows = list(csv.DictReader(open(os.path.join(SESSION, "all_summary.csv"), encoding="utf-8")))


def get(exp, heap, variant, load):
    for r in rows:
        if (r["experiment"].startswith(exp) and r["heap"] == heap
                and r["variant"] == variant and int(r["load"]) == load):
            return r
    return None


def f(r, key):
    try:
        return float(r[key])
    except (TypeError, ValueError, KeyError):
        return None


def success_rps(r):
    """Пропускная способность успешных ответов: в k6 неуспешные запросы тоже входят в http_reqs."""
    rps, fail = f(r, "rps_median"), f(r, "failed_pct_median") or 0.0
    return None if rps is None else rps * (1 - fail / 100.0)


STYLE = {  # читаемо и в чёрно-белой печати
    "platform-200": dict(color="#444444", marker="s", ls="-", label="платформенные (пул 200)"),
    "virtual": dict(color="#1f77b4", marker="o", ls="--", label="виртуальные потоки"),
    "reactive": dict(color="#d95f02", marker="^", ls="-.", label="реактивный (WebFlux)"),
}
VARS = list(STYLE)


def save(fig, name):
    fig.tight_layout(pad=0.4)
    path = os.path.join(OUT, name)
    fig.savefig(path)
    plt.close(fig)
    print("saved", path)


# ---------- Рис. 1: пропускная способность, медленный backend (E2) ----------
loads = [1000, 2000, 5000, 10000]
fig, ax = plt.subplots(figsize=(W, H))
ax.plot(loads, [l / 1.0 for l in loads], color="#888888", ls=":", lw=1.2,
        label="теоретический предел")
for v in VARS:
    ys = [success_rps(get("E2", "2g", v, l)) for l in loads]
    ax.plot(loads, ys, **STYLE[v], lw=1.6, ms=6)
ax.set_xlabel("Одновременных клиентов")
ax.set_ylabel("Запросов в секунду")
ax.set_xscale("log"); ax.set_xticks(loads); ax.set_xticklabels([str(l) for l in loads])
ax.set_yscale("log"); ax.set_ylim(150, 15000)
ax.legend(loc="upper left", framealpha=0.9)
save(fig, "fig1_throughput_slow_backend.png")

# ---------- Рис. 2: задержка p95, медленный backend (E2) ----------
fig, ax = plt.subplots(figsize=(W, H))
for v in VARS:
    ys = [f(get("E2", "2g", v, l), "p95_ms_median") / 1000.0 for l in loads]
    ax.plot(loads, ys, **STYLE[v], lw=1.6, ms=6)
ax.set_xlabel("Одновременных клиентов")
ax.set_ylabel("Задержка p95, с")
ax.set_xscale("log"); ax.set_xticks(loads); ax.set_xticklabels([str(l) for l in loads])
ax.set_yscale("log"); ax.set_ylim(0.8, 100)
ax.set_yticks([1, 10, 100]); ax.set_yticklabels(["1", "10", "100"])
ax.legend(loc="upper left", framealpha=0.9)
save(fig, "fig2_latency_p95_slow_backend.png")

# ---------- Рис. 3: минимальная куча при 10 000 клиентов (E4) ----------
heaps = ["256m", "512m", "1g", "2g", "4g"]
labels = ["256 МБ", "512 МБ", "1 ГБ", "2 ГБ", "4 ГБ"]
fig, ax = plt.subplots(figsize=(W, H))
bw = 0.26
hatches = {"platform-200": "", "virtual": "//", "reactive": "xx"}
for i, v in enumerate(VARS):
    for j, h in enumerate(heaps):
        r = get("E4", h, v, 10000)
        x = j + (i - 1) * bw
        y = success_rps(r) if r and r["status"] == "ok" else None
        if y is not None:
            ax.bar(x, y, bw * 0.92, color=STYLE[v]["color"], hatch=hatches[v], edgecolor="white", lw=0.5)
        else:
            ax.bar(x, 250, bw * 0.92, color="white", edgecolor=STYLE[v]["color"], lw=1.0, hatch="..")
            txt = "OOM" if (r and r["status"] == "oom") else "сбой"
            ax.text(x, 330, txt, rotation=90, ha="center", va="bottom", fontsize=12)
ax.set_xticks(range(len(heaps))); ax.set_xticklabels(labels)
ax.set_xlabel("Размер кучи (-Xmx)")
ax.set_ylabel("Запросов в секунду")
ax.set_ylim(0, 14800)
handles = [plt.Rectangle((0, 0), 1, 1, color=STYLE[v]["color"], hatch=hatches[v], ec="white") for v in VARS]
ax.legend(handles, [STYLE[v]["label"] for v in VARS], loc="upper left", ncol=1, framealpha=0.9)
save(fig, "fig3_min_heap_10000_clients.png")

# ---------- Рис. 4: перегрузка, открытая модель (E5) ----------
rates = [1000, 1900, 3000, 6000]
fig, ax = plt.subplots(figsize=(W, H))
ax.plot(rates, rates, color="#888888", ls=":", lw=1.2, label="поступающая нагрузка")
for v in VARS:
    ys = [success_rps(get("E5", "2g", v, r)) for r in rates]
    ax.plot(rates, ys, **STYLE[v], lw=1.6, ms=6)
ax.set_xlabel("Поступающая нагрузка, запросов в секунду")
ax.set_ylabel("Успешных ответов в секунду")
ax.set_xticks(rates)
ax.set_ylim(0, 7000)
ax.legend(loc="upper left", framealpha=0.9)
save(fig, "fig4_overload_open_model.png")

# ---------- числа для проверки и для текста статьи ----------
with open(os.path.join(OUT, "article_numbers.csv"), "w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh, lineterminator="\n")
    w.writerow(["experiment", "heap", "variant", "load", "status", "rps_all", "failed_pct",
                "rps_success", "p95_ms", "p99_ms", "cpu_cores", "gc_pause_total_ms", "gc_pauses", "rss_max_mb"])
    for r in rows:
        w.writerow([r["experiment"], r["heap"], r["variant"], r["load"], r["status"],
                    r["rps_median"], r["failed_pct_median"],
                    "" if success_rps(r) is None else round(success_rps(r), 1),
                    r["p95_ms_median"], r["p99_ms_median"], r["cpu_cores_avg_median"],
                    r["gc_pause_total_ms_median"], r["gc_pauses_median"], r["rss_max_mb_median"]])
print("saved", os.path.join(OUT, "article_numbers.csv"), "| шрифт:", FONT)
