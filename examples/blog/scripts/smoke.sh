#!/usr/bin/env bash
# Builds the blog, starts a throwaway MySQL in Docker, migrates it, sets the
# editor's password, serves the blog on its own port and checks every route
# over a real socket (bearer tokens and signed sessions, signed here with
# openssl), stops it with SIGTERM, then rolls the migrations back. Tasks: a
# sign-up is welcomed by serve's own workers; a second one, queued while no
# worker runs, outlives a kill -9 and is welcomed by `blog work`. Doors:
# `posts:show` and `posts:create` on the command line, and an MCP client
# that registers, is allowed by the editor, trades its code with PKCE,
# calls the post tools and refreshes its token.
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
trap 'docker rm -f -v "${name}" >/dev/null 2>&1 || true' EXIT

export DATABASE_URL="mysql://app:secret@127.0.0.1:${db_port}/blog?fetchServerKey=true"
export AUTH_KEY=smoke-auth-key-of-at-least-32-characters

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
check "migrate"           6 "$(printf '%s\n' "${migrated}" | grep -c '^migrated')"
check "migrate again"     "nothing to do" "$(./ecobuild/blog migrate 2>&1)"
check "migrate:status"    6 "$(./ecobuild/blog migrate:status 2>&1 | grep -c '^ran')"
check "password, nobody"  1 "$(./ecobuild/blog user:password --email nobody@example.com --password smoke-password-1 >/dev/null 2>&1; echo $?)"
check "password, short"   1 "$(./ecobuild/blog user:password --email editor@example.com --password short >/dev/null 2>&1; echo $?)"
check "password"          "password set for editor@example.com" "$(./ecobuild/blog user:password --email editor@example.com --password smoke-password-1 2>&1)"
check "work:schedule"     1 "$(./ecobuild/blog work:schedule 2>&1 | grep -c '^blog::PruneAuth  0 3 \* \* \*  next ')"
check "work:failed"       "no failed tasks" "$(./ecobuild/blog work:failed 2>&1)"
check "doctor"            1 "$(./ecobuild/blog doctor 2>&1 | grep -c '^ok: .* routes, .* commands')"

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

# the Authorization value of a signed request: method, target, time, body
signed() {
    local method="$1" target="$2" body="$3" ts digest sig
    ts="$(date +%s)"
    digest="$(printf '%s' "${body}" | openssl dgst -sha256 -hex | awk '{print $NF}')"
    sig="$(printf '%s\n%s\n%s\n%s' "${method}" "${target}" "${ts}" "${digest}" | openssl dgst -sha256 -hmac "${secret}" -hex | awk '{print $NF}')"
    printf 'Nexus-Sig id=%s,ts=%s,sig=%s' "${sid}" "${ts}" "${sig}"
}

