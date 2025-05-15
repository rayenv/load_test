#!/bin/bash

# 📌 ШАПКА СКРИПТА
# ==================
# Требуемые утилиты: bash curl stress-ng kubectl bc
# Переменные окружения:
#   URL_1        — первый тестируемый адрес (по умолчанию: http://10.213.22.39:81/)
#   URL_2        — второй тестируемый адрес (по умолчанию: http://10.213.22.40/)
#   TARGET_POD   — имя пода для тестирования политик безопасности
#   COMPONENT    — контейнер в поде (если нужно указать конкретный)
#   NAMESPACE    — namespace, где находится под
#   K8S_INTERVAL — интервал между kubectl exec командами (по умолчанию: 30 секунд)
#   SKIP_K8S     — если задан, отключает выполнение kubectl exec команд
# Опции:
#   --time       — время тестирования (например: 1m, 5h, 60)
#   --rps        — целевое число запросов в секунду
#   --log        — путь к файлу лога (по умолчанию: /var/log/curl_monitor_*.log)
#   --quiet      — тихий режим (без вывода в терминал)
# Пример:
#   export URL_1="http://my-service-a/api/" URL_2="http://my-service-b/api/"
#   export TARGET_POD="nginx-pod" COMPONENT="nginx" NAMESPACE="default"
#   ./check.sh --time 1m --rps 100 --quiet
# ==================

# === Проверка наличия необходимых утилит ===
for cmd in curl stress-ng kubectl bc; do
    command -v $cmd >/dev/null 2>&1 || {
        echo "Ошибка: '$cmd' не установлен. Установите зависимости перед запуском."
        exit 1
    }
done

# === Переменные PID ===
curl_pid=0
stress_pid=0
k8s_pid=0

# === Флаг для защиты от повторного вызова cleanup() ===
CLEANUP_RUNNING=0

# === Стартовое время ===
START_TIME=$(date +%s)
START_DATETIME=$(date '+%Y-%m-%d %H:%M:%S')
echo "[START] $START_DATETIME"

# === Справка по использованию ===
usage() {
    if ! $QUIET; then
        echo "Использование: $0 [ОПЦИИ]"
        echo ""
        echo "Опции:"
        echo "  --help               Показать это сообщение"
        echo "  --time <TIME>        Время тестирования (например: 1m, 5h)"
        echo "  --rps <N>            Целевое число запросов в секунду"
        echo "  --log <PATH>         Путь к файлу лога"
        echo "  --no-k8s             Отключить kubectl exec команды"
        echo "  --quiet, -q          Тихий режим"
        echo ""
    fi
    exit 1
}

# === Парсинг аргументов командной строки ===
SKIP_K8S=false
QUIET=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help) usage ;;
        --time) MONITOR_TIME="$2"; shift ;;
        --rps) RPS="$2"; shift ;;
        --log) LOGFILE="$2"; shift ;;
        --no-k8s) SKIP_K8S=true ;;
        --quiet | -q) QUIET=true ;;
        *) echo "Неизвестный параметр: $1"; usage ;;
    esac
    shift
done

# === Настройки по умолчанию или из env ===
MONITOR_TIME="${MONITOR_TIME:-1m}"
RPS="${RPS:-50}" # По умолчанию 50 RPS
K8S_INTERVAL="${K8S_INTERVAL:-30}"

# === Параметризованные URL для curl ===
URL_1="${URL_1:-http://10.213.22.39:81/}"
URL_2="${URL_2:-http://10.213.22.40/}"

# === Генерация имени лог-файла ===
TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
DEFAULT_LOGFILE="/var/log/curl_monitor_${TIMESTAMP}.log"
LOGFILE="${LOGFILE:-$DEFAULT_LOGFILE}"

# === Переводим MONITOR_TIME в секунды ===
to_seconds() {
    local time_str="$1"
    if [[ "$time_str" =~ ^([0-9]+)h$ ]]; then
        echo "$((BASH_REMATCH[1] * 3600))"
    elif [[ "$time_str" =~ ^([0-9]+)m$ ]]; then
        echo "$((BASH_REMATCH[1] * 60))"
    elif [[ "$time_str" =~ ^[0-9]+$ ]]; then
        echo "$time_str"
    else
        echo "0"
    fi
}

MONITOR_DURATION_SEC=$(to_seconds "$MONITOR_TIME")
END_TIME_UNIX=$(( $(date +%s) + MONITOR_DURATION_SEC ))

# === Рассчитываем parallel и interval из RPS ===
MAX_PARALLEL=$(( RPS / 10 ))
MAX_PARALLEL=${MAX_PARALLEL:-1}
INTERVAL="0.1"

# === Счётчики для статистики ===
total_1=0
success_1=0
fail_1=0

total_2=0
success_2=0
fail_2=0

read_success=0
read_fail=0
write_success=0
write_fail=0
unauth_ping_success=0
unauth_ping_fail=0

