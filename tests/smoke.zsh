#!/usr/bin/env zsh
# Smoke test for qb.zsh. Read-only: never starts, stops or recreates anything.
# Uses a temporary .env file, so the real .env.qbittorrent is never read.
#
# Usage: zsh tests/smoke.zsh

emulate -L zsh
setopt pipe_fail

REPO="${${(%):-%x}:A:h:h}"
QB="$REPO/qb.zsh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/qb-smoke.XXXXXX")" || exit 1
ENV_FILE="$TMP/test.env"
LISTENER_PID=""

cleanup() {
    [[ -n "$LISTENER_PID" ]] && kill "$LISTENER_PID" 2>/dev/null
    [[ -n "$TMP" && -d "$TMP" && "$TMP" == */qb-smoke.* ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM

typeset -i passed=0 failed=0 skipped=0

pass() { passed+=1; printf '  ok    %s\n' "$1"; }
fail() { failed+=1; printf '  FAIL  %s\n' "$1"; [[ -n "$2" ]] && printf '        %s\n' "${(@f)2}"; }
skip() { skipped+=1; printf '  skip  %s\n' "$1"; }

# Run zsh code with qb.zsh sourced against the temporary env file.
# Prints combined output; exit status is the snippet's.
qbrun() {
    (cd / && zsh -f -c "
        source ${(q)QB} || exit 99
        QB_API_KEY_FILE=${(q)ENV_FILE}
        emulate -L zsh
        $1
    " 2>&1)
}

expect_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$got" == "$want" ]]; then
        pass "$name"
    else
        fail "$name" "want: $want"$'\n'"got:  $got"
    fi
}

# zsh errors that mean a code bug rather than an expected failure.
has_shell_error() {
    [[ "$1" == *"command not found"* || "$1" == *"parse error"* ||
       "$1" == *"bad substitution"* || "$1" == *"bad math expression"* ||
       "$1" == *"no such file or directory: _qb"* ]]
}

printf 'qb smoke test\n\n'

# 1. Syntax and loading ------------------------------------------------------
printf 'Syntax and loading\n'

if zsh -n "$QB" 2>"$TMP/syntax.err"; then
    pass "qb.zsh parses (zsh -n)"
else
    fail "qb.zsh parses (zsh -n)" "$(<"$TMP/syntax.err")"
fi

: > "$ENV_FILE"
out="$(qbrun 'print -r -- "$QB_DIR"')"
expect_eq "QB_DIR resolves to the repo" "$REPO" "$out"

out="$(qbrun 'qb help')"; rc=$?
if (( rc == 0 )) && [[ "$out" == *"qb start"* ]]; then
    pass "qb help exits 0"
else
    fail "qb help exits 0" "rc=$rc"$'\n'"$out"
fi

out="$(qbrun 'qb no-such-command')"; rc=$?
if (( rc == 1 )) && [[ "$out" == *"Unknown command"* ]]; then
    pass "unknown command exits 1"
else
    fail "unknown command exits 1" "rc=$rc"$'\n'"$out"
fi

# 2. Command lists stay in sync ----------------------------------------------
printf '\nCommand lists\n'

# Dispatcher: case labels inside qb() { ... }.
dispatch=(${(f)"$(
    awk '/^qb\(\) \{/ {f=1} f && /^}/ {f=0} f' "$QB" |
        sed -nE 's/^        ([a-z]+)(\|[^)]*)?\)$/\1/p' | sort -u
)"})
# Completion: words in commands=( ... ) inside _qb_complete.
complete=(${(f)"$(
    awk '/^_qb_complete\(\)/ {f=1} f && /^    \)/ {f=0} f' "$QB" |
        sed -n '/commands=(/,$p' | sed '1d' | tr -s ' ' '\n' | grep -E '^[a-z]+$' | sort -u
)"})
# Help text: "  qb <command>" lines in _qb_help.
helpcmds=(${(f)"$(
    awk '/^_qb_help\(\)/ {f=1} f && /^}/ {f=0} f' "$QB" |
        sed -nE 's/^ *"  qb ([a-z]+).*/\1/p' | sort -u
)"})
helpcmds+=(help)
helpcmds=(${(u)helpcmds})
# README command table: "| `qb <command>" rows.
readme=(${(f)"$(sed -nE 's/^\| `qb ([a-z]+).*/\1/p' "$REPO/README.md" | sort -u)"})

compare_lists() {
    local name="$1"; shift
    local -a a b
    a=(${(s: :)1}); b=(${(s: :)2})
    local -a only_a=(${a:|b}) only_b=(${b:|a})
    if (( ${#only_a} == 0 && ${#only_b} == 0 )); then
        pass "$name"
    else
        fail "$name" "missing from ${name##*= }: ${only_a:-none}"$'\n'"not in dispatcher: ${only_b:-none}"
    fi
}

if (( ${#dispatch} < 10 )); then
    fail "dispatcher commands found" "only ${#dispatch}: $dispatch"
else
    pass "dispatcher commands found (${#dispatch})"
    compare_lists "dispatcher = completion" "$dispatch" "$complete"
    compare_lists "dispatcher = help text"  "$dispatch" "$helpcmds"
    compare_lists "dispatcher = README table" "$dispatch" "$readme"
fi

# 3. .env parsing --------------------------------------------------------------
printf '\nSettings from .env.qbittorrent\n'

printf 'QB_STYLE=bare\r\n  QB_TZ = "Europe/Berlin"  \nQBIT_API_KEY='"'"'k3y'"'"'\nQB_STYLE=emoji\nQB_EMPTY=\n' > "$ENV_FILE"
expect_eq "_qb_env_get: last assignment wins" "emoji" "$(qbrun '_qb_env_get QB_STYLE')"
expect_eq "_qb_env_get: spaces and quotes stripped" "Europe/Berlin" "$(qbrun '_qb_env_get QB_TZ')"
expect_eq "_qb_env_get: single quotes stripped" "k3y" "$(qbrun '_qb_env_get QBIT_API_KEY')"
qbrun '_qb_env_get QB_EMPTY' >/dev/null
expect_eq "_qb_env_get: empty value returns 1" "1" "$?"
qbrun '_qb_env_get QB_MISSING' >/dev/null
expect_eq "_qb_env_get: missing key returns 1" "1" "$?"

print -r -- 'QB_DOWNLOADS=~/qb-smoke-dl' > "$ENV_FILE"
expect_eq "QB_DOWNLOADS expands ~/" "$HOME/qb-smoke-dl" "$(qbrun '_qb_refresh_downloads; print -r -- $QB_DOWNLOADS')"
: > "$ENV_FILE"
expect_eq "QB_DOWNLOADS default" "$HOME/Downloads/qbittorrent-downloads" \
    "$(qbrun '_qb_refresh_downloads; print -r -- $QB_DOWNLOADS')"

printf 'QB_WEBUI_PORT=9191\nQB_WEBUI_BIND=lan\n' > "$ENV_FILE"
expect_eq "QB_WEBUI_PORT and bind" "9191 http://localhost:9191 0.0.0.0:9191" \
    "$(qbrun '_qb_refresh_webui_bind; print -r -- "$QB_WEBUI_PORT $QB_URL $QB_WEBUI_PUBLISH"')"
print -r -- 'QB_WEBUI_PORT=abc' > "$ENV_FILE"
expect_eq "invalid QB_WEBUI_PORT falls back to 8090" "8090 127.0.0.1:8090" \
    "$(qbrun '_qb_refresh_webui_bind; print -r -- "$QB_WEBUI_PORT $QB_WEBUI_PUBLISH"')"

printf 'QB_PUID=1234\nQB_PGID=x\nQB_TZ=Asia/Tokyo\n' > "$ENV_FILE"
expect_eq "QB_PUID/QB_PGID/QB_TZ (invalid PGID falls back)" "1234 $(id -g) Asia/Tokyo" \
    "$(qbrun '_qb_refresh_container_env; print -r -- "$QB_PUID $QB_PGID $QB_TZ"')"

# 4. Port owner detection ---------------------------------------------------
printf '\nPort owner detection\n'
: > "$ENV_FILE"

port=18555
if ! command -v python3 >/dev/null; then
    skip "port owner (python3 not found)"
elif lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    skip "port owner (port $port already in use)"
else
    mkdir -p "$TMP/www"
    python3 -m http.server "$port" --bind 127.0.0.1 --directory "$TMP/www" >/dev/null 2>&1 &
    LISTENER_PID=$!
    for _ in {1..20}; do
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 0.1
    done

    out="$(qbrun "QB_WEBUI_PORT=$port; _qb_refresh_webui_bind; _qb_require_port_free")"; rc=$?
    if (( rc == 1 )) && [[ "$out" == *"in use by python"* ]]; then
        pass "taken port is reported with its process"
    else
        fail "taken port is reported with its process" "rc=$rc"$'\n'"$out"
    fi

    kill "$LISTENER_PID" 2>/dev/null; wait "$LISTENER_PID" 2>/dev/null; LISTENER_PID=""

    qbrun "QB_WEBUI_PORT=$port; _qb_refresh_webui_bind; _qb_require_port_free" >/dev/null
    expect_eq "free port passes" "0" "$?"
fi

# 5. Compose error output (fake docker; nothing real runs) --------------------
printf '\nCompose error output\n'

out="$(qbrun '
    docker() { print "progress"; print ""; print "Error: bind: address already in use" >&2; return 1; }
    if ! _qb_compose up -d; then _qb_compose_error; fi
')"
expect_eq "failure shows output incl. stderr, blank lines dropped" \
    "    progress"$'\n'"    Error: bind: address already in use" "$out"

out="$(qbrun '
    docker() { for i in {1..12}; do print "line $i"; done; return 1; }
    _qb_compose pull || _qb_compose_error
')"
expect_eq "long output is cut to the last 8 lines" "8 line 5 line 12" \
    "$(print -r -- "${#${(f)out}} ${${(f)out}[1]##    } ${${(f)out}[-1]##    }")"

out="$(qbrun 'docker() { print "noisy"; return 0; }; _qb_compose up -d && print -r -- "rc=0"')"
expect_eq "success prints nothing" "rc=0" "$out"

# 6. Read-only commands against the real Docker state -----------------------
printf '\nRead-only commands\n'

for cmd in status doctor; do
    out="$(qbrun "qb $cmd")"; rc=$?
    if has_shell_error "$out"; then
        fail "qb $cmd runs without shell errors" "$out"
    elif (( rc > 1 )); then
        fail "qb $cmd exits 0 or 1" "rc=$rc"
    else
        pass "qb $cmd runs (rc=$rc)"
    fi
done

if docker info >/dev/null 2>&1; then
    skip "stack-down guard (Docker is running)"
else
    out="$(qbrun 'qb torrents')"; rc=$?
    if (( rc == 1 )) && [[ "$out" == *"qb start"* ]]; then
        pass "qb torrents fails fast with 'Run: qb start' when Docker is down"
    else
        fail "qb torrents fails fast with 'Run: qb start' when Docker is down" "rc=$rc"$'\n'"$out"
    fi
fi

# Summary ---------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
(( failed == 0 ))
