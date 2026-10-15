#!/usr/bin/env python3
"""TV Renamer (Python port of TVRenamer.ps1).

Renames downloaded TV episodes using episode titles from TMDb and moves them
into <Destination>/<Show>/Season NN/. Standard library only, so it runs inside
the Home Assistant container (or anywhere with Python 3.9+).

    python3 tv_renamer.py SOURCE DESTINATION            # preview, nothing moved
    python3 tv_renamer.py SOURCE DESTINATION --apply    # move the files

The TMDb API key comes from the TMDB_API_KEY environment variable, or from a
`tmdb_api_key:` line in the file given by --secrets (e.g. HA's secrets.yaml).

Output is a plain-text summary on stdout, sized for a phone notification.
Exit code: 0 = ran (even if some files were skipped), 1 = setup error.
"""

import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

MIN_SIZE = 100 * 1024 * 1024          # only files over 100MB, skips samples/subs
SKIP_DIRS = {"@eaDir", "#recycle", "#snapshot", ".@__thumb"}   # Synology/QNAP clutter
API = "https://api.themoviedb.org/3"

# Windows-invalid filename characters, kept so names stay valid over SMB
_INVALID = re.compile(r'[<>:"/\\|?*\x00-\x1f]')


# ---------------------------------------------------------------- helpers

def remove_invalid_filename_chars(name):
    # A colon between digits (a time like 11:59) becomes a period, otherwise " -"
    name = re.sub(r"(?<=\d):(?=\d)", ".", name).replace(":", " -")
    return _INVALID.sub("", name)


