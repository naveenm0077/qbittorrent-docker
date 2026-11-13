#!/usr/bin/env python3
"""JSON parsing and formatting helpers for qb.zsh (standard library only).

qb.zsh does the HTTP and Docker work; this file turns the JSON it fetched into
terminal output. API JSON is read from stdin, never from argv, so large
responses are not limited by the OS argument size (ARG_MAX, 1 MiB on macOS).

Usage (normally called by qb.zsh):
    python3 lib/qb_json.py torrents            < torrents/info JSON
    python3 lib/qb_json.py transfer <alt-mode> < transfer/info JSON
    python3 lib/qb_json.py show <hash>         < {"props": {...}, "files": [...]}
    python3 lib/qb_json.py plugins             < search/plugins JSON
    python3 lib/qb_json.py image-age <created>   (Docker image Created timestamp)
    python3 lib/qb_json.py images                (runs docker itself)
    python3 lib/qb_json.py active-count         < torrents/info JSON  (-1 on bad input)
    python3 lib/qb_json.py resolve-hashes <id>... < torrents/info JSON  (-> hash|hash)
    python3 lib/qb_json.py search-enabled-count < search/plugins JSON
    python3 lib/qb_json.py search-job-id        < search/start JSON
    python3 lib/qb_json.py search-status        < search/status JSON
    python3 lib/qb_json.py search-sort          < search/results JSON  (-> sorted array)
    python3 lib/qb_json.py search-count         < sorted array
    python3 lib/qb_json.py search-url <n>       < sorted array
    python3 lib/qb_json.py search-page <page> <page-size> <cols> [note] < sorted array
"""

import json
import re
import subprocess
import sys
from datetime import datetime, timezone


# --- Shared formatting ------------------------------------------------------

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


def read_json_stdin():
    return json.loads(sys.stdin.read())


def print_json(data):
    """--json output: one line of compact JSON, non-ASCII kept as is."""
    print(json.dumps(data, ensure_ascii=False, separators=(",", ":")))


# --- Commands -----------------------------------------------------------------

def cmd_torrents(args):
    try:
        torrents = read_json_stdin()
    except Exception as e:
        print(f"Failed to parse qBittorrent response: {e}", file=sys.stderr)
        return 1

    if "--json" in args:
        print_json(torrents)
        return 0

    if not torrents:
        print("No torrents.")
        return 0

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
    return 0


def cmd_transfer(args):
    # Silent on bad input: the transfer line is optional in `qb status`.
    try:
        info = read_json_stdin()
    except Exception:
        return 0

    dl = human_rate(info.get("dl_info_speed") or 0)
    up = human_rate(info.get("up_info_speed") or 0)
    alt = (args[0] if args else "").strip()
    alt_label = "on" if alt == "1" else "off"
    print(f"Transfer: ↓{dl}  ↑{up}  alt-limits={alt_label}")
    return 0


def cmd_show(args):
    try:
        data = read_json_stdin()
        p = data["props"]
        files = data["files"]
    except Exception as e:
        print(f"Failed to parse response: {e}", file=sys.stderr)
        return 1

    h = args[0] if args else ""
    if "--json" in args[1:]:
        print_json({"hash": h, "properties": p, "files": files})
        return 0

    print(p.get("name") or "unknown")
    print(f"  hash: {h}")
    print(f"  save: {p.get('save_path') or '-'}")
    print(
        f"  size: {human_bytes(p.get('total_size') or 0)}  "
        f"↓{human_bytes(p.get('total_downloaded') or 0)}  "
        f"↑{human_bytes(p.get('total_uploaded') or 0)}"
    )
    print(f"  speed: ↓{human_rate(p.get('dl_speed') or 0)}  ↑{human_rate(p.get('up_speed') or 0)}")
    print(
        f"  peers: {p.get('peers') or 0}/{p.get('peers_total') or 0}  "
        f"seeds: {p.get('seeds') or 0}/{p.get('seeds_total') or 0}"
    )
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
    return 0


def cmd_plugins(args):
    try:
        plugins = read_json_stdin()
    except Exception as e:
        print(f"Failed to parse plugins: {e}", file=sys.stderr)
        return 1

    if not plugins:
        print("No search plugins installed.")
        print("Install one, e.g.:")
        print("  qb plugins install https://raw.githubusercontent.com/qbittorrent/search-plugins/master/nova3/engines/eztv.py")
        print("Plugins are third-party Python — review before enabling.")
        return 0

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

    print("  ".join(fmt(h, widths[i]) for i, h in enumerate(headers)))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print("  ".join(fmt(row[i], widths[i], truncate=(i == 4)) for i in range(len(headers))))
    return 0


