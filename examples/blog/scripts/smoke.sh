#!/usr/bin/env bash
# Builds the blog, starts a throwaway MySQL in Docker, migrates it, sets the
# editor's password, serves the blog on its own port and checks every route
# over a real socket (signed sessions: opened first, every request signed here
# with openssl, signing in on them), stops it with SIGTERM, then rolls the
# migrations back. Tasks: a
# sign-up stores a pipeline (welcome, then count the users) that serve's own
# workers run; a second one, stored while no worker runs, outlives a kill -9
# and is run by `blog work`. nexus-work-carbon's live test runs against the
# same server. Mail goes to a throwaway Mailpit in Docker: each welcome is
# read back from its API, and nexus-mail's live test runs against it. Doors:
# `posts:show` and `posts:create` on the command line, and an MCP client
# that registers, is allowed by the editor on the request the authorize
# step kept, trades its code with PKCE, calls the post tools and
# refreshes its token.
#
#   scripts/smoke.sh                     # mysql:8.0
#   IMAGE=mariadb:11 scripts/smoke.sh
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
port="${SMOKE_PORT:-18471}"
image="${IMAGE:-mysql:8.0}"
base="http://127.0.0.1:${port}"
echoc="${ECHOC:-echoc}"
cd "${here}"
"${echoc}" build >/dev/null || { echo "build failed"; exit 1; }

db_port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
name="nexus-blog-smoke-$$"
docker run -d --rm --name "${name}" \
    -e MYSQL_ROOT_PASSWORD=rootpw -e MYSQL_DATABASE=blog -e MYSQL_USER=app -e MYSQL_PASSWORD=secret \
    -e MARIADB_ROOT_PASSWORD=rootpw -e MARIADB_DATABASE=blog -e MARIADB_USER=app -e MARIADB_PASSWORD=secret \
    -p "127.0.0.1:${db_port}:3306" "${image}" >/dev/null || { echo "docker run failed"; exit 1; }
mail_smtp=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mail_http=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
mail_name="nexus-blog-mail-$$"
docker run -d --rm --name "${mail_name}" \
    -p "127.0.0.1:${mail_smtp}:1025" -p "127.0.0.1:${mail_http}:8025" "${MAIL_IMAGE:-axllent/mailpit}" >/dev/null \
    || { docker rm -f -v "${name}" >/dev/null 2>&1; echo "docker run (mailpit) failed"; exit 1; }
trap 'docker rm -f -v "${name}" "${mail_name}" >/dev/null 2>&1 || true' EXIT
mailapi="http://127.0.0.1:${mail_http}/api/v1"

export NEXUS_DATABASE_URL="mysql://app:secret@127.0.0.1:${db_port}/blog?fetchServerKey=true"
export NEXUS_AUTH_KEY=smoke-auth-key-of-at-least-32-characters
export NEXUS_MAIL_URL="smtp://127.0.0.1:${mail_smtp}" NEXUS_MAIL_TLS=none NEXUS_MAIL_FROM=hello@blog.test NEXUS_MAIL_FROM_NAME="A nexus blog"

failed=0
check() {
    local name="$1" want="$2" got="$3"
    if [ "${got}" = "${want}" ]; then
        echo "ok   ${name}"
    else
        echo "FAIL ${name}: want ${want}, got ${got}"
        failed=1
    fi
}

# the server takes a while to take connections; migrate until it does
migrated=""
for _ in $(seq 1 90); do
    if migrated="$(./ecobuild/blog migrate 2>&1)"; then
        break
    fi
    migrated=""
    sleep 1
