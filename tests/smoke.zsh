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

: > "$ENV_FILE"
zone="$(readlink /etc/localtime 2>/dev/null)"
[[ "$zone" == */zoneinfo/* ]] && zone="${zone#*/zoneinfo/}" || zone="Etc/UTC"
expect_eq "PUID/PGID/TZ defaults: id -u, id -g, system timezone" "$(id -u) $(id -g) $zone" \
    "$(qbrun '_qb_refresh_container_env; print -r -- "$QB_PUID $QB_PGID $QB_TZ"')"

# 3b. compose.yaml uses what qb exports (docker compose config; no daemon needed)
printf '\ncompose.yaml uses qb settings\n'

# Sorted key=value summary: env WEBUI_PORT PUID PGID TZ, plus the WebUI port
# mapping (the first ports entry; host_ip appears only on that one).
compose_summary() {
    awk '
        { gsub(/"/, "") }
        $1 ~ /^(WEBUI_PORT|PUID|PGID|TZ):$/ { sub(/:$/, "", $1); print $1 "=" $2 }
        $1 == "host_ip:"                    { print "host_ip=" $2 }
        $1 == "target:"    && !t++          { print "target=" $2 }
        $1 == "published:" && !p++          { print "published=" $2 }
    ' | sort | tr '\n' ' '
}

if ! docker compose version >/dev/null 2>&1; then
    skip "compose rendering (docker compose not available)"
else
    printf 'QB_WEBUI_PORT=9191\nQB_WEBUI_BIND=lan\nQB_PUID=1234\nQB_PGID=4321\nQB_TZ=Asia/Tokyo\nQB_DOWNLOADS=%s\n' \
        "$TMP" > "$ENV_FILE"
    out="$(qbrun "
        _qb_refresh_downloads; _qb_refresh_container_env; _qb_refresh_webui_bind
        docker compose --project-directory ${(q)REPO} -f ${(q)REPO}/compose.yaml config
    " | compose_summary)"
    expect_eq "settings from qb reach the container" \
        "PGID=4321 PUID=1234 TZ=Asia/Tokyo WEBUI_PORT=9191 host_ip=0.0.0.0 published=9191 target=9191 " "$out"

    out="$(cd / && env -u QB_WEBUI_PORT -u QB_WEBUI_PUBLISH -u QB_PUID -u QB_PGID -u QB_TZ -u QB_DOWNLOADS \
        docker compose --project-directory "$REPO" -f "$REPO/compose.yaml" config 2>&1 | compose_summary)"
    expect_eq "compose fallbacks without qb" \
        "PGID=20 PUID=501 TZ=Etc/UTC WEBUI_PORT=8090 host_ip=127.0.0.1 published=8090 target=8090 " "$out"
fi

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

# Container cases, with a fake docker that reports who publishes the port.
port_container_run() {
    qbrun "
        _qb_port_listening() { return 0; }
        _qb_docker_running() { return 0; }
        docker() { [[ \$1 == ps ]] && print -r -- ${(q)1}; }
        _qb_refresh_webui_bind
        print -r -- \"owner=\$(_qb_port_owner)\"
        _qb_port_conflict >/dev/null && print conflict || print no-conflict
    "
}
expect_eq "another container on the port is named and is a conflict" \
    "owner=container meuwic-web"$'\n'"conflict" "$(port_container_run meuwic-web)"
expect_eq "the qbittorrent container itself is not a conflict" \
    "owner=container qbittorrent"$'\n'"no-conflict" "$(port_container_run qbittorrent)"

# start / repair stop before compose when the port is taken (fake docker logs calls).
print -r -- "QB_DOWNLOADS=$TMP/dl" > "$ENV_FILE"
port_guard_run() {
    : > "$TMP/calls"
    qbrun "
        CALLS=${(q)TMP}/calls
        _qb_docker_running() { return 0; }
        _qb_container_running() { return 1; }
        _qb_container_exists() { return 1; }
        _qb_port_conflict() { print 'container meuwic-web'; }
        _qb_spinner() { :; }
        docker() { print -r -- \"\$*\" >> \$CALLS; return 0; }
        $1
        print -r -- \"rc=\$? compose-calls=\$(grep -c compose \$CALLS)\"
    "
}
out="$(port_guard_run 'qb start --cli')"
if [[ "$out" == *"Port 8090 is in use by container meuwic-web"* && "$out" == *"rc=1 compose-calls=0" ]]; then
    pass "qb start stops before compose when the port is taken"
else
    fail "qb start stops before compose when the port is taken" "$out"
fi
out="$(port_guard_run 'qb repair')"
if [[ "$out" == *"Port 8090 is in use by container meuwic-web"* && "$out" == *"rc=1 compose-calls=0" ]]; then
    pass "qb repair stops before compose when the port is taken"
else
    fail "qb repair stops before compose when the port is taken" "$out"
fi

# qb is a shell function: lifecycle commands must not change the caller's
# directory, and compose must be pointed at the repo explicitly.
: > "$ENV_FILE"
out="$(qbrun "
    _qb_docker_running() { return 0; }; _qb_container_running() { return \$RUNNING; }
    _qb_container_exists() { return 1; }; _qb_require_port_free() { return 0; }
    _qb_webui_ready() { return 0; }; _qb_wait_for_webui() { return 0; }; _qb_image_age_notice() { :; }
    _qb_present_webui() { :; }; _qb_close_app() { :; }; _qb_other_containers() { :; }; _qb_spinner() { :; }
    _qb_quit_lock_acquire() { return 0; }; _qb_quit_lock_release() { :; }
    docker() { [[ \$1 == compose ]] && print -r -- \"\$*\" >> ${(q)TMP}/dc-calls; return 0; }
    : > ${(q)TMP}/dc-calls
    cd ${(q)TMP}
    RUNNING=1; qb start --cli >/dev/null 2>&1
    RUNNING=0; qb quit >/dev/null 2>&1; qb restart >/dev/null 2>&1
    RUNNING=1; qb repair >/dev/null 2>&1
    print -r -- \"pwd=\$PWD\"
    print -r -- \"compose-calls=\$(grep -c . ${(q)TMP}/dc-calls) with-project=\$(grep -c -- '--project-directory ${REPO} -f ${REPO}/compose.yaml' ${(q)TMP}/dc-calls)\"
")"
if [[ "$out" == "pwd=${TMP:a}"$'\n'"compose-calls=4 with-project=4" ]]; then
    pass "start / quit / restart / repair leave the shell's directory alone"
else
    fail "start / quit / restart / repair leave the shell's directory alone" "$out"
fi

# _qb_await_webui: shared by start / restart / update / repair.
await_run() {
    qbrun "_qb_spinner() { :; }; _qb_wait_for_webui() { print -n \"wait=\$1 \"; return $1; }
           _qb_await_webui; print \" rc=\$?\"" | sed -E $'s/\r//g; s/\e\\[2K//g' | tr '\n' ' ' | sed 's/  */ /g; s/ $//'
}
expect_eq "await WebUI: ready"   "wait=60 ✓ WebUI ready rc=0" "$(await_run 0)"
expect_eq "await WebUI: timeout" "wait=60 X WebUI did not become available rc=1" "$(await_run 1)"

# _qb_ensure_docker: shared by start / repair.
ensure_run() {
    qbrun "_qb_spinner() { :; }; _qb_docker_running() { return $1; }
           _qb_wait_for_docker() { return 0; }
           : > ${(q)TMP}/docker-calls
           docker() { print -r -- \"[docker \$*]\" >> ${(q)TMP}/docker-calls; return $2; }
           _qb_ensure_docker; rc=\$?
           print -r -- \"\$(<${(q)TMP}/docker-calls) rc=\$rc\"" 2>&1 | sed -E $'s/\r//g; s/\e\\[2K//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}
expect_eq "ensure Docker: already running, nothing to do" "rc=0" "$(ensure_run 0 0)"
expect_eq "ensure Docker: stopped, starts Docker Desktop" "✓ Docker Desktop started [docker desktop start] rc=0" "$(ensure_run 1 0)"
expect_eq "ensure Docker: start fails" "X Failed to start Docker Desktop [docker desktop start] rc=1" "$(ensure_run 1 1)"

# qb start --cli / --app win over QB_START_UI in .env.qbittorrent.
start_ui_run() {
    print -r -- "QB_START_UI=$1" > "$ENV_FILE"
    qbrun "
        _qb_docker_running() { return 0; }; _qb_container_running() { return 0; }
        _qb_downloads_mount_matches() { return 0; }; _qb_webui_publish_matches() { return 0; }
        _qb_webui_ready() { return 0; }; _qb_image_age_notice() { :; }
        _qb_open_app() { print OPENED-APP; }
        qb start $2 | grep -qE OPENED-APP && print app || print cli
    "
}
expect_eq "qb start --cli beats QB_START_UI=app" "cli" "$(start_ui_run app --cli)"
expect_eq "qb start --app beats QB_START_UI=cli" "app" "$(start_ui_run cli --app)"
expect_eq "qb start without a flag follows QB_START_UI=cli" "cli" "$(start_ui_run cli '')"

# doctor with Docker stopped: container unknown, port owner shown.
: > "$ENV_FILE"
out="$(qbrun '
    _qb_docker_running() { return 1; }
    _qb_container_exists() { return 1; }
    _qb_container_running() { return 1; }
    _qb_port_conflict() { print "python3 (pid 42)"; }
    docker() { return 1; }
    qb doctor
')"
if [[ "$out" == *"Container: unknown (Docker stopped)"* && "$out" != *"Container: missing"* ]]; then
    pass "doctor: container unknown (not missing) when Docker is stopped"
else
    fail "doctor: container unknown (not missing) when Docker is stopped" "$out"
fi
if [[ "$out" == *"Port 8090: in use by python3 (pid 42) (qb start will fail)"* ]]; then
    pass "doctor: names the process holding the WebUI port"
else
    fail "doctor: names the process holding the WebUI port" "$out"
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

# 6. qb repair pull-and-retry (fake docker; nothing real runs) ---------------
printf '\nRepair retry\n'

repair_run() {
    : > "$TMP/calls"
    qbrun "
        MODE=$1; CALLS=${(q)TMP}/calls
        _qb_docker_running() { return 0; }
        _qb_container_running() { return 1; }
        _qb_container_exists() { return 1; }
        _qb_require_port_free() { return 0; }
        _qb_wait_for_webui() { return 0; }
        _qb_present_webui() { :; }
        _qb_spinner() { :; }
        docker() {
            # Drop qb's --project-directory DIR -f FILE so calls read as 'compose <cmd>'.
            [[ \$1 == compose && \$2 == --project-directory ]] && set -- compose \"\${@:6}\"
            print -r -- \"\$*\" >> \$CALLS
            case \"\$*\" in
                'compose pull') [[ \$MODE == pullfail ]] && return 1; return 0 ;;
                'compose up -d --force-recreate')
                    (( \$(grep -c 'compose up' \$CALLS) >= 2 )) && [[ \$MODE == retryok ]] && return 0
                    print 'No such image' >&2; return 1 ;;
            esac
            return 0
        }
        qb repair >/dev/null
        print -r -- \"rc=\$? \${(j:|:)\${(f)\"\$(<\$CALLS)\"}}\"
    "
}

expect_eq "recreate fails, pull + retry succeeds" \
    "rc=0 rm -f qbittorrent|compose up -d --force-recreate|compose pull|compose up -d --force-recreate" \
    "$(repair_run retryok)"
expect_eq "pull fails: stop without a second recreate" \
    "rc=1 rm -f qbittorrent|compose up -d --force-recreate|compose pull" \
    "$(repair_run pullfail)"

# 7. qb_json.py formatters, called through qb.zsh (fixtures; nothing real runs)
printf '\nJSON formatters (qb_json.py)\n'

FIX="$REPO/tests/fixtures"
# Stub the API with fixture files; then run a qb.zsh formatter function.
fmt_run() {
    qbrun "
        F=${(q)FIX}
        _qb_require_stack() { return 0; }; _qb_require_api() { return 0; }
        _qb_api_curl() {
            case \$1 in
                /api/v2/transfer/info) cat \$F/transfer.json ;;
                /api/v2/transfer/speedLimitsMode) print 1 ;;
                /api/v2/torrents/properties*) cat \$F/properties.json ;;
                /api/v2/torrents/files*) cat \$F/files.json ;;
                /api/v2/search/plugins) cat \$F/plugins.json ;;
            esac
        }
        _qb_torrents_info() { cat \$F/torrents.json; }
        $1
    "
}

