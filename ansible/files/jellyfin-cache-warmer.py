#!/usr/bin/env python3
"""Pre-warm the nginx Jellyfin cache on this node.

Asks Jellyfin (through the proxy) what the configured users are likely to watch
next -- Continue Watching, a hand-curated collection, Next Up and recently added
titles -- then requests each file through the proxy in slice-aligned ranges so
nginx pulls it from the home server and keeps it on local disk.

Idempotent: slices already cached answer HIT and cost nothing, so the job is
safe to run often. All configuration comes from the environment; see
/etc/jellyfin-cache-warmer.env, which Ansible renders from group_vars.
"""
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo


def env(name, default=None):
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def parse_size(text):
    text = str(text).strip().lower()
    units = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3, "t": 1024 ** 4}
    if text and text[-1] in units:
        return int(float(text[:-1]) * units[text[-1]])
    return int(text)


def fmt_bytes(n):
    if n is None:
        return "?"
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{n} B"
        n /= 1024


def log(msg):
    print(msg, flush=True)


CFG = {
    "api_key": env("JELLYFIN_API_KEY"),
    "proxy": env("PROXY_URL", "http://127.0.0.1:8096").rstrip("/"),
    "users": [u.strip() for u in env("WARM_USERS", "admin").split(",") if u.strip()],
    "budget": parse_size(env("WARM_BUDGET", "80g")),
    "rate_mbit": float(env("WARM_RATE_MBIT", "30")),
    "recent_days": int(env("WARM_RECENT_DAYS", "14")),
    "window": env("WARM_WINDOW", ""),
    "tz": env("WARM_TZ", "UTC"),
    "collection": env("WARM_COLLECTION", "Pre-cache"),
    "slice": parse_size(env("WARM_SLICE", "8m")),
    "cache_dir": env("CACHE_DIR", "/var/cache/nginx/jellyfin/media"),
    "max_run": int(env("MAX_RUN_SECONDS", "1500")),
    "resume_limit": int(env("RESUME_LIMIT", "20")),
    "nextup_limit": int(env("NEXTUP_LIMIT", "10")),
    "latest_limit": int(env("LATEST_LIMIT", "30")),
}

AUTH_HEADER = (
    'MediaBrowser Client="jellyfin-cache-warmer", Device="nginx-cache", '
    'DeviceId="jellyfin-cache-warmer", Version="1.0", Token="{token}"'
)
USER_AGENT = "jellyfin-cache-warmer/1.0"
# Fill order. The hand-curated collection outranks Next Up because it is the
# one list the user chooses deliberately.
PRIORITY = {"resume": 0, "collection": 1, "nextup": 2, "latest": 3}
# Sources that are only warmed inside the configured time window.
WINDOWED_SOURCES = {"collection", "latest"}


# --------------------------------------------------------------------------- HTTP

def request(path, params=None, headers=None, timeout=30):
    url = CFG["proxy"] + path
    if params:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
    all_headers = {
        "Authorization": AUTH_HEADER.format(token=CFG["api_key"]),
        "User-Agent": USER_AGENT,
        "Accept": "application/json",
    }
    if headers:
        all_headers.update(headers)
    return urllib.request.urlopen(urllib.request.Request(url, headers=all_headers), timeout=timeout)


def api(path, params=None):
    with request(path, params) as resp:
        return json.load(resp)


def fetch_range(path, start, end, read_body):
    """GET one byte range through the proxy. Returns (status, cache_status, total_size)."""
    with request(path, headers={"Range": f"bytes={start}-{end}", "Accept": "*/*"}, timeout=180) as resp:
        cache = resp.headers.get("X-Cache-Status", "-")
        total = None
        content_range = resp.headers.get("Content-Range", "")
        if "/" in content_range:
            try:
                total = int(content_range.rsplit("/", 1)[1])
            except ValueError:
                pass
        if read_body:
            while resp.read(1 << 20):
                pass
        else:
            resp.read()
        return resp.status, cache, total


# ------------------------------------------------------------------ selection

def parse_jellyfin_date(text):
    # Jellyfin emits up to seven fractional digits; Python accepts six.
    text = re.sub(r"(\.\d{6})\d+", r"\1", text.replace("Z", "+00:00"))
    value = dt.datetime.fromisoformat(text)
    if value.tzinfo is None:
        value = value.replace(tzinfo=dt.timezone.utc)
    return value


def resolve_users():
    by_name = {u["Name"].lower(): u for u in api("/Users")}
    users = []
    for name in CFG["users"]:
        user = by_name.get(name.lower())
        if user:
            users.append(user)
        else:
            log(f"WARN Jellyfin has no user named {name!r}; skipping")
    return users