done
check "migrate"           7 "$(printf '%s\n' "${migrated}" | grep -c '^migrated')"
check "migrate again"     "nothing to do" "$(./ecobuild/blog migrate 2>&1)"
check "migrate:status"    7 "$(./ecobuild/blog migrate:status 2>&1 | grep -c '^ran')"
check "password, nobody"  1 "$(./ecobuild/blog user:password --email nobody@example.com --password smoke-password-1 >/dev/null 2>&1; echo $?)"
check "password, short"   1 "$(./ecobuild/blog user:password --email editor@example.com --password short >/dev/null 2>&1; echo $?)"
check "password"          "password set for editor@example.com" "$(./ecobuild/blog user:password --email editor@example.com --password smoke-password-1 2>&1)"
check "work:schedule"     1 "$(./ecobuild/blog work:schedule 2>&1 | grep -c '^Blog::Tasks::PruneAuth  0 3 \* \* \*  into Blog::Queues::JobLane  next ')"
check "work:failed"       "no failed tasks" "$(./ecobuild/blog work:failed 2>&1)"
check "doctor"            1 "$(./ecobuild/blog doctor 2>&1 | grep -c '^ok: .* routes, .* commands')"

# nexus-work-carbon's live test on this server: two servers settling at once both count down the
# task that waits for them (it only runs when WORK_LIVE_URL is set)
live="$(cd "${here}/../../modules/work/carbon" && WORK_LIVE_URL="${NEXUS_DATABASE_URL}" epm run -m "${here}/../.." ecotest --style simple --timeout 120000 --echoc "${echoc}" 2>&1)"
check "work store, live"  1 "$(printf '%s\n' "${live}" | grep -c '^ok .*LiveTest.eco::dependencies_finishing_at_once_on_two_servers_all_count')"

# nexus-mail's live test on the Mailpit: a mail over SMTP, read back from its API
for _ in $(seq 1 50); do
    curl -s -o /dev/null "${mailapi}/messages" && break
    sleep 0.2
done
live="$(cd "${here}/../../modules/mail" && MAIL_LIVE_URL="${NEXUS_MAIL_URL}" MAIL_LIVE_API="http://127.0.0.1:${mail_http}" epm run -m "${here}/../.." ecotest --style simple --timeout 120000 --echoc "${echoc}" 2>&1)"
check "mail, live"        1 "$(printf '%s\n' "${live}" | grep -c '^ok .*LiveTest.eco::a_mail_reaches_a_real_server')"

# the subjects of every mail to `$1` Mailpit holds
mailed() { curl -s -G --data-urlencode "query=to:$1" "${mailapi}/search" | grep -o '"Subject":"[^"]*"'; }

log="$(mktemp)"
./ecobuild/blog serve --listen "127.0.0.1:${port}" >"${log}" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
    curl -s -o /dev/null "${base}/health" && break
    sleep 0.1
