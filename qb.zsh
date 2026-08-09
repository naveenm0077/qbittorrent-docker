# qBittorrent CLI
# Loaded from ~/.zshrc

emulate -L zsh

QB_DIR="$HOME/qbittorrent"
QB_DOWNLOADS_DEFAULT="$HOME/Downloads/qbittorrent-downloads"
QB_DOWNLOADS="$QB_DOWNLOADS_DEFAULT"
QB_APP="$HOME/Applications/qBittorrent.app"
QB_URL="http://localhost:8080"
QB_API_KEY_FILE="$QB_DIR/.env.qbittorrent"
QB_IMAGE_STALE_DAYS=60
QB_QUIT_LOCK="/tmp/qb-quit.lock"
QB_STYLE_DEFAULT="color"
typeset -g QB_STYLE="$QB_STYLE_DEFAULT"
QB_WEBUI_BIND_DEFAULT="localhost"
typeset -g QB_WEBUI_BIND="$QB_WEBUI_BIND_DEFAULT"
typeset -g QB_WEBUI_PUBLISH="127.0.0.1:8080"
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

    if [[ -f "$QB_QUIT_LOCK" ]]; then
        pid="$(<"$QB_QUIT_LOCK" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            _qb_line info "Quit already in progress"
            return 1
        fi
    fi

    printf '%s\n' "$$" >"$QB_QUIT_LOCK" || return 1
    return 0
}

_qb_quit_lock_release() {
    rm -f "$QB_QUIT_LOCK" 2>/dev/null
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
# Shown only when the image is at least QB_IMAGE_STALE_DAYS old.
_qb_image_age_notice() {
    local days

    days="$(_qb_image_age_days)" || return 0

    if (( days >= QB_IMAGE_STALE_DAYS )); then
        _qb_line info "Image is $days days old. Consider: qb update"
    fi
}

_qb_app_running() {
    [[ "$(
        osascript -e 'tell application "qBittorrent" to get running' 2>/dev/null
    )" == "true" ]]
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

    _qb_open_app
}

_qb_quit() {
    _qb_refresh_downloads
    _qb_refresh_webui_bind

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

        if [[ -n "$other_containers" ]]; then
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
        
        _qb_open_app
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

    _qb_line info "Output style: $QB_STYLE"
    _qb_line info "WebUI bind: $QB_WEBUI_BIND"
}

_qb_torrents() {
    _qb_require_stack || return 1
    _qb_require_api || return 1

    local response
    response="$(_qb_active_downloads)" || {
        _qb_failure "Failed to query qBittorrent"
        return 1
    }
    
    python3 - "$response" <<'PY'
import json
import sys

try:
    torrents = json.loads(sys.argv[1])

    if not torrents:
        print("No active downloads.")
        sys.exit(0)

    for torrent in torrents:
        speed = torrent.get("dlspeed", 0) / 1024 / 1024
        progress = torrent.get("progress", 0) * 100
        state = torrent.get("state", "unknown")
        name = torrent.get("name", "unknown")

        print(name)
        print(f"  {progress:.2f}% | {speed:.2f} MiB/s | {state}")

except Exception as e:
    print(f"Failed to parse qBittorrent response: {e}", file=sys.stderr)
    sys.exit(1)
PY
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

    _qb_open_app
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
    
    _qb_open_app
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
        "  qb start       Start Docker + qBittorrent + open/focus WebUI app" \
        "  qb quit        Stop qBittorrent + Docker safely" \
        "  qb restart     Restart qBittorrent" \
        "  qb status      Show current state" \
        "  qb torrents    Show active downloads" \
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
    _qb_update_color_ok

    case "$1" in
        start)
            _qb_start
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
            _qb_torrents
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
        start quit restart status torrents logs shell
        info version update images prune repair doctor layout help
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
_qb_update_color_ok