def cmd_image_age(args):
    """Days since a Docker image's Created timestamp (exit 1 if unparseable)."""
    raw = (args[0] if args else "").strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    # Docker gives nanoseconds; fromisoformat accepts at most microseconds.
    raw = re.sub(r"\.(\d{6})\d*", r".\1", raw)

    try:
        created = datetime.fromisoformat(raw)
    except ValueError:
        return 1

    if created.tzinfo is None:
        created = created.replace(tzinfo=timezone.utc)

    age = (datetime.now(timezone.utc) - created.astimezone(timezone.utc)).days
    print(max(age, 0))
    return 0


def cmd_images(args):
    """List local qBittorrent images (tagged + dangling) with sizes."""

    def run(cmd):
        return subprocess.check_output(cmd, text=True)

    def short_id(image_id):
        if image_id.startswith("sha256:"):
            image_id = image_id[7:]
        return image_id[:12]

    rows = []
    seen_ids = set()

    try:
        tagged = run(["docker", "images", "--filter", "reference=*qbittorrent*", "--format", "{{json .}}"])
    except subprocess.CalledProcessError:
        print("Failed to list qBittorrent images", file=sys.stderr)
        return 1

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
            labels = run(["docker", "image", "inspect", image_id, "--format", "{{json .Config.Labels}}"]).strip()
        except subprocess.CalledProcessError:
            continue

        blob = labels.lower() if labels and labels != "null" else ""
        if "qbittorrent" not in blob:
            continue

        rows.append({"id": image_id, "repository": "<none>", "tag": "<none>", "created": "dangling"})
        seen_ids.add(image_id)

    if not rows:
        print("No qBittorrent images found.")
        return 0

    sizes = {}
    for image_id in sorted(seen_ids):
        try:
            size = int(run(["docker", "image", "inspect", image_id, "--format", "{{.Size}}"]).strip())
        except Exception:
            size = 0
        sizes[image_id] = size

    print(f"{'REPOSITORY':<40} {'TAG':<16} {'IMAGE ID':<12} {'SIZE':>10}  CREATED")
    for row in rows:
        print(
            f"{row['repository']:<40} {row['tag']:<16} {short_id(row['id']):<12} "
            f"{human_bytes(sizes.get(row['id'], 0)):>10}  {row['created']}"
        )

    print()
    print(f"Images: {len(seen_ids)} unique ({len(rows)} tag(s)/row(s))")
    print(f"Total:  {human_bytes(sum(sizes.values()))}")
    print()
    print("Note: sizes are per-image logical size; shared layers may mean less disk than the sum.")
    return 0


def cmd_active_count(args):
    """Number of entries in a torrents/info list (-1 on bad input)."""
    try:
        print(len(read_json_stdin()))
    except Exception:
        print(-1)
    return 0


def cmd_resolve_hashes(args):
    """Resolve ids (hash prefix or name substring) to full hashes, joined by "|".

    Exit 1 when an id matches nothing or several torrents (details on stderr),
    exit 2 when the torrent list cannot be parsed.
    """
    try:
        torrents = read_json_stdin()
    except Exception as e:
        print(f"Failed to parse torrent list: {e}", file=sys.stderr)
        return 2

    hashes = []
    for q in args:
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
            return 1

        # Unique by hash.
        by_hash = {}
        for t in matches:
            by_hash[(t.get("hash") or "").lower()] = t
        uniq = list(by_hash.values())

        if len(uniq) > 1:
            print(f"Ambiguous id: {q}", file=sys.stderr)
            for t in uniq:
                print(f"  {(t.get('hash') or '')[:8]}  {t.get('name') or 'unknown'}", file=sys.stderr)
            return 1

        hashes.append(uniq[0].get("hash") or "")

    print("|".join(hashes))
    return 0


# --- Search -------------------------------------------------------------------

def cmd_search_enabled_count(args):
    """Number of enabled plugins (0 on bad input)."""
    try:
        plugins = read_json_stdin()
    except Exception:
        print(0)
        return 0
    print(sum(1 for p in plugins if p.get("enabled")))
    return 0


