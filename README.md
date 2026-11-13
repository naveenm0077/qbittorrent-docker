# qBittorrent for macOS

Dockerized qBittorrent with a Zsh CLI for macOS.

The qBittorrent service runs in Docker, stores downloads in `~/Downloads/qbittorrent-downloads` by default, and is managed with the `qb` command. A Safari Web App can be used as a local desktop wrapper for the WebUI.

## Requirements

- macOS
- Docker Desktop
- Zsh
- Python 3

## Setup

Clone this repository anywhere (the examples below use `~/projects/qbittorrent`). `qb.zsh` locates its own directory when sourced, so no path needs editing.

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

### Output style (optional)

CLI messages default to **color** (same marks as `gh`: green `✓`, red `X`, plus colored status words). Set in `.env.qbittorrent`:

```zsh
QB_STYLE=bare    # ✓ / X / ■ — no color; plain braille spinner
QB_STYLE=color   # same marks + ANSI (default; like gh); green braille spinner
QB_STYLE=emoji   # ✅ ❌ 🛑 ➡️ ↗️; moon-phase spinner
```

Color is skipped when output is not a TTY or when `NO_COLOR` is set. Set `FORCE_COLOR=1` to keep ANSI even when piped.

### WebUI network bind (optional)

By default Docker publishes the WebUI on **localhost only** (`127.0.0.1:<port>`), so other devices on your Wi‑Fi cannot open the login page. The app inside the container still listens normally; this only limits the host publish.

To allow LAN access (still needs password / API key):

```zsh
QB_WEBUI_BIND=lan
```

Then run `qb start` (recreates if the publish changed) or `qb repair`. Peer port `6881` is unchanged.

### WebUI port (optional)

The WebUI uses port **8090** by default. If another service on the Mac already uses that port, set a different one in `.env.qbittorrent`:

```zsh
QB_WEBUI_PORT=9090
```

This is the only place the port is set: `qb` exports it, and `compose.yaml` uses it for both the container's `WEBUI_PORT` and the host publish. Run `qb start` (recreates if the port changed) or `qb repair`.

The WebUI URL changes with the port, so a Dock Web App created for the old URL must be re-created (**File → Add to Dock** at the new URL), and the column layout re-applied with `qb layout`.

### Container user and timezone (optional)

The container runs as the current Mac user and group (`id -u` / `id -g`), so downloaded files are owned by that user, and uses the Mac's system timezone (from `/etc/localtime`). To override any of these, set in `.env.qbittorrent`:

```zsh
QB_PUID=501
QB_PGID=20
QB_TZ=Asia/Kolkata
```

`QB_TZ` takes an IANA zone name. Run `qb start` or `qb repair` after changing them; Compose recreates the container when its environment differs.

### Quit behavior (optional)

By default `qb quit` also stops Docker Desktop when no other containers are running. To leave Docker Desktop up and only stop qBittorrent, set in `.env.qbittorrent`:

```zsh
QB_QUIT_DOCKER=keep
```

(`stop` is the default.)

### Start UI (optional)

By default `qb start` (and restart / repair / update) open or focus the Dock Web App. To start the stack only and print the WebUI URL:

```zsh
QB_START_UI=cli
```

For one run without changing the default: `qb start --cli` (or `qb start --app` to force the app). Flags win over the env for that invocation.

Load the CLI from your `~/.zshrc`:

```zsh
source ~/projects/qbittorrent/qb.zsh
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
source ~/projects/qbittorrent/qb.zsh
```

Many Mac zsh setups (and Docker Desktop’s zsh snippet) already run `compinit`. If `compinit` was never set up, nothing fails: there is no prompt, warning, or error — Tab completion is simply unavailable and every `qb` command still works as usual.

Start qBittorrent:

```zsh
qb start
```

