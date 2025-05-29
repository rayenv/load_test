import subprocess
import time
import logging

def run_k8s_commands(pod, namespace, component=None):
    interval = 30
    logging.info(f"Выполнение команд в поде: {pod}/{namespace}")
    while getattr(run_k8s_commands, "do_run", True):
        try:
            # Чтение файла
            cmd = ["kubectl", "exec", pod, "-n", namespace]
            if component:
                cmd += ["-c", component]
            cmd += ["--", "cat", "/etc/os-release"]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            exit_code = res.returncode
            with open("logs/curl_monitor_latest.log", "a") as f:
                f.write(f"[K8S_RESULT] type=read exit_code={exit_code}\n")
        except Exception as e:
            logging.error("Ошибка выполнения read: %s", str(e))

        try:
            # ICMP пинг
            cmd = ["kubectl", "exec", pod, "-n", namespace]
            if component:
                cmd += ["-c", component]
            cmd += ["--", "ping", "-c", "2", "8.8.8.8"]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            exit_code = res.returncode
            with open("logs/curl_monitor_latest.log", "a") as f:
                f.write(f"[K8S_RESULT] type=unauth-ping exit_code={exit_code}\n")
        except Exception as e:
            logging.error("Ошибка выполнения ping: %s", str(e))

        try:
            # Запись в файл
            cmd = ["kubectl", "exec", pod, "-n", namespace]
            if component:
                cmd += ["-c", component]
            cmd += ["--", "sh", "-c", "echo 'test' >> /tmp/report.txt"]
            res = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            exit_code = res.returncode
            with open("logs/curl_monitor_latest.log", "a") as f:
                f.write(f"[K8S_RESULT] type=write exit_code={exit_code}\n")
        except Exception as e:
            logging.error("Ошибка записи в файл: %s", str(e))

        time.sleep(interval)