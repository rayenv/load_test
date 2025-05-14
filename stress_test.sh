#!/bin/bash

# === Переменные для S3 ===
UPLOAD_TO_S3=false
S3_BUCKET=""
NO_UPLOAD=false

# === Парсинг аргументов командной строки ===
SKIP_K8S=false
QUIET=false

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help) usage ;;
        --time) MONITOR_TIME="$2"; shift ;;
        --parallel) MAX_PARALLEL="$2"; shift ;;
        --interval) INTERVAL="$2"; shift ;;
        --log) LOGFILE="$2"; shift ;;
        --no-k8s) SKIP_K8S=true ;;
        --quiet | -q) QUIET=true ;;
        --upload-s3) S3_BUCKET="$2"; UPLOAD_TO_S3=true; shift ;;
        --no-upload) NO_UPLOAD=true ;;
        *) echo "Неизвестный параметр: $1"; usage ;;
    esac
    shift
done

# === Функция перевода времени в секунды ===
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

# === Настройки по умолчанию ===
MONITOR_TIME="${MONITOR_TIME:-8h}"
MAX_PARALLEL="${MAX_PARALLEL:-50}"
INTERVAL="${INTERVAL:-0.01}"

TIMESTAMP=$(date "+%Y%m%d_%H%M%S")
DEFAULT_LOGFILE="/tmp/curl_monitor_${TIMESTAMP}.log"
LOGFILE="${LOGFILE:-$DEFAULT_LOGFILE}"

# === Логика логгирования ===
log() {
    if ! $QUIET; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    fi
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGFILE"
}

# === Выполнение запросов ===
do_request() {
    local url="$1"
    local host="$2"

    output=$(curl -s -iv "$url")
    echo "$output" >> "$LOGFILE"

    status=$(echo "$output" | grep -A1 'HTTP/' | tail -n1 | awk '{print $2}')

    if [[ "$host" == "39" ]]; then
        ((total_39++))
        if [[ "$status" =~ ^2 ]]; then ((success_39++)); else ((fail_39++)); fi
    elif [[ "$host" == "40" ]]; then
        ((total_40++))
        if [[ "$status" =~ ^2 ]]; then ((success_40++)); else ((fail_40++)); fi
    fi
}

# === Запуск kubectl exec команд ===
run_kubectl_commands() {
    if [[ -z "$POD_NAME" ]]; then
        log "[KUBECTL] Имя пода не задано. Пропуск выполнения kubectl exec."
        return 0
    fi

    local ns="$NAMESPACE"
    if [[ -z "$ns" ]]; then
        log "[KUBECTL] Namespace не задан"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [KUBECTL] Namespace не задан" >> "$LOGFILE"
        return 1
    fi

    while true; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] === kubectl exec в под: $POD_NAME (namespace: $ns) ===" >> "$LOGFILE"

        IFS=';' read -r -a commands <<< "$K8S_COMMAND"
        for cmd in "${commands[@]}"; do
            trimmed_cmd=$(echo "$cmd" | xargs)
            if [[ -n "$trimmed_cmd" ]]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] > $trimmed_cmd" >> "$LOGFILE"
                kubectl exec "$POD_NAME" -n "$ns" -- sh -c "$trimmed_cmd" >> "$LOGFILE" 2>&1
            fi
        done

        sleep "$K8S_INTERVAL"
    done
}

# === Завершение работы и статистика ===
cleanup() {
    log "Остановка процессов..."
    kill $curl_pid $stress_pid $k8s_pid 2>/dev/null
    wait $curl_pid $stress_pid $k8s_pid 2>/dev/null

    echo "" >> "$LOGFILE"
    echo "=== СТАТИСТИКА ===" >> "$LOGFILE"
    echo "Всего запросов:" >> "$LOGFILE"
    echo "  http://10.213.22.39:81 — $total_39" >> "$LOGFILE"
    echo "  http://10.213.22.40     — $total_40" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    echo "Успешные ответы (2xx):" >> "$LOGFILE"
    echo "  http://10.213.22.39:81 — $success_39" >> "$LOGFILE"
    echo "  http://10.213.22.40     — $success_40" >> "$LOGFILE"
    echo "" >> "$LOGFILE"
    echo "Неуспешные ответы (не 2xx):" >> "$LOGFILE"
    echo "  http://10.213.22.39:81 — $fail_39" >> "$LOGFILE"
    echo "  http://10.213.22.40     — $fail_40" >> "$LOGFILE"
    echo "==================" >> "$LOGFILE"
    log "Мониторинг и нагрузка завершены."

    # Загрузка в S3
    if $UPLOAD_TO_S3 && ! $NO_UPLOAD; then
        if command -v aws &> /dev/null; then
            log "Загрузка лога в S3: $S3_BUCKET"
            aws s3 cp "$LOGFILE" "$S3_BUCKET/" >> "$LOGFILE" 2>&1
            if [[ $? -eq 0 ]]; then
                log "Лог успешно загружен в S3"
            else
                log "Ошибка при загрузке лога в S3"
            fi
        else
            log "AWS CLI не установлен. Пропуск загрузки в S3."
        fi
    fi

    exit 0
}

# === Установка trap ===
trap cleanup SIGINT SIGTERM EXIT

# === Настройки kubectl exec ===
POD_NAME=""             # имя пода (если пустое — kubectl exec НЕ выполняется)
NAMESPACE="default"     # namespace
K8S_COMMAND="echo 'Hello from pod'; uptime; df -h"  # команда или список команд через ;
K8S_INTERVAL=30         # интервал между вызовами команд

# === Запуск stress-ng ===
STRESS_CMD="stress-ng --cpu 10 --cpu-method matrixprod --vm 4 --vm-bytes 9G --vm-keep --metrics --timeout"
log "Запуск нагрузки: $STRESS_CMD $MONITOR_TIME"
$STRESS_CMD "$MONITOR_TIME" &
stress_pid=$!

# === Запуск мониторинга HTTP-запросов ===
log "Запуск мониторинга HTTP-запросов..."

monitor() {
    local END_TIME="$1"
    while [ $(date +%s) -lt $END_TIME ]; do
        for i in $(seq 1 $MAX_PARALLEL); do
            do_request "http://10.213.22.39:81/" "39" &
            do_request "http://10.213.22.40/" "40" &
        done
        wait
        sleep "$INTERVAL"
    done
}

monitor "$END_TIME_UNIX" &
curl_pid=$!

# === Запуск kubectl команд (если разрешено и указан POD_NAME) ===
if ! $SKIP_K8S && [[ -n "$POD_NAME" ]]; then
    log "Запуск kubectl exec команд..."
    run_kubectl_commands &
    k8s_pid=$!
else
    log "Выполнение kubectl команд отключено или POD_NAME не задан."
    k8s_pid=0
fi

log "Все процессы запущены."

# === Ожидание завершения ===
wait $curl_pid
wait $stress_pid
wait $k8s_pid