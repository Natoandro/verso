#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: $0 PATH_TO_VERSO" >&2
    exit 2
fi

command -v curl >/dev/null 2>&1 || {
    echo "bootstrap verification requires curl" >&2
    exit 2
}
command -v python3 >/dev/null 2>&1 || {
    echo "bootstrap verification requires python3" >&2
    exit 2
}

binary=$1
case "$binary" in
    /*) ;;
    *) binary=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd)/$(basename -- "$binary") ;;
esac
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
migrations_directory=$(CDPATH= cd -- "$script_directory/../migrations" && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/verso-bootstrap.XXXXXX")
server_pid=

cleanup() {
    if [ -n "${server_pid:-}" ] && kill -0 "$server_pid" 2>/dev/null; then
        kill -TERM "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

fail() {
    echo "bootstrap verification failed: $*" >&2
    exit 1
}

assert_log_contains() {
    log_file=$1
    expected=$2
    grep -F "$expected" "$log_file" >/dev/null || fail "missing '$expected' in $log_file"
}

run_server() {
    case_directory=$1
    port=$2
    stdout_file=$3
    stderr_file=$4
    shutdown_signal=$5
    check_initial_setup=${6:-false}

    (
        cd "$case_directory"
        exec env -i \
            "PATH=${PATH:-/usr/bin:/bin}" \
            VERSO_SERVER_PORT="$port" \
            VERSO_MIGRATIONS_PATH="$migrations_directory" \
            "$binary" serve >"$stdout_file" 2>"$stderr_file"
    ) &
    server_pid=$!

    ready=0
    response=
    attempt=0
    while [ "$attempt" -lt 100 ]; do
        if response=$(curl --fail --silent "http://127.0.0.1:$port/"); then
            ready=1
            break
        fi
        if ! kill -0 "$server_pid" 2>/dev/null; then
            break
        fi
        sleep 0.05
        attempt=$((attempt + 1))
    done

    [ "$ready" -eq 1 ] || {
        sed -n '1,120p' "$stderr_file" >&2 || true
        fail "server did not become ready"
    }
    [ "$response" = "Verso is running" ] || fail "unexpected HTTP response: $response"

    not_found_body="$case_directory/not-found.body"
    not_found_headers=$(curl --silent --dump-header - --output "$not_found_body" "http://127.0.0.1:$port/does-not-exist") || fail "not-found request failed"
    printf '%s\n' "$not_found_headers" | grep -F 'HTTP/1.1 404' >/dev/null || fail "not-found response had the wrong status"
    printf '%s\n' "$not_found_headers" | grep -Fi 'content-type: text/html; charset=utf-8' >/dev/null || fail "not-found response was not HTML"
    grep -F '<h1>Not Found</h1>' "$not_found_body" >/dev/null || fail "not-found page was incomplete"

    if [ "$check_initial_setup" = true ]; then
        admin_headers=$(curl --silent --dump-header - --output /dev/null "http://127.0.0.1:$port/admin") || fail "admin entry route was not served"
        printf '%s\n' "$admin_headers" | grep -F 'HTTP/1.1 303' >/dev/null || fail "empty database admin entry did not redirect"
        printf '%s\n' "$admin_headers" | grep -F 'location: /admin/register' >/dev/null || fail "admin entry did not redirect to registration"
        login_body_file="$case_directory/login.body"
        login_headers=$(curl --silent --dump-header - --output "$login_body_file" "http://127.0.0.1:$port/admin/login") || fail "login route was not served"
        printf '%s\n' "$login_headers" | grep -F 'HTTP/1.1 303' >/dev/null || fail "empty database did not redirect to registration"
        printf '%s\n' "$login_headers" | grep -F 'location: /admin/register' >/dev/null || fail "login did not redirect to registration"
        register_response=$(curl --fail --silent "http://127.0.0.1:$port/admin/register") || fail "registration page was not served"
        printf '%s\n' "$register_response" | grep -F 'name="display_name"' >/dev/null || fail "registration page was incomplete"
        register_csrf_token=$(printf '%s\n' "$register_response" | sed -n 's/.*name="csrf_token" value="\([0-9a-f]*\)".*/\1/p')
        [ "${#register_csrf_token}" -eq 64 ] || fail "registration page did not include a CSRF token"
        register_headers=$(curl --silent --dump-header - --output /dev/null \
            -H "Cookie: __Host-verso_setup_csrf=$register_csrf_token" \
            -H "Origin: http://127.0.0.1:$port" \
            --data "csrf_token=$register_csrf_token&display_name=Site+Owner&email=owner%40example.test&login=owner%40example.test&password=correct+horse+battery+staple&password_confirmation=correct+horse+battery+staple" \
            "http://127.0.0.1:$port/admin/register") || {
            sed -n '1,180p' "$stderr_file" >&2 || true
            fail "initial registration request failed"
        }
        printf '%s\n' "$register_headers" | grep -F 'HTTP/1.1 303' >/dev/null || fail "registration did not redirect"
        printf '%s\n' "$register_headers" | grep -F 'location: /admin/editor' >/dev/null || fail "registration did not establish owner session"
        login_response=$(curl --silent "http://127.0.0.1:$port/admin/login" 2>"$case_directory/login-request.err") || {
            sed -n '1,120p' "$case_directory/login-request.err" >&2 || true
            sed -n '1,160p' "$stderr_file" >&2 || true
            fail "login page was not served after registration"
        }
        printf '%s\n' "$login_response" | grep -F 'name="login"' >/dev/null || fail "login page was incomplete"
        duplicate_register_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
            -H "Origin: http://127.0.0.1:$port" \
            --data 'display_name=Second+Owner&login=second%40example.test&password=correct+horse+battery+staple' \
            "http://127.0.0.1:$port/admin/register")
        [ "$duplicate_register_status" = "303" ] || fail "registration remained open after owner creation"
        editor_headers=$(curl --silent --dump-header - --output /dev/null "http://127.0.0.1:$port/admin/editor") || fail "protected editor request failed"
        printf '%s\n' "$editor_headers" | grep -F 'HTTP/1.1 303' >/dev/null || fail "editor route was not protected"
        printf '%s\n' "$editor_headers" | grep -F 'location: /admin/login' >/dev/null || fail "editor did not redirect to login"
        login_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
            -H "Origin: http://127.0.0.1:$port" \
            --data 'login=unknown%40example.test&password=wrong-password' \
            "http://127.0.0.1:$port/admin/login") || {
            sed -n '1,180p' "$stderr_file" >&2 || true
            fail "invalid local login request failed"
        }
        if [ "$login_status" != "401" ]; then
            sed -n '1,180p' "$stderr_file" >&2 || true
            fail "invalid local login did not fail generically (status $login_status)"
        fi
        editor_post_status=$(curl --silent --output "$case_directory/editor-post.body" --write-out '%{http_code}' -X POST "http://127.0.0.1:$port/admin/editor")
        [ "$editor_post_status" = "403" ] || fail "editor method did not enforce origin protection"
        grep -F '<h1>Forbidden</h1>' "$case_directory/editor-post.body" >/dev/null || fail "forbidden response was not the HTML error page"
        if grep -F 'Origin rejected' "$case_directory/editor-post.body" >/dev/null; then
            fail "forbidden response exposed the origin rejection reason"
        fi
    fi

    case "$shutdown_signal" in
        INT) kill -INT "$server_pid" ;;
        TERM) kill -TERM "$server_pid" ;;
        *) fail "unsupported shutdown signal: $shutdown_signal" ;;
    esac
    if wait "$server_pid"; then
        :
    else
        status=$?
        fail "server did not shut down cleanly (status $status)"
    fi
    server_pid=
}

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