check "health"            200 "$(code "${base}/health")"
check "list, empty"       '"data":[]' "$(body "${base}/v1/posts" | grep -o '"data":\[\]')"
check "login, wrong"      401 "$(code -X POST -H "${json}" -d '{"email":"editor@example.com","password":"nope"}' "${base}/v1/auth/token")"
check "login, nobody"     401 "$(code -X POST -H "${json}" -d '{"email":"nobody@example.com","password":"nope"}' "${base}/v1/auth/token")"
token="$(body -X POST -H "${json}" -d "${login}" "${base}/v1/auth/token" | field token)"
check "login"             blog_ "${token:0:5}"
key="Authorization: Bearer ${token}"
check "me"                '"name":"The editor"' "$(body -H "${key}" "${base}/v1/me" | grep -o '"name":"The editor"')"
check "me, own email"     '"email":"editor@example.com"' "$(body -H "${key}" "${base}/v1/me" | grep -o '"email":"editor@example.com"')"
check "me, no token"      401 "$(code "${base}/v1/me")"
check "create, no token"  401 "$(code -X POST -H "${json}" -d '{"title":"Hello","body":"x"}' "${base}/v1/posts")"
check "no token, bad body" 401 "$(code -X POST -H "${json}" -d '{' "${base}/v1/posts")"
check "server timing"     1 "$(curl -s -D - -o /dev/null "${base}/health" | grep -ci '^server-timing: app;dur=')"
last="${token: -1}"
if [ "${last}" = 0 ]; then bad="${token%?}1"; else bad="${token%?}0"; fi
check "create, bad token" 401 "$(code -X POST -H "Authorization: Bearer ${bad}" -H "${json}" -d '{"title":"Hello","body":"x"}' "${base}/v1/posts")"
check "create, invalid"   422 "$(code -X POST -H "${key}" -H "${json}" -d '{"title":"Hi"}' "${base}/v1/posts")"
check "create, bad json"  400 "$(code -X POST -H "${key}" -H "${json}" -d '{' "${base}/v1/posts")"
check "create"            201 "$(code -X POST -H "${key}" -H "${json}" -d '{"title":"Hello smoke","body":"First","tags":["smoke","echo"]}' "${base}/v1/posts")"
check "batch, invalid"    '"field":"posts.1.title"' "$(body -X POST -H "${key}" -H "${json}" -d '{"posts":[{"title":"Batch one","body":"x"},{"title":"No","body":"y"}]}' "${base}/v1/posts/batch" | grep -o '"field":"posts.1.title"')"
check "batch, form"       '"field":"posts.1.title"' "$(body -X POST -H "${key}" --data 'posts[0][title]=Batch+one&posts[0][body]=x&posts[1][title]=No&posts[1][body]=y' "${base}/v1/posts/batch" | grep -o '"field":"posts.1.title"')"
check "create, form"      201 "$(code -X POST -H "${key}" --data 'title=Another+post&body=Second' "${base}/v1/posts")"
check "show"              '"title":"Hello smoke"' "$(body "${base}/v1/posts/1" | grep -o '"title":"Hello smoke"')"
check "show + author"     '"name":"The editor"' "$(body "${base}/v1/posts/1?include=author" | grep -o '"name":"The editor"')"
check "author, no email"  0 "$(body "${base}/v1/posts/1?include=author" | grep -c '"email"')"
check "show missing"      404 "$(code "${base}/v1/posts/99")"
check "show not a number" 404 "$(code "${base}/v1/posts/abc")"
check "bad include"       400 "$(code "${base}/v1/posts/1?include=secrets")"
check "list, counted"     '"total_count":2' "$(body "${base}/v1/posts?count=1" | grep -o '"total_count":2')"
check "list, by title"    '"data":[{"id":2' "$(body "${base}/v1/posts?order=title" | grep -o '"data":\[{"id":2')"
check "list, by tag"      '"filter_count":1' "$(body "${base}/v1/posts?tag=smoke&count=1" | grep -o '"filter_count":1')"
check "list, by ids"      '"filter_count":1' "$(body "${base}/v1/posts?ids=2&count=1" | grep -o '"filter_count":1')"
check "list, bad order"   422 "$(code "${base}/v1/posts?order=views")"
check "list, xml"         '<title>Hello smoke</title>' "$(body -H 'Accept: application/xml' "${base}/v1/posts" | grep -o '<title>Hello smoke</title>')"
check "update"            '"title":"Hello again"' "$(body -X PATCH -H "${key}" -H "${json}" -d '{"title":"Hello again"}' "${base}/v1/posts/1" | grep -o '"title":"Hello again"')"
check "update, invalid"   422 "$(code -X PATCH -H "${key}" -H "${json}" -d '{"title":"x"}' "${base}/v1/posts/1")"
check "update, missing"   404 "$(code -X PATCH -H "${key}" -H "${json}" -d '{}' "${base}/v1/posts/99")"
check "delete"            204 "$(code -X DELETE -H "${key}" "${base}/v1/posts/2")"
check "deleted"           404 "$(code "${base}/v1/posts/2")"
check "delete, no token"  401 "$(code -X DELETE "${base}/v1/posts/1")"
session="$(body -X POST -H "${json}" -d "${login}" "${base}/v1/auth/session")"
sid="$(printf '%s' "${session}" | field id)"
secret="$(printf '%s' "${session}" | field secret)"
check "session"           64 "${#secret}"
check "signed me"         200 "$(code -H "Authorization: $(signed GET /v1/me '')" "${base}/v1/me")"
signed_post='{"title":"Signed post","body":"Through a session"}'
check "signed create"     201 "$(code -X POST -H "Authorization: $(signed POST /v1/posts "${signed_post}")" -H "${json}" -d "${signed_post}" "${base}/v1/posts")"
check "signed, tampered"  401 "$(code -X POST -H "Authorization: $(signed POST /v1/posts "${signed_post}")" -H "${json}" -d '{"title":"Swapped","body":"x"}' "${base}/v1/posts")"
check "signed, elsewhere" 401 "$(code -H "Authorization: $(signed GET /v1/me '')" "${base}/v1/me?x=1")"