expect_eq "torrents list matches expected output" "$(<"$FIX/torrents.expected.txt")" "$(fmt_run _qb_torrents_print)"
expect_eq "empty torrent list" "No torrents." "$(fmt_run '_qb_torrents_info() { print "[]"; }; _qb_torrents_print')"
out="$(fmt_run '_qb_torrents_info() { print "not json"; }; _qb_torrents_print; print "rc=$?"')"
if [[ "$out" == "Failed to parse qBittorrent response:"*"rc=1" ]]; then
    pass "invalid torrents JSON: error and rc=1"
else
    fail "invalid torrents JSON: error and rc=1" "$out"
fi

# --json: stdout is the API JSON only; messages go to stderr.
expect_eq "torrents --json: API JSON, filter passed" "4 a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 filter=seeding" \
    "$(fmt_run '_qb_torrents_info() { print -r -- "filter=$1" > '"${(q)TMP}"'/filter; cat $F/torrents.json; }
                qb torrents --json --seeding 2>/dev/null | python3 -I -c "import json,sys; d=json.load(sys.stdin); print(len(d), d[0][\"hash\"], end=\" \")"
                cat '"${(q)TMP}"'/filter')"
expect_eq "torrents --json: empty list is []" "[]" "$(fmt_run '_qb_torrents_info() { print "[]"; }; qb torrents --json')"
expect_eq "torrents --json: API failure keeps stdout empty, rc=1" "rc=1" \
    "$(fmt_run '_qb_torrents_info() { return 1; }; qb torrents --json 2>/dev/null; print "rc=$?"')"
