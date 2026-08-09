# qBittorrent CLI
# Loaded from ~/.zshrc

emulate -L zsh

QB_DIR="$HOME/qbittorrent"
QB_DOWNLOADS_DEFAULT="$HOME/Downloads/qbittorrent-downloads"
QB_DOWNLOADS="$QB_DOWNLOADS_DEFAULT"
QB_APP="$HOME/Applications/qBittorrent.app"
QB_URL="http://localhost:8080"
QB_API_KEY_FILE="$QB_DIR/.env.qbittorrent"
QB_IMAGE_STALE_DAYS=90
QB_QUIT_LOCK="$QB_DIR/.qb-quit.lock"
QB_STYLE_DEFAULT="color"
typeset -g QB_STYLE="$QB_STYLE_DEFAULT"
QB_WEBUI_BIND_DEFAULT="localhost"
typeset -g QB_WEBUI_BIND="$QB_WEBUI_BIND_DEFAULT"
typeset -g QB_WEBUI_PUBLISH="127.0.0.1:8080"
QB_QUIT_DOCKER_DEFAULT="stop"
typeset -g QB_QUIT_DOCKER="$QB_QUIT_DOCKER_DEFAULT"
QB_START_UI_DEFAULT="app"
typeset -g QB_START_UI="$QB_START_UI_DEFAULT"
# Sticky: color allowed for this shell (survives $() subshells where -t 1 is false).
typeset -g QB_COLOR_OK=0

typeset -g QB_SPINNER_PID=""

_qb_cleanup_spinner() {
    if [[ -n "$QB_SPINNER_PID" ]]; then
        kill "$QB_SPINNER_PID" 2>/dev/null
        wait "$QB_SPINNER_PID" 2>/dev/null
        QB_SPINNER_PID=""
    fi
}

# bare/color: braille dots; emoji: moon phases. color paints the braille green.
_qb_spinner_frames() {
    if _qb_style_emoji; then
        printf '%s\n' '🌑' '🌒' '🌓' '🌔' '🌕' '🌖' '🌗' '🌘'
    else
        printf '%s\n' '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'
    fi
}

_qb_spinner() {
    local message="$1"
    local style="$QB_STYLE"
    local color_ok="$QB_COLOR_OK"
    local -a frames
    local interval=0.08

    frames=("${(@f)$(_qb_spinner_frames)}")
    if _qb_style_emoji; then
        interval=0.12
    fi

    (
        local i=1
        local frame
        local QB_STYLE="$style"
        local QB_COLOR_OK="$color_ok"

        while true; do
            frame="${frames[i]}"
            if [[ "$QB_STYLE" == "color" ]] && (( QB_COLOR_OK )) && [[ -z "${NO_COLOR:-}" ]]; then
                frame=$'\033[32m'"${frame}"$'\033[0m'
            fi
            printf "\r\033[2K%s %s" "$frame" "$message"
            i=$((i % ${#frames[@]} + 1))
            sleep "$interval"
        done
    ) &!

    QB_SPINNER_PID=$!
}

# Load QB_STYLE from .env.qbittorrent (bare|color|emoji). Default: color.
# File wins when set; otherwise keep current value (allows QB_STYLE=bare qb status).
_qb_refresh_style() {
    local configured=""
    local line=""

    if [[ -f "$QB_API_KEY_FILE" ]]; then
        line="$(
            grep -E '^[[:space:]]*QB_STYLE[[:space:]]*=' "$QB_API_KEY_FILE" 2>/dev/null |
                tail -n 1
        )"
        configured="${line#*=}"
        configured="${configured//$'\r'/}"
        configured="${configured//$'\n'/}"
        # trim spaces
        configured="${configured#"${configured%%[![:space:]]*}"}"
        configured="${configured%"${configured##*[![:space:]]}"}"
        configured="${configured#\"}"
        configured="${configured%\"}"
        configured="${configured#\'}"
        configured="${configured%\'}"
        configured="${configured:l}"
    fi

    if [[ -z "$configured" ]]; then
        [[ -n "$QB_STYLE" ]] || QB_STYLE="$QB_STYLE_DEFAULT"
        _qb_update_color_ok
        return 0
    fi

    case "$configured" in
        bare|plain|ascii)
            QB_STYLE="bare"
            ;;
        color|ansi|gh)
            QB_STYLE="color"
            ;;
        emoji|rich|boxes)
            QB_STYLE="emoji"
            ;;
        *)
            QB_STYLE="$QB_STYLE_DEFAULT"
            ;;
    esac

    _qb_update_color_ok
}

_qb_style_emoji() {
    [[ "$QB_STYLE" == "emoji" ]]
}

# Decide whether ANSI color is allowed. Must be sticky: $(_qb_state …) runs in a
# subshell where stdout is not a TTY, so a live [[ -t 1 ]] check would strip color.
_qb_update_color_ok() {
    QB_COLOR_OK=0

    [[ -z "${NO_COLOR:-}" ]] || return 0
    [[ "$QB_STYLE" == "color" || "$QB_STYLE" == "emoji" ]] || return 0

    if [[ "${FORCE_COLOR:-0}" == "1" || -t 1 ]]; then
        QB_COLOR_OK=1
    fi
}

_qb_style_color() {
    [[ "$QB_STYLE" == "color" || "$QB_STYLE" == "emoji" ]] || return 1
    [[ -z "${NO_COLOR:-}" ]] || return 1
    (( QB_COLOR_OK )) || return 1
    return 0
}

_qb_paint() {
    local color="$1"
    local text="$2"
    local code=""

    if ! _qb_style_color; then
        printf '%s' "$text"
        return 0
    fi

    case "$color" in
        green)   code='32' ;;
        red)     code='31' ;;                 # bright — errors (X)
        # Clear crimson (not brown/maroon 124). Ghostty/truecolor.
        darkred)
            printf '\033[38;2;220;38;38m%s\033[0m' "$text"
            return 0
            ;;
        yellow)  code='33' ;;
        dim)     code='2' ;;
        *)
            printf '%s' "$text"
            return 0
            ;;
    esac

    printf '\033[%sm%s\033[0m' "$code" "$text"
}

# Glyphs: bare/color match gh-style (✓ / X); emoji uses boxed marks.
_qb_sym() {
    local kind="$1"

    if _qb_style_emoji; then
        case "$kind" in
            ok)   printf '✅' ;;
            fail) printf '❌' ;;
            off)  printf '🛑' ;;
            info) printf '➡️' ;;
            open) printf '↗️' ;;
            *)    printf '•' ;;
        esac
    else
        case "$kind" in
            ok)   printf '✓' ;;
            fail) printf 'X' ;;
            off)  printf '■' ;;
            info) printf '→' ;;
            open) printf '↗' ;;
            *)    printf '-' ;;
        esac
    fi
}

# Mark with optional color (gh paints ✓ green / X red; emoji glyphs as-is —
# terminals ignore ANSI on most emoji, so off uses an inherently red 🛑).
_qb_mark() {
    local kind="$1"
    local sym

    sym="$(_qb_sym "$kind")"

    if _qb_style_emoji; then
        printf '%s' "$sym"
        return 0
    fi

    case "$kind" in
        ok)   _qb_paint green "$sym" ;;
        fail) _qb_paint red "$sym" ;;
        off)  _qb_paint darkred "$sym" ;;
        *)    printf '%s' "$sym" ;;
    esac
}

_qb_state() {
    local word="$1"

    case "$word" in
        running|ready|present|exists|listening|reachable)
            _qb_paint green "$word"
            ;;
        stopped|missing|unavailable|unreachable|rejected)
            _qb_paint darkred "$word"
            ;;
        unknown|skipped)
            _qb_paint dim "$word"
            ;;
        *)
            printf '%s' "$word"
            ;;
    esac
}

_qb_line() {
    local kind="$1"
    shift
    printf '%s %s\n' "$(_qb_mark "$kind")" "$*"
}

_qb_success() {
    _qb_cleanup_spinner
    printf "\r\033[2K%s %s\n" "$(_qb_mark ok)" "$1"
}

# Successful stop / already-stopped (off mark, not green ✓).
_qb_stopped() {
    _qb_cleanup_spinner
    printf "\r\033[2K%s %s\n" "$(_qb_mark off)" "$1"
}

_qb_failure() {
    _qb_cleanup_spinner
    printf "\r\033[2K%s %s\n" "$(_qb_mark fail)" "$1"
}

_qb_docker_running() {
    docker info >/dev/null 2>&1
}

_qb_container_exists() {
    docker ps -a \
    --format '{{.Names}}' 2>/dev/null |
    grep -qx 'qbittorrent'
}

_qb_container_running() {
    docker ps \
    --format '{{.Names}}' 2>/dev/null |
    grep -qx 'qbittorrent'
}

_qb_webui_ready() {
    curl -fsS "$QB_URL" >/dev/null 2>&1
}

# Docker engine only (for images/prune). No compose/API side effects before this returns.
_qb_require_docker() {
    if _qb_docker_running; then
        return 0
    fi

    _qb_failure "Docker Desktop is not running"
    printf "Run: qb start\n"
    return 1
}

# Live stack gate — see _qb_stack_ready (defined after API helpers).
_qb_require_stack() {
    if _qb_stack_ready; then
        return 0
    fi

    _qb_failure "qBittorrent is not running"
    printf "Run: qb start\n"
    return 1
}

_qb_quit_lock_acquire() {
    local pid=""

    if mkdir "$QB_QUIT_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" >"$QB_QUIT_LOCK/pid" || {
            rmdir "$QB_QUIT_LOCK" 2>/dev/null
            return 1
        }
        return 0
    fi

    # Stale lock (crash / killed quit): reclaim if owner PID is gone.
    if [[ -d "$QB_QUIT_LOCK" ]]; then
        pid="$(<"$QB_QUIT_LOCK/pid" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            _qb_line info "Quit already in progress"
            return 1
        fi
        rm -rf "$QB_QUIT_LOCK" 2>/dev/null
    elif [[ -e "$QB_QUIT_LOCK" ]]; then
        rm -rf "$QB_QUIT_LOCK" 2>/dev/null
    fi

    if mkdir "$QB_QUIT_LOCK" 2>/dev/null; then
        printf '%s\n' "$$" >"$QB_QUIT_LOCK/pid" || {
            rmdir "$QB_QUIT_LOCK" 2>/dev/null
            return 1
        }
        return 0
    fi

    _qb_line info "Quit already in progress"
    return 1
}

_qb_quit_lock_release() {
    rm -rf "$QB_QUIT_LOCK" 2>/dev/null
}

_qb_wait_for_docker() {
    local timeout="${1:-60}"
    local elapsed=0
    
    while ! _qb_docker_running; do
        sleep 1
        elapsed=$((elapsed + 1))
        
        if (( elapsed >= timeout )); then
            return 1
        fi
    done
    
    return 0
}

_qb_wait_for_webui() {
    local timeout="${1:-60}"
    local elapsed=0
    
    while ! _qb_webui_ready; do
        sleep 1
        elapsed=$((elapsed + 1))
        
        if (( elapsed >= timeout )); then
            return 1
        fi
    done
    
    return 0
}