The WebUI is available at [http://localhost:8090](http://localhost:8090) (or the port set in `QB_WEBUI_PORT`). In Safari, use **File → Add to Dock** to create the optional qBittorrent Web App wrapper.

`qb start` opens or focuses that Dock Web App (`~/Applications/qBittorrent.app`) when `QB_START_UI=app` (default). With `QB_START_UI=cli` or `qb start --cli`, it only prints the WebUI URL — it does not open a Safari tab.

### Docker Desktop tip (optional)

`qb start` may launch Docker Desktop. If you do not want the dashboard window to cover the screen when that happens:

1. Open **Docker Desktop → Settings → General**.
2. Turn off **Open Docker Dashboard when Docker Desktop starts**.
3. Click **Apply** (or **Apply & restart** if Docker offers it). The setting does nothing until it is applied.

After that, `qb start` can still start the Docker engine; the dashboard stays closed. The Docker icon may still appear in the Dock.

## Commands

Torrent ids are a **hash prefix** or a **unique name substring**.

| Command | Description |
| --- | --- |
| `qb start` | Start Docker Desktop if needed, start qBittorrent, and open/focus the Dock Web App unless `QB_START_UI=cli` or `qb start --cli` (idempotent; never a Safari tab). Remounts if `QB_DOWNLOADS` or the WebUI bind changed. If the local image is 90+ days old **and** a newer registry digest exists, prints a one-line suggestion to run `qb update` (does not auto-update; no nag when already latest or offline). |
| `qb quit` | Close the WebUI app and stop qBittorrent. Docker Desktop stops only when no other containers are running (override with `QB_QUIT_DOCKER=keep`). |
| `qb restart` | Restart qBittorrent and wait for the WebUI. |
| `qb status` | Show Docker, container, WebUI, transfer speeds (when API works), and prefs. |
| `qb torrents` | List all torrents (short hash, progress, size, speeds, state). Filters: `--downloading`, `--seeding`, `--stopped`, `--completed`, `--active`, `--errored`. |
| `qb torrents --watch` | Redraw the torrent list every 2 seconds until Ctrl-C. |
| `qb show <id>` | Show one torrent’s properties and file list. |
| `qb add <magnet-or-url>` | Add a magnet link or http(s) `.torrent` URL. |
| `qb pause <id…>` | Pause torrent(s) by hash prefix or unique name substring. |
| `qb resume <id…>` | Resume torrent(s) by hash prefix or unique name substring. |
| `qb remove [--files] <id…>` | Remove torrent(s); `--files` also deletes downloaded data. |
| `qb recheck <id…>` | Recheck torrent data. |
| `qb reannounce <id…>` | Force tracker reannounce. |
| `qb force [--off] <id…>` | Enable (or `--off` disable) force start. |
| `qb alt` | Toggle alternative global speed limits. |
| `qb plugins` | Manage search plugins: `list`, `install <url>`, `enable`/`disable`, `update`, `remove`. |
| `qb search <pattern>` | Search with enabled plugins (spinner while waiting). Results table sorted by seeds; 10/page on a TTY. Type a `#` to add, `<` `>` to page, Enter/`q` to quit. `--add N` adds result #N non-interactively; `--limit` page size; `--watch` live table; `--timeout`, `--category`, `--plugins`. Pattern may be quoted or bare words. |
| `qb logs [lines]` | Follow container logs; defaults to 50 lines. |
| `qb shell` | Open a shell in the qBittorrent container. |
| `qb info` | Show image, container, mount, and port details. |
| `qb version` | Show the running qBittorrent version. |
| `qb update` | Check registry digests first (no layer download); pull/recreate only when newer. If the check fails, falls back to pull-then-compare. Blocks while downloads are active; removes the previous image when safe. Run occasionally (for example monthly); `qb start` never auto-updates. |
| `qb images` | List local qBittorrent images (including dangling) with sizes and a unique total. |
| `qb prune` | Remove unused local qBittorrent images; always keeps the image currently used by the container/compose service. |
| `qb repair` | Recreate the qBittorrent container without touching downloads or configuration. If the recreate fails, pulls the image once and retries (a pull can bring a newer `:latest` build). |
| `qb doctor` | Check Docker, container, WebUI, mounts, API auth, the WebUI port, and local directories. |
| `qb layout` | Copy the column layout script to the clipboard and print the Web Inspector steps (see below). |
| `qb help` | Show the command list. |

### When the stack is not running

- **Lifecycle** (`start`, `quit`, `restart`, `repair`): may change state. `start` / `restart` (when down) / `repair` can bring things up. `quit` is idempotent (finishes a partial shutdown; says already stopped if nothing is left; blocks overlapping quit spam).
- **Diagnose** (`status`, `doctor`, `help`): read-only; OK when everything is down.
- **Need a live stack** (`torrents`, `show`, `add`, `pause`, `resume`, `remove`, `recheck`, `reannounce`, `force`, `alt`, `plugins`, `search`, `logs`, `shell`, `info`, `version`, `update`, `layout`): fail immediately with `Run: qb start` — checks qBittorrent via `/api/v2/app/version` (uses the API key when configured).
- **Need Docker only** (`images`, `prune`): fail with `Run: qb start` if the Docker engine is down.

## WebUI column layout (optional)

### What it is

qBittorrent’s WebUI torrent table can show many columns. Visibility and order are stored in the browser as `localStorage` keys (for example `column_name_visible_torrentsTableDiv` and `columns_order_torrentsTableDiv`). They are not part of the Docker `config/` on disk.

`webui-layout.js` is a small one-shot script that writes those keys, then reloads the page. It does not change download behavior, categories, or server settings — only which torrent-list columns you see and in what order.

You only need to apply it once per browser / Web App profile, unless you clear Safari site data for `http://localhost:8090`.

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

The `wanted` list shipped in this repo is just a starter layout (compact download-focused columns). Change the arrays to suit you, save the file, then apply the script again (`qb layout`). You can also toggle columns from the WebUI table header menu; re-running the script overwrites browser prefs with whatever is in the file.

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

### Applying the script

Safari Web Apps on current macOS do not accept Apple Events, so the script cannot be injected automatically. `qb layout` opens the Dock Web App, copies `webui-layout.js` to the clipboard, and prints the steps below.

```zsh
qb layout
```

1. Safari → **Develop → [this Mac's name] → qBittorrent (localhost:8090)**, or **Develop → Inspect Apps and Devices**. A Web Inspector attached to the Dock Web App opens.  
   (If **Develop** is missing: Safari → **Settings → Advanced → Show features for web developers**.)
2. **Console** tab → paste → Return.
3. The page reloads with the new columns.

The Web App's own settings window has no developer options; the inspector is reached only through Safari's **Develop** menu. No **Allow JavaScript from Apple Events** permission is needed.

## Project directories

| Path | Purpose |
| --- | --- |
| `compose.yaml` | qBittorrent Docker service definition. |
| `qb.zsh` | `qb` CLI commands. |
| `qb_json.py` | Python helpers used by `qb.zsh` to format API and Docker JSON (torrents, show, transfer line, plugins, images, image age). Standard library only; JSON is read from stdin. |
| `config/` | Persistent qBittorrent configuration and session state. |
| `~/Downloads/qbittorrent-downloads` | Default download folder (override with `QB_DOWNLOADS`). |
| `plugins/` | Local search plugins (third-party Python — review before enabling). Use `qb plugins` / `qb search`. |
| `webui-layout.js` | Column layout script used by `qb layout`. |
| `tests/smoke.zsh` | Read-only smoke test (see [Tests](#tests)). |
| `tests/fixtures/` | Sample qBittorrent API responses (and expected output) used by the smoke test. |
| `.env.qbittorrent` | Local WebUI API key, optional `QB_DOWNLOADS`, `QB_PUID`, `QB_PGID`, `QB_TZ`, `QB_STYLE`, `QB_WEBUI_PORT`, `QB_WEBUI_BIND`, `QB_QUIT_DOCKER`, `QB_START_UI`. |

`config/`, `plugins/`, and `.env.qbittorrent` are intentionally ignored by Git because they can contain local data, credentials, or third-party files.

## Tests

```zsh
zsh tests/smoke.zsh
```

The smoke test is read-only: it never starts, stops, or recreates Docker or the container, and it uses a temporary env file instead of `.env.qbittorrent`. It checks:

- `qb.zsh` syntax, loading, `qb help`, and unknown-command handling.
- That the command dispatcher, Tab completion, `qb help`, and the README command table list the same commands.
- Parsing of `.env.qbittorrent` settings (quotes, spaces, CRLF, `~` paths, invalid values falling back to defaults), and the user, group and timezone defaults.
- That `compose.yaml` receives the port, user, group and timezone from `qb`, and its fallbacks when run without `qb` (`docker compose config`; no Docker engine needed).
- WebUI port owner detection, using a temporary local listener on port 18555, plus another container holding the port, `qb start` / `qb repair` stopping before Compose, and the `qb doctor` port and container lines.
- The `qb_json.py` formatters, called through `qb.zsh` with sample API responses from `tests/fixtures/` (torrents, show, transfer line, plugins, images, image age), including a torrent list larger than the 1 MiB macOS argument limit.
- Compose error output on failure, and the `qb repair` pull-and-retry path (with a stand-in `docker` function, so nothing real runs).
- That `qb status` and `qb doctor` run without shell errors, and that stack commands fail fast with `Run: qb start` when Docker is down.

It exits non-zero when any check fails.

## Ports

| Port | Protocol | Purpose |
| --- | --- | --- |
| 8090 | TCP | qBittorrent WebUI (default; change with `QB_WEBUI_PORT`. Default host bind: localhost only; see `QB_WEBUI_BIND`) |
| 6881 | TCP/UDP | BitTorrent peer connections |

The WebUI is intended for local use. Default publish is `127.0.0.1` only. Set `QB_WEBUI_BIND=lan` if you knowingly want LAN access, and keep a strong WebUI password / API key.
