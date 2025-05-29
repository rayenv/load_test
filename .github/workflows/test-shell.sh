name: Test Bash Script

on:
  push:
    branches:
      - main
  workflow_dispatch:

jobs:
  test-bash:
    runs-on: ubuntu-latest
    container:
      image: alpine:latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3

      - name: Install dependencies
        run: |
          apk add --no-cache bash stress-ng curl kubernetes-cli bc

      - name: Make script executable
        run: chmod +x ./shell/stress_test.sh

      - name: Run test with sample args
        env:
          URL_1: "http://example.com"
          URL_2: "http://example.org"
          SKIP_K8S: "true"
        run: |
          ./shell/stress_test.sh --time 1m --rps 50 --quiet

      - name: Show log output
        run: |
          cat /tmp/curl_monitor_*.log || echo "No logs found."