_qb_api_key() {
    local key

    [[ -f "$QB_API_KEY_FILE" ]] || return 1

    key="$(
        grep -E '^QBIT_API_KEY=' "$QB_API_KEY_FILE" 2>/dev/null |
            tail -n 1 |
            sed 's/^QBIT_API_KEY=//'
    )"
    key="${key//$'\r'/}"
    key="${key//$'\n'/}"
    key="${key#\"}"
    key="${key%\"}"
    key="${key#\'}"
    key="${key%\'}"

    [[ -n "$key" ]] || return 1
    printf '%s\n' "$key"
}

# Load QB_DOWNLOADS from .env.qbittorrent (optional) and export for compose.
_qb_refresh_downloads() {
    local configured=""

    if [[ -f "$QB_API_KEY_FILE" ]]; then
        configured="$(
            grep -E '^QB_DOWNLOADS=' "$QB_API_KEY_FILE" 2>/dev/null |
                tail -n 1 |
                sed 's/^QB_DOWNLOADS=//'
        )"
        configured="${configured//$'\r'/}"
        configured="${configured//$'\n'/}"
        configured="${configured#\"}"
        configured="${configured%\"}"
        configured="${configured#\'}"
        configured="${configured%\'}"
    fi

    if [[ -z "$configured" ]]; then
        QB_DOWNLOADS="$QB_DOWNLOADS_DEFAULT"
    elif [[ "$configured" == "~" ]]; then
        QB_DOWNLOADS="$HOME"
    elif [[ "$configured" == "~/"* ]]; then
        QB_DOWNLOADS="$HOME/${configured#~/}"
    else
        QB_DOWNLOADS="$configured"
    fi

    if [[ -d "$QB_DOWNLOADS" ]]; then
        QB_DOWNLOADS="${QB_DOWNLOADS:A}"
    fi

    export QB_DOWNLOADS
}

# Load QB_WEBUI_BIND from .env.qbittorrent (optional). Default: localhost-only publish.
# localhost → 127.0.0.1:8080:8080 ; lan → 0.0.0.0:8080:8080
_qb_refresh_webui_bind() {
    local configured=""
    local line=""

    if [[ -f "$QB_API_KEY_FILE" ]]; then
        line="$(
            grep -E '^[[:space:]]*QB_WEBUI_BIND[[:space:]]*=' "$QB_API_KEY_FILE" 2>/dev/null |
                tail -n 1
        )"
        configured="${line#*=}"
        configured="${configured//$'\r'/}"
        configured="${configured//$'\n'/}"
        configured="${configured#"${configured%%[![:space:]]*}"}"
        configured="${configured%"${configured##*[![:space:]]}"}"
        configured="${configured#\"}"
        configured="${configured%\"}"
        configured="${configured#\'}"
        configured="${configured%\'}"
        configured="${configured:l}"
    fi

    if [[ -z "$configured" ]]; then
        [[ -n "$QB_WEBUI_BIND" ]] || QB_WEBUI_BIND="$QB_WEBUI_BIND_DEFAULT"
    else
        case "$configured" in
            localhost|local|loopback|127.0.0.1)
                QB_WEBUI_BIND="localhost"
                ;;
            lan|all|any|0.0.0.0|\*)
                QB_WEBUI_BIND="lan"
                ;;
            *)
                QB_WEBUI_BIND="$QB_WEBUI_BIND_DEFAULT"
                ;;
        esac
    fi

    if [[ "$QB_WEBUI_BIND" == "lan" ]]; then
        QB_WEBUI_PUBLISH="0.0.0.0:8080"
    else
        QB_WEBUI_BIND="localhost"
        QB_WEBUI_PUBLISH="127.0.0.1:8080"
    fi

    export QB_WEBUI_BIND
    export QB_WEBUI_PUBLISH
}

# Load QB_QUIT_DOCKER from .env.qbittorrent (optional).
# stop = also stop Docker Desktop when no other containers (default)
# keep = leave Docker Desktop running after qb quit
_qb_refresh_quit_docker() {
    local configured=""
    local line=""

    if [[ -f "$QB_API_KEY_FILE" ]]; then
        line="$(
            grep -E '^[[:space:]]*QB_QUIT_DOCKER[[:space:]]*=' "$QB_API_KEY_FILE" 2>/dev/null |
                tail -n 1
        )"
        configured="${line#*=}"
        configured="${configured//$'\r'/}"
        configured="${configured//$'\n'/}"
        configured="${configured#"${configured%%[![:space:]]*}"}"
        configured="${configured%"${configured##*[![:space:]]}"}"
        configured="${configured#\"}"
        configured="${configured%\"}"
        configured="${configured#\'}"
        configured="${configured%\'}"
        configured="${configured:l}"
    fi

    if [[ -z "$configured" ]]; then
        [[ -n "$QB_QUIT_DOCKER" ]] || QB_QUIT_DOCKER="$QB_QUIT_DOCKER_DEFAULT"
    else
        case "$configured" in
            stop|off|shutdown)
                QB_QUIT_DOCKER="stop"
                ;;
            keep|leave|on)
                QB_QUIT_DOCKER="keep"
                ;;
            *)
                QB_QUIT_DOCKER="$QB_QUIT_DOCKER_DEFAULT"
                ;;
        esac
    fi

    export QB_QUIT_DOCKER
}

# Load QB_START_UI from .env.qbittorrent (optional).
# app = open/focus Dock Web App after start (default)
# cli = leave Dock app alone; print WebUI URL
_qb_refresh_start_ui() {
    local configured=""
    local line=""

    if [[ -f "$QB_API_KEY_FILE" ]]; then
        line="$(
            grep -E '^[[:space:]]*QB_START_UI[[:space:]]*=' "$QB_API_KEY_FILE" 2>/dev/null |
                tail -n 1
        )"
        configured="${line#*=}"
        configured="${configured//$'\r'/}"
        configured="${configured//$'\n'/}"
        configured="${configured#"${configured%%[![:space:]]*}"}"
        configured="${configured%"${configured##*[![:space:]]}"}"
        configured="${configured#\"}"
        configured="${configured%\"}"
        configured="${configured#\'}"
        configured="${configured%\'}"
        configured="${configured:l}"
    fi

    if [[ -z "$configured" ]]; then
        [[ -n "$QB_START_UI" ]] || QB_START_UI="$QB_START_UI_DEFAULT"
    else
        case "$configured" in
            app|ui|gui)
                QB_START_UI="app"
                ;;
            cli|none|headless)
                QB_START_UI="cli"
                ;;
            *)
                QB_START_UI="$QB_START_UI_DEFAULT"
                ;;
        esac
    fi

    export QB_START_UI
}

_qb_downloads_mount_matches() {
    local src

    _qb_container_exists || return 1

    src="$(
        docker inspect qbittorrent \
            --format '{{range .Mounts}}{{if eq .Destination "/downloads"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null
    )"
    [[ -n "$src" ]] || return 1

    if [[ -d "$src" ]]; then
        src="${src:A}"
    fi

    [[ "$src" == "$QB_DOWNLOADS" ]]
}

# True when container's published 8080 HostIp matches QB_WEBUI_BIND.
_qb_webui_publish_matches() {
    local host_ip

    _qb_container_exists || return 1

    host_ip="$(
        docker inspect qbittorrent \
            --format '{{with index .HostConfig.PortBindings "8080/tcp"}}{{with index . 0}}{{.HostIp}}{{end}}{{end}}' \
            2>/dev/null
    )"

    if [[ "$QB_WEBUI_BIND" == "lan" ]]; then
        [[ -z "$host_ip" || "$host_ip" == "0.0.0.0" ]]
    else
        [[ "$host_ip" == "127.0.0.1" ]]
    fi
}

# Authenticated WebAPI curl. Header via process substitution so the key is
# not on curl's argv (ps would otherwise show "Authorization: Bearer …").
# Usage: _qb_api_curl '/api/v2/app/version'
_qb_api_curl() {
    local api_path="$1"
    local api_key

    [[ -n "$api_path" ]] || return 1

    api_key="$(_qb_api_key)" || return 1
    api_key="${api_key//$'\r'/}"
    api_key="${api_key//$'\n'/}"

    [[ -n "$api_key" ]] || return 1
    [[ "$api_key" != "replace_with_your_qbittorrent_webui_api_key" ]] || return 1

    curl -fsS \
        -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "${QB_URL}${api_path}"
}

# Authenticated WebAPI POST (form fields via extra curl args, e.g. --data-urlencode).
# Usage: _qb_api_post '/api/v2/torrents/stop' --data-urlencode "hashes=abc"
_qb_api_post() {
    local api_path="$1"
    local api_key
    shift

    [[ -n "$api_path" ]] || return 1

    api_key="$(_qb_api_key)" || return 1
    api_key="${api_key//$'\r'/}"
    api_key="${api_key//$'\n'/}"

    [[ -n "$api_key" ]] || return 1
    [[ "$api_key" != "replace_with_your_qbittorrent_webui_api_key" ]] || return 1

    curl -fsS -X POST \
        -H @<(printf 'Authorization: Bearer %s\n' "$api_key") \
        "$@" \
        "${QB_URL}${api_path}"
}

_qb_api_ok() {
    _qb_api_curl /api/v2/app/version >/dev/null 2>&1
}

_qb_api_key_usable() {
    local api_key

    api_key="$(_qb_api_key)" || return 1
    api_key="${api_key//$'\r'/}"
    api_key="${api_key//$'\n'/}"

    [[ -n "$api_key" ]] || return 1
    [[ "$api_key" != "replace_with_your_qbittorrent_webui_api_key" ]] || return 1
    return 0
}

_qb_api_key_hint() {
    printf "Set QBIT_API_KEY in %s\n" "$QB_API_KEY_FILE"
    printf "Copy from: qBittorrent WebUI → Tools → Options → Web UI → Authentication (API key)\n"
    printf "Create the file with: cp %s/.env.example %s\n" "$QB_DIR" "$QB_API_KEY_FILE"
}

# For commands that call the authenticated WebAPI (torrents, update, …).
_qb_require_api() {
    if ! _qb_api_key_usable; then
        _qb_failure "WebUI API key is missing or not set"
        _qb_api_key_hint
        return 1
    fi

    if ! _qb_api_ok; then
        _qb_failure "WebUI API key was rejected (incorrect or revoked)"
        printf "Update QBIT_API_KEY in %s\n" "$QB_API_KEY_FILE"
        _qb_api_key_hint
        return 1
    fi

    return 0
}

# Stricter than UI root curl: proves qBit API (not a random :8080 listener).
# Prefer auth when a real API key is configured; otherwise try public version, then UI root.
_qb_stack_ready() {
    if _qb_api_ok; then
        return 0
    fi

    if curl -fsS "$QB_URL/api/v2/app/version" >/dev/null 2>&1; then
        return 0
    fi

    # No usable key: allow UI root so logs/shell still work before key setup.
    if ! _qb_api_key >/dev/null 2>&1; then
        _qb_webui_ready
        return $?
    fi

    local api_key
    api_key="$(_qb_api_key)" || return 1
    api_key="${api_key//$'\r'/}"
    api_key="${api_key//$'\n'/}"
    if [[ -z "$api_key" || "$api_key" == "replace_with_your_qbittorrent_webui_api_key" ]]; then
        _qb_webui_ready
        return $?
    fi

    # Key present but auth failed — do not treat a generic :8080 page as OK.
    return 1
}