done

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
body() { curl -s "$@"; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
json='Content-Type: application/json'
login='{"email":"editor@example.com","password":"smoke-password-1"}'

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

check "health"            200 "$(code "${base}/health")"
check "no session"        401 "$(code "${base}/v1/posts")"
check "no session, me"    401 "$(code "${base}/v1/me")"
check "options, no session" 204 "$(code -X OPTIONS "${base}/v1/posts")"
visitor="$(opensession)"
visitor_secret="${visitor#* }"
check "session"           64 "${#visitor_secret}"
check "session, nobody"   '"signed_in":false' "$(as "${visitor}" GET /v1/auth/session '' | grep -o '"signed_in":false')"
check "list, empty"       '"data":[]' "$(as "${visitor}" GET /v1/posts '' | grep -o '"data":\[\]')"
check "login, wrong"      401 "$(scode "${visitor}" POST /v1/auth/signin '{"email":"editor@example.com","password":"nope"}')"
check "login, nobody"     401 "$(scode "${visitor}" POST /v1/auth/signin '{"email":"nobody@example.com","password":"nope"}')"
editor="$(opensession)"
check "login"             '"name":"The editor"' "$(as "${editor}" POST /v1/auth/signin "${login}" | grep -o '"name":"The editor"')"
check "login, twice"      409 "$(scode "${editor}" POST /v1/auth/signin "${login}")"
check "session, editor"   '"signed_in":true' "$(as "${editor}" GET /v1/auth/session '' | grep -o '"signed_in":true')"
check "me"                '"name":"The editor"' "$(as "${editor}" GET /v1/me '' | grep -o '"name":"The editor"')"
check "me, own email"     '"email":"editor@example.com"' "$(as "${editor}" GET /v1/me '' | grep -o '"email":"editor@example.com"')"
check "me, nobody"        401 "$(scode "${visitor}" GET /v1/me '')"
check "create, nobody"    401 "$(scode "${visitor}" POST /v1/posts '{"title":"Hello","body":"x"}')"
check "nobody, bad body"  401 "$(scode "${visitor}" POST /v1/posts '{')"
check "server timing"     1 "$(curl -s -D - -o /dev/null "${base}/health" | grep -ci '^server-timing: app;dur=')"
check "create, forged"    401 "$(scode "${editor%% *} not-the-secret" POST /v1/posts '{"title":"Hello","body":"x"}')"
check "create, bearer"    401 "$(code -X POST -H 'Authorization: Bearer blog_000000000000_0000000000000000000000000000000000000000000000000000000000000000' -H "${json}" -d '{"title":"Hello","body":"x"}' "${base}/v1/posts")"
check "create, invalid"   422 "$(scode "${editor}" POST /v1/posts '{"title":"Hi"}')"
check "create, bad json"  400 "$(scode "${editor}" POST /v1/posts '{')"
check "create"            201 "$(scode "${editor}" POST /v1/posts '{"title":"Hello smoke","body":"First","tags":["smoke","echo"]}')"
check "batch, invalid"    '"field":"posts.1.title"' "$(as "${editor}" POST /v1/posts/batch '{"posts":[{"title":"Batch one","body":"x"},{"title":"No","body":"y"}]}' | grep -o '"field":"posts.1.title"')"
check "batch, form"       '"field":"posts.1.title"' "$(as "${editor}" POST /v1/posts/batch 'posts[0][title]=Batch+one&posts[0][body]=x&posts[1][title]=No&posts[1][body]=y' | grep -o '"field":"posts.1.title"')"
check "create, form"      201 "$(scode "${editor}" POST /v1/posts 'title=Another+post&body=Second')"
check "show"              '"title":"Hello smoke"' "$(as "${visitor}" GET /v1/posts/1 '' | grep -o '"title":"Hello smoke"')"
check "show + author"     '"name":"The editor"' "$(as "${visitor}" GET '/v1/posts/1?include=author' '' | grep -o '"name":"The editor"')"
check "author, no email"  0 "$(as "${visitor}" GET '/v1/posts/1?include=author' '' | grep -c '"email"')"
check "show missing"      404 "$(scode "${visitor}" GET /v1/posts/99 '')"
check "show not a number" 404 "$(scode "${visitor}" GET /v1/posts/abc '')"
check "bad include"       400 "$(scode "${visitor}" GET '/v1/posts/1?include=secrets' '')"
check "list, counted"     '"total_count":2' "$(as "${visitor}" GET '/v1/posts?count=1' '' | grep -o '"total_count":2')"
check "list, by title"    '"data":[{"id":2' "$(as "${visitor}" GET '/v1/posts?order=title' '' | grep -o '"data":\[{"id":2')"
check "list, by tag"      '"filter_count":1' "$(as "${visitor}" GET '/v1/posts?tag=smoke&count=1' '' | grep -o '"filter_count":1')"
check "list, by ids"      '"filter_count":1' "$(as "${visitor}" GET '/v1/posts?ids=2&count=1' '' | grep -o '"filter_count":1')"
check "list, bad order"   422 "$(scode "${visitor}" GET '/v1/posts?order=views' '')"
check "list, xml"         '<title>Hello smoke</title>' "$(as "${visitor}" GET /v1/posts '' -H 'Accept: application/xml' | grep -o '<title>Hello smoke</title>')"
check "update"            '"title":"Hello again"' "$(as "${editor}" PATCH /v1/posts/1 '{"title":"Hello again"}' | grep -o '"title":"Hello again"')"
check "update, invalid"   422 "$(scode "${editor}" PATCH /v1/posts/1 '{"title":"x"}')"
check "update, missing"   404 "$(scode "${editor}" PATCH /v1/posts/99 '{}')"
check "delete"            204 "$(scode "${editor}" DELETE /v1/posts/2 '')"
check "deleted"           404 "$(scode "${visitor}" GET /v1/posts/2 '')"
check "delete, nobody"    401 "$(scode "${visitor}" DELETE /v1/posts/1 '')"
# a second session for the editor, kept until the end: it outlives a restart
keeper="$(opensession)"
check "login, kept"       200 "$(scode "${keeper}" POST /v1/auth/signin "${login}")"
signed_post='{"title":"Signed post","body":"Through a session"}'
check "signed create"     201 "$(scode "${keeper}" POST /v1/posts "${signed_post}")"
check "signed, tampered"  401 "$(code -X POST -H "$(authz "${keeper}" POST /v1/posts "${signed_post}")" -H "${json}" -d '{"title":"Swapped","body":"x"}' "${base}/v1/posts")"
check "signed, elsewhere" 401 "$(code -H "$(authz "${keeper}" GET /v1/me '')" "${base}/v1/me?x=1")"

# the command line, on the same service and database as the API
shown="$(./ecobuild/blog posts:show 1 2>&1)"
check "cli posts:show"    1 "$(printf '%s\n' "${shown}" | grep -c '^#1  Hello again$')"
check "cli shows author"  1 "$(printf '%s\n' "${shown}" | grep -c '^by The editor <editor@example.com>$')"
check "cli show missing"  1 "$(./ecobuild/blog posts:show 99 >/dev/null 2>&1; echo $?)"
check "cli show, error"   1 "$(./ecobuild/blog posts:show 99 2>&1 | grep -c 'Not Found')"
check "cli create"        "published post #4 by The editor" "$(./ecobuild/blog posts:create --author 1 --title 'From the shell' --body 'Typed in a terminal' --tags Shell --tags ' shell' --tags CLI 2>/dev/null)"
check "cli create, rules" 1 "$(./ecobuild/blog posts:create --author 1 --title No --body x >/dev/null 2>&1; echo $?)"
check "cli tags cleaned"  '"tags":["shell","cli"]' "$(as "${visitor}" GET /v1/posts/4 '' | grep -o '"tags":\["shell","cli"\]')"

# an MCP client: it finds the sign in through the 401, registers, and the editor allows it
mcp='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
check "mcp, no token"     401 "$(code -X POST -H "${json}" -d "${mcp}" "${base}/mcp")"
check "mcp challenge"     1 "$(curl -s -i -X POST -H "${json}" -d "${mcp}" "${base}/mcp" | grep -ci "^www-authenticate: Bearer resource_metadata=\"${base}/.well-known/oauth-protected-resource/mcp\"")"
check "resource meta"     "\"resource\":\"${base}/mcp\"" "$(body "${base}/.well-known/oauth-protected-resource/mcp" | grep -o "\"resource\":\"${base}/mcp\"")"
check "server meta"       "\"registration_endpoint\":\"${base}/oauth/register\"" "$(body "${base}/.well-known/oauth-authorization-server" | grep -o "\"registration_endpoint\":\"${base}/oauth/register\"")"
redirect='http://127.0.0.1:9/callback'
client="$(body -X POST -H "${json}" -d "{\"client_name\":\"Smoke client\",\"redirect_uris\":[\"${redirect}\"]}" "${base}/oauth/register" | field client_id)"
check "register"          32 "${#client}"
check "register, http"    400 "$(code -X POST -H "${json}" -d '{"redirect_uris":["http://evil.example/cb"]}' "${base}/oauth/register")"
verifier="$(openssl rand -hex 32)"
challenge="$(printf '%s' "${verifier}" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
query="response_type=code&client_id=${client}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback&code_challenge=${challenge}&code_challenge_method=S256&state=smoke&scope=mcp"
consent="$(curl -s -o /dev/null -w '%{redirect_url}' "${base}/oauth/authorize?${query}")"
request="$(printf '%s' "${consent}" | sed -n 's/.*[?&]request=\([0-9a-f]*\).*/\1/p')"
check "authorize"         "${base}/oauth/consent?request=${request}" "${consent}"
check "consent, nobody"   401 "$(scode "${visitor}" GET "/oauth/requests/${request}" '')"
check "consent asks"      '"name":"Smoke client"' "$(as "${editor}" GET "/oauth/requests/${request}" '' | grep -o '"name":"Smoke client"')"
check "consent, resource" '"url":"'"${base}"'/mcp"' "$(as "${editor}" GET "/oauth/requests/${request}" '' | grep -o '"url":"[^"]*"')"
back="$(as "${editor}" POST "/oauth/requests/${request}" '{"allow":true}' | field redirect)"
oauth_code="$(printf '%s' "${back}" | sed -n 's/.*[?&]code=\([0-9a-f]*\).*/\1/p')"
check "approved"          64 "${#oauth_code}"
check "answered once"     404 "$(scode "${editor}" POST "/oauth/requests/${request}" '{"allow":true}')"
trade="grant_type=authorization_code&client_id=${client}&code=${oauth_code}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback"
check "pkce, wrong"       400 "$(code -X POST --data "${trade}&code_verifier=wrong-verifier-wrong-verifier-wrong-verifier" "${base}/oauth/token")"
# the wrong try spent the code; ask again
consent="$(curl -s -o /dev/null -w '%{redirect_url}' "${base}/oauth/authorize?${query}")"
request="$(printf '%s' "${consent}" | sed -n 's/.*[?&]request=\([0-9a-f]*\).*/\1/p')"
back="$(as "${editor}" POST "/oauth/requests/${request}" '{"allow":true}' | field redirect)"
oauth_code="$(printf '%s' "${back}" | sed -n 's/.*[?&]code=\([0-9a-f]*\).*/\1/p')"
trade="grant_type=authorization_code&client_id=${client}&code=${oauth_code}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback"
pair="$(body -X POST --data "${trade}&code_verifier=${verifier}" "${base}/oauth/token")"
access="$(printf '%s' "${pair}" | field access_token)"
refresh="$(printf '%s' "${pair}" | field refresh_token)"
check "token"             nxo_ "${access:0:4}"
check "code used"         400 "$(code -X POST --data "${trade}&code_verifier=${verifier}" "${base}/oauth/token")"
app="Authorization: Bearer ${access}"
check "mcp initialize"    '"protocolVersion":"2025-06-18"' "$(body -X POST -H "${app}" -H "${json}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}' "${base}/mcp" | grep -o '"protocolVersion":"2025-06-18"')"
check "mcp tools"         2 "$(body -X POST -H "${app}" -H "${json}" -d "${mcp}" "${base}/mcp" | grep -o '"name":"\(show\|create\)_post"' | wc -l | tr -d ' ')"
check "mcp show_post"     '"title":"Hello again"' "$(body -X POST -H "${app}" -H "${json}" -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"show_post","arguments":{"post":1}}}' "${base}/mcp" | grep -o '"title":"Hello again"' | head -1)"
check "mcp create_post"   '"isError":false' "$(body -X POST -H "${app}" -H "${json}" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_post","arguments":{"title":"Over MCP","body":"Written by a client"}}}' "${base}/mcp" | grep -o '"isError":false')"
check "mcp, bad args"     '"isError":true' "$(body -X POST -H "${app}" -H "${json}" -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"create_post","arguments":{"title":"No"}}}' "${base}/mcp" | grep -o '"isError":true')"
check "oauth token, api"  401 "$(code -H "${app}" "${base}/v1/me")"
renewed="$(body -X POST --data "grant_type=refresh_token&client_id=${client}&refresh_token=${refresh}" "${base}/oauth/token")"
next_access="$(printf '%s' "${renewed}" | field access_token)"
check "refresh"           nxo_ "${next_access:0:4}"
check "old access gone"   401 "$(code -X POST -H "${app}" -H "${json}" -d "${mcp}" "${base}/mcp")"
check "new access works"  200 "$(code -X POST -H "Authorization: Bearer ${next_access}" -H "${json}" -d "${mcp}" "${base}/mcp")"
check "refresh reused"    '"error":"invalid_grant"' "$(body -X POST --data "grant_type=refresh_token&client_id=${client}&refresh_token=${refresh}" "${base}/oauth/token" | grep -o '"error":"invalid_grant"')"
check "grant ended"       401 "$(code -X POST -H "Authorization: Bearer ${next_access}" -H "${json}" -d "${mcp}" "${base}/mcp")"
# sign in with Google is left out without NEXUS_CONNECT_GOOGLE_CLIENT_ID
check "google, unset"     404 "$(code -X POST -H "${json}" -d '{}' "${base}/auth/connect/google")"