def normalize_title(title):
    # Drop apostrophes so Don't == Dont, spell out &, keep alnum only
    if not title or not title.strip():
        return ""
    t = re.sub(r"['`‘’]", "", title)
    t = t.replace("&", " and ").lower()
    t = re.sub(r"[^a-z0-9]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def get_expected_episode_title(base_name):
    # Strip everything up to and including S00E00 (plus an optional E00 / -E00)
    t = re.sub(r"(?i)^.*s\d{2}e\d{2}((?:-e\d{2})|(?:e\d{2}))?[.\s_-]*", "", base_name).strip()
    # Cut off quality/source tokens and anything after
    t = re.split(r"(?i)\b(?:2160p|1080p|720p|480p|uhd|hdr|dv|webrip|web[- ]dl|bdrip|bluray|"
                 r"x264|x265|h\.?264|h\.?265|hevc|aac|dts|proper|repack)\b", t)[0].strip()
    # Drop a trailing unclosed bracket left behind by the cut
    t = re.sub(r"[(\[{][^)\]}]*$", "", t).strip()
    return re.sub(r"\.+", " ", t).strip()


def digits_only(text):
    return re.sub(r"\D", "", text or "")


def prefix_match(a, b):
    """PowerShell `a -like "b*"`, case-insensitive (inputs are already normalized)."""
    return a.startswith(b)


def get_show_search_info(prefix):
    # Candidate search terms for the show plus a year hint, from the text before S00E00.
    # Dots are only treated as separators when the name has no spaces, so
    # "11.22.63 (2016) - S01E01" and "S.W.A.T.2017.S01E01" both work.
    raw = prefix.strip()

    year = None
    m = re.search(r"[(\[]((?:19|20)\d{2})[)\]]", raw)
    if m:
        year = m.group(1)
    else:
        m = re.search(r"(?:^|[\s.\-_])((?:19|20)\d{2})(?:$|[\s.\-_])", raw)
        if m:
            year = m.group(1)

    primary = raw if re.search(r"\s", raw) else raw.replace(".", " ")
    cleaned = []
    for c in (primary, raw):
        t = re.sub(r"[(\[](?:19|20)\d{2}[)\]]", " ", c)
        t = re.sub(r"[\s\-_.]+$", "", t)                       # so "S.W.A.T.2017." loses its year too
        t = re.sub(r"(?:^|[\s.\-_])((?:19|20)\d{2})\s*$", " ", t)
        t = re.sub(r"[\s_]+", " ", t).strip()
        t = re.sub(r"^[\s\-_.]+", "", t)
        t = re.sub(r"[\s\-_.]+$", "", t).strip()
        if t and t not in cleaned:
            cleaned.append(t)
    return cleaned, year


# ---------------------------------------------------------------- TMDb

class TMDb:
    """Single choke point for API calls: rate limiting, retries, 404 -> None."""

    def __init__(self, api_key):
        self.key = api_key
        self.window_count = 0
        self.total = 0
        self.auth_failed = False
        self.show_cache = {}
        self.season_cache = {}

    def get(self, path, retries=3, **params):
        params["api_key"] = self.key
        url = f"{API}{path}?{urllib.parse.urlencode(params)}"
        for attempt in range(1, retries + 1):
            # 40 requests per 10 seconds; pause before we hit it
            if self.window_count >= 39:
                time.sleep(10)
                self.window_count = 0
            self.window_count += 1
            self.total += 1
            try:
                with urllib.request.urlopen(url, timeout=15) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code == 401:
                    self.auth_failed = True
                    return None
                if attempt == retries:
                    return None
                if e.code == 429:
                    self.window_count = 0
                    time.sleep(10)
                else:
                    time.sleep(2 * attempt)
            except (urllib.error.URLError, TimeoutError, ValueError):
                if attempt == retries:
                    return None
                time.sleep(2 * attempt)
        return None

    def resolve_show(self, candidates, year):
        # Year-filtered search first, then unfiltered; prefer an exact normalized
        # title match, then a prefix match either way round, then TMDb's top hit
        for candidate in candidates:
            cache_key = f"{candidate}|{year}"
            if cache_key in self.show_cache:
                if self.show_cache[cache_key]:
                    return self.show_cache[cache_key]
                continue

            searches = []
            if year:
                searches.append({"query": candidate, "first_air_date_year": year})
            searches.append({"query": candidate})

            for params in searches:
                resp = self.get("/search/tv", **params)
                results = (resp or {}).get("results") or []
                if not results:
                    continue
                wanted = normalize_title(candidate)
                hit = next((r for r in results if normalize_title(r.get("name")) == wanted), None)
                if not hit:
                    for r in results:
                        n = normalize_title(r.get("name"))
                        if n and (prefix_match(n, wanted) or prefix_match(wanted, n)):
                            hit = r
                            break
                hit = hit or results[0]
                self.show_cache[cache_key] = hit
                return hit

            self.show_cache[cache_key] = None
        return None

    def season(self, show_id, season):
        k = f"{show_id}|{season}"
        if k not in self.season_cache:
            self.season_cache[k] = self.get(f"/tv/{show_id}/season/{int(season)}")
        return self.season_cache[k]


# ---------------------------------------------------------------- main logic

def titles_match(found, expected):
    fn, en = normalize_title(found), normalize_title(expected)
    fd, ed = digits_only(found), digits_only(expected)
    return prefix_match(fn, en) or prefix_match(en, fn) or bool(fd and ed and fd == ed)


def find_files(source):
    files = []
    for root, dirs, names in os.walk(source):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS and not d.startswith("."))
        for n in sorted(names):
            p = os.path.join(root, n)
            try:
                if os.path.getsize(p) > MIN_SIZE:
                    files.append(p)
            except OSError:
                pass
    return files


