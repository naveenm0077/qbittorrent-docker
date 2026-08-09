# qBittorrent CLI
# Loaded from ~/.zshrc

emulate -L zsh

QB_DIR="$HOME/qbittorrent"
QB_DOWNLOADS="$HOME/Downloads/qbittorrent-downloads"
QB_APP="$HOME/Applications/qBittorrent.app"
QB_URL="http://localhost:8080"
QB_API_KEY_FILE="$QB_DIR/.env.qbittorrent"
QB_IMAGE_STALE_DAYS=60
QB_QUIT_LOCK="/tmp/qb-quit.lock"

typeset -g QB_SPINNER_PID=""

_qb_cleanup_spinner() {
    if [[ -n "$QB_SPINNER_PID" ]]; then
        kill "$QB_SPINNER_PID" 2>/dev/null
        wait "$QB_SPINNER_PID" 2>/dev/null
        QB_SPINNER_PID=""
    fi
}

_qb_spinner() {
    local message="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    
    (
        local i=1
        
        while true; do
            printf "\r\033[2K%s %s" "${frames[i]}" "$message"
            i=$((i % ${#frames[@]} + 1))
            sleep 0.08
        done
    ) &!
    
    QB_SPINNER_PID=$!
}

_qb_success() {
    _qb_cleanup_spinner
    printf "\r\033[2K✓ %s\n" "$1"
}

_qb_failure() {
    _qb_cleanup_spinner
    printf "\r\033[2K✗ %s\n" "$1"
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
            printf "→ Quit already in progress\n"
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
    [[ -f "$QB_API_KEY_FILE" ]] || return 1
    
    sed 's/^QBIT_API_KEY=//' "$QB_API_KEY_FILE"
}

_qb_api_ok() {
    local api_key

    api_key="$(_qb_api_key)" || return 1
    api_key="${api_key//$'\r'/}"
    api_key="${api_key//$'\n'/}"

    [[ -n "$api_key" ]] || return 1
    [[ "$api_key" != "replace_with_your_qbittorrent_webui_api_key" ]] || return 1

    curl -fsS \
    -H "Authorization: Bearer $api_key" \
    "$QB_URL/api/v2/app/version" >/dev/null 2>&1
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
    local api_key
    api_key="$(_qb_api_key)" || return 1
    
    curl -fsS \
    -H "Authorization: Bearer $api_key" \
    "$QB_URL/api/v2/torrents/info?filter=downloading"
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
        printf "→ Image is %s days old. Consider: qb update\n" "$days"
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
            printf "✓ qBittorrent WebUI already open\n"
            return 0
        fi

        _qb_failure "Failed to focus qBittorrent WebUI"
        return 1
    fi

    printf "↗ Opening qBittorrent\n"

    if open -a "$QB_APP" >/dev/null 2>&1; then
        return 0
    fi

    _qb_failure "Failed to open qBittorrent WebUI"
    return 1
}

_qb_close_app() {
    if _qb_app_running; then
        if osascript -e 'tell application "qBittorrent" to quit' >/dev/null 2>&1; then
            printf "✓ qBittorrent WebUI closed\n"
        else
            _qb_failure "Failed to close qBittorrent WebUI"
            return 1
        fi
    else
        printf "✓ qBittorrent WebUI already closed\n"
    fi
}

_qb_start() {
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
    fi
    
    if ! _qb_webui_ready; then
        _qb_spinner "Waiting for WebUI..."
        
        if ! _qb_wait_for_webui 60; then
            _qb_failure "WebUI did not become available"
            return 1
        fi
        
        _qb_success "WebUI ready"
    else
        printf "✓ WebUI ready\n"
    fi

    _qb_image_age_notice

    _qb_open_app
}

_qb_quit() {
    if ! _qb_quit_lock_acquire; then
        return 0
    fi
    trap '_qb_quit_lock_release; trap - EXIT' EXIT

    # Already fully stopped.
    if ! _qb_app_running && ! _qb_container_running; then
        if ! _qb_docker_running; then
            printf "✓ qBittorrent already stopped\n"
            return 0
        fi

        local other_containers
        other_containers="$(_qb_other_containers)"

        if [[ -n "$other_containers" ]]; then
            printf "✓ qBittorrent already stopped\n"
            printf "→ Leaving Docker Desktop running\n"
            return 0
        fi

        _qb_spinner "Stopping Docker Desktop..."

        if ! docker desktop stop --detach >/dev/null 2>&1; then
            _qb_failure "Failed to stop Docker Desktop"
            return 1
        fi

        _qb_success "Docker Desktop stopped"
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

        _qb_success "qBittorrent stopped"
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

        printf "✓ %s other Docker container(s) still running\n" "$other_count"
        printf "→ Leaving Docker Desktop running\n"
        return 0
    fi

    _qb_spinner "Stopping Docker Desktop..."

    if ! docker desktop stop --detach >/dev/null 2>&1; then
        _qb_failure "Failed to stop Docker Desktop"
        return 1
    fi

    _qb_success "Docker Desktop stopped"
}

_qb_restart() {
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
        printf "✓ Docker Desktop: running\n"
    else
        printf "○ Docker Desktop: stopped\n"
    fi
    
    if _qb_container_running; then
        printf "✓ qBittorrent: running\n"
    else
        printf "○ qBittorrent: stopped\n"
    fi
    
    if _qb_webui_ready; then
        printf "✓ WebUI: ready\n"
    else
        printf "○ WebUI: unavailable\n"
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
            
            printf "✓ Other containers: %s\n" "$other_count"
        else
            printf "○ Other containers: 0\n"
        fi
    fi
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
            printf "✓ Already up to date\n"
            return 0
        fi

        printf "→ Newer image available\n"
    else
        printf "○ Could not compare digests; pulling to verify\n"
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
        printf "✓ Already up to date\n"
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
        printf "✓ Removed previous image %s\n" "$(_qb_short_image_id "$old_id")"
    else
        printf "○ Previous image left in place (in use or already gone)\n"
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
            printf "✓ Removed %s\n" "$(_qb_short_image_id "$image_id")"
            removed=$((removed + 1))
        else
            printf "○ Skipped %s (in use or already gone)\n" \
                "$(_qb_short_image_id "$image_id")"
            skipped=$((skipped + 1))
        fi
    done

    if (( removed == 0 && skipped == 0 )); then
        printf "✓ No leftover qBittorrent images to prune\n"
        return 0
    fi

    printf "✓ Prune finished (removed %s, kept/skipped %s)\n" "$removed" "$skipped"
    printf "→ Keeping active image %s\n" "$(_qb_short_image_id "$keep_id")"
}

_qb_repair() {
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
        printf "✓ Docker Desktop: running\n"
    else
        printf "✗ Docker Desktop: stopped\n"
        issues=1
    fi
    
    if _qb_container_exists; then
        printf "✓ Container: exists\n"
    else
        printf "✗ Container: missing\n"
        issues=1
    fi
    
    if _qb_container_running; then
        printf "✓ Container: running\n"
    else
        printf "○ Container: stopped\n"
    fi
    
    if _qb_container_running; then
        if _qb_webui_ready; then
            printf "✓ WebUI: reachable\n"
        else
            printf "✗ WebUI: unreachable\n"
            issues=1
        fi

        if _qb_port_listening 8080; then
            printf "✓ Port 8080: listening\n"
        else
            printf "✗ Port 8080: not listening\n"
            issues=1
        fi
    else
        printf "○ WebUI: unavailable\n"
        printf "○ Port 8080: not listening\n"
    fi

    if _qb_container_exists; then
        if _qb_container_mounts_ok; then
            printf "✓ Mounts: /config /downloads /plugins\n"
        else
            printf "✗ Mounts: missing expected paths\n"
            issues=1
        fi
    else
        printf "○ Mounts: skipped\n"
    fi
    
    if [[ -d "$QB_DIR/config" ]]; then
        printf "✓ Config directory: present\n"
    else
        printf "✗ Config directory: missing\n"
        issues=1
    fi
    
    if [[ -d "$QB_DOWNLOADS" ]]; then
        printf "✓ Downloads directory: present\n"
    else
        printf "✗ Downloads directory: missing\n"
        issues=1
    fi
    
    if [[ -d "$QB_DIR/plugins" ]]; then
        printf "✓ Plugins directory: present\n"
    else
        printf "✗ Plugins directory: missing\n"
        issues=1
    fi

    local days
    if days="$(_qb_image_age_days)"; then
        if (( days >= QB_IMAGE_STALE_DAYS )); then
            printf "→ Image age: %s day(s) (consider qb update)\n" "$days"
        else
            printf "✓ Image age: %s day(s)\n" "$days"
        fi
    else
        printf "○ Image age: unknown\n"
    fi
    
    if ! _qb_api_key_usable; then
        printf "✗ API key: missing or not set\n"
        _qb_api_key_hint
        issues=1
    elif ! _qb_webui_ready; then
        printf "✓ API key file: present\n"
        printf "○ API: skipped (WebUI unavailable)\n"
    elif _qb_api_ok; then
        printf "✓ API key file: present\n"
        printf "✓ API: authorized\n"
    else
        printf "✓ API key file: present\n"
        printf "✗ API: authorization failed (incorrect or revoked key)\n"
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
        printf "→ Only needed again if Safari site data is cleared\n"
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
            printf "✗ Unknown command: %s\n" "$1"
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