expect_eq "torrents --json with --watch is refused" "rc=1" "$(fmt_run 'qb torrents --watch --json 2>/dev/null; print "rc=$?"')"
expect_eq "show --json: hash, properties, all files" "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678 /downloads/ 45" \
    "$(fmt_run '_qb_resolve_hashes() { print -r -- a1b2c3d4e5f60718293a4b5c6d7e8f9012345678; }; qb show a1b2 --json 2>/dev/null' |
       python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["hash"], d["properties"]["save_path"], len(d["files"]))')"

expect_eq "transfer line" "→ Transfer: ↓7.0 MiB/s  ↑50.0 KiB/s  alt-limits=on" "$(fmt_run _qb_transfer_print)"

out="$(fmt_run '_qb_resolve_hashes() { print -r -- $1; }; _qb_show a1b2c3d4')"
if [[ "${${(f)out}[1]}" == "ubuntu-24.04.1-desktop-amd64.iso" && "$out" == *"  ratio: 0.040  added: "* &&
      "$out" == *"  files (45):"* && "$out" == *"    … 5 more" && ${#${(f)out}} -eq 50 ]]; then
    pass "show: properties, ratio, first 40 of 45 files"
else
    fail "show: properties, ratio, first 40 of 45 files" "$out"
fi

out="$(fmt_run _qb_plugins_list)"
if [[ "${${(f)out}[3]}" == "Academictorrents  off      1.2      Academic Torrents  https://academictorrents.com/very/long/path/tha…" &&
      "${${(f)out}[4]}" == "eztv              on       1.16     EZTV               https://eztvx.to"* ]]; then
    pass "plugins table: sorted, URL truncated"
else
    fail "plugins table: sorted, URL truncated" "$out"
fi

expect_eq "image age: old timestamp gives a day count" "yes" \
    "$(qbrun '_qb_kept_image_id() { print x; }; docker() { print 2020-01-01T00:00:00.123456789Z; }
              d=$(_qb_image_age_days) && (( d > 365 )) && print yes')"
qbrun '_qb_kept_image_id() { print x; }; docker() { print garbage; }; _qb_image_age_days' >/dev/null
expect_eq "image age: unparseable timestamp returns 1" "1" "$?"

# images runs docker itself from Python: put a fake docker first on PATH.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/bin/sh
case "$*" in
    "images --filter reference=*qbittorrent* --format {{json .}}")
        echo '{"ID":"sha256:aaaaaaaaaaaa1111","Repository":"lscr.io/linuxserver/qbittorrent","Tag":"latest","CreatedSince":"3 weeks ago"}' ;;
    "images -f dangling=true -q") echo "cccccccccccc" ;;
    "image inspect cccccccccccc --format {{json .Config.Labels}}") echo '{"title":"qbittorrent"}' ;;
    "image inspect sha256:aaaaaaaaaaaa1111 --format {{.Size}}") echo 214748364 ;;
    "image inspect cccccccccccc --format {{.Size}}") echo 1536 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/docker"