# === Функция логгирования ===
log() {
    if ! $QUIET; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# === Выполнение одного curl-запроса с обновлением статистики ===
do_request() {
    local url="$1"
    local host="$2"

    output=$(curl -s -I --max-time 5 "$url" 2>&1)

    echo "$output" >> "$LOGFILE"

    if [[ -z "$output" ]]; then
        http_code="TIMEOUT"
    else
        status_line=$(echo "$output" | grep -v '^$' | head -n1)
        if [[ "$status_line" =~ HTTP\/[0-9.]+\ +([0-9]{3}) ]]; then
            http_code="${BASH_REMATCH[1]}"
        else
            http_code="NO_RESPONSE"
        fi
    fi

    echo "[RESULT] host=$host code=$http_code" >> "$LOGFILE"
}

# === Мониторинг HTTP-запросов ===
monitor() {
    local END_TIME="$1"
    while [ $(date +%s) -lt $END_TIME ]; do
        for i in $(seq 1 $MAX_PARALLEL); do
            do_request "$URL_1" "1" &
            do_request "$URL_2" "2" &
        done

        wait
        sleep "$INTERVAL"
    done
}

# === Выполнение тестовых команд в поде ===
run_kubectl_commands() {
    local COUNT=0

    while [ $(date +%s) -lt $END_TIME_UNIX ]; do
        ((COUNT++))
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === kubectl exec итерация #$COUNT ===" >> "$LOGFILE"

        # --- Команда 1: Чтение файла (санкционированная) ---
        cmd="cat /etc/os-release"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] > [READ] $cmd" >> "$LOGFILE"
        timeout 10 kubectl exec "$TARGET_POD" -n "$NAMESPACE" -c "$COMPONENT" -- sh -c "$cmd" >> "$LOGFILE" 2>&1
        exit_code=$?
        echo "[K8S_RESULT] type=read exit_code=$exit_code" >> "$LOGFILE"

        # --- Команда 2: DNS-запрос (нЕсанкционированный) ---
        cmd="nc -zv 8.8.8.8 53"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] > [UNAUTH] $cmd" >> "$LOGFILE"
        timeout 10 kubectl exec "$TARGET_POD" -n "$NAMESPACE" -c "$COMPONENT" -- sh -c "$cmd" >> "$LOGFILE" 2>&1
        exit_code=$?
        echo "[K8S_RESULT] type=unauth-dns exit_code=$exit_code" >> "$LOGFILE"

        # --- Команда 3: Запись в файл (санкционированная) ---
        cmd="echo 'test' >> /tmp/report.txt"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] > [WRITE] $cmd" >> "$LOGFILE"
        timeout 10 kubectl exec "$TARGET_POD" -n "$NAMESPACE" -c "$COMPONENT" -- sh -c "$cmd" >> "$LOGFILE" 2>&1
        exit_code=$?
        echo "[K8S_RESULT] type=write exit_code=$exit_code" >> "$LOGFILE"

        sleep "$K8S_INTERVAL"
    done
}

