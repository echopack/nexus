#!/usr/bin/env bash
# Runs this suite with the live tests on, against a throwaway MinIO in
# Docker (IMAGE picks another build); the server and its bucket go with the run.
set -euo pipefail
IMAGE=${IMAGE:-minio/minio:latest}
NAME=nexus-files-live-$$
PORT=${PORT:-$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}
cd "$(dirname "$0")/.."
docker run -d --rm --name "${NAME}" -p "127.0.0.1:${PORT}:9000" \
    -e MINIO_ROOT_USER=nexus-live -e MINIO_ROOT_PASSWORD=nexus-live-secret \
    "${IMAGE}" server /data >/dev/null
trap 'docker rm -f -v "${NAME}" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 60); do
    if docker exec "${NAME}" mc alias set live http://127.0.0.1:9000 nexus-live nexus-live-secret >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
docker exec "${NAME}" mc mb live/nexus-test >/dev/null
FILES_S3_LIVE_URL=s3://nexus-test \
NEXUS_FILES_S3_ACCESS_KEY=nexus-live \
NEXUS_FILES_S3_SECRET_KEY=nexus-live-secret \
NEXUS_FILES_S3_ENDPOINT="http://127.0.0.1:${PORT}" \
NEXUS_FILES_S3_PATH_STYLE=true \
    echoc test "$@"