dump_directory="$temporary_directory/dump-default"
mkdir "$dump_directory"
(
    cd "$dump_directory"
    env -i "PATH=${PATH:-/usr/bin:/bin}" "$binary" config dump-default >default.toml 2>stderr.log
)
grep -F '# Starter configuration generated by' "$dump_directory/default.toml" >/dev/null || fail "default config was not written"
[ ! -e "$dump_directory/data" ] || fail "dump-default created runtime state"
(
    cd "$dump_directory"
    env -i "PATH=${PATH:-/usr/bin:/bin}" "$binary" config env-reference >environment-reference.txt 2>environment-reference.stderr
)
grep -F 'VERSO_SERVER_PORT = server.port' "$dump_directory/environment-reference.txt" >/dev/null || fail "environment reference was not generated"

default_directory="$temporary_directory/built-in-defaults"
mkdir "$default_directory"
run_server \
    "$default_directory" \
    "$(free_port)" \
    "$default_directory/stdout.log" \
    "$default_directory/stderr.log" \
    TERM \
    true
test -f "$default_directory/data/verso.db" || fail "default server did not create database"
test -d "$default_directory/data/assets" || fail "default server did not create asset directory"
test -d "$default_directory/data/cache" || fail "default server did not create cache directory"
assert_log_contains "$default_directory/stderr.log" 'event="server.starting"'
assert_log_contains "$default_directory/stderr.log" 'event="server.listening"'
assert_log_contains "$default_directory/stderr.log" 'event="http.request"'
assert_log_contains "$default_directory/stderr.log" 'event="server.shutdown"'

