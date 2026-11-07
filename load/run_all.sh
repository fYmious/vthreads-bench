#!/usr/bin/env bash
# Все эксперименты для статьи одним запуском. Использует JDK 25 (ищет сам, см. run_bench.sh).
#
#   bash load/run_all.sh --list              показать план и оценку времени
#   bash load/run_all.sh                     выполнить всё (несколько часов)
#   bash load/run_all.sh --only E1,E2        выполнить только перечисленные
#   QUICK=1 bash load/run_all.sh             быстрая проверка (по одному уровню, 1 повтор, короткие замеры)
#
# Общие параметры (переменные окружения):
#   HEAP (2g)  куча приложения в основных экспериментах (E4 перебирает разные значения)
#   APP_CPUS / K6_CPUS / BACKEND_CPUS  разведение по ядрам; по умолчанию 0-7 / 8-11 / 12-15
#              (если на машине 16 логических ядер, иначе без разведения). Отключить: APP_CPUS= K6_CPUS= BACKEND_CPUS=
#   SESSION    каталог результатов (по умолчанию results/final-<дата-время>)

set -u -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

QUICK="${QUICK:-0}"
if [[ "$QUICK" == "1" ]]; then
  export REPEATS="${REPEATS:-1}" DURATION="${DURATION:-10}" WARMUP="${WARMUP:-5}"
else
  export REPEATS="${REPEATS:-3}" DURATION="${DURATION:-45}" WARMUP="${WARMUP:-20}"
fi
export COOLDOWN="${COOLDOWN:-5}"
export HEAP="${HEAP:-2g}"
SESSION="${SESSION:-results/final-$(date +%Y%m%d-%H%M%S)}"

NPROC="$(nproc)"
if (( NPROC >= 16 )); then
  export APP_CPUS="${APP_CPUS-0-7}" K6_CPUS="${K6_CPUS-8-11}" BACKEND_CPUS="${BACKEND_CPUS-12-15}"
else
  export APP_CPUS="${APP_CPUS-}" K6_CPUS="${K6_CPUS-}" BACKEND_CPUS="${BACKEND_CPUS-}"
  echo "ВНИМАНИЕ: на машине $NPROC логических ядер, разведение по ядрам по умолчанию отключено (задайте APP_CPUS/K6_CPUS/BACKEND_CPUS сами)"
fi

ALL="E1 E2 E3 E4 E5 E6 E7"
ONLY="$ALL"
LIST_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) LIST_ONLY=1 ;;
    --only) shift; ONLY="${1//,/ }" ;;
    *) echo "неизвестный аргумент: $1"; exit 2 ;;
  esac
  shift
done

# lv "<полный список>": при QUICK берёт только первый уровень
lv() { if [[ "$QUICK" == "1" ]]; then echo "${1%% *}"; else echo "$1"; fi; }
# est <комбинаций> <повторов> <пауза>: оценка минут
est() { awk -v c="$1" -v r="$2" -v cd="$3" -v d="$DURATION" -v w="$WARMUP" 'BEGIN{printf "%d", c*(18+w+r*(cd+d+3))/60+0.5}'; }
nlev() { echo "$1" | wc -w; }

E1_LEVELS="$(lv "200 500 1000 2000 5000")"
E2_LEVELS="$(lv "1000 2000 5000 10000")"
E3_VARIANTS="platform:50 platform:100 platform:200 platform:500 platform:1000"
E4_HEAPS="256m 512m 1g 2g 4g"; [[ "$QUICK" == "1" ]] && E4_HEAPS="512m 2g"
E5_LEVELS="$(lv "1000 1900 3000 6000")"
E5_COOLDOWN="${E5_COOLDOWN:-15}"
E6_LEVELS="$(lv "2000 5000")"
E7_LEVELS="$(lv "500 2000")"
V3="platform:200 virtual reactive"

