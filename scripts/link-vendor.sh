#!/usr/bin/env bash
# Links vendor/echolang/libjson and vendor/echolang/libcurl (and calendar and
# libcrypto, where a suite vendors them) to the sibling checkouts next to nexus
# in every suite that tests through nexus-testing. nexus-testing reaches ecotest-http by path, and
# ecotest-http `requires` both libraries; echoc refuses two modules with one
# name, and nexus core already depends on the sibling libjson, so the
# vendored copy has to be that same checkout. Safe to run again: a link that
# is already right is left alone, anything else in its place is replaced.
# `epm install` in one of these suites puts a copy back; run this after it.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

# links <root>/<vendor>/<lib> to the sibling checkout next to nexus, unless it already points there
link() {
    local vendor="$1" lib="$2" up="../" part parts
    # one `../` per component of the vendor dir, plus one from the root up to the siblings
    IFS=/ read -ra parts <<< "${vendor}"
    for part in "${parts[@]}"; do
        up="../${up}"
    done
    local target="${up}${lib}" at="${root}/${vendor}/${lib}"
    mkdir -p "${root}/${vendor}"
    if [ -L "${at}" ] && [ "$(readlink "${at}")" = "${target}" ]; then
        return
    fi
    rm -rf "${at:?}"
    ln -s "${target}" "${at}"
    echo "linked ${vendor}/${lib} -> ${target}"
}
for dir in modules/testing modules/carbon/testing modules/app modules/auth modules/auth/carbon modules/carbon modules/crud modules/mcp modules/debug modules/debug/work modules/debug/realtime modules/oauth modules/oauth/carbon modules/connect modules/connect/carbon modules/rest modules/work modules/work/carbon modules/mail modules/cache modules/cache/redis modules/realtime modules/realtime/redis examples/blog; do
    # libjson and libcurl always; calendar and libcrypto where the suite vendors them, since
    # nexus and carbon build against those siblings too
    wanted="echolang/libjson echolang/libcurl"
    for maybe in echopack/calendar echolang/libcrypto; do
        if [ -e "${root}/${dir}/vendor/${maybe}" ]; then
            wanted="${wanted} ${maybe}"
        fi
    done
    for pkg in ${wanted}; do
        link "${dir}/vendor/$(dirname "${pkg}")" "$(basename "${pkg}")"
    done
done

# the runner every suite uses is the root's (`epm run -m root ecotest`); it has to be the sibling
# ecotest so it knows the newest events, such as `step`
link vendor/echolang ecotest
