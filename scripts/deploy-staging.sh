#!/usr/bin/env bash
set -euo pipefail

# Xác định thư mục gốc repository từ vị trí script.
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/compose.staging.yml"

# Đối số đầu tiên là image muốn triển khai.
CANDIDATE="${1:-}"

# Cho phép đổi đường dẫn để thử tình huống thất bại.
DEPLOY_HEALTH_PATH="${DEPLOY_HEALTH_PATH:-/health}"

# Chỉ nhận image của dự án, được xác định bằng digest.
if [[ ! "$CANDIDATE" =~ ^minmin203/devops-health-lab@sha256:[0-9a-f]{64}$ ]]; then
  echo "ERROR: Can image dang minmin203/devops-health-lab@sha256:<64 ky tu hex>."
  exit 2
fi

# Kiểm tra các công cụ cần thiết.
for tool in docker python3 flock; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: Thieu $tool"
    exit 2
  }
done

# Kiểm tra file Compose.
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: Khong tim thay $COMPOSE_FILE"
  exit 2
fi

# Ngăn hai lần chạy script deploy đồng thời.
exec 9>"/tmp/devops-staging-${UID}.lock"

if ! flock -n 9; then
  echo "ERROR: Dang co mot lan deploy khac."
  exit 2
fi

# Gọi Compose với image được chỉ định.
compose_for() {
  local image="$1"
  shift

  STAGING_IMAGE="$image" docker compose \
    -p devops-staging \
    -f "$COMPOSE_FILE" \
    "$@"
}

# Kiểm tra phiên bản, trạng thái và HTTP từ host.
verify_release() {
  local image="$1"
  local path="$2"
  local cid
  local actual

  cid="$(compose_for "$image" ps -q health-api)" || return 1

  [[ -n "$cid" ]] || return 1

  actual="$(docker inspect "$cid" --format \
    '{{.Config.Image}}|{{.State.Running}}|{{.State.Health.Status}}')" || return 1

  [[ "$actual" == "$image|true|healthy" ]] || return 1

  python3 - "$path" <<'PY'
import json
import sys
from urllib.request import urlopen

url = "http://127.0.0.1:8003" + sys.argv[1]

with urlopen(url, timeout=3) as response:
    if response.status != 200 or json.load(response) != {"status": "ok"}:
        raise SystemExit("HTTP hoac JSON khong dung")
PY
}

# Kiểm tra cấu hình trước khi thay đổi dịch vụ.
compose_for "$CANDIDATE" config -q || exit 2

# Tìm container hiện tại, kể cả container đã dừng.
CURRENT_ID="$(compose_for "$CANDIDATE" ps -a -q health-api)" || exit 2

PREVIOUS=""

if [[ -n "$CURRENT_ID" ]]; then
  PREVIOUS="$(docker inspect "$CURRENT_ID" \
    --format '{{.Config.Image}}')" || exit 2

  if ! verify_release "$PREVIOUS" /health; then
    echo "ERROR: Dich vu hien tai chua healthy."
    echo "Hay xu ly dich vu hien tai truoc khi deploy."
    exit 2
  fi
fi

# Pull thất bại thì dừng, chưa thay đổi dịch vụ.
docker pull "$CANDIDATE" || exit 2

printf 'Previous: %s\n' "${PREVIOUS:-none}"
printf 'Candidate: %s\n' "$CANDIDATE"

# Triển khai và xác minh bản được yêu cầu.
if compose_for "$CANDIDATE" up -d --wait --wait-timeout 45 health-api \
  && verify_release "$CANDIDATE" "$DEPLOY_HEALTH_PATH"; then

  echo "DEPLOY_OK: $CANDIDATE"
  exit 0
fi

# Lấy log trước khi thay container bằng bản cũ.
echo "DEPLOY_FAILED: Lay log truoc khi rollback."
compose_for "$CANDIDATE" logs --tail 30 health-api || true

# Lần triển khai đầu tiên chưa có phiên bản trước.
if [[ -z "$PREVIOUS" ]]; then
  echo "NO_ROLLBACK: Chua co phien ban truoc."
  echo "Container duoc giu lai de kiem tra."
  exit 2
fi

# Khôi phục và xác minh phiên bản trước.
if compose_for "$PREVIOUS" up -d --wait --wait-timeout 45 health-api \
  && verify_release "$PREVIOUS" /health; then

  echo "ROLLBACK_OK: $PREVIOUS"

  # Bản mới vẫn triển khai thất bại dù đã phục hồi dịch vụ.
  exit 1
fi

echo "ROLLBACK_FAILED: Can kiem tra dich vu ngay."
compose_for "$PREVIOUS" logs --tail 30 health-api || true

exit 2
