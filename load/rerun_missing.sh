#!/usr/bin/env bash
# Дозапуск комбинаций, которые в основном прогоне были ошибочно помечены "unresponsive":
# платформенный вариант после перегрузки (E2 на 10000 клиентов, E4 на всех кучах, E6).
# Строки дописываются в results.csv тех же экспериментов, сводки пересчитываются.
#
#   bash load/rerun_missing.sh results/final-20261031-144413
set -u -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

S="${1:-$(ls -d results/final-* 2>/dev/null | tail -1)}"
[[ -d "$S" ]] || { echo "нет каталога результатов: $S"; exit 1; }
export REPEATS="${REPEATS:-3}" DURATION="${DURATION:-45}" WARMUP="${WARMUP:-20}" COOLDOWN="${COOLDOWN:-5}"
if (( $(nproc) >= 16 )); then
  export APP_CPUS="${APP_CPUS-0-7}" K6_CPUS="${K6_CPUS-8-11}" BACKEND_CPUS="${BACKEND_CPUS-12-15}"
else
  export APP_CPUS="${APP_CPUS-}" K6_CPUS="${K6_CPUS-}" BACKEND_CPUS="${BACKEND_CPUS-}"
  echo "ВНИМАНИЕ: меньше 16 логических ядер, разведение по ядрам по умолчанию отключено"
fi

bash load/run_bench.sh --check || exit 1

# описание системы (в основном прогоне этот блок из-за ошибки не записался)
{
  echo "date: $(date -Is)"
  echo "kernel: $(uname -sr)"
  echo "cpu: $(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
  echo "cpus: $(nproc)"
  echo "mem: $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  bash load/run_bench.sh --check | sed -n '1,3p'
} > "$S/env-system.txt"

run() { # run <каталог> VAR=значение ...
  local dir="$1"; shift
  env OUT="$S/$dir" "$@" bash load/run_bench.sh
}

echo "### E2: platform-200, 10000 клиентов"
run E2-slow-backend MODE=closed MS=1000 CALLS=1 LEVELS=10000 VARIANTS=platform:200 HEAP=2g

echo "### E4: platform-200 на всех кучах"
for h in 256m 512m 1g 2g 4g; do
  run E4-heap-sweep MODE=closed MS=1000 CALLS=1 LEVELS=10000 VARIANTS=platform:200 HEAP="$h" REPEATS=2
done

echo "### E6: platform-200, 2000 и 5000 клиентов"
run E6-very-slow-backend MODE=closed MS=5000 CALLS=1 LEVELS="2000 5000" VARIANTS=platform:200 HEAP=2g

# общий сводный файл по всем экспериментам
ALLSUM="$S/all_summary.csv"; first=1
for d in "$S"/E*/; do
  [[ -f "$d/summary.csv" ]] || continue
  name="$(basename "$d")"
  if (( first )); then head -1 "$d/summary.csv" | sed 's/^/experiment,/' > "$ALLSUM"; first=0; fi
  tail -n +2 "$d/summary.csv" | sed "s/^/$name,/" >> "$ALLSUM"
done
echo "ГОТОВО. Сводка: $ALLSUM"