# === Очистка и вывод статистики при завершении ===
cleanup() {
    if (( CLEANUP_RUNNING == 1 )); then
        return 0
    fi
    CLEANUP_RUNNING=1

    log "Остановка фоновых процессов..."
    kill $curl_pid $stress_pid $k8s_pid 2>/dev/null

    wait $curl_pid 2>/dev/null
    wait $stress_pid 2>/dev/null
    wait $k8s_pid 2>/dev/null

    END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    RUNTIME=$(( $(date +%s) - START_TIME ))

    echo "[END] $END_TIME" >> "$LOGFILE"
    echo "[RUNTIME] $RUNTIME секунд" >> "$LOGFILE"
    echo "[START] $START_DATETIME" >> "$LOGFILE"
    echo "[END] $END_TIME" >> "$LOGFILE"
    echo "[RUNTIME] $RUNTIME секунд" >> "$LOGFILE"

    # === Сбор статистики из логов ===
    total_1=$(grep -c "\[RESULT\] host=1" "$LOGFILE" 2>/dev/null || echo 0)
    success_1=$(grep -E "\[RESULT\] host=1 code=2" "$LOGFILE" | wc -l 2>/dev/null || echo 0)
    total_1=${total_1:-0}
    success_1=${success_1:-0}
    fail_1=$((total_1 - success_1))

    total_2=$(grep -c "\[RESULT\] host=2" "$LOGFILE" 2>/dev/null || echo 0)
    success_2=$(grep -E "\[RESULT\] host=2 code=2" "$LOGFILE" | wc -l 2>/dev/null || echo 0)
    total_2=${total_2:-0}
    success_2=${success_2:-0}
    fail_2=$((total_2 - success_2))

    # === Подсчёт CPS (если TARGET_POD был задан) ===
    k8s_iterations=$(grep -c "=== kubectl exec итерация #" "$LOGFILE" 2>/dev/null || echo 0)
    k8s_total_commands=$((k8s_iterations * 3))

    read_success=$(grep -c "\[K8S_RESULT\] type=read exit_code=0" "$LOGFILE" 2>/dev/null || echo 0)
    read_fail=$(grep -c "\[K8S_RESULT\] type=read exit_code=[1-9]" "$LOGFILE" 2>/dev/null || echo 0)

    write_success=$(grep -c "\[K8S_RESULT\] type=write exit_code=0" "$LOGFILE" 2>/dev/null || echo 0)
    write_fail=$(grep -c "\[K8S_RESULT\] type=write exit_code=[1-9]" "$LOGFILE" 2>/dev/null || echo 0)

    unauth_ping_success=$(grep -c "\[K8S_RESULT\] type=unauth-dns exit_code=0" "$LOGFILE" 2>/dev/null || echo 0)
    unauth_ping_fail=$(grep -c "\[K8S_RESULT\] type=unauth-dns exit_code=[1-9]" "$LOGFILE" 2>/dev/null || echo 0)

    # === Расчёт RPS и CPS с защитой от пустых значений ===
    safe_runtime=${RUNTIME:-1}  # чтобы не делить на 0

    avg_rps_1=$(echo "scale=2; ${total_1:-0} / $safe_runtime" | bc 2>/dev/null || echo 0)
    avg_rps_2=$(echo "scale=2; ${total_2:-0} / $safe_runtime" | bc 2>/dev/null || echo 0)
    avg_cps=$(echo "scale=2; ${k8s_total_commands:-0} / $safe_runtime" | bc 2>/dev/null || echo 0)

    avg_rps_1=${avg_rps_1:-0}
    avg_rps_2=${avg_rps_2:-0}
    avg_cps=${avg_cps:-0}

    # === Вывод статистики в лог ===
    echo "" >> "$LOGFILE"
    echo "=== СТАТИСТИКА ===" >> "$LOGFILE"
    echo "Всего HTTP-запросов:" >> "$LOGFILE"
    echo "  $URL_1 — $total_1 (avg: $avg_rps_1 req/sec)" >> "$LOGFILE"
    echo "  $URL_2 — $total_2 (avg: $avg_rps_2 req/sec)" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    echo "Успешные ответы (2xx):" >> "$LOGFILE"
    echo "  $URL_1 — $success_1" >> "$LOGFILE"
    echo "  $URL_2 — $success_2" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    echo "Неуспешные ответы (не 2xx):" >> "$LOGFILE"
    echo "  $URL_1 — $fail_1" >> "$LOGFILE"
    echo "  $URL_2 — $fail_2" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    echo "Команды в поде:" >> "$LOGFILE"
    echo "  Итераций выполнено: $k8s_iterations" >> "$LOGFILE"
    echo "  Всего команд: $k8s_total_commands (avg: $avg_cps cmd/sec)" >> "$LOGFILE"
    echo "  Чтение из файла (sanctioned): $read_success OK, $read_fail FAIL" >> "$LOGFILE"
    echo "  Запись в файл (sanctioned): $write_success OK, $write_fail FAIL" >> "$LOGFILE"
    echo "  DNS-запрос (unauthorized): $unauth_ping_success OK, $unauth_ping_fail FAIL" >> "$LOGFILE"
    echo "==================" >> "$LOGFILE"
    echo "[STAT] RPS ($URL_1): $avg_rps_1 req/sec" >> "$LOGFILE"
    echo "[STAT] RPS ($URL_2): $avg_rps_2 req/sec" >> "$LOGFILE"
    echo "[STAT] CPS (kubectl exec): $avg_cps cmd/sec" >> "$LOGFILE"

    log "Мониторинг и нагрузка завершены."
    exit 0
}

trap cleanup EXIT

# === Запуск stress-ng ===
STRESS_CMD="stress-ng --cpu 10 --cpu-method matrixprod --vm 4 --vm-bytes 9G --vm-keep --metrics --timeout"
log "Запуск нагрузки: $STRESS_CMD $MONITOR_TIME"
$STRESS_CMD "$MONITOR_TIME" &
stress_pid=$!

# === Запуск мониторинга HTTP-запросов ===
log "Запуск мониторинга HTTP-запросов..."
monitor "$END_TIME_UNIX" &
curl_pid=$!

# === Запуск kubectl exec команд (если разрешён TARGET_POD) ===
if ! $SKIP_K8S && [[ -n "${TARGET_POD}" ]]; then
    log "Запуск проверочных kubectl exec команд..."
    run_kubectl_commands &
    k8s_pid=$!
else
    log "Выполнение kubectl exec отключено или TARGET_POD не задан."
    k8s_pid=0
fi

log "[LAUNCH] Все процессы запущены."

# === Ожидание завершения ===
wait_time=0
while [ $(date +%s) -lt $END_TIME_UNIX ]; do
    sleep 1
    ((wait_time += 1))
done

kill $curl_pid $stress_pid $k8s_pid 2>/dev/null
wait $curl_pid 2>/dev/null
wait $stress_pid 2>/dev/null
wait $k8s_pid 2>/dev/null

# === Явный вызов cleanup() ===
cleanup