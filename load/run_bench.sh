#!/usr/bin/env bash
# Движок бенчмарка: прогоняет один набор (варианты x уровни нагрузки x повторы).
# Обычно вызывается из run_all.sh, но можно и вручную.
#
# Для каждого уровня нагрузки и варианта скрипт: перезапускает приложение (холодная JVM),
# прогревает, делает REPEATS замеров k6 и параллельно снимает CPU, RSS, потоки ОС и лог GC.
# Если приложение умерло (OutOfMemoryError и т.п.), повторы для этой пары прекращаются,
# а в CSV пишется статус. В конце считает медианы (summary.csv).
#
# JDK 25 ищется автоматически (/usr/lib/jvm, sdkman и т.д.). Свой путь: JDK_HOME=/путь/к/jdk-25
# Проверка окружения без запуска: bash load/run_bench.sh --check
#
# Параметры (переменные окружения, значения по умолчанию в скобках):
#   MODE (closed)   closed: LEVELS = число одновременных клиентов (k6 constant-vus);
#                   open:   LEVELS = число запросов в секунду (k6 constant-arrival-rate)
#   LEVELS ("200 500 1000 2000 5000")
#   VARIANTS ("platform:200 virtual reactive")     platform:N = пул Tomcat из N потоков
#   MS (100)  задержка backend, мс     CALLS (1)  последовательных обращений к backend за запрос
#   HEAP (2g) размер кучи приложения   EXTRA_JAVA_OPTS ("")
#   REPEATS (3)  DURATION (45)  WARMUP (20)  COOLDOWN (5)   секунды
#   OUT         каталог результатов (по умолчанию results/<дата-время>); при повторном
#               вызове с тем же OUT строки дописываются в тот же results.csv
#   APP_CPUS / K6_CPUS / BACKEND_CPUS   ядра для taskset (например 0-7, 8-11, 12-15)
#   DRAIN_MAX (300)  сколько секунд ждать, пока приложение разберёт очередь после перегрузки
#   QUICK=1     быстрая проверка (меньше уровней, повторов и времени)

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ОШИБКА: $*" >&2; exit 1; }
now() { date +%s.%N; }
diff_s() { awk -v a="$1" -v b="$2" 'BEGIN{printf "%.3f", a-b}'; }
port_busy() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------- параметры ----------
if [[ "${QUICK:-0}" == "1" ]]; then
  D_LEVELS="200 1000"; D_REPEATS=1; D_DURATION=15; D_WARMUP=10
else
  D_LEVELS="200 500 1000 2000 5000"; D_REPEATS=3; D_DURATION=45; D_WARMUP=20
fi
MODE="${MODE:-closed}"
VARIANTS="${VARIANTS:-platform:200 virtual reactive}"
LEVELS="${LEVELS:-${VUS_LEVELS:-$D_LEVELS}}"
REPEATS="${REPEATS:-$D_REPEATS}"
DURATION="${DURATION:-$D_DURATION}"
WARMUP="${WARMUP:-$D_WARMUP}"
COOLDOWN="${COOLDOWN:-5}"
MS="${MS:-100}"
CALLS="${CALLS:-1}"
HEAP="${HEAP:-2g}"
EXTRA_JAVA_OPTS="${EXTRA_JAVA_OPTS:-}"
BACKEND_JAVA_OPTS="${BACKEND_JAVA_OPTS:--Xms1g -Xmx1g}"
APP_PORT=8080
BACKEND_PORT=8081
[[ "$MODE" == "closed" || "$MODE" == "open" ]] || die "MODE должен быть closed или open"

APP_PID=""; BACKEND_PID=""; SAMPLER_PID=""; APP_LOG=""; GC_LOG=""

