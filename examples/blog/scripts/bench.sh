#!/usr/bin/env bash
# Measures what the blog answers per second, and how fast, with wrk: a release build against a
# throwaway MySQL on a tmpfs, served four ways so the cost of each piece shows on its own:
#
#   lean     NEXUS_LOG=warn, no debug console
#   log      the access log on (NEXUS_LOG=info)
#   console  the debug console on (NEXUS_DEBUG_ENABLED=true)
#   both     what scripts/dev.sh runs, built for release
#
# Each is hit on /health (no database) and on a signed GET /v1/posts (a session check and a
# query on ten posts), with one connection and with 64. The build goes to ecobuild/bench/, so a
# running dev.sh is not touched; the servers and the container go away on exit.
#
#   scripts/bench.sh
#   DURATION=10s scripts/bench.sh
#   ONLY="lean both" scripts/bench.sh
#   BLOG=/path/to/other/blog scripts/bench.sh   # no build, that binary
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
echoc="${ECHOC:-echoc}"
duration="${DURATION:-4s}"
only="${ONLY:-lean log console both}"
cd "${here}"

command -v wrk >/dev/null || { echo "bench.sh needs wrk on PATH (brew install wrk)"; exit 1; }
command -v docker >/dev/null || { echo "bench.sh needs docker"; exit 1; }

if [ -n "${BLOG:-}" ]; then
    # a binary built elsewhere, to compare two builds on the same machine
    blog="${BLOG}"
else
    echo "building for release"
    mkdir -p ecobuild/bench
    "${echoc}" build --release -o ecobuild/bench/blog --build-dir ecobuild/bench/build >/dev/null 2>&1 \
        || { echo "build failed"; exit 1; }
    blog="${here}/ecobuild/bench/blog"
fi

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }
db_port=$(free_port)
name="nexus-blog-bench-$$"
pids=()

cleanup() {
    trap - EXIT INT TERM
    for p in "${pids[@]+"${pids[@]}"}"; do
        kill -TERM "${p}" 2>/dev/null
        wait "${p}" 2>/dev/null
    done
    docker rm -f -v "${name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker run -d --rm --name "${name}" --tmpfs /var/lib/mysql \
    -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=blog -e MYSQL_USER=app -e MYSQL_PASSWORD=secret \
    -p "127.0.0.1:${db_port}:3306" "${IMAGE:-mysql:8.0}" --skip-log-bin >/dev/null \
    || { echo "docker run (mysql) failed"; exit 1; }

export NEXUS_DATABASE_URL="mysql://app:secret@127.0.0.1:${db_port}/blog?fetchServerKey=true"
export NEXUS_AUTH_KEY="bench-auth-key-of-at-least-32-characters"
# nothing is mailed while benchmarking; the address only has to parse
export NEXUS_MAIL_URL="smtp://127.0.0.1:9" NEXUS_MAIL_TLS=none NEXUS_MAIL_FROM=hello@blog.test NEXUS_MAIL_FROM_NAME="A nexus blog"
password="bench-password-1"

echo "waiting for mysql"
migrated=""
for _ in $(seq 1 90); do
    "${blog}" migrate >/dev/null 2>&1 && { migrated=1; break; }
    sleep 1
done
[ -n "${migrated}" ] || { echo "migrate failed:"; "${blog}" migrate; exit 1; }
"${blog}" user:password --email editor@example.com --password "${password}" >/dev/null || exit 1

# serves variant $1 with debug console $2 and log level $3, its port in port_$1
start() {
    local port
    port=$(free_port)
    NEXUS_DEBUG_ENABLED="$2" NEXUS_LOG="$3" "${blog}" serve --listen "127.0.0.1:${port}" >/dev/null 2>&1 &
    pids+=($!)
    for _ in $(seq 1 100); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/health" && break
        sleep 0.1
    done
    printf -v "port_$1" '%s' "${port}"
}

# one wrk run on port $1, path $2, $3 connections, any more wrk arguments after; prints
# "rps p50 p99"
hit() {
    local port="$1" path="$2" c="$3" threads=4
    shift 3
    [ "${c}" -lt 4 ] && threads=1
    wrk -t "${threads}" -c "${c}" -d "${duration}" --latency "$@" "http://127.0.0.1:${port}${path}" 2>/dev/null \
        | awk '/Requests\/sec/{rps=$2} /^ +50%/{p50=$2} /^ +99%/{p99=$2} /Non-2xx/{bad=$NF} END{printf "%s %s %s %s", rps, p50, p99, bad}'
}

for v in ${only}; do
    case "${v}" in
        lean) start lean false warn ;;
        log) start log false info ;;
        console) start console true warn ;;
        both) start both true info ;;
        *) echo "no variant ${v}"; exit 1 ;;
    esac
done

# a signed-in editor and ten posts, through the first server; every server shares the database
# and the auth key, so the session works on all of them
first="port_${only%% *}"
base="http://127.0.0.1:${!first}"
. "${here}/scripts/sign.sh"
editor="$(opensession)"
login='{"email":"editor@example.com","password":"'"${password}"'"}'
signed_in="$(scode "${editor}" POST /v1/auth/signin "${login}")"
[ "${signed_in}" = 200 ] || { echo "sign in failed: ${signed_in}"; exit 1; }
for i in $(seq 1 10); do
    post='{"title":"Benchmark post '"${i}"'","body":"Some text to list","tags":["bench"]}'
    scode "${editor}" POST /v1/posts "${post}" >/dev/null
done

echo
printf '%-8s %-10s %4s  %10s  %9s  %9s\n' variant path conns req/s p50 p99
for v in ${only}; do
    var="port_${v}"
    port="${!var}"
    for c in 1 64; do
        read -r rps p50 p99 bad <<<"$(hit "${port}" /health "${c}")"
        printf '%-8s %-10s %4s  %10s  %9s  %9s  %s\n' "${v}" /health "${c}" "${rps}" "${p50}" "${p99}" "${bad:+non-2xx: ${bad}}"
    done
    for c in 1 64; do
        # signed now, so the time in the header is fresh for the whole run
        read -r rps p50 p99 bad <<<"$(hit "${port}" /v1/posts "${c}" -H "$(authz "${editor}" GET /v1/posts '')")"
        printf '%-8s %-10s %4s  %10s  %9s  %9s  %s\n' "${v}" /v1/posts "${c}" "${rps}" "${p50}" "${p99}" "${bad:+non-2xx: ${bad}}"
    done
done
