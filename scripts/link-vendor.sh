#!/usr/bin/env bash
# Links vendor/echolang/libjson and vendor/echolang/libcurl to the sibling
# checkouts (../libjson, ../libcurl next to nexus) in every suite that tests
# through nexus-testing. nexus-testing reaches ecotest-http by path, and
# ecotest-http `requires` both libraries; echoc refuses two modules with one
# name, and nexus core already depends on the sibling libjson, so the
# vendored copy has to be that same checkout. Safe to run again: a link that
# is already right is left alone, anything else in its place is replaced.
# `epm install` in one of these suites puts a copy back; run this after it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
libs="$(cd "${root}/.." && pwd)"
for dir in modules/testing modules/app modules/auth modules/auth/carbon modules/carbon modules/crud modules/mcp modules/oauth modules/oauth/carbon modules/rest modules/work modules/work/carbon examples/blog; do
    vendor="${root}/${dir}/vendor/echolang"
    mkdir -p "${vendor}"
    for lib in libjson libcurl; do
        target="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${libs}/${lib}" "${vendor}")"
        if [ -L "${vendor}/${lib}" ] && [ "$(readlink "${vendor}/${lib}")" = "${target}" ]; then
            continue
        fi
        rm -rf "${vendor:?}/${lib}"
        ln -s "${target}" "${vendor}/${lib}"
        echo "linked ${dir}/vendor/echolang/${lib} -> ${target}"
    done
done
