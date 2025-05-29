import os
import time
import threading
import subprocess
import logging
from flask import Flask, render_template, request, jsonify
from stress import run_stress
from k8s import run_k8s_commands

app = Flask(__name__)
LOGFILE = "logs/curl_monitor_latest.log"

@app.route("/")
def index():
    return render_template("index.html")

@app.route("/start", methods=["POST"])
def start_test():
    data = request.json
    url1 = data.get("url1")
    url2 = data.get("url2")
    rps = int(data.get("rps", 50))
    duration = data.get("duration", "1m")
    pod = data.get("pod")
    namespace = data.get("namespace")
    component = data.get("component")
    skip_k8s = not bool(pod and namespace)

    # Переводим время в секунды
    if duration.endswith("m"):
        runtime = int(duration[:-1]) * 60
    elif duration.endswith("h"):
        runtime = int(duration[:-1]) * 3600
    else:
        runtime = int(duration)

    interval = max(0.01, 1 / (rps // 10 or 1))

    # Запись стартового времени
    start_time = time.time()
    with open(LOGFILE, "w") as f:
        f.write(f"[START] {time.strftime('%Y-%m-%d %H:%M:%S')}\n")

    def run_curl(url, host):
        while getattr(threading.currentThread(), "do_run", True):
            try:
                response = subprocess.run(["curl", "-I", "--max-time", "5", url], capture_output=True, text=True)
                code = "TIMEOUT"
                for line in response.stdout.splitlines():
                    if line.startswith("HTTP/"):
                        code = line.split()[1]
                with open(LOGFILE, "a") as f:
                    f.write(f"[RESULT] host={host} code={code}\n")
            except Exception as e:
                with open(LOGFILE, "a") as f:
                    f.write(f"[ERROR] curl failed: {str(e)}\n")
            time.sleep(interval)

    # Потоки для запросов
    threads = []
    for _ in range(rps // 10 + 1):
        t1 = threading.Thread(target=run_curl, args=(url1, 1))
        t2 = threading.Thread(target=run_curl, args=(url2, 2))
        t1.start()
        t2.start()
        threads.extend([t1, t2])

    stress_thread = threading.Thread(target=run_stress)
    stress_thread.start()

    if not skip_k8s:
        k8s_thread = threading.Thread(target=run_k8s_commands, args=(pod, namespace, component))
        k8s_thread.start()
    else:
        logging.info("Kubernetes тестирование отключено.")

    time.sleep(runtime)

    # Остановка потоков
    for t in threads:
        setattr(t, 'do_run', False)
    stress_thread.do_run = False
    if not skip_k8s:
        k8s_thread.do_run = False

    # Ждём завершения
    for t in threads:
        t.join(timeout=1)
    stress_thread.join(timeout=1)
    if not skip_k8s:
        k8s_thread.join(timeout=1)

    # Логируем окончание
    end_time = time.strftime("%Y-%m-%d %H:%M:%S")
    runtime_sec = int(time.time() - start_time)
    with open(LOGFILE, "a") as f:
        f.write(f"[END] {end_time}\n")
        f.write(f"[RUNTIME] {runtime_sec} секунд\n")

    return jsonify({"status": "Тест завершён", "log_file": LOGFILE})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)