_qb_port_listening() {
    local port="${1:-8080}"

    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
}

_qb_container_mounts_ok() {
    local mounts

    mounts="$(
        docker inspect qbittorrent \
        --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}' 2>/dev/null
    )" || return 1

    printf '%s\n' "$mounts" | grep -qx '/config' || return 1
    printf '%s\n' "$mounts" | grep -qx '/downloads' || return 1
    printf '%s\n' "$mounts" | grep -qx '/plugins' || return 1

    return 0
}

_qb_active_downloads() {
    _qb_api_curl '/api/v2/torrents/info?filter=downloading'
}

_qb_torrents_info() {
    local filter="${1:-}"

    if [[ -n "$filter" ]]; then
        _qb_api_curl "/api/v2/torrents/info?filter=${filter}"
    else
        _qb_api_curl '/api/v2/torrents/info'
    fi
}

_qb_active_download_count() {
    local response="$1"
    
    python3 - "$response" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
    print(len(data))
except Exception:
    print(-1)
PY
}

_qb_other_containers() {
    docker ps \
    --format '{{.Names}}' 2>/dev/null |
    grep -vx 'qbittorrent' || true
}

_qb_service_image() {
    local image

    image="$(docker compose config --images 2>/dev/null | head -n 1)"
    [[ -n "$image" ]] || return 1

    printf '%s\n' "$image"
}

_qb_image_id() {
    local image="$1"

    [[ -n "$image" ]] || return 1

    docker image inspect "$image" --format '{{.Id}}' 2>/dev/null
}

_qb_local_repo_digest() {
    local image="$1"
    local digest

    [[ -n "$image" ]] || return 1

    digest="$(
        docker image inspect "$image" \
            --format '{{range .RepoDigests}}{{println .}}{{end}}' \
            2>/dev/null |
            head -n 1
    )"
    [[ -n "$digest" ]] || return 1

    # lscr.io/...@sha256:abcd → sha256:abcd
    printf '%s\n' "${digest##*@}"
}

# Registry index digest for :tag (no layer download). Matches Docker Desktop RepoDigests.
_qb_remote_index_digest() {
    local image="$1"
    local digest

    [[ -n "$image" ]] || return 1

    digest="$(
        docker buildx imagetools inspect "$image" 2>/dev/null |
            awk '/^Digest:/{ print $2; exit }'
    )"
    [[ "$digest" == sha256:* ]] || return 1

    printf '%s\n' "$digest"
}

_qb_digests_equal() {
    local left="${1#sha256:}"
    local right="${2#sha256:}"

    [[ -n "$left" && -n "$right" && "$left" == "$right" ]]
}

_qb_image_ids_equal() {
    local left="${1#sha256:}"
    local right="${2#sha256:}"

    [[ -n "$left" && -n "$right" ]] || return 1
    [[ "$left" == "$right" || "$left" == "$right"* || "$right" == "$left"* ]]
}

_qb_short_image_id() {
    local id="${1#sha256:}"

    printf '%s\n' "${id:0:12}"
}

# Best-effort removal. Never treat failure as fatal for callers.
_qb_remove_image_id() {
    local image_id="$1"

    [[ -n "$image_id" ]] || return 1

    docker rmi "$image_id" >/dev/null 2>&1
}

_qb_kept_image_id() {
    local image
    local image_id

    if _qb_container_exists; then
        image_id="$(
            docker inspect qbittorrent --format '{{.Image}}' 2>/dev/null
        )"
        if [[ -n "$image_id" ]]; then
            printf '%s\n' "$image_id"
            return 0
        fi
    fi

    cd "$QB_DIR" 2>/dev/null || return 1
    image="$(_qb_service_image)" || return 1
    _qb_image_id "$image"
}

_qb_image_age_days() {
    local image_id
    local created

    image_id="$(_qb_kept_image_id)" || return 1
    created="$(
        docker image inspect "$image_id" --format '{{.Created}}' 2>/dev/null
    )" || return 1
    [[ -n "$created" ]] || return 1

    python3 - "$created" <<'PY'
import re
import sys
from datetime import datetime, timezone

raw = sys.argv[1].strip()
if raw.endswith("Z"):
    raw = raw[:-1] + "+00:00"

raw = re.sub(r"\.(\d{6})\d*", r".\1", raw)

try:
    created = datetime.fromisoformat(raw)
except ValueError:
    sys.exit(1)

if created.tzinfo is None:
    created = created.replace(tzinfo=timezone.utc)

age = (datetime.now(timezone.utc) - created.astimezone(timezone.utc)).days
print(max(age, 0))
PY
}

# Soft notice only — never pulls or recreates.
# Age gate first (no network). If stale, digest-check; hint only when newer exists.
# Same digests or failed check → stay quiet.
_qb_image_age_notice() {
    local days
    local image
    local local_digest
    local remote_digest

    days="$(_qb_image_age_days)" || return 0
    (( days >= QB_IMAGE_STALE_DAYS )) || return 0

    image="$(_qb_service_image)" || return 0
    local_digest="$(_qb_local_repo_digest "$image")" || return 0
    remote_digest="$(_qb_remote_index_digest "$image")" || return 0

    if _qb_digests_equal "$local_digest" "$remote_digest"; then
        return 0
    fi

    _qb_line info "Image is $days days old; newer available. Run: qb update"
}

# True if the Dock Web App process is already running.
# Do NOT use `tell application "qBittorrent"` here — that can launch it.
_qb_app_running() {
    pgrep -f "/Applications/qBittorrent.app" >/dev/null 2>&1
}

_qb_open_app() {
    if [[ ! -d "$QB_APP" ]]; then
        _qb_failure "qBittorrent.app not found"
        return 1
    fi

    # Always use the Dock Web App. Never open QB_URL in Safari.
    if _qb_app_running; then
        if osascript -e 'tell application "qBittorrent" to activate' >/dev/null 2>&1; then
            _qb_line ok "qBittorrent WebUI already open"
            return 0
        fi

        _qb_failure "Failed to focus qBittorrent WebUI"
        return 1
    fi

    _qb_line open "Opening qBittorrent"

    if open -a "$QB_APP" >/dev/null 2>&1; then
        return 0
    fi

    _qb_failure "Failed to open qBittorrent WebUI"
    return 1
}

# Present WebUI per QB_START_UI: open Dock app (app) or print URL only (cli).
_qb_present_webui() {
    _qb_refresh_start_ui

    if [[ "$QB_START_UI" == "cli" ]]; then
        _qb_line info "Skipping Dock Web App (QB_START_UI=cli)"
        _qb_line info "WebUI: $QB_URL"
        return 0
    fi

    _qb_open_app
}

_qb_close_app() {
    if _qb_app_running; then
        if osascript -e 'tell application "qBittorrent" to quit' >/dev/null 2>&1; then
            _qb_line ok "qBittorrent WebUI closed"
        else
            _qb_failure "Failed to close qBittorrent WebUI"
            return 1
        fi
    else
        _qb_line ok "qBittorrent WebUI already closed"
    fi
}

_qb_start() {
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_start_ui

    local arg
    for arg in "$@"; do
        case "$arg" in
            --cli|cli)
                QB_START_UI="cli"
                ;;
            --app|app)
                QB_START_UI="app"
                ;;
            -h|--help)
                printf "Usage: qb start [--cli|--app|cli|app]\n"
                printf "  --cli / cli  Start stack only; do not open Dock Web App\n"
                printf "  --app / app  Open/focus Dock Web App (default)\n"
                printf "Env default: QB_START_UI=app|cli (flags win)\n"
                return 0
                ;;
            *)
                _qb_line fail "Unknown option: $arg"
                printf "Usage: qb start [--cli|--app|cli|app]\n"
                return 1
                ;;
        esac
    done

    if ! _qb_docker_running; then
        _qb_spinner "Starting Docker Desktop..."
        
        if ! docker desktop start >/dev/null 2>&1 ||
        ! _qb_wait_for_docker 60; then
            _qb_failure "Failed to start Docker Desktop"
            return 1
        fi
        
        _qb_success "Docker Desktop started"
    fi
    
    if ! _qb_container_running; then
        cd "$QB_DIR" || {
            _qb_failure "qBittorrent directory not found"
            return 1
        }

        mkdir -p "$QB_DOWNLOADS" || {
            _qb_failure "Failed to create downloads directory"
            return 1
        }
        
        _qb_spinner "Starting qBittorrent..."
        
        if ! docker compose up -d >/dev/null 2>&1; then
            _qb_failure "Failed to start qBittorrent"
            return 1
        fi
        
        _qb_success "qBittorrent started"
    elif ! _qb_downloads_mount_matches || ! _qb_webui_publish_matches; then
        cd "$QB_DIR" || {
            _qb_failure "qBittorrent directory not found"
            return 1
        }

        mkdir -p "$QB_DOWNLOADS" || {
            _qb_failure "Failed to create downloads directory"
            return 1
        }

        _qb_spinner "Updating container mounts/ports..."

        if ! docker compose up -d --force-recreate >/dev/null 2>&1; then
            _qb_failure "Failed to update container mounts/ports"
            return 1
        fi

        _qb_success "Container mounts/ports updated"
        _qb_line info "Downloads: $QB_DOWNLOADS"
        _qb_line info "WebUI bind: $QB_WEBUI_BIND ($QB_WEBUI_PUBLISH)"
    fi
    
    if ! _qb_webui_ready; then
        _qb_spinner "Waiting for WebUI..."
        
        if ! _qb_wait_for_webui 60; then
            _qb_failure "WebUI did not become available"
            return 1
        fi
        
        _qb_success "WebUI ready"
    else
        _qb_line ok "WebUI ready"
    fi

    _qb_image_age_notice

    _qb_present_webui
}

_qb_quit() {
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_quit_docker

    local keep_docker=0
    [[ "$QB_QUIT_DOCKER" == "keep" ]] && keep_docker=1

    if ! _qb_quit_lock_acquire; then
        return 0
    fi
    trap '_qb_quit_lock_release; trap - EXIT' EXIT

    # Already fully stopped.
    if ! _qb_app_running && ! _qb_container_running; then
        if ! _qb_docker_running; then
            _qb_line off "qBittorrent already stopped"
            return 0
        fi

        local other_containers
        other_containers="$(_qb_other_containers)"

        if (( keep_docker )) || [[ -n "$other_containers" ]]; then
            _qb_line off "qBittorrent already stopped"
            _qb_line info "Leaving Docker Desktop running"
            return 0
        fi

        _qb_spinner "Stopping Docker Desktop..."

        if ! docker desktop stop --detach >/dev/null 2>&1; then
            _qb_failure "Failed to stop Docker Desktop"
            return 1
        fi

        _qb_stopped "Docker Desktop stopped"
        return 0
    fi

    # Gradual quit: close whatever is still up.
    _qb_close_app

    if _qb_container_running; then
        cd "$QB_DIR" || {
            _qb_failure "qBittorrent directory not found"
            return 1
        }

        _qb_spinner "Stopping qBittorrent..."

        if ! docker compose stop >/dev/null 2>&1; then
            _qb_failure "Failed to stop qBittorrent"
            return 1
        fi

        _qb_stopped "qBittorrent stopped"
    fi

    if ! _qb_docker_running; then
        return 0
    fi

    if (( keep_docker )); then
        _qb_line info "Leaving Docker Desktop running"
        return 0
    fi

    local other_containers
    other_containers="$(_qb_other_containers)"

    if [[ -n "$other_containers" ]]; then
        local other_count
        other_count="$(
            printf '%s\n' "$other_containers" |
            wc -l |
            tr -d ' '
        )"

        _qb_line ok "$other_count other Docker container(s) still running"
        _qb_line info "Leaving Docker Desktop running"
        return 0
    fi

    _qb_spinner "Stopping Docker Desktop..."

    if ! docker desktop stop --detach >/dev/null 2>&1; then
        _qb_failure "Failed to stop Docker Desktop"
        return 1
    fi

    _qb_stopped "Docker Desktop stopped"
}