def item_label(item):
    if item.get("Type") == "Episode":
        season = item.get("ParentIndexNumber")
        episode = item.get("IndexNumber")
        code = f"S{season:02d}E{episode:02d}" if season is not None and episode is not None else ""
        return f"{item.get('SeriesName', '?')} {code} {item.get('Name', '')}".strip()
    year = item.get("ProductionYear")
    return f"{item.get('Name', '?')}" + (f" ({year})" if year else "")


def candidates(users):
    """Return [(source, item)] ordered by priority, de-duplicated across users."""
    chosen = {}

    def add(item, source):
        if item.get("Type") not in ("Movie", "Episode"):
            return
        if item.get("LocationType") == "Virtual" or item.get("IsFolder"):
            return
        current = chosen.get(item["Id"])
        if current is None or PRIORITY[source] < PRIORITY[current[0]]:
            chosen[item["Id"]] = (source, item)

    fields = "MediaSources,DateCreated,Path"
    cutoff = dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=CFG["recent_days"])

    def items_of(result):
        return result if isinstance(result, list) else result.get("Items", [])

    def resume(uid):
        # Jellyfin 10.9+ moved Continue Watching to /UserItems/Resume.
        return items_of(api("/UserItems/Resume", {"userId": uid, "limit": CFG["resume_limit"],
                                                  "mediaTypes": "Video", "fields": fields}))

    def next_up(uid):
        return items_of(api("/Shows/NextUp", {"userId": uid, "limit": CFG["nextup_limit"], "fields": fields}))

    def collection(uid):
        # A recursive query on a collection descends into Series members but
        # not into Season members, so expand each member explicitly instead.
        found = []
        boxes = items_of(api("/Items", {"userId": uid, "includeItemTypes": "BoxSet", "recursive": "true",
                                        "searchTerm": CFG["collection"]}))
        for box in boxes:
            if box.get("Name", "").lower() != CFG["collection"].lower():
                continue
            for member in items_of(api("/Items", {"userId": uid, "parentId": box["Id"], "fields": fields})):
                if member.get("Type") in ("Movie", "Episode"):
                    found.append(member)
                elif member.get("IsFolder") or member.get("Type") in ("Series", "Season", "BoxSet"):
                    found += items_of(api("/Items", {"userId": uid, "parentId": member["Id"], "recursive": "true",
                                                     "includeItemTypes": "Movie,Episode", "fields": fields}))
        return found

    def latest(uid):
        recent = items_of(api("/Items/Latest", {"userId": uid, "limit": CFG["latest_limit"],
                                                "includeItemTypes": "Movie,Episode", "groupItems": "false",
                                                "fields": fields}))
        return [item for item in recent
                if item.get("DateCreated") and parse_jellyfin_date(item["DateCreated"]) >= cutoff]

    queries = (("resume", resume), ("collection", collection), ("nextup", next_up), ("latest", latest))
    for user in users:
        for source, query in queries:
            try:
                for item in query(user["Id"]):
                    add(item, source)
            except (urllib.error.URLError, json.JSONDecodeError, KeyError, ValueError) as exc:
                log(f"WARN {source} query failed for user {user['Name']!r}: {exc}")
    return sorted(chosen.values(), key=lambda pair: PRIORITY[pair[0]])


def media_source(item, user_id):
    sources = item.get("MediaSources") or []
    if not sources:
        sources = api(f"/Items/{item['Id']}/PlaybackInfo", {"userId": user_id}).get("MediaSources", [])
    for source in sources:
        if source.get("Protocol", "File") == "File" and source.get("Id"):
            return source
    return None


def stream_path(item, source):
    container = (source.get("Container") or "").split(",")[0].strip()
    path = f"/Videos/{item['Id']}/stream" + (f".{container}" if container else "")
    params = {"Static": "true", "mediaSourceId": source["Id"]}
    if source.get("ETag"):
        params["Tag"] = source["ETag"]
    return path + "?" + urllib.parse.urlencode(params)


# -------------------------------------------------------------------- warming

def cache_bytes():
    total = 0
    try:
        for root, _dirs, files in os.walk(CFG["cache_dir"]):
            for name in files:
                try:
                    total += os.stat(os.path.join(root, name)).st_size
                except OSError:
                    pass
    except OSError as exc:
        log(f"WARN cannot measure cache directory: {exc}")
        return None
    return total


def in_window(now):
    window = CFG["window"]
    if not window:
        return True
    try:
        start_text, end_text = window.split("-")
        start = int(start_text[:2]) * 60 + int(start_text[3:5])
        end = int(end_text[:2]) * 60 + int(end_text[3:5])
    except (ValueError, IndexError):
        log(f"WARN bad WARM_WINDOW {window!r}; treating as always open")
        return True
    current = now.hour * 60 + now.minute
    if start <= end:
        return start <= current < end
    return current >= start or current < end