check "wrong method"      405 "$(scode "${visitor}" PUT /v1/posts '')"
check "wrong media"       415 "$(scode "${editor}" POST /v1/posts '<x/>' -H 'Content-Type: text/xml')"
check "head"              200 "$(code -I "${base}/health")"
check "options"           204 "$(code -X OPTIONS "${base}/v1/posts")"
check "unknown"           404 "$(code "${base}/nope")"
check "request id"        1 "$(curl -s -i "${base}/health" | grep -ci '^x-request-id:')"
check "logout"            204 "$(scode "${editor}" DELETE /v1/auth '')"
check "logged out"        401 "$(scode "${editor}" GET /v1/me '')"
check "session ended"     401 "$(scode "${editor}" GET /v1/posts '')"
check "sign up"           201 "$(scode "${visitor}" POST /v1/users '{"name":"First reader","email":" First@Example.com ","password":"first-password-1","passwordConfirmation":"first-password-1"}')"
check "sign up, taken"    '"code":"unique"' "$(as "${visitor}" POST /v1/users '{"name":"Again","email":"first@example.com","password":"first-password-1","passwordConfirmation":"first-password-1"}' | grep -o '"code":"unique"')"
check "sign up, german"   'Die Best' "$(as "${visitor}" POST /v1/users '{"name":"Again","email":"third@example.com","password":"first-password-1","passwordConfirmation":"other"}' -H 'Accept-Language: de' | grep -o 'Die Best')"
first="$(opensession)"
check "login, reader"     200 "$(scode "${first}" POST /v1/auth/signin '{"email":"first@example.com","password":"first-password-1"}')"
# serve's own workers welcome them, within a poll or two
welcomed=0
for _ in $(seq 1 50); do
    if as "${first}" GET /v1/me '' | grep -q '"welcomed_at":"'; then
        welcomed=1
        break
    fi
    sleep 0.1