describe() {
  echo "План (кучa основных экспериментов HEAP=$HEAP, повторов REPEATS=$REPEATS, замер ${DURATION} с, прогрев ${WARMUP} с):"
  printf "  %-4s %-62s %s\n" E1 "быстрый backend (100 мс), закрытая модель, клиентов: $E1_LEVELS" "~$(est $(( $(nlev "$E1_LEVELS") * 3 )) "$REPEATS" "$COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E2 "медленный backend (1000 мс), закрытая модель, клиентов: $E2_LEVELS" "~$(est $(( $(nlev "$E2_LEVELS") * 3 )) "$REPEATS" "$COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E3 "размер пула платформенных потоков (50/100/200/500/1000), 2000 клиентов, 1000 мс" "~$(est 5 "$REPEATS" "$COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E4 "минимальная куча: $E4_HEAPS, 10000 клиентов, 1000 мс, 3 варианта" "~$(est $(( $(nlev "$E4_HEAPS") * 3 )) "$([[ $QUICK == 1 ]] && echo 1 || echo 2)" "$COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E5 "перегрузка, открытая модель, запросов/с: $E5_LEVELS, 100 мс" "~$(est $(( $(nlev "$E5_LEVELS") * 3 )) "$([[ $QUICK == 1 ]] && echo 1 || echo 2)" "$E5_COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E6 "очень медленный backend (5000 мс), клиентов: $E6_LEVELS" "~$(est $(( $(nlev "$E6_LEVELS") * 3 )) "$REPEATS" "$COOLDOWN") мин"
  printf "  %-4s %-62s %s\n" E7 "3 последовательных обращения к backend за запрос (100 мс), клиентов: $E7_LEVELS" "~$(est $(( $(nlev "$E7_LEVELS") * 3 )) "$REPEATS" "$COOLDOWN") мин"
  echo "Оценка грубая: без учёта запуска JVM и пауз между экспериментами."
}

if [[ "$LIST_ONLY" == "1" ]]; then describe; exit 0; fi

# fail-fast: JDK 25, jar-файлы, порты
bash load/run_bench.sh --check || exit 1
mkdir -p "$SESSION"
describe | tee "$SESSION/plan.txt"
echo "результаты: $SESSION"

run_engine() { # run_engine <каталог эксперимента> [VAR=значение ...]
  local dir="$1"; shift
  env OUT="$SESSION/$dir" "$@" bash load/run_bench.sh
}

exp_E1() { run_engine E1-fast-backend MODE=closed MS=100 CALLS=1 LEVELS="$E1_LEVELS" VARIANTS="$V3"; }
exp_E2() { run_engine E2-slow-backend MODE=closed MS=1000 CALLS=1 LEVELS="$E2_LEVELS" VARIANTS="$V3"; }
exp_E3() { run_engine E3-pool-size MODE=closed MS=1000 CALLS=1 LEVELS="$(lv 2000)" VARIANTS="$E3_VARIANTS"; }
exp_E4() {
  local h r=2; [[ "$QUICK" == "1" ]] && r=1
  for h in $E4_HEAPS; do
    run_engine E4-heap-sweep MODE=closed MS=1000 CALLS=1 LEVELS="$(lv 10000)" VARIANTS="$V3" HEAP="$h" REPEATS="$r"
  done
}
exp_E5() {
  local r=2; [[ "$QUICK" == "1" ]] && r=1
  run_engine E5-overload-open MODE=open MS=100 CALLS=1 LEVELS="$E5_LEVELS" VARIANTS="$V3" REPEATS="$r" COOLDOWN="$E5_COOLDOWN"
}
exp_E6() { run_engine E6-very-slow-backend MODE=closed MS=5000 CALLS=1 LEVELS="$E6_LEVELS" VARIANTS="$V3"; }
exp_E7() { run_engine E7-multi-call MODE=closed MS=100 CALLS=3 LEVELS="$E7_LEVELS" VARIANTS="$V3"; }

for e in $ONLY; do
  declare -F "exp_$e" >/dev/null || { echo "нет эксперимента $e"; continue; }
  echo; echo "################ $e ################"
  "exp_$e"
done

# общий сводный файл по всем экспериментам
ALLSUM="$SESSION/all_summary.csv"
first=1
for d in "$SESSION"/E*/; do
  [[ -f "$d/summary.csv" ]] || continue
  name="$(basename "$d")"
  if (( first )); then head -1 "$d/summary.csv" | sed 's/^/experiment,/' > "$ALLSUM"; first=0; fi
  tail -n +2 "$d/summary.csv" | sed "s/^/$name,/" >> "$ALLSUM"
done
echo; echo "ГОТОВО. Сводка по всем экспериментам: $ALLSUM"
