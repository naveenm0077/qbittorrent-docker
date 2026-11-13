#!/usr/bin/env python3
"""JSON parsing and formatting helpers for qb.zsh (standard library only).

qb.zsh does the HTTP and Docker work; this file turns the JSON it fetched into
terminal output. API JSON is read from stdin, never from argv, so large
responses are not limited by the OS argument size (ARG_MAX, 1 MiB on macOS).

Usage (normally called by qb.zsh):
    python3 qb_json.py torrents            < torrents/info JSON
    python3 qb_json.py transfer <alt-mode> < transfer/info JSON
    python3 qb_json.py show <hash>         < {"props": {...}, "files": [...]}
    python3 qb_json.py plugins             < search/plugins JSON
    python3 qb_json.py image-age <created>   (Docker image Created timestamp)
    python3 qb_json.py images                (runs docker itself)
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


# --- Commands -----------------------------------------------------------------

def cmd_torrents(args):
    try:
        torrents = read_json_stdin()
    except Exception as e:
        print(f"Failed to parse qBittorrent response: {e}", file=sys.stderr)
        return 1

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


COMMANDS = {
    "torrents": cmd_torrents,
    "transfer": cmd_transfer,
    "show": cmd_show,
    "plugins": cmd_plugins,
    "image-age": cmd_image_age,
    "images": cmd_images,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(f"Usage: {argv[0]} {{{'|'.join(COMMANDS)}}} [args]", file=sys.stderr)
        return 2
    return COMMANDS[argv[1]](argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
