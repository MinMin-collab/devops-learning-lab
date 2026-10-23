#!/usr/bin/env bash
set -euo pipefail

# Image mặc định; có thể truyền tên image khác qua đối số đầu tiên.
IMAGE="${1:-devops-health-lab:smoke}"

# Cho phép đổi đường dẫn khi thực hành tình huống thất bại.
HEALTH_PATH="${HEALTH_PATH:-/health}"

# Mỗi lần chạy dùng tên container riêng.
NAME="health-smoke-$$-$RANDOM"
URL="http://127.0.0.1:8002${HEALTH_PATH}"
BODY_FILE="$(mktemp)"

cleanup() {
  result=$?
  trap - EXIT

  if (( result != 0 )); then
    echo "FAIL: Smoke Test kết thúc với mã $result"
    echo "--- Container logs ---"
    docker logs "$NAME" || true
  fi

  docker rm -f "$NAME" >/dev/null 2>&1 || true
  rm -f "$BODY_FILE"

  exit "$result"
}

trap cleanup EXIT

echo "Kiểm tra image: $IMAGE"

docker run -d \
  --pull=never \
  --name "$NAME" \
  -p 127.0.0.1:8002:8000 \
  "$IMAGE"

for attempt in {1..10}; do
  echo "Kiểm tra lần $attempt/10: $URL"

  running="$(docker inspect -f '{{.State.Running}}' "$NAME")"

  if [[ "$running" != "true" ]]; then
    echo "Container đã dừng."
    exit 1
  fi

  if code="$(curl -fsS \
    --connect-timeout 1 \
    --max-time 2 \
    --output "$BODY_FILE" \
    --write-out '%{http_code}' \
    "$URL")"; then

    if [[ "$code" == "200" ]] && python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    body = json.load(f)

sys.exit(0 if body == {"status": "ok"} else 1)
' "$BODY_FILE"; then
      echo "PASS: HTTP 200 và JSON đúng."
      exit 0
    fi
  fi

  sleep 1
done

echo "Không nhận được phản hồi đúng sau 10 lần kiểm tra."
exit 1