def warm_item(path, size, deadline, stats):
    """Probe every slice; pull the ones nginx does not already hold."""
    slice_size = CFG["slice"]
    slices = (size + slice_size - 1) // slice_size
    min_seconds_per_fill = slice_size * 8 / (CFG["rate_mbit"] * 1e6)
    filled = hits = 0
    for index in range(slices):
        if time.monotonic() > deadline:
            return filled, hits, slices, "time budget exhausted"
        start = index * slice_size
        end = min(start + slice_size, size) - 1
        began = time.monotonic()
        status, cache, _total = fetch_range(path, start, start, read_body=False)
        if status != 206:
            return filled, hits, slices, f"upstream ignored Range (HTTP {status})"
        if cache in ("HIT", "REVALIDATED", "STALE"):
            hits += 1
            continue
        # Not cached yet: read the whole slice so nginx completes and stores it.
        fetch_range(path, start, end, read_body=True)
        filled += 1
        stats["bytes"] += end - start + 1
        elapsed = time.monotonic() - began
        if elapsed < min_seconds_per_fill:
            time.sleep(min_seconds_per_fill - elapsed)
    return filled, hits, slices, "ok"


def main():
    if not CFG["api_key"]:
        log("ERROR JELLYFIN_API_KEY is not set")
        return 2
    started = time.monotonic()
    deadline = started + CFG["max_run"]
    now = dt.datetime.now(ZoneInfo(CFG["tz"]))
    window_open = in_window(now)

    users = resolve_users()
    if not users:
        log("ERROR none of the configured users exist in Jellyfin")
        return 2
    user_ids = {u["Name"]: u["Id"] for u in users}
    any_user_id = next(iter(user_ids.values()))

    picks = candidates(users)
    used = cache_bytes()
    stats = {"bytes": 0, "items_filled": 0, "items_cached": 0, "skipped_window": 0,
             "skipped_budget": 0, "errors": 0, "slices_filled": 0, "slices_hit": 0}
    log(f"start users={list(user_ids)} candidates={len(picks)} window_open={window_open} "
        f"local_time={now:%Y-%m-%d %H:%M %Z} cache_used={fmt_bytes(used)} budget={fmt_bytes(CFG['budget'])}")

    if "--dry-run" in sys.argv[1:]:
        # List what would be warmed, in order, without touching the cache.
        total = 0
        for source_name, item in picks:
            source = (item.get("MediaSources") or [{}])[0]
            size = int(source.get("Size") or 0)
            total += size
            deferred = " (deferred to window)" if source_name in WINDOWED_SOURCES and not window_open else ""
            log(f"  {source_name:10s} {fmt_bytes(size):>9s}  {item_label(item)}{deferred}")
        log(f"dry run: {len(picks)} items, {fmt_bytes(total)} total against a {fmt_bytes(CFG['budget'])} budget")
        return 0

    for source_name, item in picks:
        if time.monotonic() > deadline:
            log("time budget exhausted; remaining items continue on the next run")
            break
        label = item_label(item)
        if source_name in WINDOWED_SOURCES and not window_open:
            stats["skipped_window"] += 1
            continue
        try:
            source = media_source(item, any_user_id)
            if source is None:
                log(f"WARN {source_name:10s} {label}: no file-backed media source")
                stats["errors"] += 1
                continue
            path = stream_path(item, source)
            size = int(source.get("Size") or 0)
            status, first_cache, total = fetch_range(path, 0, 0, read_body=False)
            if status != 206 or not total:
                log(f"WARN {source_name:10s} {label}: proxy did not return a ranged response (HTTP {status})")
                stats["errors"] += 1
                continue
            size = total
            if first_cache not in ("HIT", "REVALIDATED", "STALE") and used is not None \
                    and used + size > CFG["budget"]:
                log(f"skip {source_name:10s} {label}: {fmt_bytes(size)} would exceed the warm budget")
                stats["skipped_budget"] += 1
                continue
            filled, hits, slices, outcome = warm_item(path, size, deadline, stats)
        except (urllib.error.URLError, json.JSONDecodeError, OSError) as exc:
            log(f"WARN {source_name:10s} {label}: {exc}")
            stats["errors"] += 1
            continue
        stats["slices_filled"] += filled
        stats["slices_hit"] += hits
        if filled:
            stats["items_filled"] += 1
            if used is not None:
                used += filled * CFG["slice"]
        else:
            stats["items_cached"] += 1
        log(f"{'warm' if filled else 'ok  '} {source_name:10s} {label}: {outcome}; "
            f"slices={slices} filled={filled} hit={hits} size={fmt_bytes(size)}")

    elapsed = time.monotonic() - started
    log(f"done in {elapsed:.0f}s: pulled {fmt_bytes(stats['bytes'])} across {stats['items_filled']} items, "
        f"{stats['items_cached']} already cached, {stats['skipped_window']} deferred to window, "
        f"{stats['skipped_budget']} over budget, {stats['errors']} errors, "
        f"slices filled={stats['slices_filled']} hit={stats['slices_hit']}, cache_used={fmt_bytes(used)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
