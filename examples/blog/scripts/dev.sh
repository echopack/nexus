#!/usr/bin/env bash
# Runs the blog locally on throwaway services: builds it for debugging, starts MySQL (on a
# tmpfs, so nothing reaches the disk) and Mailpit in Docker, migrates, sets the
# editor's password and serves until Ctrl-C. On the way out the server is
# stopped and both containers are removed with their volumes, so the next run
# starts from an empty database.
#
#   scripts/dev.sh                       # http://127.0.0.1:3246, mails at http://127.0.0.1:8025
#   PORT=9000 MAIL_PORT=9025 scripts/dev.sh
#   PASSWORD=... scripts/dev.sh          # editor@example.com's password, dev-password-1 by default
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
port="${PORT:-3246}"
mail_http="${MAIL_PORT:-8025}"
password="${PASSWORD:-dev-password-1}"
echoc="${ECHOC:-echoc}"
cd "${here}"
# a dev build: asserts and runtime checks kept, no optimizer, DWARF to step through
"${echoc}" build --debug --optimize none -g >/dev/null || { echo "build failed"; exit 1; }

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
db_port=$(free_port)
mail_smtp=$(free_port)
name="nexus-blog-dev-$$"
mail_name="nexus-blog-dev-mail-$$"
pid=""

cleanup() {
    trap - EXIT INT TERM
    echo
    if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
        echo "stopping the blog"
        kill -TERM "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
    fi
    echo "removing ${name} and ${mail_name}"
    docker rm -f -v "${name}" "${mail_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker run -d --rm --name "${name}" --tmpfs /var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=blog -e MYSQL_USER=app -e MYSQL_PASSWORD=secret \
    -p "127.0.0.1:${db_port}:3306" "${IMAGE:-mysql:8.0}" --skip-log-bin >/dev/null \
    || { echo "docker run (mysql) failed"; exit 1; }
docker run -d --rm --name "${mail_name}" \
    -p "127.0.0.1:${mail_smtp}:1025" -p "127.0.0.1:${mail_http}:8025" "${MAIL_IMAGE:-axllent/mailpit}" >/dev/null \
    || { echo "docker run (mailpit) failed"; exit 1; }

export NEXUS_DATABASE_URL="mysql://app:secret@127.0.0.1:${db_port}/blog?fetchServerKey=true"
export NEXUS_AUTH_KEY="${NEXUS_AUTH_KEY:-dev-auth-key-of-at-least-32-characters}"
export NEXUS_MAIL_URL="smtp://127.0.0.1:${mail_smtp}" NEXUS_MAIL_TLS=none NEXUS_MAIL_FROM=hello@blog.test NEXUS_MAIL_FROM_NAME="A nexus blog"
# the debug console at /__nexus/, opened by the editor's login (the blog's admin)
export NEXUS_DEBUG_ENABLED="${NEXUS_DEBUG_ENABLED:-true}"

# the server takes a while to take connections; migrate until it does
echo "waiting for mysql"
migrated=""
for _ in $(seq 1 90); do
    ./ecobuild/blog migrate >/dev/null 2>&1 && { migrated=1; break; }
    sleep 1
done
[ -n "${migrated}" ] || { echo "migrate failed:"; ./ecobuild/blog migrate; exit 1; }
./ecobuild/blog user:password --email editor@example.com --password "${password}" || exit 1

echo
echo "blog    http://127.0.0.1:${port}"
echo "debug   http://127.0.0.1:${port}/__nexus/"
echo "mail    http://127.0.0.1:${mail_http}"
echo "editor  editor@example.com / ${password}"
echo "Ctrl-C stops it and removes everything"
echo

# in the background so the trap runs as soon as Ctrl-C arrives
./ecobuild/blog serve --listen "127.0.0.1:${port}" &
pid=$!
wait "${pid}"
