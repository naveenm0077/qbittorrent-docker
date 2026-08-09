# qBittorrent for macOS

Dockerized qBittorrent with a Zsh CLI for macOS.

The qBittorrent service runs in Docker, stores downloads in `~/Downloads/qbittorrent-downloads` by default, and is managed with the `qb` command. A Safari Web App can be used as a local desktop wrapper for the WebUI.

## Requirements

- macOS
- Docker Desktop
- Zsh
- Python 3

## Setup

Clone this repository to `~/qbittorrent`, or update `QB_DIR` near the top of `qb.zsh` to match its location.

Create the local API-key file:

```zsh
cp .env.example .env.qbittorrent
```

Set `QBIT_API_KEY` in `.env.qbittorrent` to your WebUI API key:

1. Start qBittorrent (`qb start`) and open the WebUI.
2. **Tools → Options → Web UI**.
3. Under **Authentication**, copy or generate the **API key**.
4. Paste it into `.env.qbittorrent` as `QBIT_API_KEY=...` and save.

This file is ignored by Git. Commands like `qb torrents` and `qb update` need a valid key; if it is missing or wrong they print where to fix it.

### Custom download folder (optional)

By default downloads go to `~/Downloads/qbittorrent-downloads`. To use another host folder, set `QB_DOWNLOADS` in the same `.env.qbittorrent` file:

```zsh
QB_DOWNLOADS=/Volumes/Storage/torrents
```

`~` is expanded. You do not need this variable for the default path. After changing it, run `qb start` (recreates the container only if the mount differs) or `qb repair`.

Load the CLI from your `~/.zshrc`:

```zsh
source ~/qbittorrent/qb.zsh
```

Restart your shell or reload the configuration:

```zsh
source ~/.zshrc
```

### Tab completion (optional)

After `qb.zsh` is loaded, you can type `qb ` and press **Tab** to list or fill in subcommands (`start`, `quit`, `status`, and so on). Completion is tied to the full command name `qb`, not a bare `q`.

This uses zsh’s built-in completion system. For it to register, source `qb.zsh` **after** you initialize completions in `~/.zshrc`:

```zsh
autoload -Uz compinit
compinit
# ... other setup ...
source ~/qbittorrent/qb.zsh
```

Many Mac zsh setups (and Docker Desktop’s zsh snippet) already run `compinit`. If `compinit` was never set up, nothing fails: there is no prompt, warning, or error — Tab completion is simply unavailable and every `qb` command still works as usual.

Start qBittorrent:

```zsh
qb start
```