out="$(PATH="$TMP/bin:$PATH" qbrun '_qb_require_docker() { return 0; }; _qb_images')"
if [[ "$out" == *"latest           aaaaaaaaaaaa  204.8 MiB  3 weeks ago"* &&
      "$out" == *"<none>           cccccccccccc    1.5 KiB  dangling"* && "$out" == *"Images: 2 unique"* ]]; then
    pass "images: tagged + dangling rows and totals"
else
    fail "images: tagged + dangling rows and totals" "$out"
fi

expect_eq "active download count" "4" "$(fmt_run '_qb_active_download_count "$(<$F/torrents.json)"')"
expect_eq "active download count, bad JSON gives -1" "-1" "$(fmt_run '_qb_active_download_count garbage')"

expect_eq "resolve ids: hash prefix, name (any case), several at once" \
    "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678|0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c" \
    "$(fmt_run '_qb_resolve_hashes a1b2 DEBIAN')"
out="$(fmt_run '_qb_resolve_hashes iso 2>&1; print "rc=$?"')"
if [[ "$out" == "Ambiguous id: iso"*"a1b2c3d4  ubuntu"*"0f1e2d3c  debian"*"rc=1" ]]; then
    pass "resolve ids: ambiguous id lists the matches, rc=1"
else
    fail "resolve ids: ambiguous id lists the matches, rc=1" "$out"
