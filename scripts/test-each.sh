#!/usr/bin/env bash
# Runs every nexus suite on its own: one `epm install` and one ecotest run
# per directory, each against its own vendor/. This is the proof that every
# package builds and passes alone, the way its users get it, so it is the
# check before a release. scripts/test.sh is the everyday run: the same
# tests as one build.
#
# The suites with an ecotest.json start their MySQL or Redis in Docker, then
# no generated file may be stale, then the blog's smoke test runs over a real
# socket against MySQL in Docker (SMOKE=0 skips it, IMAGE=mariadb:11 picks
# another server). DOCKER=0 skips everything that needs Docker: the suites
# with an ecotest.json and the smoke test.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echoc="${ECHOC:-echoc}"
status=0
# each suite vendors its own packages, then prints its ecotest summary line,
# and every line that is not a passing test when it fails. Every suite runs
# the ecotest nexus itself vendors, testing the directory it runs in, so the
# runner is the same everywhere.
(cd "${root}" && epm install >/dev/null)
# TODO: back to `epm run -m root ecotest` once echoc builds a tool inside
# vendor/: echoc 0.15.1 fails there with "no entry module 'ecotest' in the
# bundle", so the runner is built from a copy outside it
runner="${root}/ecobuild/ecotest-runner"
mkdir -p "${runner}"
rsync -a --delete --exclude vendor --exclude ecobuild "${root}/vendor/echolang/ecotest/" "${runner}/"
(cd "${runner}" && epm install >/dev/null && "${echoc}" build --target ecotest >/dev/null 2>&1)
export ECOTEST="${runner}/ecobuild/ecotest"
for dir in . modules/http modules/testing modules/carbon modules/carbon/testing modules/rest modules/crud modules/auth modules/auth/carbon modules/work modules/work/carbon modules/mail modules/cache modules/cache/redis modules/files modules/files/s3 modules/realtime modules/realtime/redis modules/mcp modules/debug modules/debug/work modules/debug/realtime modules/oauth modules/oauth/carbon modules/connect modules/connect/carbon modules/app examples/blog; do
    echo "== ${dir}"
    if [ "${DOCKER:-1}" = "0" ] && [ -f "${root}/${dir}/ecotest.json" ]; then
        echo "skipped: its services need Docker"
        continue
    fi
    out="$(mktemp)"
    if (cd "${root}/${dir}" && epm install >/dev/null && "${ECOTEST}" --style simple --timeout 120000 --echoc "${echoc}") >"${out}" 2>&1; then
        grep '^ecotest ' "${out}" || tail -1 "${out}"
    else
        status=1
        grep -v '^ok ' "${out}" || true
    fi
    rm -f "${out}"
done
(cd "${root}" && "${echoc}" build --target nexus >/dev/null)
for dir in modules/http modules/carbon modules/auth modules/auth/carbon modules/work modules/work/carbon modules/mail modules/cache modules/cache/redis modules/files modules/files/s3 modules/realtime modules/realtime/redis modules/mcp modules/debug modules/debug/work modules/debug/realtime modules/oauth modules/oauth/carbon modules/connect modules/connect/carbon examples/blog; do
    echo "== nexus gen --check (${dir})"
    (cd "${root}/${dir}" && epm install >/dev/null && "${root}/ecobuild/nexus" gen --check) || status=1
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
