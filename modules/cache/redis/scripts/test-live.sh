#!/usr/bin/env bash
# Runs this suite with the live tests on, against a throwaway Redis in
# Docker (IMAGE=redis:6.2 picks another); the server goes with the run.
set -euo pipefail
IMAGE=${IMAGE:-redis:7}
NAME=nexus-cache-live-$$
PORT=${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
cd "$(dirname "$0")/.."
docker run -d --rm --name "${NAME}" -p "127.0.0.1:${PORT}:6379" "${IMAGE}" >/dev/null
trap 'docker rm -f -v "${NAME}" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 60); do
    if docker exec "${NAME}" redis-cli ping 2>/dev/null | grep -q PONG; then
        break
    fi
    sleep 0.5
done
CACHE_REDIS_URL="redis://127.0.0.1:${PORT}/15" echoc test "$@"