def cmd_search_job_id(args):
    """Job id from /search/start (exit 1 on bad input)."""
    try:
        print(read_json_stdin().get("id") or "")
    except Exception:
        return 1
    return 0


def cmd_search_status(args):
    """Job status from /search/status ("" on bad input)."""
    try:
        data = read_json_stdin()
        if isinstance(data, list) and data:
            print(data[0].get("status") or "")
        elif isinstance(data, dict):
            print(data.get("status") or "")
    except Exception:
        print("")
    return 0


def search_seeds(row):
    try:
        return int(row.get("nbSeeders") or 0)
    except (TypeError, ValueError):
        return 0


def cmd_search_sort(args):
    """/search/results JSON -> compact JSON array sorted by seeds (desc)."""
    try:
        rows = list(read_json_stdin().get("results") or [])
    except Exception as e:
        print(f"Failed to parse results: {e}", file=sys.stderr)
        return 1
    rows.sort(key=search_seeds, reverse=True)
    print(json.dumps(rows, separators=(",", ":")))
    return 0


def cmd_search_count(args):
    """Number of rows in a sorted results array (0 on bad input)."""
    try:
        print(len(read_json_stdin()))
    except Exception:
        print(0)
    return 0


def cmd_search_url(args):
    """fileUrl of result #N (1-based) in a sorted results array."""
    try:
        rows = read_json_stdin()
    except Exception as e:
        print(f"parse error: {e}", file=sys.stderr)
        return 1

    idx = int(args[0])
    if idx < 1 or idx > len(rows):
        print(f"No result #{idx} (have {len(rows)})", file=sys.stderr)
        return 1

    url = (rows[idx - 1].get("fileUrl") or "").strip()
    if not url:
        print("Result has no magnet/file URL", file=sys.stderr)
        return 1
    print(url)
    return 0


def cmd_search_page(args):
    """One page of a sorted results array. args: page (0-based) page_size cols [status_note]."""
    from urllib.parse import urlparse

    def size_text(n):
        # qBittorrent reports unknown sizes as -1.
        try:
            if float(n) < 0:
                return "?"
        except (TypeError, ValueError):
            return "?"
        return human_bytes(n)

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
        rows = read_json_stdin()
    except Exception as e:
        print(f"Failed to parse results: {e}", file=sys.stderr)
        return 1

    page = int(args[0])
    page_size = int(args[1])
    cols = int(args[2] or 80)
    status_note = args[3] if len(args) > 3 else ""

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
        return 0

    # Fixed columns: # SIZE SEEDS LEECH SITE; NAME gets the remainder (max 60).
    idx_w = max(2, len(str(start + len(chunk))))
    # SIZE fits the longest human_bytes value, "1023.9 GiB" (10 chars).
    size_w, seeds_w, leech_w, site_w, gap = 10, 5, 5, 18, 2
    fixed = idx_w + size_w + seeds_w + leech_w + site_w + gap * 5
    name_w = min(max(12, cols - fixed), 60)

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
        try:
            leech = int(row.get("nbLeechers") or 0)
        except (TypeError, ValueError):
            leech = 0
        print(
            "  ".join(
                [
                    cell(start + i + 1, idx_w, "right"),
                    cell(row.get("fileName") or "unknown", name_w, cut=True),
                    cell(size_text(row.get("fileSize")), size_w, "right"),
                    cell(search_seeds(row), seeds_w, "right"),
                    cell(leech, leech_w, "right"),
                    cell(short_site(row.get("siteUrl") or ""), site_w, cut=True),
                ]
            )
        )
    return 0


COMMANDS = {
    "torrents": cmd_torrents,
    "transfer": cmd_transfer,
    "show": cmd_show,
    "plugins": cmd_plugins,
    "image-age": cmd_image_age,
    "images": cmd_images,
    "active-count": cmd_active_count,
    "resolve-hashes": cmd_resolve_hashes,
    "search-enabled-count": cmd_search_enabled_count,
    "search-job-id": cmd_search_job_id,
    "search-status": cmd_search_status,
    "search-sort": cmd_search_sort,
    "search-count": cmd_search_count,
    "search-url": cmd_search_url,
    "search-page": cmd_search_page,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(f"Usage: {argv[0]} {{{'|'.join(COMMANDS)}}} [args]", file=sys.stderr)
        return 2
    return COMMANDS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