_qb_restart() {
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_start_ui

    if _qb_container_running; then
        cd "$QB_DIR" || {
            _qb_failure "qBittorrent directory not found"
            return 1
        }
        
        _qb_spinner "Restarting qBittorrent..."
        
        if ! docker compose restart >/dev/null 2>&1; then
            _qb_failure "Failed to restart qBittorrent"
            return 1
        fi
        
        _qb_success "qBittorrent restarted"
        
        _qb_spinner "Waiting for WebUI..."
        
        if ! _qb_wait_for_webui 60; then
            _qb_failure "WebUI did not become available"
            return 1
        fi
        
        _qb_success "WebUI ready"
        
        _qb_present_webui
        return $?
    fi
    
    _qb_start
}

_qb_status() {
    if _qb_docker_running; then
        _qb_line ok "Docker Desktop: $(_qb_state running)"
    else
        _qb_line off "Docker Desktop: $(_qb_state stopped)"
    fi

    if _qb_container_running; then
        _qb_line ok "qBittorrent: $(_qb_state running)"
    else
        _qb_line off "qBittorrent: $(_qb_state stopped)"
    fi

    if _qb_webui_ready; then
        _qb_line ok "WebUI: $(_qb_state ready)"
    else
        _qb_line off "WebUI: $(_qb_state unavailable)"
    fi

    if _qb_docker_running; then
        local other_containers
        other_containers="$(_qb_other_containers)"

        if [[ -n "$other_containers" ]]; then
            local other_count
            other_count="$(
                printf '%s\n' "$other_containers" |
                wc -l |
                tr -d ' '
            )"

            _qb_line ok "Other containers: $other_count"
        else
            _qb_line off "Other containers: 0"
        fi
    fi

    if _qb_api_ok; then
        _qb_transfer_print
    fi

    _qb_line info "Output style: $QB_STYLE"
    _qb_line info "WebUI bind: $QB_WEBUI_BIND"
    if [[ "$QB_QUIT_DOCKER" == "keep" ]]; then
        _qb_line info "On quit: leave Docker Desktop running"
    else
        _qb_line info "On quit: stop Docker Desktop if idle"
    fi
    if [[ "$QB_START_UI" == "cli" ]]; then
        _qb_line info "On start: CLI only (no Dock Web App)"
    else
        _qb_line info "On start: open Dock Web App"
    fi
}

_qb_transfer_print() {
    local response
    local alt_mode
    local line

    response="$(_qb_api_curl /api/v2/transfer/info)" || return 0
    alt_mode="$(_qb_api_curl /api/v2/transfer/speedLimitsMode 2>/dev/null)" || alt_mode=""

    line="$(
        python3 - "$response" "$alt_mode" <<'PY'
import json
import sys


def human_rate(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    if n <= 0:
        return "0 B/s"
    units = ["B/s", "KiB/s", "MiB/s", "GiB/s"]
    for unit in units:
        if n < 1024 or unit == units[-1]:
            if unit == "B/s":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} GiB/s"


try:
    info = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

dl = human_rate(info.get("dl_info_speed") or 0)
up = human_rate(info.get("up_info_speed") or 0)
alt = (sys.argv[2] or "").strip()
alt_label = "on" if alt == "1" else "off"
print(f"Transfer: ↓{dl}  ↑{up}  alt-limits={alt_label}")
PY
    )" || return 0

    [[ -n "$line" ]] && _qb_line info "$line"
}

_qb_torrents_print() {
    local filter="${1:-}"
    local response

    response="$(_qb_torrents_info "$filter")" || {
        _qb_failure "Failed to query qBittorrent"
        return 1
    }

    python3 - "$response" <<'PY'
import json
import sys


def human_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if n < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def human_rate(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    if n <= 0:
        return "0 B/s"
    return f"{human_bytes(n)}/s"


try:
    torrents = json.loads(sys.argv[1])
except Exception as e:
    print(f"Failed to parse qBittorrent response: {e}", file=sys.stderr)
    sys.exit(1)

if not torrents:
    print("No torrents.")
    sys.exit(0)

for t in torrents:
    name = t.get("name") or "unknown"
    state = t.get("state") or "unknown"
    progress = float(t.get("progress") or 0) * 100
    size = human_bytes(t.get("size") or 0)
    dlspeed = human_rate(t.get("dlspeed") or 0)
    upspeed = human_rate(t.get("upspeed") or 0)
    h = (t.get("hash") or "")[:8]
    print(name)
    print(f"  {h}  {progress:5.1f}%  {size}  ↓{dlspeed}  ↑{upspeed}  {state}")
PY
}

# Resolve id args (hash prefix or unique name substring) to full hashes (| joined).
_qb_resolve_hashes() {
    local response
    local resolved

    (( $# > 0 )) || {
        _qb_line fail "No torrent id given"
        return 1
    }

    response="$(_qb_torrents_info)" || {
        _qb_failure "Failed to query qBittorrent"
        return 1
    }

    resolved="$(
        python3 - "$response" "$@" <<'PY'
import json
import sys

try:
    torrents = json.loads(sys.argv[1])
except Exception as e:
    print(f"Failed to parse torrent list: {e}", file=sys.stderr)
    sys.exit(2)

queries = sys.argv[2:]
hashes = []

for q in queries:
    ql = q.lower()
    matches = []
    for t in torrents:
        h = (t.get("hash") or "").lower()
        name = (t.get("name") or "").lower()
        if h.startswith(ql) or ql in name:
            matches.append(t)

    # Prefer exact hash match when present.
    exact = [t for t in matches if (t.get("hash") or "").lower() == ql]
    if len(exact) == 1:
        matches = exact

    if not matches:
        print(f"No torrent matches: {q}", file=sys.stderr)
        sys.exit(1)

    # Unique by hash.
    by_hash = {}
    for t in matches:
        by_hash[(t.get("hash") or "").lower()] = t
    uniq = list(by_hash.values())

    if len(uniq) > 1:
        print(f"Ambiguous id: {q}", file=sys.stderr)
        for t in uniq:
            h = (t.get("hash") or "")[:8]
            print(f"  {h}  {t.get('name') or 'unknown'}", file=sys.stderr)
        sys.exit(1)

    hashes.append(uniq[0].get("hash") or "")

print("|".join(hashes))
PY
    )" || return 1

    [[ -n "$resolved" ]] || return 1
    printf '%s\n' "$resolved"
}

_qb_torrents() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local watch=0
    local filter=""
    local arg

    for arg in "$@"; do
        case "$arg" in
            --watch|-w)
                watch=1
                ;;
            --downloading)
                filter="downloading"
                ;;
            --seeding)
                filter="seeding"
                ;;
            --stopped|--paused)
                filter="stopped"
                ;;
            --completed)
                filter="completed"
                ;;
            --active)
                filter="active"
                ;;
            --errored)
                filter="errored"
                ;;
            -h|--help)
                printf "Usage: qb torrents [--watch] [--downloading|--seeding|--stopped|--completed|--active|--errored]\n"
                printf "  --watch / -w     Redraw list every 2s until Ctrl-C\n"
                printf "  --downloading    Only downloading\n"
                printf "  --seeding        Only seeding\n"
                printf "  --stopped        Only stopped (alias: --paused)\n"
                return 0
                ;;
            *)
                _qb_line fail "Unknown option: $arg"
                printf "Usage: qb torrents [--watch] [--downloading|--seeding|--stopped]\n"
                return 1
                ;;
        esac
    done

    if (( ! watch )); then
        _qb_torrents_print "$filter"
        return $?
    fi

    trap 'break' INT
    while true; do
        printf '\033[H\033[2J'
        _qb_torrents_print "$filter" || {
            trap - INT
            return 1
        }
        _qb_line info "Watching (Ctrl-C to stop)"
        sleep 2
    done
    trap - INT
    printf '\n'
    return 0
}

_qb_add() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local url="$1"

    if [[ -z "$url" || "$url" == "-h" || "$url" == "--help" ]]; then
        printf "Usage: qb add <magnet-or-url>\n"
        return 1
    fi

    if (( $# > 1 )); then
        _qb_line fail "Pass a single magnet or http(s) URL"
        printf "Usage: qb add <magnet-or-url>\n"
        return 1
    fi

    case "$url" in
        magnet:*|http://*|https://*)
            ;;
        *)
            _qb_line fail "Expected magnet: or http(s) URL"
            return 1
            ;;
    esac

    if ! _qb_api_post /api/v2/torrents/add --data-urlencode "urls=$url" >/dev/null; then
        _qb_failure "Failed to add torrent"
        return 1
    fi

    _qb_success "Torrent added"
}

