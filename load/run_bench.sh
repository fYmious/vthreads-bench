#!/usr/bin/env bash
# Автоматический прогон бенчмарка.
#
# Для каждого уровня нагрузки и каждого варианта (platform / virtual / reactive):
#   1) перезапускает приложение (холодная JVM, замеряет время старта),
#   2) прогревает его,
#   3) прогоняет k6 REPEATS раз, параллельно снимая RSS, число потоков ОС и CPU приложения,
#   4) дописывает строку в results.csv.
# В конце считает медианы по повторам (summary.csv).
#
# Запуск из корня проекта:
#   bash load/run_bench.sh                 # полный прогон (около часа)
#   QUICK=1 bash load/run_bench.sh         # быстрая проверка скрипта (несколько минут)
#
# Параметры (переменные окружения), значения по умолчанию в скобках:
#   VARIANTS   ("platform:200 virtual reactive")  platform:N - пул из N потоков Tomcat
#   VUS_LEVELS ("200 500 1000 2000 5000")         число одновременных клиентов k6
#   REPEATS (3)  DURATION (45, сек)  WARMUP (20, сек)  COOLDOWN (5, сек)
#   MS (100)     задержка backend, мс        CALLS (1)  число обращений к backend за запрос
#   JAVA_OPTS ("-Xms1g -Xmx1g")  BACKEND_JAVA_OPTS ("-Xms512m -Xmx512m")
#   APP_CPUS / K6_CPUS / BACKEND_CPUS  списки ядер для taskset, например APP_CPUS=0-3 K6_CPUS=4-5 BACKEND_CPUS=6-7

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if [[ "${QUICK:-0}" == "1" ]]; then
  D_LEVELS="200 1000"; D_REPEATS=1; D_DURATION=15; D_WARMUP=10
else
  D_LEVELS="200 500 1000 2000 5000"; D_REPEATS=3; D_DURATION=45; D_WARMUP=20
fi
VARIANTS="${VARIANTS:-platform:200 virtual reactive}"
VUS_LEVELS="${VUS_LEVELS:-$D_LEVELS}"
REPEATS="${REPEATS:-$D_REPEATS}"
DURATION="${DURATION:-$D_DURATION}"
WARMUP="${WARMUP:-$D_WARMUP}"
COOLDOWN="${COOLDOWN:-5}"
MS="${MS:-100}"
CALLS="${CALLS:-1}"
JAVA_OPTS="${JAVA_OPTS:--Xms1g -Xmx1g}"
BACKEND_JAVA_OPTS="${BACKEND_JAVA_OPTS:--Xms512m -Xmx512m}"
APP_PORT=8080
BACKEND_PORT=8081

APP_PID=""; BACKEND_PID=""; SAMPLER_PID=""

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }
now() { date +%s.%N; }
diff_s() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", a-b}'; }
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------- проверки окружения ----------
for tool in java curl k6 python3 awk; do
  command -v "$tool" >/dev/null || die "не найден '$tool'"
done
JARS=(backend/target/backend-1.0.0.jar app-mvc/target/app-mvc-1.0.0.jar app-webflux/target/app-webflux-1.0.0.jar)
for j in "${JARS[@]}"; do
  [[ -f "$j" ]] || die "нет $j - сначала: mvn -q package -DskipTests"
done
port_busy "$APP_PORT" && die "порт $APP_PORT занят (остановите запущенное приложение)"
port_busy "$BACKEND_PORT" && die "порт $BACKEND_PORT занят (остановите запущенный backend)"

ulimit -n 65535 2>/dev/null || log "ВНИМАНИЕ: не удалось поднять ulimit -n, при тысячах соединений возможны ошибки"
CLK_TCK="$(getconf CLK_TCK)"

PIN_APP=(); PIN_K6=(); PIN_BACKEND=()
if command -v taskset >/dev/null; then
  if [[ -n "${APP_CPUS:-}" ]]; then PIN_APP=(taskset -c "$APP_CPUS"); fi
  if [[ -n "${K6_CPUS:-}" ]]; then PIN_K6=(taskset -c "$K6_CPUS"); fi
  if [[ -n "${BACKEND_CPUS:-}" ]]; then PIN_BACKEND=(taskset -c "$BACKEND_CPUS"); fi
fi