def plan_file(path, dest, tmdb, planned_targets):
    """Returns (plan_dict, None) or (None, skip_reason)."""
    name = os.path.basename(path)
    base, ext = os.path.splitext(name)

    parts = re.split(r"(?i)s(\d\d)e(\d\d)", base)
    if len(parts) < 3:
        return None, "no S00E00 marker"
    season, episode = parts[1], parts[2]

    candidates, year = get_show_search_info(parts[0])
    if not candidates:
        return None, "unparsable show name"

    show = tmdb.resolve_show(candidates, year)
    if not show:
        return None, "show not found on TMDb"
    show_id = show["id"]

    expected = get_expected_episode_title(base)
    ep = tmdb.get(f"/tv/{show_id}/season/{int(season)}/episode/{int(episode)}")
    rejected = None

    # If TMDb's title doesn't match what the filename claims, look for the
    # title elsewhere in the season and use TMDb's episode number
    if ep and expected and not titles_match(ep.get("name", ""), expected):
        rejected, ep = ep.get("name"), None

    if not ep and expected:
        data = tmdb.season(show_id, season)
        match = next((e for e in (data or {}).get("episodes") or []
                      if titles_match(e.get("name", ""), expected)), None)
        if match:
            episode = f"{int(match['episode_number']):02d}"
            ep = tmdb.get(f"/tv/{show_id}/season/{int(season)}/episode/{int(episode)}")

    if not ep or not (ep.get("name") or "").strip():
        if rejected:
            return None, (f"filename says '{expected}' but TMDb S{season}E{episode} is "
                          f"'{rejected}', and nothing else in the season matched")
        return None, f"TMDb has no S{season}E{episode} for '{show['name']}'"

    safe_show = remove_invalid_filename_chars(show["name"])
    new_name = (f"{safe_show} - S{season}E{episode} - "
                f"{remove_invalid_filename_chars(ep['name'])}{ext}")
    target_dir = os.path.join(dest, safe_show, f"Season {season}")
    target = os.path.join(target_dir, new_name)

    if os.path.exists(target):
        return None, "target already exists"
    if target.lower() in planned_targets:
        return None, "two files want the same name"

    return {"old": path, "new": target, "dir": target_dir,
            "old_name": name, "new_name": new_name}, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("source")
    ap.add_argument("destination")
    ap.add_argument("--apply", action="store_true", help="move files (default is preview)")
    ap.add_argument("--secrets", help="YAML file holding a tmdb_api_key: line")
    ap.add_argument("--time-budget", type=float, default=0,
                    help="stop planning after N seconds and report what's left (0 = no limit)")
    ap.add_argument("--max-lines", type=int, default=25,
                    help="cap on listed files in the summary")
    args = ap.parse_args()
    started = time.monotonic()

    key = os.environ.get("TMDB_API_KEY", "").strip()
    if not key and args.secrets:
        try:
            with open(args.secrets, encoding="utf-8") as f:
                for line in f:
                    m = re.match(r"""^\s*tmdb_api_key\s*:\s*["']?([^"'\s#]+)""", line)
                    if m:
                        key = m.group(1)
        except OSError as e:
            print(f"Couldn't read {args.secrets}: {e.strerror}")
            return 1
    if not key:
        print("No TMDb API key: set TMDB_API_KEY or add tmdb_api_key to secrets.yaml.")
        return 1

    for folder in (args.source, args.destination):
        if not os.path.isdir(folder):
            print(f"Folder not found: {folder}")
            return 1

    tmdb = TMDb(key)
    files = find_files(args.source)
    if not files:
        print("Nothing to do: no files over 100MB in the source folder.")
        return 0

    plans, skipped, not_checked = [], [], 0
    planned_targets = set()
    for i, path in enumerate(files):
        if args.time_budget and time.monotonic() - started > args.time_budget:
            not_checked = len(files) - i
            break
        plan, why = plan_file(path, args.destination, tmdb, planned_targets)
        if tmdb.auth_failed:
            print("TMDb rejected the API key (401). Check tmdb_api_key in secrets.yaml.")
            return 1
        if plan:
            plans.append(plan)
            planned_targets.add(plan["new"].lower())
        else:
            skipped.append(f"{os.path.basename(path)}: {why}")

    moved, failed = [], []
    if args.apply:
        for p in plans:
            try:
                os.makedirs(p["dir"], exist_ok=True)
                if os.path.exists(p["new"]):
                    raise FileExistsError("target appeared since planning")
                shutil.move(p["old"], p["new"])   # rename on the same share, copy otherwise
                moved.append(p)
            except OSError as e:
                failed.append(f"{p['old_name']}: {e.strerror or e}")

    # ---- summary for the phone
    out = []
    lim = args.max_lines
    if args.apply:
        out.append(f"Moved {len(moved)}, skipped {len(skipped)}"
                   + (f", failed {len(failed)}" if failed else "") + ".")
        listed = moved
    else:
        out.append(f"Preview: {len(plans)} ready to move, {len(skipped)} skipped.")
        listed = plans
    for p in listed[:lim]:
        out.append(f"• {p['new_name']}")
    if len(listed) > lim:
        out.append(f"...and {len(listed) - lim} more")
    for s in (failed + skipped)[:lim]:
        out.append(f"✖ {s}")
    if not_checked:
        out.append(f"{not_checked} file(s) not checked yet (time limit). Run again for the rest.")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
