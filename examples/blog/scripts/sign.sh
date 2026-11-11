# Helpers for talking to the blog over curl with signed sessions, sourced by smoke.sh and
# bench.sh. Set `base` (http://127.0.0.1:<port>) before calling them.

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
json='Content-Type: application/json'

# opens a session for nobody, as the page does first, and prints it as "<id> <secret>"
opensession() {
    local s
    s="$(body -X POST "${base}/v1/auth/session")"
    printf '%s %s' "$(printf '%s' "${s}" | field id)" "$(printf '%s' "${s}" | field secret)"
}

# the Authorization header of a request signed with session $1: method, target, time, body
authz() {
    local sid="${1%% *}" secret="${1#* }" method="$2" target="$3" body="$4" ts digest sig
    ts="$(date +%s)"
    digest="$(printf '%s' "${body}" | openssl dgst -sha256 -hex | awk '{print $NF}')"
    sig="$(printf '%s\n%s\n%s\n%s' "${method}" "${target}" "${ts}" "${digest}" | openssl dgst -sha256 -hmac "${secret}" -hex | awk '{print $NF}')"
    printf 'Authorization: Nexus-Sig id=%s,ts=%s,sig=%s' "${sid}" "${ts}" "${sig}"
}

# curl signed with session $1: method $2, target $3, body $4 (JSON when it starts with { or [,
# else a form; empty for none), any more curl arguments after
as() {
    local sess="$1" method="$2" target="$3" data="$4"
    shift 4
    local args=(-s -X "${method}" -H "$(authz "${sess}" "${method}" "${target}" "${data}")")
    if [ -n "${data}" ]; then
        case "${data}" in
            '{'*|'['*) args+=(-H "${json}") ;;
        esac
        args+=(--data-binary "${data}")
    fi
    curl "${args[@]}" "$@" "${base}${target}"
}
scode() { as "$@" -o /dev/null -w '%{http_code}'; }