OUT="results/$(date +%Y%m%d-%H%M%S)"
RAW="$OUT/raw"
mkdir -p "$RAW"
CSV="$OUT/results.csv"
echo "variant,vus,repeat,duration_s,requests,rps,failed_pct,avg_ms,med_ms,p90_ms,p95_ms,p99_ms,max_ms,cpu_cores_avg,rss_max_mb,threads_max,startup_s" > "$CSV"

# ---------- описание окружения для методики ----------
{
  echo "date: $(date -Is)"
  echo "kernel: $(uname -sr)"
  echo "cpu: $(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
  echo "cpus: $(nproc)"
  echo "mem: $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
  echo "--- java ---"; java -version 2>&1
  echo "--- k6 ---"; k6 version 2>&1
  echo "--- parameters ---"
  echo "VARIANTS=$VARIANTS"; echo "VUS_LEVELS=$VUS_LEVELS"; echo "REPEATS=$REPEATS"
  echo "DURATION=$DURATION"; echo "WARMUP=$WARMUP"; echo "COOLDOWN=$COOLDOWN"
  echo "MS=$MS"; echo "CALLS=$CALLS"
  echo "JAVA_OPTS=$JAVA_OPTS"; echo "BACKEND_JAVA_OPTS=$BACKEND_JAVA_OPTS"
  echo "APP_CPUS=${APP_CPUS:-}"; echo "K6_CPUS=${K6_CPUS:-}"; echo "BACKEND_CPUS=${BACKEND_CPUS:-}"
} > "$OUT/env.txt"

# ---------- очистка при выходе ----------
stop_app() {
  [[ -n "$APP_PID" ]] || return 0
  kill "$APP_PID" 2>/dev/null
  for _ in $(seq 1 50); do kill -0 "$APP_PID" 2>/dev/null || break; sleep 0.2; done
  kill -9 "$APP_PID" 2>/dev/null
  wait "$APP_PID" 2>/dev/null
  APP_PID=""
}
cleanup() {
  [[ -n "$SAMPLER_PID" ]] && kill "$SAMPLER_PID" 2>/dev/null
  stop_app
  if [[ -n "$BACKEND_PID" ]]; then kill "$BACKEND_PID" 2>/dev/null; wait "$BACKEND_PID" 2>/dev/null; fi
}
trap cleanup EXIT
trap 'echo; log "прервано"; exit 130' INT TERM

# ---------- функции ----------
# wait_http <url> <таймаут, сек> <pid процесса, который должен жить>
wait_http() {
  local url="$1" timeout="$2" pid="$3" t0
  t0="$(now)"
  while true; do
    curl -sf -o /dev/null "$url" && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    awk -v a="$(now)" -v b="$t0" -v t="$timeout" 'BEGIN{exit !(a-b>t)}' && return 1
    sleep 0.2
  done
}

# start_app <вариант> <метка для логов>; задаёт APP_PID и STARTUP_S
start_app() {
  local variant="$1" label="$2" kind arg="" jar
  local args=()
  kind="${variant%%:*}"
  [[ "$variant" == *:* ]] && arg="${variant#*:}"
  case "$kind" in
    platform) jar=app-mvc/target/app-mvc-1.0.0.jar
              args=(--spring.profiles.active=platform "--server.tomcat.threads.max=${arg:-200}") ;;
    virtual)  jar=app-mvc/target/app-mvc-1.0.0.jar
              args=(--spring.profiles.active=virtual) ;;
    reactive) jar=app-webflux/target/app-webflux-1.0.0.jar ;;
    *) die "неизвестный вариант '$variant' (ожидается platform[:N], virtual или reactive)" ;;
  esac
  local t0; t0="$(now)"
  # shellcheck disable=SC2086
  ${PIN_APP[@]+"${PIN_APP[@]}"} java $JAVA_OPTS -jar "$jar" ${args[@]+"${args[@]}"} > "$RAW/app-$label.log" 2>&1 &
  APP_PID=$!
  if ! wait_http "http://127.0.0.1:$APP_PORT/whoami" 90 "$APP_PID"; then
    log "приложение $variant не поднялось, см. $RAW/app-$label.log"
    stop_app
    return 1
  fi
  STARTUP_S="$(diff_s "$(now)" "$t0")"
  return 0
}

# k6_run <vus> <длительность, сек> [файл для summary-export]
k6_run() {
  local vus="$1" dur="$2" export_file="${3:-}" logf="$4"
  local extra=()
  [[ -n "$export_file" ]] && extra=(--summary-export="$export_file")
  ${PIN_K6[@]+"${PIN_K6[@]}"} k6 run \
    -e VUS="$vus" -e DURATION="${dur}s" -e MS="$MS" -e CALLS="$CALLS" \
    ${extra[@]+"${extra[@]}"} load/work.js > "$logf" 2>&1
}