_qb_pause() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local hashes

    if [[ "$1" == "-h" || "$1" == "--help" || $# -eq 0 ]]; then
        printf "Usage: qb pause <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "$@")" || return 1

    if ! _qb_api_post /api/v2/torrents/stop --data-urlencode "hashes=$hashes" >/dev/null; then
        _qb_failure "Failed to pause torrent(s)"
        return 1
    fi

    _qb_success "Paused"
}

_qb_resume() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local hashes

    if [[ "$1" == "-h" || "$1" == "--help" || $# -eq 0 ]]; then
        printf "Usage: qb resume <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "$@")" || return 1

    if ! _qb_api_post /api/v2/torrents/start --data-urlencode "hashes=$hashes" >/dev/null; then
        _qb_failure "Failed to resume torrent(s)"
        return 1
    fi

    _qb_success "Resumed"
}

_qb_remove() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local delete_files=false
    local -a ids=()
    local arg
    local hashes

    for arg in "$@"; do
        case "$arg" in
            --files)
                delete_files=true
                ;;
            -h|--help)
                printf "Usage: qb remove [--files] <hash-or-name>…\n"
                printf "  --files  Also delete downloaded files from disk\n"
                return 0
                ;;
            *)
                ids+=("$arg")
                ;;
        esac
    done

    if (( ${#ids[@]} == 0 )); then
        _qb_line fail "No torrent id given"
        printf "Usage: qb remove [--files] <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "${ids[@]}")" || return 1

    if ! _qb_api_post /api/v2/torrents/delete \
        --data-urlencode "hashes=$hashes" \
        --data-urlencode "deleteFiles=$delete_files" >/dev/null; then
        _qb_failure "Failed to remove torrent(s)"
        return 1
    fi

    if [[ "$delete_files" == "true" ]]; then
        _qb_success "Removed (files deleted)"
    else
        _qb_success "Removed (files kept)"
    fi
}

_qb_show() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local hash
    local props
    local files

    if [[ -z "$1" || "$1" == "-h" || "$1" == "--help" ]]; then
        printf "Usage: qb show <hash-or-name>\n"
        return 1
    fi

    if (( $# > 1 )); then
        _qb_line fail "Show one torrent at a time"
        printf "Usage: qb show <hash-or-name>\n"
        return 1
    fi

    hash="$(_qb_resolve_hashes "$1")" || return 1

    props="$(_qb_api_curl "/api/v2/torrents/properties?hash=${hash}")" || {
        _qb_failure "Failed to load torrent properties"
        return 1
    }
    files="$(_qb_api_curl "/api/v2/torrents/files?hash=${hash}")" || files="[]"

    python3 - "$props" "$files" "$hash" <<'PY'
import json
import sys
from datetime import datetime, timezone


def human_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if n < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def human_rate(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    if n <= 0:
        return "0 B/s"
    return f"{human_bytes(n)}/s"


def fmt_ts(ts):
    try:
        ts = int(ts)
    except (TypeError, ValueError):
        return "-"
    if ts <= 0:
        return "-"
    return datetime.fromtimestamp(ts, tz=timezone.utc).astimezone().strftime("%Y-%m-%d %H:%M")


try:
    p = json.loads(sys.argv[1])
    files = json.loads(sys.argv[2])
except Exception as e:
    print(f"Failed to parse response: {e}", file=sys.stderr)
    sys.exit(1)

h = sys.argv[3]
print(p.get("name") or "unknown")
print(f"  hash: {h}")
print(f"  save: {p.get('save_path') or '-'}")
print(
    f"  size: {human_bytes(p.get('total_size') or 0)}  "
    f"↓{human_bytes(p.get('total_downloaded') or 0)}  "
    f"↑{human_bytes(p.get('total_uploaded') or 0)}"
)
print(f"  speed: ↓{human_rate(p.get('dl_speed') or 0)}  ↑{human_rate(p.get('up_speed') or 0)}")
print(f"  peers: {p.get('peers') or 0}/{p.get('peers_total') or 0}  seeds: {p.get('seeds') or 0}/{p.get('seeds_total') or 0}")
ratio = p.get("share_ratio")
try:
    ratio_s = f"{float(ratio):.3f}"
except (TypeError, ValueError):
    ratio_s = "-"
print(f"  ratio: {ratio_s}  added: {fmt_ts(p.get('addition_date'))}")
if p.get("comment"):
    print(f"  comment: {p.get('comment')}")

if not files:
    print("  files: (none)")
else:
    print(f"  files ({len(files)}):")
    for f in files[:40]:
        prog = float(f.get("progress") or 0) * 100
        print(f"    {prog:5.1f}%  {human_bytes(f.get('size') or 0)}  {f.get('name') or '?'}")
    if len(files) > 40:
        print(f"    … {len(files) - 40} more")
PY
}

_qb_recheck() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local hashes

    if [[ "$1" == "-h" || "$1" == "--help" || $# -eq 0 ]]; then
        printf "Usage: qb recheck <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "$@")" || return 1

    if ! _qb_api_post /api/v2/torrents/recheck --data-urlencode "hashes=$hashes" >/dev/null; then
        _qb_failure "Failed to recheck torrent(s)"
        return 1
    fi

    _qb_success "Recheck started"
}

_qb_reannounce() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local hashes

    if [[ "$1" == "-h" || "$1" == "--help" || $# -eq 0 ]]; then
        printf "Usage: qb reannounce <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "$@")" || return 1

    if ! _qb_api_post /api/v2/torrents/reannounce --data-urlencode "hashes=$hashes" >/dev/null; then
        _qb_failure "Failed to reannounce torrent(s)"
        return 1
    fi

    _qb_success "Reannounce sent"
}

_qb_force() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local value=true
    local -a ids=()
    local arg
    local hashes

    for arg in "$@"; do
        case "$arg" in
            --off|--no)
                value=false
                ;;
            -h|--help)
                printf "Usage: qb force [--off] <hash-or-name>…\n"
                printf "  --off  Disable force start\n"
                return 0
                ;;
            *)
                ids+=("$arg")
                ;;
        esac
    done

    if (( ${#ids[@]} == 0 )); then
        _qb_line fail "No torrent id given"
        printf "Usage: qb force [--off] <hash-or-name>…\n"
        return 1
    fi

    hashes="$(_qb_resolve_hashes "${ids[@]}")" || return 1

    if ! _qb_api_post /api/v2/torrents/setForceStart \
        --data-urlencode "hashes=$hashes" \
        --data-urlencode "value=$value" >/dev/null; then
        _qb_failure "Failed to set force start"
        return 1
    fi

    if [[ "$value" == "true" ]]; then
        _qb_success "Force start enabled"
    else
        _qb_success "Force start disabled"
    fi
}

_qb_alt() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local mode

    if [[ "$1" == "-h" || "$1" == "--help" ]]; then
        printf "Usage: qb alt\n"
        printf "  Toggle alternative global speed limits\n"
        return 0
    fi

    if ! _qb_api_post /api/v2/transfer/toggleSpeedLimitsMode >/dev/null; then
        _qb_failure "Failed to toggle alternative speed limits"
        return 1
    fi

    mode="$(_qb_api_curl /api/v2/transfer/speedLimitsMode 2>/dev/null)" || mode=""
    if [[ "$mode" == "1" ]]; then
        _qb_success "Alternative speed limits: on"
    else
        _qb_success "Alternative speed limits: off"
    fi
}

_qb_plugins_help() {
    printf '%s\n' \
        "Usage: qb plugins <command>" \
        "" \
        "  list                 List installed search plugins" \
        "  install <url>        Install plugin from URL (confirm; third-party Python)" \
        "  enable <name>…       Enable plugin(s)" \
        "  disable <name>…      Disable plugin(s)" \
        "  update               Update all installed plugins" \
        "  remove <name>…       Uninstall plugin(s)" \
        "" \
        "Official engines (examples):" \
        "  https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/eztv.py" \
        "  https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/piratebay.py"
}

_qb_plugins_list() {
    local response

    response="$(_qb_api_curl /api/v2/search/plugins)" || {
        _qb_failure "Failed to list search plugins"
        return 1
    }

    python3 - "$response" <<'PY'
import json
import sys

try:
    plugins = json.loads(sys.argv[1])
except Exception as e:
    print(f"Failed to parse plugins: {e}", file=sys.stderr)
    sys.exit(1)

if not plugins:
    print("No search plugins installed.")
    print("Install one, e.g.:")
    print("  qb plugins install https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/eztv.py")
    print("Plugins are third-party Python — review before enabling.")
    sys.exit(0)

rows = []
for p in sorted(plugins, key=lambda x: (x.get("name") or "").lower()):
    rows.append(
        (
            p.get("name") or "?",
            "on" if p.get("enabled") else "off",
            p.get("version") or "?",
            p.get("fullName") or p.get("name") or "?",
            p.get("url") or "-",
        )
    )

headers = ("NAME", "ENABLED", "VERSION", "FULL NAME", "URL")
widths = [len(h) for h in headers]
for row in rows:
    for i, cell in enumerate(row):
        widths[i] = max(widths[i], len(str(cell)))

# Cap URL column so wide hosts don't blow the terminal.
widths[4] = min(widths[4], 48)

def fmt(cell, width, truncate=False):
    text = str(cell)
    if truncate and len(text) > width:
        text = text[: max(width - 1, 1)] + "…"
    return text.ljust(width)

header_line = "  ".join(fmt(h, widths[i]) for i, h in enumerate(headers))
rule = "  ".join("-" * w for w in widths)
print(header_line)
print(rule)
for row in rows:
    print(
        "  ".join(
            fmt(row[i], widths[i], truncate=(i == 4)) for i in range(len(headers))
        )
    )
PY
}

_qb_plugins_install() {
    local url="$1"
    local yes=0
    local arg
    local reply

    for arg in "$@"; do
        case "$arg" in
            --yes|-y)
                yes=1
                ;;
            -h|--help)
                printf "Usage: qb plugins install [--yes] <plugin-url>\n"
                return 0
                ;;
        esac
    done

    # Last non-flag arg is URL.
    url=""
    for arg in "$@"; do
        case "$arg" in
            --yes|-y|-h|--help) ;;
            *)
                url="$arg"
                ;;
        esac
    done

    if [[ -z "$url" ]]; then
        _qb_line fail "Plugin URL required"
        printf "Usage: qb plugins install [--yes] <plugin-url>\n"
        return 1
    fi

    case "$url" in
        http://*|https://*)
            ;;
        *)
            _qb_line fail "Expected http(s) plugin URL"
            return 1
            ;;
    esac

    _qb_line info "Install plugin from:"
    printf "  %s\n" "$url"
    _qb_line info "Third-party Python runs inside the container"

    if (( ! yes )); then
        if [[ ! -t 0 ]]; then
            _qb_line fail "Non-interactive shell: pass --yes to confirm"
            return 1
        fi
        printf "Continue? [y/N] "
        read -r reply
        case "${reply:l}" in
            y|yes) ;;
            *)
                _qb_line info "Cancelled"
                return 0
                ;;
        esac
    fi

    if ! _qb_api_post /api/v2/search/installPlugin --data-urlencode "sources=$url" >/dev/null; then
        _qb_failure "Failed to install plugin"
        return 1
    fi

    _qb_success "Plugin install requested"
    _qb_line info "Run: qb plugins list"
}

_qb_plugins_enable() {
    local enable="$1"
    shift
    local names
    local label

    if (( $# == 0 )); then
        _qb_line fail "Plugin name required"
        return 1
    fi

    names="${(j:|:)@}"
    label="enabled"
    [[ "$enable" == "true" ]] || label="disabled"

    if ! _qb_api_post /api/v2/search/enablePlugin \
        --data-urlencode "names=$names" \
        --data-urlencode "enable=$enable" >/dev/null; then
        _qb_failure "Failed to set plugin state"
        return 1
    fi

    _qb_success "Plugin(s) $label"
}

_qb_plugins_update() {
    if ! _qb_api_post /api/v2/search/updatePlugins >/dev/null; then
        _qb_failure "Failed to update plugins"
        return 1
    fi

    _qb_success "Plugin update started"
}

_qb_plugins_remove() {
    local names

    if (( $# == 0 )); then
        _qb_line fail "Plugin name required"
        return 1
    fi

    names="${(j:|:)@}"

    if ! _qb_api_post /api/v2/search/uninstallPlugin --data-urlencode "names=$names" >/dev/null; then
        _qb_failure "Failed to remove plugin(s)"
        return 1
    fi

    _qb_success "Plugin(s) removed"
}

_qb_plugins() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local cmd="${1:-list}"

    case "$cmd" in
        list)
            _qb_plugins_list
            ;;
        install)
            shift
            _qb_plugins_install "$@"
            ;;
        enable)
            shift
            _qb_plugins_enable true "$@"
            ;;
        disable)
            shift
            _qb_plugins_enable false "$@"
            ;;
        update)
            _qb_plugins_update
            ;;
        remove|uninstall)
            shift
            _qb_plugins_remove "$@"
            ;;
        -h|--help|help)
            _qb_plugins_help
            ;;
        *)
            _qb_line fail "Unknown plugins command: $cmd"
            _qb_plugins_help
            return 1
            ;;
    esac
}

