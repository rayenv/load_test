# 🛠 CUrl Stress Tester (Python версия)
Инструмент для тестирования доступности сервисов и политик безопасности в Kubernetes через веб-интерфейс.

## 💡 Функционал
- Параллельные HTTP-запросы к двум URL
- Нагрузка CPU/память через stress-ng
- Выполнение команд в Kubernetes:
    - Чтение из файла
    - ICMP-пинг
    - Запись в файл
- Вывод RPS, CPS
- Поддержка запуска через Docker

## 📦 Требования
Python 3.9+
Docker + Docker Compose
Kubeconfig (на хосте)
Доступ к API-серверу

## 🚀 Как развернуть
1. Клонируй репозиторий:
```bash
git clone https://github.com/rayenv/load_test.git 
cd load_test\python
```
2. Установи зависимости:
```bash
pip install -r requirements.txt
```
3. Собери и запусти:
```bash
docker-compose up --build
```
4. Открой браузер:
http://localhost:5000

## 🧪 Как использовать
1. Введи URL_1, URL_2
2. Укажи RPS (например: 100)
3. Укажи TARGET_POD и NAMESPACE
4. Нажми «Запустить»

### 📁 Логи
Сохраняются в:
```./logs/curl_monitor_latest.log```

### 📈 Отчёт
После завершения теста выводится:
|метрика|значение|
|-|-|
|RPS| req/sec|
|CPS|cmd/sec|
|Успешные|шт., %|
|Неуспешные|шт., %|