done
check "welcomed by serve" 1 "${welcomed}"
check "welcome mailed"    '"Subject":"Welcome to A nexus blog"' "$(mailed first@example.com)"
# then the next step of the sign-up's pipeline counts the users
for _ in $(seq 1 50); do
    grep -q 'users counted' "${log}" && break
    sleep 0.1
done
# the editor is the blog's admin; a reader is an author of their own posts only
check "users, no session" 401 "$(code "${base}/v1/users")"
check "users, nobody"     401 "$(scode "${visitor}" GET /v1/users '')"
check "users, a reader"   403 "$(scode "${first}" GET /v1/users '')"
check "users, the admin"  '"name":"First reader"' "$(as "${keeper}" GET /v1/users '' | grep -o '"name":"First reader"')"
# the admin shape: everyone's email and role
check "users, emails"     '"email":"first@example.com"' "$(as "${keeper}" GET /v1/users '' | grep -o '"email":"first@example.com"')"
check "users, roles"      '"role":2' "$(as "${keeper}" GET /v1/users '' | grep -o '"role":2')"
check "delete, not yours" 403 "$(scode "${first}" DELETE /v1/posts/1 '')"

kill -TERM "${pid}"
wait "${pid}"
check "clean stop"        0 "$?"
check "logged stop"       1 "$(grep -c 'stopping' "${log}")"
check "workers started"   1 "$(grep -c 'working Blog::Queues::WorkerLane (2 threads), Blog::Queues::JobLane into Blog::Queues::WorkerLane' "${log}")"
check "pipeline ran"      1 "$(grep -c 'users counted' "${log}")"
check "scheduler started" 1 "$(grep -c 'scheduling 1 tasks' "${log}")"
check "workers drained"   1 "$(grep -c 'workers stopped' "${log}")"
rm -f "${log}"