# the command line, on the same service and database as the API
shown="$(./ecobuild/blog posts:show 1 2>&1)"
check "cli posts:show"    1 "$(printf '%s\n' "${shown}" | grep -c '^#1  Hello again$')"
check "cli shows author"  1 "$(printf '%s\n' "${shown}" | grep -c '^by The editor <editor@example.com>$')"
check "cli show missing"  1 "$(./ecobuild/blog posts:show 99 >/dev/null 2>&1; echo $?)"
check "cli show, error"   1 "$(./ecobuild/blog posts:show 99 2>&1 | grep -c 'Not Found')"
check "cli create"        "published post #4 by The editor" "$(./ecobuild/blog posts:create --author 1 --title 'From the shell' --body 'Typed in a terminal' --tags Shell --tags ' shell' --tags CLI 2>/dev/null)"
check "cli create, rules" 1 "$(./ecobuild/blog posts:create --author 1 --title No --body x >/dev/null 2>&1; echo $?)"
check "cli tags cleaned"  '"tags":["shell","cli"]' "$(body "${base}/v1/posts/4" | grep -o '"tags":\["shell","cli"\]')"

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
check "authorize"         "${base}/oauth/consent?${query}" "$(curl -s -o /dev/null -w '%{redirect_url}' "${base}/oauth/authorize?${query}")"
check "consent asks"      '"name":"Smoke client"' "$(body -H "${key}" "${base}/oauth/request?${query}" | grep -o '"name":"Smoke client"')"
back="$(body -X POST -H "${key}" -H "${json}" -d "{\"query\":\"${query}\",\"allow\":true}" "${base}/oauth/approve" | field redirect)"
oauth_code="$(printf '%s' "${back}" | sed -n 's/.*[?&]code=\([0-9a-f]*\).*/\1/p')"
check "approved"          64 "${#oauth_code}"
trade="grant_type=authorization_code&client_id=${client}&code=${oauth_code}&redirect_uri=http%3A%2F%2F127.0.0.1%3A9%2Fcallback"
check "pkce, wrong"       400 "$(code -X POST --data "${trade}&code_verifier=wrong-verifier-wrong-verifier-wrong-verifier" "${base}/oauth/token")"
# the wrong try spent the code; ask again
back="$(body -X POST -H "${key}" -H "${json}" -d "{\"query\":\"${query}\",\"allow\":true}" "${base}/oauth/approve" | field redirect)"
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

check "wrong method"      405 "$(code -X PUT "${base}/v1/posts")"
check "wrong media"       415 "$(code -X POST -H "${key}" -H 'Content-Type: text/xml' -d '<x/>' "${base}/v1/posts")"
check "head"              200 "$(code -I "${base}/health")"
check "options"           204 "$(code -X OPTIONS "${base}/v1/posts")"
check "unknown"           404 "$(code "${base}/nope")"
check "request id"        1 "$(curl -s -i "${base}/health" | grep -ci '^x-request-id:')"
check "logout"            204 "$(code -X DELETE -H "${key}" "${base}/v1/auth")"
check "logged out"        401 "$(code -H "${key}" "${base}/v1/me")"
check "sign up"           201 "$(code -X POST -H "${json}" -d '{"name":"First reader","email":" First@Example.com ","password":"first-password-1","passwordConfirmation":"first-password-1"}' "${base}/v1/users")"
check "sign up, taken"    '"code":"unique"' "$(body -X POST -H "${json}" -d '{"name":"Again","email":"first@example.com","password":"first-password-1","passwordConfirmation":"first-password-1"}' "${base}/v1/users" | grep -o '"code":"unique"')"
check "sign up, german"   'Die Best' "$(body -X POST -H "${json}" -H 'Accept-Language: de' -d '{"name":"Again","email":"third@example.com","password":"first-password-1","passwordConfirmation":"other"}' "${base}/v1/users" | grep -o 'Die Best')"
first="$(body -X POST -H "${json}" -d '{"email":"first@example.com","password":"first-password-1"}' "${base}/v1/auth/token" | field token)"
# serve's own workers welcome them, within a poll or two
welcomed=0
for _ in $(seq 1 50); do
    if body -H "Authorization: Bearer ${first}" "${base}/v1/me" | grep -q '"welcomed_at":"'; then
        welcomed=1
        break
    fi
    sleep 0.1