_qb_search_enabled_count() {
    local response

    response="$(_qb_api_curl /api/v2/search/plugins)" || {
        printf '0\n'
        return 1
    }

    python3 - "$response" <<'PY'
import json
import sys
try:
    plugins = json.loads(sys.argv[1])
except Exception:
    print(0)
    sys.exit(0)
print(sum(1 for p in plugins if p.get("enabled")))
PY
}

_qb_search() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local -a pattern_parts=()
    local add_n=""
    local page_size=10
    local fetch_limit=200
    local watch=0
    local category="all"
    local plugins="enabled"
    local timeout=60
    local arg
    local next=""
    local pattern
    local enabled_count
    local start_json
    local job_id
    local elapsed=0
    local status_json
    local results_json
    local sorted_json
    local job_status="Running"
    local add_url
    local cols

    for arg in "$@"; do
        if [[ -n "$next" ]]; then
            case "$next" in
                add) add_n="$arg" ;;
                limit) page_size="$arg" ;;
                category) category="$arg" ;;
                plugins) plugins="$arg" ;;
                timeout) timeout="$arg" ;;
            esac
            next=""
            continue
        fi

        case "$arg" in
            --add)
                next="add"
                ;;
            --limit)
                next="limit"
                ;;
            --category)
                next="category"
                ;;
            --plugins)
                next="plugins"
                ;;
            --timeout)
                next="timeout"
                ;;
            --watch|-w)
                watch=1
                ;;
            -h|--help)
                printf "Usage: qb search [options] <pattern>\n"
                printf "  Pattern may be quoted or bare words (joined with spaces).\n"
                printf "  --add N         Add result #N (seeds-desc order) after search\n"
                printf "  --limit N       Rows per page (default 10)\n"
                printf "  --category C    Category (default all)\n"
                printf "  --plugins P     Plugin list, all, or enabled (default enabled)\n"
                printf "  --timeout N     Seconds to wait (default 60)\n"
                printf "  --watch         Redraw live table while searching (no spinner)\n"
                printf "  After search:  type a # to add, < > to page, Enter/q to quit\n"
                return 0
                ;;
            --*)
                _qb_line fail "Unknown option: $arg"
                return 1
                ;;
            *)
                pattern_parts+=("$arg")
                ;;
        esac
    done

    if [[ -n "$next" ]]; then
        _qb_line fail "Missing value for --$next"
        return 1
    fi

    pattern="${(j: :)pattern_parts}"
    if [[ -z "$pattern" ]]; then
        _qb_line fail "Search pattern required"
        printf "Usage: qb search [options] <pattern>\n"
        return 1
    fi

    if [[ -n "$add_n" && ! "$add_n" =~ '^[0-9]+$' ]]; then
        _qb_line fail "--add needs a number"
        return 1
    fi
    if [[ ! "$page_size" =~ '^[0-9]+$' || "$page_size" -lt 1 ]]; then
        _qb_line fail "--limit needs a positive number"
        return 1
    fi
    if [[ ! "$timeout" =~ '^[0-9]+$' || "$timeout" -lt 1 ]]; then
        _qb_line fail "--timeout needs a positive number"
        return 1
    fi

    enabled_count="$(_qb_search_enabled_count)" || enabled_count=0
    if (( enabled_count < 1 )) && [[ "$plugins" == "enabled" ]]; then
        _qb_failure "No enabled search plugins"
        printf "Run: qb plugins list\n"
        printf "Install e.g.: qb plugins install https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/eztv.py\n"
        return 1
    fi

    cols="${COLUMNS:-}"
    [[ "$cols" =~ '^[0-9]+$' ]] || cols="$(tput cols 2>/dev/null || echo 80)"

    if (( ! watch )); then
        _qb_spinner "Searching…"
    fi

    start_json="$(
        _qb_api_post /api/v2/search/start \
            --data-urlencode "pattern=$pattern" \
            --data-urlencode "plugins=$plugins" \
            --data-urlencode "category=$category"
    )" || {
        _qb_failure "Failed to start search"
        return 1
    }

    job_id="$(
        python3 - "$start_json" <<'PY'
import json
import sys
try:
    print(json.loads(sys.argv[1]).get("id") or "")
except Exception:
    sys.exit(1)
PY
    )" || {
        _qb_failure "Failed to parse search job id"
        return 1
    }

    if [[ -z "$job_id" ]]; then
        _qb_failure "Search returned no job id"
        return 1
    fi

    trap '_qb_cleanup_spinner
          _qb_api_post /api/v2/search/stop --data-urlencode "id='"$job_id"'" >/dev/null 2>&1
          _qb_api_post /api/v2/search/delete --data-urlencode "id='"$job_id"'" >/dev/null 2>&1
          trap - INT
          return 130' INT

    while (( elapsed < timeout )); do
        status_json="$(_qb_api_curl "/api/v2/search/status?id=${job_id}")" || break
        job_status="$(
            python3 - "$status_json" <<'PY'
import json
import sys
try:
    data = json.loads(sys.argv[1])
    if isinstance(data, list) and data:
        print(data[0].get("status") or "")
    elif isinstance(data, dict):
        print(data.get("status") or "")
except Exception:
    print("")
PY
        )"

        if (( watch )); then
            results_json="$(_qb_api_curl "/api/v2/search/results?id=${job_id}&limit=${fetch_limit}")" || results_json=""
            if [[ -n "$results_json" ]]; then
                sorted_json="$(_qb_search_sort_json "$results_json")" || sorted_json="[]"
                printf '\033[H\033[2J'
                _qb_search_print_page "$sorted_json" 0 "$page_size" "$cols" "$job_status"
                _qb_line info "Searching… ${elapsed}s / ${timeout}s  (< > after finish)"
            fi
        fi

        [[ "$job_status" == "Stopped" ]] && break
        sleep 1
        elapsed=$((elapsed + 1))
    done

    results_json="$(_qb_api_curl "/api/v2/search/results?id=${job_id}&limit=${fetch_limit}")" || {
        _qb_api_post /api/v2/search/stop --data-urlencode "id=$job_id" >/dev/null 2>&1
        _qb_api_post /api/v2/search/delete --data-urlencode "id=$job_id" >/dev/null 2>&1
        trap - INT
        _qb_failure "Failed to fetch search results"
        return 1
    }

    if [[ "$job_status" != "Stopped" ]]; then
        _qb_api_post /api/v2/search/stop --data-urlencode "id=$job_id" >/dev/null 2>&1
        _qb_cleanup_spinner
        printf '\r\033[2K'
        _qb_line info "Search timed out after ${timeout}s; showing partial results"
    else
        _qb_success "Search finished"
    fi

    sorted_json="$(_qb_search_sort_json "$results_json")" || sorted_json="[]"

    _qb_api_post /api/v2/search/delete --data-urlencode "id=$job_id" >/dev/null 2>&1
    trap - INT

    if [[ -n "$add_n" ]]; then
        _qb_search_print_page "$sorted_json" 0 "$page_size" "$cols" ""
        add_url="$(_qb_search_url_at "$sorted_json" "$add_n")" || return 1
        _qb_add "$add_url"
        return $?
    fi

    _qb_search_browse "$sorted_json" "$page_size" "$cols"
}

# API results JSON → sorted JSON array (seeds desc).
_qb_search_sort_json() {
    local results_json="$1"

    python3 - "$results_json" <<'PY'
import json
import sys

try:
    data = json.loads(sys.argv[1])
    rows = list(data.get("results") or [])
except Exception as e:
    print(f"Failed to parse results: {e}", file=sys.stderr)
    sys.exit(1)

def seeds(row):
    try:
        return int(row.get("nbSeeders") or 0)
    except (TypeError, ValueError):
        return 0

rows.sort(key=seeds, reverse=True)
print(json.dumps(rows, separators=(",", ":")))
PY
}

_qb_search_url_at() {
    local sorted_json="$1"
    local idx="$2"

    python3 - "$sorted_json" "$idx" <<'PY'
import json
import sys

try:
    rows = json.loads(sys.argv[1])
except Exception as e:
    print(f"parse error: {e}", file=sys.stderr)
    sys.exit(1)

idx = int(sys.argv[2])
if idx < 1 or idx > len(rows):
    print(f"No result #{idx} (have {len(rows)})", file=sys.stderr)
    sys.exit(1)

url = (rows[idx - 1].get("fileUrl") or "").strip()
if not url:
    print("Result has no magnet/file URL", file=sys.stderr)
    sys.exit(1)
print(url)
PY
}

# Print one page of a sorted results JSON array.
# page is 0-based. status_note optional footer context.
_qb_search_print_page() {
    local sorted_json="$1"
    local page="$2"
    local page_size="$3"
    local cols="$4"
    local status_note="${5:-}"

    python3 - "$sorted_json" "$page" "$page_size" "$cols" "$status_note" <<'PY'
import json
import sys
from urllib.parse import urlparse


def human_bytes(n):
    try:
        n = float(n)
    except (TypeError, ValueError):
        return "?"
    if n < 0:
        return "?"
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    for unit in units:
        if n < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(n)} {unit}"
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def short_site(url):
    if not url:
        return "-"
    try:
        host = urlparse(url).netloc or url
    except Exception:
        host = url
    if host.startswith("www."):
        host = host[4:]
    return host


def trunc(text, width):
    text = str(text)
    if width <= 1:
        return "…"
    if len(text) <= width:
        return text
    return text[: width - 1] + "…"


try:
    rows = json.loads(sys.argv[1])
except Exception as e:
    print(f"Failed to parse results: {e}", file=sys.stderr)
    sys.exit(1)

page = int(sys.argv[2])
page_size = int(sys.argv[3])
cols = int(sys.argv[4] or 80)
status_note = sys.argv[5] if len(sys.argv) > 5 else ""

total = len(rows)
pages = max(1, (total + page_size - 1) // page_size) if total else 1
if page < 0:
    page = 0
if page >= pages:
    page = pages - 1

start = page * page_size
chunk = rows[start : start + page_size]

if not rows:
    print("No results.")
    sys.exit(0)

# Fixed columns: # SIZE SEEDS LEECH SITE — NAME gets the remainder.
idx_w = max(2, len(str(start + len(chunk))))
size_w = 8
seeds_w = 5
leech_w = 5
site_w = 18
gap = 2
fixed = idx_w + size_w + seeds_w + leech_w + site_w + gap * 5
name_w = max(12, cols - fixed)
if name_w > 60:
    name_w = 60

headers = ("#", "NAME", "SIZE", "SEEDS", "LEECH", "SITE")
widths = [idx_w, name_w, size_w, seeds_w, leech_w, site_w]

def cell(text, width, align="left", cut=False):
    text = str(text)
    if cut:
        text = trunc(text, width)
    if align == "right":
        return text.rjust(width)[:width]
    return text.ljust(width)[:width]

print(f"Results: {total}  page {page + 1}/{pages}" + (f"  [{status_note}]" if status_note else ""))
print("  ".join(cell(h, widths[i]) for i, h in enumerate(headers)))
print("  ".join("-" * w for w in widths))

for i, row in enumerate(chunk):
    n = start + i + 1
    name = row.get("fileName") or "unknown"
    size = human_bytes(row.get("fileSize"))
    try:
        seeds = int(row.get("nbSeeders") or 0)
    except (TypeError, ValueError):
        seeds = 0
    try:
        leech = int(row.get("nbLeechers") or 0)
    except (TypeError, ValueError):
        leech = 0
    site = short_site(row.get("siteUrl") or "")
    print(
        "  ".join(
            [
                cell(n, idx_w, "right"),
                cell(name, name_w, cut=True),
                cell(size, size_w, "right"),
                cell(seeds, seeds_w, "right"),
                cell(leech, leech_w, "right"),
                cell(site, site_w, cut=True),
            ]
        )
    )
PY
}