file_directory="$temporary_directory/file-backed"
mkdir "$file_directory"
printf '%s\n' \
    '[site]' \
    'name = "File-backed publication"' \
    '' \
    '[server]' \
    'host = "127.0.0.1"' \
    'port = 8080' \
    '' \
    '[database]' \
    'url = "state/database/verso.db"' \
    '' \
    '[migrations]' \
    'run_on_startup = false' \
    '' \
    '[storage.filesystem]' \
    'path = "state/assets"' \
    '' \
    '[cache]' \
    'path = "state/cache"' \
    >"$file_directory/verso.toml"
run_server \
    "$file_directory" \
    "$(free_port)" \
    "$file_directory/stdout.log" \
    "$file_directory/stderr.log" \
    INT
test -f "$file_directory/state/database/verso.db" || fail "file-backed server ignored database path"
test -d "$file_directory/state/assets" || fail "file-backed server ignored asset path"
test -d "$file_directory/state/cache" || fail "file-backed server ignored cache path"
if grep -F 'event="migrations.loaded"' "$file_directory/stderr.log" >/dev/null; then
    fail "file-backed server ran disabled startup migrations"
fi

invalid_directory="$temporary_directory/invalid-config"
mkdir "$invalid_directory"
printf '%s\n' '[server]' 'port = 0' >"$invalid_directory/verso.toml"
if (
    cd "$invalid_directory"
    env -i "PATH=${PATH:-/usr/bin:/bin}" "$binary" serve >stdout.log 2>stderr.log
); then
    fail "invalid configuration was accepted"
fi
assert_log_contains "$invalid_directory/stderr.log" 'event="configuration.failed"'

blocked_directory="$temporary_directory/blocked-path"
mkdir "$blocked_directory"
printf '%s\n' 'not a directory' >"$blocked_directory/blocked"
printf '%s\n' '[database]' 'url = "blocked/verso.db"' >"$blocked_directory/verso.toml"
if (
    cd "$blocked_directory"
    env -i "PATH=${PATH:-/usr/bin:/bin}" "$binary" serve >stdout.log 2>stderr.log
); then
    fail "unusable configured path was accepted"
fi
assert_log_contains "$blocked_directory/stderr.log" 'event="server.startup_failed"'
assert_log_contains "$blocked_directory/stderr.log" 'stage="directories"'

echo "bootstrap verification passed"
