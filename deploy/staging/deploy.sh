#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Prevent two copies of this script from deploying at the same time.
exec 9>.deploy.lock
flock -n 9 || {
    echo "Another deployment is running."
    exit 2
}

NEW_IMAGE="${1:-}"
EXPECTED_VERSION="${2:-}"
IMAGE_PATTERN='^minmin203/devops-health-lab@sha256:[0-9a-f]{64}$'

if [[ ! "$NEW_IMAGE" =~ $IMAGE_PATTERN ]]; then
    echo "Usage: bash deploy.sh IMAGE_WITH_DIGEST [EXPECTED_VERSION]"
    exit 2
fi

[[ -f .env && -f compose.yml && -f check_version.py ]] || {
    echo "Missing .env, compose.yml or check_version.py."
    exit 2
}

OLD_IMAGE=$(sed -n 's/^APP_IMAGE=//p' .env)

if [[ ! "$OLD_IMAGE" =~ $IMAGE_PATTERN ]]; then
    echo ".env must contain exactly one APP_IMAGE line using a digest."
    exit 2
fi

sudo -v

dc() {
    local env_file="$1"
    shift
    sudo env -u APP_IMAGE docker compose \
        -f compose.yml --env-file "$env_file" "$@"
}

check_http() {
    python3 - <<'PY'
import json
import urllib.request

with urllib.request.urlopen(
    "http://127.0.0.1:8000/health", timeout=5
) as response:
    status = response.status
    body = json.load(response)

if status != 200 or body.get("status") != "ok":
    raise SystemExit("Health endpoint did not return the expected response")
PY
}
check_version(){ 
    if [[ -z "$EXPECTED_VERSION" ]]; then 
       echo "Version check skipped: no expected version supplied."
       return 0 
    fi 

    python3  ./check_version.py "$EXPECTED_VERSION"
} 

dc .env config -q

CURRENT_ID=$(dc .env ps -q app)
[[ -n "$CURRENT_ID" ]] || {
    echo "The current app is not running."
    exit 2
}

CURRENT_HEALTH=$(sudo docker inspect \
    --format '{{.State.Health.Status}}' "$CURRENT_ID")

CURRENT_REF=$(sudo docker inspect \
    --format '{{.Config.Image}}' "$CURRENT_ID")

if [[ "$CURRENT_HEALTH" != "healthy" || "$CURRENT_REF" != "$OLD_IMAGE" ]]; then
    echo "Current container must be healthy and match APP_IMAGE in .env."
    exit 2
fi

check_http

CANDIDATE=$(mktemp .env.candidate.XXXXXX)
trap 'rm -f -- "$CANDIDATE"' EXIT

cp .env "$CANDIDATE"
sed -i "s|^APP_IMAGE=.*|APP_IMAGE=$NEW_IMAGE|" "$CANDIDATE"

dc "$CANDIDATE" config -q

echo "Pulling candidate image..."
if ! dc "$CANDIDATE" pull app; then
    echo "Pull failed. Current deployment was not replaced."
    exit 1
fi

cp .env .env.previous

echo "Deploying candidate image..."
if dc "$CANDIDATE" up -d --no-deps --pull never \
    --wait --wait-timeout 60 app; then
    if check_http && check_version; then
        mv -- "$CANDIDATE" .env
        echo "Deployment succeeded: $NEW_IMAGE"
        exit 0
    fi
fi

echo "Deployment failed. Collecting application logs..."
dc "$CANDIDATE" logs --tail=50 app || true

echo "Restoring previous image: $OLD_IMAGE"
if dc .env up -d --no-deps --pull never \
    --wait --wait-timeout 60 app; then
    if check_http; then
        echo "Rollback succeeded. Deployment is still reported as failed."
        exit 1
    fi
fi

echo "ERROR: rollback did not pass verification."
exit 3