# Interactive pagination (TTY): table + prompt for # / < > / q.
# Non-TTY: first page only.
_qb_search_browse() {
    local sorted_json="$1"
    local page_size="$2"
    local cols="$3"
    local page=0
    local pages
    local total
    local reply
    local add_url

    total="$(
        python3 - "$sorted_json" <<'PY'
import json
import sys
try:
    print(len(json.loads(sys.argv[1])))
except Exception:
    print(0)
PY
    )"

    if (( total == 0 )); then
        print "No results."
        return 0
    fi

    pages=$(( (total + page_size - 1) / page_size ))
    (( pages < 1 )) && pages=1

    if [[ ! -t 0 || ! -t 1 ]]; then
        _qb_search_print_page "$sorted_json" 0 "$page_size" "$cols" ""
        if (( pages > 1 )); then
            _qb_line info "Showing page 1/${pages}. Use a TTY to page / pick a #."
        fi
        _qb_line info "Add with: qb search … --add N"
        return 0
    fi

    while true; do
        printf '\033[H\033[2J'
        _qb_search_print_page "$sorted_json" "$page" "$page_size" "$cols" ""
        printf '\n'
        printf "Add # (1-%s), < > page, Enter/q quit: " "$total"
        read -r reply || break
        reply="${reply##[[:space:]]##}"
        reply="${reply%%[[:space:]]##}"

        case "$reply" in
            ''|q|Q)
                break
                ;;
            '>'|'.'|'l'|'L'|'n'|'N')
                if (( page < pages - 1 )); then
                    page=$((page + 1))
                fi
                ;;
            '<'|','|'h'|'H'|'p'|'P')
                if (( page > 0 )); then
                    page=$((page - 1))
                fi
                ;;
            <->)
                # zsh pattern: digits only
                if (( reply < 1 || reply > total )); then
                    _qb_line fail "Pick a # between 1 and $total"
                    printf "Press Enter…"
                    read -r
                    continue
                fi
                add_url="$(_qb_search_url_at "$sorted_json" "$reply")" || {
                    _qb_line fail "Could not resolve #$reply"
                    printf "Press Enter…"
                    read -r
                    continue
                }
                printf '\n'
                _qb_add "$add_url"
                return $?
                ;;
            *)
                _qb_line fail "Enter a result #, < or >, or q"
                printf "Press Enter…"
                read -r
                ;;
        esac
    done

    printf '\n'
    return 0
}

_qb_logs() {
    local lines="${2:-50}"

    if [[ ! "$lines" =~ '^[0-9]+$' ]]; then
        printf "Usage: qb logs [number-of-lines]\n"
        return 1
    fi

    _qb_require_stack || return 1

    docker logs --tail "$lines" -f qbittorrent
}

_qb_shell() {
    _qb_require_stack || return 1

    docker exec -it qbittorrent /bin/bash
}

_qb_info() {
    _qb_require_stack || return 1

    docker inspect qbittorrent \
    --format 'Name: {{.Name}}
Image: {{.Config.Image}}
Status: {{.State.Status}}
Started: {{.State.StartedAt}}
    Restart policy: {{.HostConfig.RestartPolicy.Name}}'
    
    printf "\nMounts:\n"
    
    docker inspect qbittorrent \
    --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}'
    
    printf "\nPorts:\n"
    
    docker port qbittorrent 2>/dev/null || true
}

_qb_version() {
    _qb_require_stack || return 1

    local version

    version="$(
        curl -fsS "$QB_URL/api/v2/app/version"
        )" || {
        _qb_failure "Failed to get qBittorrent version"
        return 1
    }

    printf "qBittorrent %s\n" "$version"
}

_qb_update() {
    _qb_require_stack || return 1
    _qb_require_api || return 1
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_start_ui

    cd "$QB_DIR" || {
        _qb_failure "qBittorrent directory not found"
        return 1
    }

    local response
    response="$(_qb_active_downloads)" || {
        _qb_failure "Failed to check active downloads"
        return 1
    }
    
    local active_count
    active_count="$(_qb_active_download_count "$response")"
    
    if [[ "$active_count" == "-1" ]]; then
        _qb_failure "Failed to determine active download state"
        return 1
    fi
    
    if (( active_count > 0 )); then
        _qb_failure "Update cancelled: $active_count active download(s)"
        printf "Run: qb torrents\n"
        return 1
    fi
    
    _qb_success "No active downloads"

    local image
    image="$(_qb_service_image)" || {
        _qb_failure "Failed to resolve qBittorrent image"
        return 1
    }

    local old_id
    old_id="$(_qb_image_id "$image")" || {
        _qb_failure "Failed to inspect current qBittorrent image"
        return 1
    }

    local local_digest remote_digest
    local_digest="$(_qb_local_repo_digest "$image")"
    remote_digest="$(_qb_remote_index_digest "$image")"

    if [[ -n "$local_digest" && -n "$remote_digest" ]]; then
        if _qb_digests_equal "$local_digest" "$remote_digest"; then
            _qb_line ok "Already up to date"
            return 0
        fi

        _qb_line info "Newer image available"
    else
        _qb_line off "Could not compare digests; pulling to verify"
    fi

    _qb_spinner "Pulling latest qBittorrent image..."
    
    if ! docker compose pull >/dev/null 2>&1; then
        _qb_failure "Failed to pull qBittorrent image"
        return 1
    fi
    
    _qb_success "qBittorrent image pulled"

    local new_id
    new_id="$(_qb_image_id "$image")" || {
        _qb_failure "Failed to inspect pulled qBittorrent image"
        return 1
    }

    if [[ "$old_id" == "$new_id" ]]; then
        _qb_line ok "Already up to date"
        return 0
    fi
    
    _qb_spinner "Recreating qBittorrent..."
    
    if ! docker compose up -d --force-recreate >/dev/null 2>&1; then
        _qb_failure "Failed to recreate qBittorrent"
        return 1
    fi
    
    _qb_success "qBittorrent recreated"
    
    _qb_spinner "Waiting for WebUI..."
    
    if ! _qb_wait_for_webui 60; then
        _qb_failure "WebUI did not become available"
        return 1
    fi
    
    _qb_success "WebUI ready"

    if _qb_remove_image_id "$old_id"; then
        _qb_line ok "Removed previous image $(_qb_short_image_id "$old_id")"
    else
        _qb_line off "Previous image left in place (in use or already gone)"
    fi

    _qb_present_webui
}

_qb_images() {
    _qb_require_docker || return 1

    python3 <<'PY'
import json
import subprocess
import sys


def run(args):
    return subprocess.check_output(args, text=True)


def human(size):
    value = float(size)
    units = ["B", "KiB", "MiB", "GiB", "TiB"]
    unit = units[0]
    for candidate in units:
        unit = candidate
        if value < 1024 or candidate == units[-1]:
            break
        value /= 1024
    if unit == "B":
        return f"{int(value)} {unit}"
    return f"{value:.1f} {unit}"


def short_id(image_id):
    if image_id.startswith("sha256:"):
        image_id = image_id[7:]
    return image_id[:12]


rows = []
seen_ids = set()

try:
    tagged = run(
        [
            "docker",
            "images",
            "--filter",
            "reference=*qbittorrent*",
            "--format",
            "{{json .}}",
        ]
    )
except subprocess.CalledProcessError:
    print("Failed to list qBittorrent images", file=sys.stderr)
    raise SystemExit(1)

for line in tagged.splitlines():
    if not line.strip():
        continue
    item = json.loads(line)
    image_id = item["ID"]
    rows.append(
        {
            "id": image_id,
            "repository": item.get("Repository", "<none>"),
            "tag": item.get("Tag", "<none>"),
            "created": item.get("CreatedSince", ""),
        }
    )
    seen_ids.add(image_id)

try:
    dangling = run(["docker", "images", "-f", "dangling=true", "-q"])
except subprocess.CalledProcessError:
    dangling = ""

for image_id in {line.strip() for line in dangling.splitlines() if line.strip()}:
    if image_id in seen_ids:
        continue
    try:
        labels = run(
            [
                "docker",
                "image",
                "inspect",
                image_id,
                "--format",
                "{{json .Config.Labels}}",
            ]
        ).strip()
    except subprocess.CalledProcessError:
        continue

    blob = labels.lower() if labels and labels != "null" else ""
    if "qbittorrent" not in blob:
        continue

    rows.append(
        {
            "id": image_id,
            "repository": "<none>",
            "tag": "<none>",
            "created": "dangling",
        }
    )
    seen_ids.add(image_id)

if not rows:
    print("No qBittorrent images found.")
    raise SystemExit(0)

sizes = {}
for image_id in sorted(seen_ids):
    try:
        size = int(
            run(
                [
                    "docker",
                    "image",
                    "inspect",
                    image_id,
                    "--format",
                    "{{.Size}}",
                ]
            ).strip()
        )
    except Exception:
        size = 0
    sizes[image_id] = size

print(f"{'REPOSITORY':<40} {'TAG':<16} {'IMAGE ID':<12} {'SIZE':>10}  CREATED")
for row in rows:
    print(
        f"{row['repository']:<40} {row['tag']:<16} {short_id(row['id']):<12} "
        f"{human(sizes.get(row['id'], 0)):>10}  {row['created']}"
    )

unique_count = len(seen_ids)
tag_count = len(rows)
total = sum(sizes.values())

print()
print(f"Images: {unique_count} unique ({tag_count} tag(s)/row(s))")
print(f"Total:  {human(total)}")
print()
print("Note: sizes are per-image logical size; shared layers may mean less disk than the sum.")
PY
}

_qb_prune() {
    local keep_id
    local image_id
    local removed=0
    local skipped=0
    local -a candidates
    local -A seen

    _qb_require_docker || return 1

    keep_id="$(_qb_kept_image_id)" || {
        _qb_failure "Failed to resolve the image to keep"
        return 1
    }

    candidates=("${(@f)$(
        docker images \
            --filter 'reference=*qbittorrent*' \
            --format '{{.ID}}' 2>/dev/null
    )}")

    for image_id in "${candidates[@]}"; do
        [[ -n "$image_id" ]] || continue
        [[ -n "${seen[$image_id]}" ]] && continue
        seen[$image_id]=1

        if _qb_image_ids_equal "$image_id" "$keep_id"; then
            skipped=$((skipped + 1))
            continue
        fi

        if _qb_remove_image_id "$image_id"; then
            _qb_line ok "Removed $(_qb_short_image_id "$image_id")"
            removed=$((removed + 1))
        else
            _qb_line off "Skipped $(_qb_short_image_id "$image_id") (in use or already gone)"
            skipped=$((skipped + 1))
        fi
    done

    if (( removed == 0 && skipped == 0 )); then
        _qb_line ok "No leftover qBittorrent images to prune"
        return 0
    fi

    _qb_line ok "Prune finished (removed $removed, kept/skipped $skipped)"
    _qb_line info "Keeping active image $(_qb_short_image_id "$keep_id")"
}