# раз в секунду пишет "RSS_kB потоки_ОС" процесса в файл
sample_loop() {
  local pid="$1" out="$2" rss thr
  while kill -0 "$pid" 2>/dev/null; do
    rss="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    thr="$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null)"
    [[ -n "$rss" ]] && echo "$rss $thr" >> "$out"
    sleep 1
  done
}

# суммарное процессорное время процесса (utime+stime) в тиках
cpu_ticks() { sed 's/^.*) //' "/proc/$1/stat" | awk '{print $12+$13}'; }

# run_one <метка варианта> <vus> <повтор>
run_one() {
  local vname="$1" vus="$2" rep="$3"
  local base="$RAW/$vname-vus$vus-r$rep"
  local samples="$base.samples"
  : > "$samples"

  sample_loop "$APP_PID" "$samples" &
  SAMPLER_PID=$!
  local c0 t0 c1 t1
  c0="$(cpu_ticks "$APP_PID")"; t0="$(now)"

  k6_run "$vus" "$DURATION" "$base.json" "$base.k6.log" || log "k6 завершился с ненулевым кодом (см. $base.k6.log)"

  t1="$(now)"
  if kill -0 "$APP_PID" 2>/dev/null; then c1="$(cpu_ticks "$APP_PID")"; else c1=""; fi
  kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""

  local parsed cpu="" rss="" thr=""
  parsed="$(python3 load/parse_k6.py "$base.json" 2>>"$base.k6.log")" || parsed=",,,,,,,,"
  if [[ "$parsed" == ",,,,,,,," ]]; then
    log "  ВНИМАНИЕ: не удалось разобрать итог k6, смотрите $base.json и $base.k6.log"
  fi
  if [[ -n "$c1" ]]; then
    cpu="$(awk -v d="$((c1 - c0))" -v tck="$CLK_TCK" -v e="$(diff_s "$t1" "$t0")" 'BEGIN{printf "%.2f", d/tck/e}')"
  else
    log "ВНИМАНИЕ: приложение упало во время прогона $vname vus=$vus"
  fi
  if [[ -s "$samples" ]]; then
    rss="$(awk 'BEGIN{m=0} {if($1>m)m=$1} END{printf "%.0f", m/1024}' "$samples")"
    thr="$(awk 'BEGIN{m=0} {if($2>m)m=$2} END{print m}' "$samples")"
  fi
  echo "$vname,$vus,$rep,$DURATION,$parsed,$cpu,$rss,$thr,$STARTUP_S" >> "$CSV"
  log "  повтор $rep: $(echo "$parsed" | awk -F, '{printf "rps=%s p95=%s мс ошибок=%s%%", $2, $6, $3}'), CPU=${cpu:-?} ядер, RSS=${rss:-?} МБ, потоков ОС=${thr:-?}"
}

# ---------- основной цикл ----------
log "результаты: $OUT"
log "запускаю backend"
# shellcheck disable=SC2086
${PIN_BACKEND[@]+"${PIN_BACKEND[@]}"} java $BACKEND_JAVA_OPTS -jar backend/target/backend-1.0.0.jar > "$RAW/backend.log" 2>&1 &
BACKEND_PID=$!
wait_http "http://127.0.0.1:$BACKEND_PORT/slow?ms=1" 90 "$BACKEND_PID" || die "backend не поднялся, см. $RAW/backend.log"

for vus in $VUS_LEVELS; do
  for variant in $VARIANTS; do
    vname="${variant//:/-}"
    log "=== $vname, $vus клиентов ==="
    STARTUP_S=""
    start_app "$variant" "$vname-vus$vus" || continue
    log "  старт за ${STARTUP_S} с, прогрев ${WARMUP} с"
    k6_run "$vus" "$WARMUP" "" "$RAW/$vname-vus$vus.warmup.log" || true
    for rep in $(seq 1 "$REPEATS"); do
      sleep "$COOLDOWN"
      run_one "$vname" "$vus" "$rep"
    done
    stop_app
  done
done

log "считаю медианы"
python3 load/aggregate.py "$CSV" "$OUT/summary.csv"
log "готово: $CSV, $OUT/summary.csv, $OUT/env.txt"