fi
expect_eq "resolve ids: no match" "No torrent matches: zzz rc=1" \
    "$(fmt_run '_qb_resolve_hashes zzz 2>&1; print "rc=$?"' | tr '\n' ' ' | sed 's/ $//')"

# pause / resume / recheck / reannounce share _qb_torrent_action: check each
# command hits its own endpoint with the resolved hashes and prints its message.
action_run() {
    qbrun "
        _qb_require_stack() { return 0; }; _qb_require_api() { return 0; }
        _qb_resolve_hashes() { print -r -- \"\${(j:|:)@}\"; }
        _qb_api_post() { print -r -- \"\$1 \$3\" >> ${(q)TMP}/posts; [[ -z \$FAIL ]]; }
        : > ${(q)TMP}/posts
        FAIL=$2; qb $1 a1b2 debian
        print -r -- \"rc=\$? post=\$(<${(q)TMP}/posts)\"
    " | sed -E $'s/^\r//; s/^\e\\[2K//; s/^(✓|X|■|→) //'
}
expect_eq "qb pause: stop endpoint, message"      "Paused rc=0 post=/api/v2/torrents/stop hashes=a1b2|debian" \
    "$(action_run pause '' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "qb resume: start endpoint, message"    "Resumed rc=0 post=/api/v2/torrents/start hashes=a1b2|debian" \
    "$(action_run resume '' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "qb recheck: recheck endpoint, message" "Recheck started rc=0 post=/api/v2/torrents/recheck hashes=a1b2|debian" \
    "$(action_run recheck '' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "qb reannounce: endpoint, message"      "Reannounce sent rc=0 post=/api/v2/torrents/reannounce hashes=a1b2|debian" \
    "$(action_run reannounce '' | tr '\n' ' ' | sed 's/ $//')"
expect_eq "torrent action: API failure message and rc=1" "Failed to resume torrent(s)" \
    "$(action_run resume 1 | head -n 1)"
expect_eq "torrent action: usage without an id" "Usage: qb recheck <hash-or-name>… rc=1" \
    "$(qbrun '_qb_require_stack() { return 0; }; _qb_require_api() { return 0; }; qb recheck; print "rc=$?"' | tr '\n' ' ' | sed 's/ $//')"

# All Python lives in qb_json.py; qb.zsh pipes JSON to it on stdin.
expect_eq "no embedded Python left in qb.zsh" "0" "$(grep -c "python3 - " "$QB")"

# Large responses: JSON goes to Python on stdin, not argv (ARG_MAX is 1 MiB on macOS).
python3 -I -c 'import json; print(json.dumps([{"name": "t%05d-%s" % (i, "x" * 120), "hash": "%040x" % i,
    "state": "stalledUP", "progress": 1, "size": 1 << 30, "tracker": "udp://tracker.example.org:1337/announce",
    "magnet_uri": "magnet:?xt=urn:btih:%040x" % i} for i in range(4000)]))' > "$TMP/big.json"