_qb_repair() {
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_start_ui

    if ! _qb_docker_running; then
        _qb_spinner "Starting Docker Desktop..."
        
        if ! docker desktop start >/dev/null 2>&1 ||
        ! _qb_wait_for_docker 60; then
            _qb_failure "Failed to start Docker Desktop"
            return 1
        fi
        
        _qb_success "Docker Desktop started"
    fi
    
    local active_count="0"
    
    if _qb_container_running && _qb_webui_ready; then
        _qb_require_api || return 1

        local response
        
        response="$(_qb_active_downloads)" || {
            _qb_failure "Could not check active downloads"
            return 1
        }
        
        active_count="$(_qb_active_download_count "$response")"
        
        if [[ "$active_count" == "-1" ]]; then
            _qb_failure "Could not determine active downloads"
            return 1
        fi
        
        if (( active_count > 0 )); then
            _qb_failure "Repair cancelled: $active_count active download(s)"
            printf "Run: qb torrents\n"
            return 1
        fi
    fi
    
    _qb_spinner "Removing qBittorrent container..."
    
    if docker rm -f qbittorrent >/dev/null 2>&1; then
        _qb_success "qBittorrent container removed"
    else
        if _qb_container_exists; then
            _qb_failure "Failed to remove qBittorrent container"
            return 1
        fi
        
        _qb_success "qBittorrent container removed"
    fi
    
    cd "$QB_DIR" || {
        _qb_failure "qBittorrent directory not found"
        return 1
    }
    
    _qb_spinner "Recreating qBittorrent..."
    
    if ! docker compose up -d --force-recreate >/dev/null 2>&1; then
        _qb_failure "Failed to recreate qBittorrent"
        return 1
    fi
    
    _qb_success "qBittorrent recreated"
    
    _qb_spinner "Waiting for WebUI..."
    
    if ! _qb_wait_for_webui 60; then
        _qb_failure "WebUI did not become available"
        return 1
    fi
    
    _qb_success "WebUI ready"
    
    _qb_present_webui
}

_qb_doctor() {
    local issues=0

    printf "qBittorrent diagnostics\n\n"

    if _qb_docker_running; then
        _qb_line ok "Docker Desktop: $(_qb_state running)"
    else
        _qb_line fail "Docker Desktop: $(_qb_state stopped)"
        issues=1
    fi

    if _qb_container_exists; then
        _qb_line ok "Container: $(_qb_state exists)"
    else
        _qb_line fail "Container: $(_qb_state missing)"
        issues=1
    fi

    if _qb_container_running; then
        _qb_line ok "Container: $(_qb_state running)"
    else
        _qb_line off "Container: $(_qb_state stopped)"
    fi

    if _qb_container_running; then
        if _qb_webui_ready; then
            _qb_line ok "WebUI: $(_qb_state reachable)"
        else
            _qb_line fail "WebUI: $(_qb_state unreachable)"
            issues=1
        fi

        if _qb_port_listening 8080; then
            _qb_line ok "Port 8080: $(_qb_state listening)"
        else
            _qb_line fail "Port 8080: not listening"
            issues=1
        fi
    else
        _qb_line off "WebUI: $(_qb_state unavailable)"
        _qb_line off "Port 8080: not listening"
    fi

    if _qb_container_exists; then
        if _qb_container_mounts_ok; then
            _qb_line ok "Mounts: /config /downloads /plugins"
        else
            _qb_line fail "Mounts: missing expected paths"
            issues=1
        fi
    else
        _qb_line off "Mounts: $(_qb_state skipped)"
    fi

    if [[ -d "$QB_DIR/config" ]]; then
        _qb_line ok "Config directory: $(_qb_state present)"
    else
        _qb_line fail "Config directory: $(_qb_state missing)"
        issues=1
    fi

    if [[ -d "$QB_DOWNLOADS" ]]; then
        _qb_line ok "Downloads directory: $QB_DOWNLOADS"
    else
        _qb_line fail "Downloads directory missing: $QB_DOWNLOADS"
        issues=1
    fi

    if [[ -d "$QB_DIR/plugins" ]]; then
        _qb_line ok "Plugins directory: $(_qb_state present)"
    else
        _qb_line fail "Plugins directory: $(_qb_state missing)"
        issues=1
    fi

    local days
    if days="$(_qb_image_age_days)"; then
        if (( days >= QB_IMAGE_STALE_DAYS )); then
            _qb_line info "Image age: $days day(s) (consider qb update)"
        else
            _qb_line ok "Image age: $days day(s)"
        fi
    else
        _qb_line off "Image age: $(_qb_state unknown)"
    fi

    if ! _qb_api_key_usable; then
        _qb_line fail "API key: missing or not set"
        _qb_api_key_hint
        issues=1
    elif ! _qb_webui_ready; then
        _qb_line ok "API key file: $(_qb_state present)"
        _qb_line off "API: $(_qb_state skipped) (WebUI unavailable)"
    elif _qb_api_ok; then
        _qb_line ok "API key file: $(_qb_state present)"
        _qb_line ok "API: authorized"
    else
        _qb_line ok "API key file: $(_qb_state present)"
        _qb_line fail "API: authorization failed (incorrect or revoked key)"
        _qb_api_key_hint
        issues=1
    fi

    return "$issues"
}

_qb_layout() {
    local layout_js="$QB_DIR/webui-layout.js"
    local err

    if [[ ! -f "$layout_js" ]]; then
        _qb_failure "Layout script not found: $layout_js"
        return 1
    fi

    _qb_require_stack || return 1

    if [[ ! -d "$QB_APP" ]]; then
        _qb_failure "qBittorrent.app not found"
        return 1
    fi

    _qb_open_app || return 1

    _qb_spinner "Applying WebUI column layout..."

    if err="$(
        osascript - "$layout_js" <<'APPLESCRIPT' 2>&1
on run argv
    set jsPath to item 1 of argv
    set js to do shell script "cat " & quoted form of jsPath

    tell application "qBittorrent"
        activate
        delay 2
        do JavaScript js in front document
    end tell
end run
APPLESCRIPT
    )"; then
        _qb_success "WebUI column layout applied"
        _qb_line info "Only needed again if Safari site data is cleared"
        return 0
    fi

    _qb_failure "Failed to apply WebUI layout"
    printf "qb layout injects only into the Dock Web App (not a Safari tab).\n"
    printf "Needs: Safari → Develop → Allow JavaScript from Apple Events\n"
    printf "That setting lets other apps inject JS into Safari pages; turn it off after use if you prefer.\n"
    printf "Safer alternative: paste webui-layout.js into the Web Inspector console (see README).\n"

    if [[ -n "$err" ]]; then
        printf "%s\n" "$err"
    fi

    return 1
}

_qb_help() {
    printf '%s\n' \
        "Usage:" \
        "" \
        "  qb start       Start Docker + qBittorrent; open Dock app unless QB_START_UI=cli" \
        "  qb start --cli Start stack only; do not open Dock Web App" \
        "  qb quit        Stop qBittorrent; stop Docker Desktop if nothing else is running" \
        "  qb restart     Restart qBittorrent" \
        "  qb status      Show current state" \
        "  qb torrents    List torrents (hash, progress, speeds, state)" \
        "  qb torrents --watch  Redraw torrent list every 2s" \
        "  qb show        Show torrent details and files" \
        "  qb add         Add magnet or http(s) torrent URL" \
        "  qb pause       Pause torrent(s) by hash prefix or name" \
        "  qb resume      Resume torrent(s) by hash prefix or name" \
        "  qb remove      Remove torrent(s); --files also deletes data" \
        "  qb recheck     Recheck torrent(s)" \
        "  qb reannounce  Force tracker reannounce" \
        "  qb force       Enable force start (--off to disable)" \
        "  qb alt         Toggle alternative global speed limits" \
        "  qb plugins     Manage search plugins (list/install/enable/…)" \
        "  qb search      Search via enabled plugins; --add N to download" \
        "  qb logs        Follow last 50 log lines" \
        "  qb logs 200    Follow last 200 log lines" \
        "  qb shell       Enter qBittorrent container" \
        "  qb info        Show container details" \
        "  qb version     Show qBittorrent version" \
        "  qb update      Digest-check then pull only if newer; drop old image" \
        "  qb images      Show local qBittorrent images and disk use" \
        "  qb prune       Remove unused local qBittorrent images (keeps the active one)" \
        "  qb repair      Recreate a broken qBittorrent container" \
        "  qb doctor      Diagnose Docker, mounts, API, port, and local dirs" \
        "  qb layout      Optional: apply WebUI column layout (needs Safari Apple Events JS; see README)"
}

qb() {
    emulate -L zsh

    _qb_refresh_style
    _qb_refresh_downloads
    _qb_refresh_webui_bind
    _qb_refresh_quit_docker
    _qb_refresh_start_ui
    _qb_update_color_ok

    case "$1" in
        start)
            shift
            _qb_start "$@"
            ;;

        quit)
            _qb_quit
            ;;

        restart)
            _qb_restart
            ;;

        status)
            _qb_status
            ;;

        torrents)
            shift
            _qb_torrents "$@"
            ;;

        add)
            shift
            _qb_add "$@"
            ;;

        pause)
            shift
            _qb_pause "$@"
            ;;

        resume)
            shift
            _qb_resume "$@"
            ;;

        remove)
            shift
            _qb_remove "$@"
            ;;

        show)
            shift
            _qb_show "$@"
            ;;

        recheck)
            shift
            _qb_recheck "$@"
            ;;

        reannounce)
            shift
            _qb_reannounce "$@"
            ;;

        force)
            shift
            _qb_force "$@"
            ;;

        alt)
            shift
            _qb_alt "$@"
            ;;

        plugins)
            shift
            _qb_plugins "$@"
            ;;

        search)
            shift
            _qb_search "$@"
            ;;

        logs)
            _qb_logs "$@"
            ;;

        shell)
            _qb_shell
            ;;

        info)
            _qb_info
            ;;

        version)
            _qb_version
            ;;

        update)
            _qb_update
            ;;

        images)
            _qb_images
            ;;

        prune)
            _qb_prune
            ;;

        repair)
            _qb_repair
            ;;

        doctor)
            _qb_doctor
            ;;

        layout)
            _qb_layout
            ;;

        help|-h|--help)
            _qb_help
            ;;

        "")
            _qb_help
            ;;

        *)
            _qb_line fail "Unknown command: $1"
            printf "Run: qb help\n"
            return 1
            ;;
    esac
}

# Tab-complete subcommands after `qb` (e.g. `qb <Tab>` → start, quit, …).
# Does not attach to a bare `q`. Registers only if compinit already ran.
_qb_complete() {
    local -a commands

    commands=(
        start quit restart status torrents show add pause resume remove
        recheck reannounce force alt plugins search
        logs shell info version update images prune repair doctor layout help
    )

    if (( CURRENT == 2 )); then
        _describe 'command' commands
    fi
}

if (( $+functions[compdef] )); then
    compdef _qb_complete qb
fi

_qb_refresh_style
_qb_refresh_downloads
_qb_refresh_webui_bind
_qb_refresh_quit_docker
_qb_refresh_start_ui
_qb_update_color_ok