# the editor cannot go while a post of theirs is left
check "reset, posts left" 1 "$(./ecobuild/blog migrate:reset >/dev/null 2>&1; echo $?)"
serve() {
    ./ecobuild/blog serve --listen "127.0.0.1:${port}" "$@" >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "${base}/health" && break
        sleep 0.1
    done
}
# no workers this time: what is pushed stays queued
serve --no-work
# the sessions live in the database and their secrets come from NEXUS_AUTH_KEY, so they outlive the restart
check "delete, restarted" 204 "$(scode "${keeper}" DELETE /v1/posts/1 '')"
check "delete the signed" 204 "$(scode "${keeper}" DELETE /v1/posts/3 '')"
check "delete cli post"   204 "$(scode "${keeper}" DELETE /v1/posts/4 '')"
check "delete mcp post"   204 "$(scode "${keeper}" DELETE /v1/posts/5 '')"
check "sign up, queued"   201 "$(scode "${visitor}" POST /v1/users '{"name":"Second reader","email":"second@example.com","password":"second-password-1","passwordConfirmation":"second-password-1"}' -H 'Accept-Language: de-CH')"
second="$(opensession)"
check "login, second"     200 "$(scode "${second}" POST /v1/auth/signin '{"email":"second@example.com","password":"second-password-1"}')"
check "not welcomed yet"  1 "$(as "${second}" GET /v1/me '' | grep -c '"welcomed_at":null')"
# the process dies without a chance to clean up; the task is in the database
kill -KILL "${pid}"
wait "${pid}" 2>/dev/null