out="$(qbrun "_qb_torrents_info() { cat ${(q)TMP}/big.json; }; _qb_torrents_print | wc -l | tr -d ' '")"
expect_eq "2 MB torrent list (over ARG_MAX) prints all 4000 torrents" "8000" "$out"

# 7b. Search (qb_json.py search-*), through qb.zsh with a stubbed API -------
printf '\nSearch\n'

search_run() {
    qbrun "
        F=${(q)FIX}
        _qb_require_stack() { return 0; }; _qb_require_api() { return 0; }
        _qb_spinner() { :; }
        _qb_add() { print -r -- \"ADD: \$1\"; }
        _qb_api_post() { [[ \$1 == /api/v2/search/start ]] && print '{\"id\":7}'; }
        _qb_api_curl() {
            case \$1 in
                /api/v2/search/plugins) cat \$F/plugins.json ;;
                /api/v2/search/status*) print '[{\"id\":7,\"status\":\"Stopped\"}]' ;;
                /api/v2/search/results*) cat \$F/search-results.json ;;
            esac
        }
        S=\"\$(_qb_search_sort_json \"\$(<\$F/search-results.json)\")\"
        $1
    " </dev/null
}

expect_eq "enabled plugin count" "1" "$(search_run _qb_search_enabled_count)"
expect_eq "results sorted by seeds, desc" "1000 963 926" \
    "$(search_run 'print -r -- "$S" | python3 -c "import json,sys; print(*[int(r[\"nbSeeders\"] or 0) for r in json.load(sys.stdin)[:3]])"')"

out="$(search_run '_qb_search_print_page "$S" 0 10 80 Running')"
if [[ "${${(f)out}[1]}" == "Results: 24  page 1/3  [Running]" && ${#${(f)out}} -eq 13 &&
      "$out" == *" 7  Debian 12.6 netinst amd64 ISO            ?    778     18  archive.example.n…"* ]]; then
    pass "results page: header, 10 rows, unknown size shows ?"
else
    fail "results page: header, 10 rows, unknown size shows ?" "$out"
fi
out="$(search_run '_qb_search_print_page "$S" 0 10 80 ""
    print -r -- "[{\"fileName\":\"big\",\"fileSize\":1099404206489,\"nbSeeders\":1}]" > '"${(q)TMP}"'/big-row.json
    _qb_search_print_page "$(<'"${(q)TMP}"'/big-row.json)" 0 10 80 ""')"
if [[ "$out" == *"   300.0 MiB   1000"* && "$out" == *"  1023.9 GiB      1"* ]]; then
    pass "SIZE column shows full sizes (300.0 MiB, 1023.9 GiB)"
else
    fail "SIZE column shows full sizes (300.0 MiB, 1023.9 GiB)" "$out"
fi
expect_eq "page past the end is clamped to the last page" "Results: 24  page 3/3" \
    "$(search_run '_qb_search_print_page "$S" 99 10 80 ""' | head -n 1)"

expect_eq "pick result #2" "magnet:?xt=urn:btih:0000000000000000000000000000000000000001&dn=debian-1" \
    "$(search_run '_qb_search_url_at "$S" 2')"
expect_eq "pick out-of-range result" "No result #99 (have 24)" "$(search_run '_qb_search_url_at "$S" 99 2>&1')"

out="$(search_run '_qb_search --add 2 debian iso; print "rc=$?"')"
if [[ "$out" == *"Search finished"* && "$out" == *"ADD: magnet:?xt=urn:btih:0000000000000000000000000000000000000001&dn=debian-1"* ]]; then
    pass "qb search --add 2: full flow adds the second result"
else
    fail "qb search --add 2: full flow adds the second result" "$out"
fi

# Search job cleanup: which stop / delete calls each path makes.
cleanup_run() {
    qbrun "
        F=${(q)FIX}; LOG=${(q)TMP}/search-posts; : > \$LOG
        _qb_require_stack() { return 0; }; _qb_require_api() { return 0; }; _qb_spinner() { :; }
        _qb_api_post() { print -r -- \"\${1##*/} \$3\" >> \$LOG; [[ \$1 == */start ]] && print '{\"id\":42}'; return 0; }
        _qb_api_curl() {
            case \$1 in
                */plugins) cat \$F/plugins.json ;;
                */status*) print '[{\"status\":\"$1\"}]' ;;
                */results*) [[ $2 == fetchfail ]] && return 1; cat \$F/search-results.json ;;
            esac
        }
        _qb_search --timeout 1 debian >/dev/null 2>&1
        print -r -- \"rc=\$? \$(grep -v '^start' \$LOG | tr '\n' ';')\"
    " </dev/null
}
expect_eq "search cleanup: finished job is deleted" "rc=0 delete id=42;" "$(cleanup_run Stopped ok)"
expect_eq "search cleanup: timed-out job is stopped, then deleted" "rc=0 stop id=42;delete id=42;" "$(cleanup_run Running ok)"
expect_eq "search cleanup: failed results fetch stops and deletes" "rc=1 stop id=42;delete id=42;" "$(cleanup_run Stopped fetchfail)"

# 7c. Pre-commit hook (.githooks/pre-commit), with stand-in git and zsh ----
printf '\nPre-commit hook\n'

HOOK="$REPO/.githooks/pre-commit"
if [[ -x "$HOOK" ]] && sh -n "$HOOK" 2>/dev/null; then
    pass "hook is executable and parses (sh -n)"
else
    fail "hook is executable and parses (sh -n)" "$HOOK"
fi
# Fake git lists one staged path; fake zsh stands in for the smoke run.
mkdir -p "$TMP/hookbin"
print -r -- '#!/bin/sh
printf "%s\n" "$STAGED"' > "$TMP/hookbin/git"
print -r -- '#!/bin/sh
echo SMOKE-RAN' > "$TMP/hookbin/zsh"
chmod +x "$TMP/hookbin/git" "$TMP/hookbin/zsh"
hook_fires() {
    local p
    for p in "$@"; do
        STAGED="$p" PATH="$TMP/hookbin:$PATH" sh "$HOOK" | grep -q SMOKE-RAN && print -n "$p=run " || print -n "$p=skip "
    done
}
expect_eq "hook runs the smoke test for every file it checks, not for notes" \
    "qb.zsh=run qb_json.py=run compose.yaml=run README.md=run webui-layout.js=run tests/fixtures/torrents.json=run .githooks/pre-commit=run .env.example=skip " \
    "$(hook_fires qb.zsh qb_json.py compose.yaml README.md webui-layout.js tests/fixtures/torrents.json .githooks/pre-commit .env.example)"

# 8. Read-only commands against the real Docker state -----------------------
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