# ---------- выбор JDK 25 ----------
is_jdk25() { [[ -x "$1/bin/java" ]] && "$1/bin/java" -version 2>&1 | head -1 | grep -q 'version "25[."]'; }
select_jdk() {
  local cands=() d
  if [[ -n "${JDK_HOME:-}" ]]; then
    is_jdk25 "$JDK_HOME" || die "JDK_HOME=$JDK_HOME не является JDK 25"
    JAVA_BIN="$JDK_HOME/bin/java"; return 0
  fi
  cands+=(/usr/lib/jvm/java-25-openjdk /usr/lib/jvm/java-25-openjdk-amd64 /usr/lib/jvm/*25*
          "$HOME"/.sdkman/candidates/java/25* "$HOME"/.jdks/*25* /opt/*jdk*25* /opt/*25*)
  [[ -n "${JAVA_HOME:-}" ]] && cands+=("$JAVA_HOME")
  for d in "${cands[@]}"; do
    if is_jdk25 "$d"; then JAVA_BIN="$d/bin/java"; return 0; fi
  done
  if command -v java >/dev/null && java -version 2>&1 | head -1 | grep -q 'version "25[."]'; then
    JAVA_BIN="$(command -v java)"; return 0
  fi
  return 1
}

for tool in curl k6 python3 awk; do command -v "$tool" >/dev/null || die "не найден '$tool'"; done
if ! select_jdk; then
  echo "JDK 25 не найден. Установленные JDK:" >&2
  ls /usr/lib/jvm 2>/dev/null >&2 || true
  die "укажите путь явно: JDK_HOME=/usr/lib/jvm/<каталог jdk 25> bash load/run_bench.sh"
fi
JARS=(backend/target/backend-1.0.0.jar app-mvc/target/app-mvc-1.0.0.jar app-webflux/target/app-webflux-1.0.0.jar)
for j in "${JARS[@]}"; do [[ -f "$j" ]] || die "нет $j - сначала: mvn -q package -DskipTests"; done
[[ -f load/work.js && -f load/overload.js ]] || die "нет load/work.js или load/overload.js"

if [[ "${1:-}" == "--check" ]]; then
  echo "JDK: $JAVA_BIN"; "$JAVA_BIN" -version 2>&1 | head -1
  echo "k6: $(k6 version 2>&1 | head -1)"
  echo "порты: $(port_busy $APP_PORT && echo "$APP_PORT занят" || echo "$APP_PORT свободен"), $(port_busy $BACKEND_PORT && echo "$BACKEND_PORT занят" || echo "$BACKEND_PORT свободен")"
  echo "ok"; exit 0
fi

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

OUT="${OUT:-results/$(date +%Y%m%d-%H%M%S)}"
RAW="$OUT/raw"
mkdir -p "$RAW"
CSV="$OUT/results.csv"
CASE="$MODE-ms$MS-c$CALLS-h$HEAP"
if [[ ! -s "$CSV" ]]; then
  echo "mode,ms,calls,heap,variant,load,repeat,duration_s,requests,rps,failed_pct,avg_ms,med_ms,p90_ms,p95_ms,p99_ms,max_ms,dropped,cpu_cores_avg,rss_max_mb,threads_max,gc_pauses,gc_pause_total_ms,gc_pause_max_ms,heap_after_gc_max_mb,startup_s,idle_rss_mb,first_req_overhead_ms,status" > "$CSV"
fi

# ---------- описание окружения для методики ----------
NEW_ENV=0; [[ -f "$OUT/env.txt" ]] || NEW_ENV=1
{
  if (( NEW_ENV )); then
    echo "kernel: $(uname -sr)"
    echo "cpu: $(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
    echo "cpus: $(nproc)"
    echo "mem: $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)"
    echo "java_bin: $JAVA_BIN"
    "$JAVA_BIN" -version 2>&1
    echo "gc: $("$JAVA_BIN" -XX:+PrintFlagsFinal -version 2>/dev/null | awk '/Use(G1|Parallel|Serial|Z|Shenandoah)GC / && /true/ {print $2}' | tr '\n' ' ')"
    echo "k6: $(k6 version 2>&1 | head -1)"
    echo "backend_java_opts: $BACKEND_JAVA_OPTS"
  fi
  echo "--- прогон $(date -Is) ---"
  echo "MODE=$MODE MS=$MS CALLS=$CALLS HEAP=$HEAP EXTRA_JAVA_OPTS=$EXTRA_JAVA_OPTS"
  echo "VARIANTS=$VARIANTS LEVELS=$LEVELS REPEATS=$REPEATS DURATION=$DURATION WARMUP=$WARMUP COOLDOWN=$COOLDOWN"
  echo "APP_CPUS=${APP_CPUS:-} K6_CPUS=${K6_CPUS:-} BACKEND_CPUS=${BACKEND_CPUS:-}"
} >> "$OUT/env.txt"

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

# start_app <вариант> <метка>; задаёт APP_PID, APP_LOG, GC_LOG, STARTUP_S, FIRST_REQ_MS, IDLE_RSS_MB
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
  APP_LOG="$RAW/app-$label.log"
  GC_LOG="$RAW/gc-$label.log"
  local t0; t0="$(now)"
  # shellcheck disable=SC2086
  ${PIN_APP[@]+"${PIN_APP[@]}"} "$JAVA_BIN" "-Xms$HEAP" "-Xmx$HEAP" "-Xlog:gc:file=$GC_LOG" $EXTRA_JAVA_OPTS \
    -jar "$jar" ${args[@]+"${args[@]}"} > "$APP_LOG" 2>&1 &
  APP_PID=$!
  if ! wait_http "http://127.0.0.1:$APP_PORT/whoami" 90 "$APP_PID"; then
    log "приложение $variant не поднялось, см. $APP_LOG"
    stop_app
    return 1
  fi
  STARTUP_S="$(diff_s "$(now)" "$t0")"
  # первый запрос после старта (за вычетом искусственной задержки backend)
  FIRST_REQ_MS="$(curl -s -o /dev/null -m 120 -w '%{time_total}' "http://127.0.0.1:$APP_PORT/work?ms=$MS&calls=$CALLS" \
    | awk -v d="$((MS * CALLS))" '{printf "%.0f", $1*1000-d}')"
  sleep 2
  IDLE_RSS_MB="$(awk '/^VmRSS:/{printf "%.0f", $2/1024}' "/proc/$APP_PID/status" 2>/dev/null)"
  return 0
}

# k6_run <уровень> <длительность, сек> <файл summary-export или ""> <лог>
k6_run() {
  local level="$1" dur="$2" export_file="$3" logf="$4"
  local script=load/work.js
  local envs=(-e "VUS=$level")
  if [[ "$MODE" == "open" ]]; then
    script=load/overload.js
    envs=(-e "RATE=$level" -e "PREALLOC=${PREALLOC:-2000}" -e "MAXVUS=${MAXVUS:-20000}")
  fi
  local extra=()
  [[ -n "$export_file" ]] && extra=("--summary-export=$export_file")
  ${PIN_K6[@]+"${PIN_K6[@]}"} k6 run "${envs[@]}" \
    -e "DURATION=${dur}s" -e "MS=$MS" -e "CALLS=$CALLS" \
    ${extra[@]+"${extra[@]}"} "$script" > "$logf" 2>&1
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

# Ждёт, пока приложение снова начнёт отвечать. После перегрузки платформенный вариант
# ещё долго разбирает очередь запросов, и /whoami стоит в той же очереди.
DRAIN_MAX="${DRAIN_MAX:-300}"
drain_wait() {
  local t0; t0="$(now)"
  while ! curl -sf -m 3 -o /dev/null "http://127.0.0.1:$APP_PORT/whoami"; do
    kill -0 "$APP_PID" 2>/dev/null || return 1
    awk -v a="$(now)" -v b="$t0" -v t="$DRAIN_MAX" 'BEGIN{exit !(a-b>t)}' && return 1
    sleep 1
  done
  return 0
}

# ok | dead | oom | unresponsive (unresponsive: не ответило даже через DRAIN_MAX секунд)
health_check() {
  if [[ -z "$APP_PID" ]] || ! kill -0 "$APP_PID" 2>/dev/null; then echo dead; return; fi
  if grep -q "OutOfMemoryError" "$APP_LOG" 2>/dev/null; then echo oom; return; fi
  if ! drain_wait; then
    if grep -q "OutOfMemoryError" "$APP_LOG" 2>/dev/null; then echo oom; else echo unresponsive; fi
    return
  fi
  if grep -q "OutOfMemoryError" "$APP_LOG" 2>/dev/null; then echo oom; return; fi
  echo ok
}

# emit_row <повтор> <разобранный k6 (10 полей)> <cpu> <rss> <потоки> <gc (4 поля)> <статус>
emit_row() {
  echo "$MODE,$MS,$CALLS,$HEAP,$VNAME,$LEVEL,$1,$DURATION,$2,$3,$4,$5,$6,$STARTUP_S,$IDLE_RSS_MB,$FIRST_REQ_MS,$7" >> "$CSV"
}

# run_one <повтор>; результат: строка в CSV, код возврата 0 если приложение здорово
run_one() {
  local rep="$1"
  local base="$RAW/$LABEL-r$rep"
  local samples="$base.samples"
  : > "$samples"
  local gc0=0 gc1=0
  [[ -f "$GC_LOG" ]] && gc0="$(wc -l < "$GC_LOG")"

  sample_loop "$APP_PID" "$samples" &
  SAMPLER_PID=$!
  local c0 t0 c1 t1
  c0="$(cpu_ticks "$APP_PID")"; t0="$(now)"

  k6_run "$LEVEL" "$DURATION" "$base.json" "$base.k6.log" || log "k6 завершился с ненулевым кодом (см. $base.k6.log)"

  t1="$(now)"
  if kill -0 "$APP_PID" 2>/dev/null; then c1="$(cpu_ticks "$APP_PID")"; else c1=""; fi
  kill "$SAMPLER_PID" 2>/dev/null; wait "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=""
  sleep 1
  [[ -f "$GC_LOG" ]] && gc1="$(wc -l < "$GC_LOG")"

  local parsed cpu="" rss="" thr="" gcs
  parsed="$(python3 load/parse_k6.py "$base.json" 2>>"$base.k6.log")" || parsed=",,,,,,,,,"
  if [[ "$parsed" == ",,,,,,,,," ]]; then
    log "  ВНИМАНИЕ: не удалось разобрать итог k6, смотрите $base.json и $base.k6.log"
  fi
  gcs="$(python3 load/gcstats.py "$GC_LOG" "$gc0" "$gc1" 2>>"$base.k6.log")" || gcs=",,,"
  if [[ -n "$c1" ]]; then
    cpu="$(awk -v d="$((c1 - c0))" -v tck="$CLK_TCK" -v e="$(diff_s "$t1" "$t0")" 'BEGIN{printf "%.2f", d/tck/e}')"
  fi
  if [[ -s "$samples" ]]; then
    rss="$(awk 'BEGIN{m=0} {if($1>m)m=$1} END{printf "%.0f", m/1024}' "$samples")"
    thr="$(awk 'BEGIN{m=0} {if($2>m)m=$2} END{print m}' "$samples")"
  fi
  ST="$(health_check)"
  emit_row "$rep" "$parsed" "$cpu" "$rss" "$thr" "$gcs" "$ST"
  log "  повтор $rep [$ST]: $(echo "$parsed" | awk -F, '{printf "rps=%s p95=%s мс ошибок=%s%%", $2, $7, $3}'), CPU=${cpu:-?} ядер, RSS=${rss:-?} МБ, потоков ОС=${thr:-?}, GC: $(echo "$gcs" | awk -F, '{printf "%s пауз, %s мс", $1, $2}')"
  [[ "$ST" == "ok" ]]
}

# ---------- основной цикл ----------
log "результаты: $OUT   (JDK: $("$JAVA_BIN" -version 2>&1 | head -1))"
log "запускаю backend"
# shellcheck disable=SC2086
${PIN_BACKEND[@]+"${PIN_BACKEND[@]}"} "$JAVA_BIN" $BACKEND_JAVA_OPTS -jar backend/target/backend-1.0.0.jar > "$RAW/backend-$CASE.log" 2>&1 &
BACKEND_PID=$!
wait_http "http://127.0.0.1:$BACKEND_PORT/slow?ms=1" 90 "$BACKEND_PID" || die "backend не поднялся, см. $RAW/backend-$CASE.log"

for LEVEL in $LEVELS; do
  for variant in $VARIANTS; do
    VNAME="${variant//:/-}"
    LABEL="$CASE-$VNAME-l$LEVEL"
    log "=== [$MODE ms=$MS calls=$CALLS heap=$HEAP] $VNAME, нагрузка $LEVEL ==="
    STARTUP_S=""; FIRST_REQ_MS=""; IDLE_RSS_MB=""
    if ! start_app "$variant" "$LABEL"; then
      emit_row 0 ",,,,,,,,," "" "" "" ",,," "no_start"
      continue
    fi
    log "  старт ${STARTUP_S} с, первый запрос +${FIRST_REQ_MS} мс, RSS после старта ${IDLE_RSS_MB} МБ; прогрев ${WARMUP} с"
    k6_run "$LEVEL" "$WARMUP" "" "$RAW/$LABEL.warmup.log" || true
    ST="$(health_check)"
    if [[ "$ST" != "ok" ]]; then
      log "  приложение не пережило прогрев [$ST], пропускаю замеры"
      emit_row 0 ",,,,,,,,," "" "" "" ",,," "$ST"
      stop_app
      continue
    fi
    for rep in $(seq 1 "$REPEATS"); do
      sleep "$COOLDOWN"
      run_one "$rep" || { log "  приложение в состоянии '$ST', дальнейшие повторы бессмысленны"; break; }
    done
    stop_app
  done
done

log "считаю медианы"
python3 load/aggregate.py "$CSV" "$OUT/summary.csv"
log "готово: $CSV, $OUT/summary.csv, $OUT/env.txt"
