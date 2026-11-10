#!/usr/bin/env bash
# Runs every nexus suite through ecotest: core (with the generator), the
# modules and the blog example (whose integration tests run on a MySQL the
# tool starts in Docker, from examples/blog/ecotest.json), checks that no
# generated file is stale,
# then the blog's smoke test over a real socket against MySQL in Docker
# (SMOKE=0 skips it, IMAGE=mariadb:11 picks another server).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
echoc="${ECHOC:-echoc}"
status=0
# the suites on nexus-testing reach ecotest-http by path; its libjson and
# libcurl have to be the sibling checkouts
"${root}/scripts/link-vendor.sh" >/dev/null
# each suite prints its ecotest summary line, and every line that is not
# a passing test when it fails. Every suite runs the tool nexus itself
# vendors (-m root), testing the directory it runs in: the modules link
# vendor/echolang/libjson to the sibling 0.2 checkout, which the tool's
# ^0.1 require does not build against, and the suites on nexus-testing
# reach ecotest through path depends, so epm offers them no tool at all.
for dir in . modules/http modules/testing modules/carbon modules/carbon/testing modules/rest modules/crud modules/auth modules/auth/carbon modules/work modules/work/carbon modules/mcp modules/oauth modules/oauth/carbon modules/app examples/blog; do
    echo "== ${dir}"
    out="$(mktemp)"
    if (cd "${root}/${dir}" && epm run -m "${root}" ecotest --style simple --timeout 120000 --echoc "${echoc}") >"${out}" 2>&1; then
        grep '^ecotest ' "${out}" || tail -1 "${out}"
    else
        status=1
        grep -v '^ok ' "${out}" || true
    fi
    rm -f "${out}"
done
(cd "${root}" && "${echoc}" build --target nexus >/dev/null)
for dir in modules/http modules/carbon modules/auth modules/auth/carbon modules/work modules/work/carbon modules/mcp modules/oauth modules/oauth/carbon examples/blog; do
    echo "== nexus gen --check (${dir})"
    (cd "${root}/${dir}" && "${root}/ecobuild/nexus" gen --check) || status=1
done
if [ "${SMOKE:-1}" != "0" ]; then
    echo "== smoke (examples/blog)"
    out="$(mktemp)"
    "${root}/examples/blog/scripts/smoke.sh" >"${out}" 2>&1 || status=1
    echo "$(grep -c '^ok' "${out}") ok"
    grep -v '^ok' "${out}" | grep -v 'up to date' || true
    rm -f "${out}"
fi
exit ${status}