done
check "welcomed by serve" 1 "${welcomed}"
# the editor is the blog's admin; a reader is an author of their own posts only
check "users, no token"   401 "$(code "${base}/v1/users")"
check "users, a reader"   403 "$(code -H "Authorization: Bearer ${first}" "${base}/v1/users")"
check "users, the admin"  '"name":"First reader"' "$(body -H "Authorization: $(signed GET /v1/users '')" "${base}/v1/users" | grep -o '"name":"First reader"')"
# the admin shape: everyone's email and role
check "users, emails"     '"email":"first@example.com"' "$(body -H "Authorization: $(signed GET /v1/users '')" "${base}/v1/users" | grep -o '"email":"first@example.com"')"
check "users, roles"      '"role":2' "$(body -H "Authorization: $(signed GET /v1/users '')" "${base}/v1/users" | grep -o '"role":2')"
check "delete, not yours" 403 "$(code -X DELETE -H "Authorization: Bearer ${first}" "${base}/v1/posts/1")"

kill -TERM "${pid}"
wait "${pid}"
check "clean stop"        0 "$?"
check "logged stop"       1 "$(grep -c 'stopping' "${log}")"
check "workers started"   1 "$(grep -c 'working default, mail with 2 workers' "${log}")"
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
# the session lives in the database and its secret comes from AUTH_KEY, so it outlives the restart
check "delete, restarted" 204 "$(code -X DELETE -H "Authorization: $(signed DELETE /v1/posts/1 '')" "${base}/v1/posts/1")"
check "delete the signed" 204 "$(code -X DELETE -H "Authorization: $(signed DELETE /v1/posts/3 '')" "${base}/v1/posts/3")"
check "delete cli post"   204 "$(code -X DELETE -H "Authorization: $(signed DELETE /v1/posts/4 '')" "${base}/v1/posts/4")"
check "delete mcp post"   204 "$(code -X DELETE -H "Authorization: $(signed DELETE /v1/posts/5 '')" "${base}/v1/posts/5")"
check "sign up, queued"   201 "$(code -X POST -H "${json}" -d '{"name":"Second reader","email":"second@example.com","password":"second-password-1","passwordConfirmation":"second-password-1"}' "${base}/v1/users")"
second="$(body -X POST -H "${json}" -d '{"email":"second@example.com","password":"second-password-1"}' "${base}/v1/auth/token" | field token)"
check "not welcomed yet"  1 "$(body -H "Authorization: Bearer ${second}" "${base}/v1/me" | grep -c '"welcomed_at":null')"
# the process dies without a chance to clean up; the task is in the database
kill -KILL "${pid}"
wait "${pid}" 2>/dev/null

worklog="$(mktemp)"
./ecobuild/blog work >"${worklog}" 2>&1 &
wpid=$!
for _ in $(seq 1 50); do
    grep -q 'task done' "${worklog}" && break
    sleep 0.1
done
kill -TERM "${wpid}"
wait "${wpid}"
check "work, clean stop"  0 "$?"
check "work ran the task"  1 "$(grep -c 'task done' "${worklog}")"
check "work drained"      1 "$(grep -c 'workers stopped' "${worklog}")"
rm -f "${worklog}"

serve
check "welcomed by work"  1 "$(body -H "Authorization: Bearer ${second}" "${base}/v1/me" | grep -c '"welcomed_at":"')"
kill -TERM "${pid}"
wait "${pid}"

check "auth:prune"        "pruned  0 tokens, 0 sessions" "$(./ecobuild/blog auth:prune 2>&1)"
check "oauth:prune"       "pruned expired OAuth codes and grants" "$(./ecobuild/blog oauth:prune 2>&1)"
check "reset wants force" 1 "$(./ecobuild/blog migrate:reset --mode prod >/dev/null 2>&1; echo $?)"
check "work:failed, end"  "no failed tasks" "$(./ecobuild/blog work:failed 2>&1)"
check "migrate:reset"     6 "$(./ecobuild/blog migrate:reset 2>&1 | grep -c '^undone')"
check "all pending"       6 "$(./ecobuild/blog migrate:status 2>&1 | grep -c '^pending')"
exit ${failed}
