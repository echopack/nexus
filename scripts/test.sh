#!/usr/bin/env bash
# Runs every nexus suite as one build: `ecotest --workspace` compiles the
# core, the modules and the blog example once, as the workspace module.eco
# lists them, and runs each test in its own process. The MySQL and the Redis
# the integration tests want start in Docker, from ecotest.json. Then no
# generated file may be stale, then the blog's smoke test runs over a real
# socket against MySQL in Docker (SMOKE=0 skips it, IMAGE=mariadb:11 picks
# another server). DOCKER=0 starts no service and skips the smoke test: the
# tests that want a server skip themselves.
#
# scripts/test-each.sh runs the same suites one directory at a time, each
# against its own vendor/. That is the check before a release.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echoc="${ECHOC:-echoc}"
status=0
# one vendor/ for the workspace: the root installs what every member requires
(cd "${root}" && epm install >/dev/null)
# ECOTEST names a runner to use as it is. Otherwise it is the ecotest nexus
# vendors.
# TODO: back to `epm run -m root ecotest` once echoc builds a tool inside
# vendor/: echoc 0.15.1 fails there with "no entry module 'ecotest' in the
# bundle", so the runner is built from a copy outside it
if [ -z "${ECOTEST:-}" ]; then
    runner="${root}/ecobuild/ecotest-runner"
    mkdir -p "${runner}"
    rsync -a --delete --exclude vendor --exclude ecobuild "${root}/vendor/echolang/ecotest/" "${runner}/"
    (cd "${runner}" && epm install >/dev/null && "${echoc}" build --target ecotest >/dev/null 2>&1)
    ECOTEST="${runner}/ecobuild/ecotest"
fi
export ECOTEST
services=()
if [ "${DOCKER:-1}" = "0" ]; then
    services=(--no-services)
fi
echo "== workspace"
out="$(mktemp)"
if (cd "${root}" && "${ECOTEST}" --workspace --style simple --timeout 120000 --echoc "${echoc}" ${services[@]+"${services[@]}"}) >"${out}" 2>&1; then
    grep '^ecotest ' "${out}" || tail -1 "${out}"
else
    status=1
    grep -v '^ok ' "${out}" || true
fi
rm -f "${out}"
(cd "${root}" && "${echoc}" build --target nexus >/dev/null)
for dir in modules/http modules/carbon modules/auth modules/auth/carbon modules/work modules/work/carbon modules/mail modules/cache modules/cache/redis modules/files modules/files/s3 modules/realtime modules/realtime/redis modules/mcp modules/debug modules/debug/work modules/debug/realtime modules/oauth modules/oauth/carbon modules/connect modules/connect/carbon examples/blog; do
    echo "== nexus gen --check (${dir})"
    (cd "${root}/${dir}" && "${root}/ecobuild/nexus" gen --check) || status=1
done
if [ "${SMOKE:-1}" != "0" ] && [ "${DOCKER:-1}" != "0" ]; then
    echo "== smoke (examples/blog)"
    out="$(mktemp)"
    "${root}/examples/blog/scripts/smoke.sh" >"${out}" 2>&1 || status=1
    echo "$(grep -c '^ok' "${out}") ok"
    grep -v '^ok' "${out}" | grep -v 'up to date' || true
    rm -f "${out}"
fi
exit ${status}