The WebUI is available at [http://localhost:8080](http://localhost:8080). In Safari, use **File → Add to Dock** to create the optional qBittorrent Web App wrapper.

`qb start` always opens or focuses that Dock Web App (`~/Applications/qBittorrent.app`). If it is already running, it only brings it to the front — it does not open a new Safari tab for `localhost:8080`.

### Docker Desktop tip (optional)

`qb start` may launch Docker Desktop. If you do not want the dashboard window to cover the screen when that happens:

1. Open **Docker Desktop → Settings → General**.
2. Turn off **Open Docker Dashboard when Docker Desktop starts**.
3. Click **Apply** (or **Apply & restart** if Docker offers it). The setting does nothing until it is applied.

After that, `qb start` can still start the Docker engine; the dashboard stays closed. The Docker icon may still appear in the Dock.

## Commands

| Command | Description |
| --- | --- |
| `qb start` | Start Docker Desktop if needed, start qBittorrent, and open/focus the Dock Web App (idempotent; never a Safari tab). Remounts if `QB_DOWNLOADS` changed. If the local image is 60+ days old, prints a one-line suggestion to run `qb update` (does not auto-update). |
| `qb quit` | Close the WebUI app and stop qBittorrent. Docker Desktop stops only when no other containers are running. |
| `qb restart` | Restart qBittorrent and wait for the WebUI. |
| `qb status` | Show Docker, container, WebUI, and other-container status. |
| `qb torrents` | List active downloads. |
| `qb logs [lines]` | Follow container logs; defaults to 50 lines. |
| `qb shell` | Open a shell in the qBittorrent container. |
| `qb info` | Show image, container, mount, and port details. |
| `qb version` | Show the running qBittorrent version. |
| `qb update` | Check registry digests first (no layer download); pull/recreate only when newer. If the check fails, falls back to pull-then-compare. Blocks while downloads are active; removes the previous image when safe. Run occasionally (for example monthly); `qb start` never auto-updates. |
| `qb images` | List local qBittorrent images (including dangling) with sizes and a unique total. |
| `qb prune` | Remove unused local qBittorrent images; always keeps the image currently used by the container/compose service. |
| `qb repair` | Recreate the qBittorrent container without touching downloads or configuration. |
| `qb doctor` | Check Docker, container, WebUI, mounts, API auth, port 8080, and local directories. |
| `qb layout` | Optional one-shot helper to apply the torrent table column layout (see below). |
| `qb help` | Show the command list. |

### When the stack is not running

- **Lifecycle** (`start`, `quit`, `restart`, `repair`): may change state. `start` / `restart` (when down) / `repair` can bring things up. `quit` is idempotent (finishes a partial shutdown; says already stopped if nothing is left; blocks overlapping quit spam).
- **Diagnose** (`status`, `doctor`, `help`): read-only; OK when everything is down.
- **Need a live stack** (`torrents`, `logs`, `shell`, `info`, `version`, `update`, `layout`): fail immediately with `Run: qb start` — checks qBittorrent via `/api/v2/app/version` (uses the API key when configured).
- **Need Docker only** (`images`, `prune`): fail with `Run: qb start` if the Docker engine is down.

## WebUI column layout (optional)

### What it is

qBittorrent’s WebUI torrent table can show many columns. Visibility and order are stored in the browser as `localStorage` keys (for example `column_name_visible_torrentsTableDiv` and `columns_order_torrentsTableDiv`). They are not part of the Docker `config/` on disk.

`webui-layout.js` is a small one-shot script that writes those keys, then reloads the page. It does not change download behavior, categories, or server settings — only which torrent-list columns you see and in what order.

You only need to apply it once per browser / Web App profile, unless you clear Safari site data for `http://localhost:8080`.

This is optional. Skip it if you prefer the default columns.

### How the script works (customize this)

Open `webui-layout.js`. There are two arrays — they do different jobs:

1. **`allColumns`** — every torrent-table column id the script knows about. For each key here, the script writes a visibility flag in `localStorage` (`column_<key>_visible_torrentsTableDiv`).
2. **`wanted`** — which of those columns should be **visible**, and in **what order**. Order in this array becomes `columns_order_torrentsTableDiv`.

So visibility and “being listed” are separate ideas:

| Goal | What to edit |
| --- | --- |
| Hide a column | Keep it in `allColumns`, remove it from `wanted` (script sets visible → `0`). |
| Show a column | Put its key in `wanted` (script sets visible → `1`). |
| Change column order | Reorder keys inside `wanted` only. |
| Teach the script about a column | Add the WebUI column id to `allColumns` first; then add it to `wanted` if you want it visible. |

A key only in `wanted` but missing from `allColumns` can still appear in the order string, but this script will not set that column’s visibility flag. Put keys you care about in **both** when you want the script to manage them.

The `wanted` list shipped in this repo is just a starter layout (compact download-focused columns). Change the arrays to suit you, save the file, then apply the script again (console paste or `qb layout`). You can also toggle columns from the WebUI table header menu; re-running the script overwrites browser prefs with whatever is in the file.

**Starter `wanted` in this repo** (visible, left → right):  
`name`, `progress`, `eta`, `total_size`, `downloaded`, `amount_left`, `dlspeed`, `num_seeds`, `num_leechs`, `status`, `ratio`

Anything else in `allColumns` is explicitly hidden by that starter layout.

### Column id reference

WebUI column ids used in `allColumns` / `wanted` (labels can vary slightly by qBittorrent version):

| Code key | Typical WebUI label | Code key | Typical WebUI label |
| --- | --- | --- | --- |
| `priority` | # / Priority | `category` | Category |
| `state_icon` | Status icon | `tags` | Tags |
| `name` | Name | `added_on` | Added On |
| `size` | Size | `completion_on` | Completed On |
| `total_size` | Total Size | `creation_date` | Creation Date |
| `progress` | Progress | `tracker` | Tracker |
| `status` | Status | `save_path` | Save Path |
| `num_seeds` | Seeds | `download_limit` | Down Limit |
| `num_leechs` | Peers | `upload_limit` | Up Limit |
| `dlspeed` | Down Speed | `downloaded_session` | Session Download |
| `upspeed` | Up Speed | `uploaded_session` | Session Upload |
| `downloaded` | Downloaded | `time_active` | Time Active |
| `uploaded` | Uploaded | `seeding_time` | Seeding Time |
| `amount_left` | Remaining | `seen_complete` | Seen Complete |
| `eta` | ETA | `last_activity` | Last Activity |
| `ratio` | Ratio | `availability` | Availability |
| `popularity` | Popularity | `last_seen_complete` | Last Seen Complete |

### Option A — Console paste (recommended)

No special Safari permissions. Same idea as pasting a snippet in a browser DevTools console.

1. Start the WebUI (`qb start`) so the Dock Web App is open.
2. Open the Web Inspector console for that Web App:  
   **Develop → [qBittorrent] → Show Web Inspector → Console**  
   (If **Develop** is missing: Safari → **Settings → Advanced → Show features for web developers**.)
3. Open `webui-layout.js` from this repo, copy its full contents, paste into the console, and press Enter.
4. The page reloads with the new columns.

### Option B — `qb layout`

Automates the same script by injecting into the Dock Web App only (not a Safari tab).

```zsh
qb layout
```

**Permission required (one-time Safari setting):**

1. Safari → **Settings → Advanced** → enable **Show features for web developers**.
2. Menu bar → **Develop → Allow JavaScript from Apple Events**.

**Risk:** that setting is global for Safari. While it is on, other apps on your Mac that can send Apple Events may run JavaScript in open Safari / Web App pages — not only `qb layout`. Safari disables it by default for that reason.

**Safer use:** turn the setting on → run `qb layout` → turn it off again. The column layout remains saved in `localStorage` after you disable the setting.

If automation fails, use Option A instead.

## Project directories

| Path | Purpose |
| --- | --- |
| `compose.yaml` | qBittorrent Docker service definition. |
| `qb.zsh` | `qb` CLI commands. |
| `config/` | Persistent qBittorrent configuration and session state. |
| `~/Downloads/qbittorrent-downloads` | Default download folder (override with `QB_DOWNLOADS`). |
| `plugins/` | Local qBittorrent search plugins. |
| `webui-layout.js` | Column layout script used by `qb layout`. |
| `.env.qbittorrent` | Local WebUI API key and optional `QB_DOWNLOADS`. |

`config/`, `plugins/`, and `.env.qbittorrent` are intentionally ignored by Git because they can contain local data, credentials, or third-party files.

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8080 | TCP | qBittorrent WebUI |
| 6881 | TCP/UDP | BitTorrent peer connections |

The WebUI is intended for local use. Do not expose port 8080 to an untrusted network without reviewing qBittorrent authentication and network settings.