worklog="$(mktemp)"
./ecobuild/blog work >"${worklog}" 2>&1 &
wpid=$!
for _ in $(seq 1 50); do
    grep -q 'users counted' "${worklog}" && break
    sleep 0.1
done
kill -TERM "${wpid}"
wait "${wpid}"
check "work, clean stop"  0 "$?"
check "work ran the tasks" 2 "$(grep -c 'task done' "${worklog}")"
check "work drained"      1 "$(grep -c 'workers stopped' "${worklog}")"
rm -f "${worklog}"

serve
check "welcomed by work"  1 "$(as "${second}" GET /v1/me '' | grep -c '"welcomed_at":"')"
check "welcome mailed, de" '"Subject":"Willkommen bei A nexus blog"' "$(mailed second@example.com)"
kill -TERM "${pid}"
wait "${pid}"

check "auth:prune"        "pruned  0 tokens|pruned  0 sessions|pruned  0 oauth requests, codes and grants|pruned  0 sign-in attempts" "$(./ecobuild/blog auth:prune 2>&1 | paste -sd '|' -)"
check "reset wants force" 1 "$(./ecobuild/blog migrate:reset --mode prod >/dev/null 2>&1; echo $?)"
check "work:failed, end"  "no failed tasks" "$(./ecobuild/blog work:failed 2>&1)"
check "migrate:reset"     7 "$(./ecobuild/blog migrate:reset 2>&1 | grep -c '^undone')"
check "all pending"       7 "$(./ecobuild/blog migrate:status 2>&1 | grep -c '^pending')"
exit ${failed}
