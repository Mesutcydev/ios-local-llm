#!/usr/bin/env python3
"""Prove every catalog pack is really downloadable.

For each entry in CoreAIZooCatalog it lists the exact subtree the app would
fetch, then issues a real ranged GET against the largest file's
`/resolve/<rev>/<path>` URL — the same URL the in-app downloader builds. A pack
only passes when the tree exists, carries an `.aimodel` plus `metadata.json`,
the summed size matches the catalog's recorded bytes, and the direct link
returns data.

    python3 scripts/verify_zoo_downloads.py            # all packs
    python3 scripts/verify_zoo_downloads.py zoo-qwen3.5-0.8b ...
"""
from __future__ import annotations

import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "IOSLocalLLM" / "Models" / "CoreAIZooCatalog.swift"
TREE_API = "https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=1"
RESOLVE = "https://huggingface.co/{repo}/resolve/{rev}/{path}"
UA = {"User-Agent": "coreai-zoo-verify/1.0"}

ENTRY_RE = re.compile(
    r"CoreAIZooModel\(\s*"
    r'id:\s*"(?P<id>[^"]+)",\s*'
    r'displayName:\s*"(?P<name>[^"]+)",\s*'
    r'subtitle:\s*"[^"]*",\s*'
    r'hfRepo:\s*"(?P<repo>[^"]+)",\s*'
    r'revision:\s*"(?P<rev>[^"]+)",\s*'
    r"pathPrefix:\s*(?P<prefix>nil|\"[^\"]*\"),\s*"
    r"approxDownloadBytes:\s*(?P<bytes>[0-9_]+),"
    r".*?category:\s*\.(?P<category>\w+),",
    re.S,
)


def parse_catalog() -> list[dict]:
    text = CATALOG.read_text(encoding="utf-8")
    out = []
    for m in ENTRY_RE.finditer(text):
        prefix = m.group("prefix")
        out.append(
            {
                "id": m.group("id"),
                "name": m.group("name"),
                "repo": m.group("repo"),
                "rev": m.group("rev"),
                "prefix": None if prefix == "nil" else prefix.strip('"'),
                "bytes": int(m.group("bytes").replace("_", "")),
                "category": m.group("category"),
            }
        )
    return out


def get_json(url: str):
    req = urllib.request.Request(url, headers={**UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as resp:
        return json.loads(resp.read().decode())


def size_of(entry: dict) -> int:
    return int((entry.get("lfs") or {}).get("size") or entry.get("size") or 0)


def probe_direct(repo: str, rev: str, path: str) -> tuple[bool, str]:
    """Ranged GET: proves the direct link serves bytes without pulling the file."""
    encoded = "/".join(urllib.parse.quote(p) for p in path.split("/"))
    url = RESOLVE.format(repo=repo, rev=rev, path=encoded)
    req = urllib.request.Request(url, headers={**UA, "Range": "bytes=0-1023"})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read(1024)
            return (len(data) > 0, f"HTTP {resp.status}, {len(data)} bytes")
    except urllib.error.HTTPError as exc:
        return (False, f"HTTP {exc.code}")
    except Exception as exc:  # noqa: BLE001
        return (False, f"{type(exc).__name__}: {exc}")


def verify(entry: dict) -> bool:
    label = f"{entry['id']:34s}"
    try:
        tree = get_json(TREE_API.format(repo=entry["repo"], rev=entry["rev"]))
    except Exception as exc:  # noqa: BLE001
        print(f"FAIL {label} tree API: {type(exc).__name__}: {exc}")
        return False

    prefix = entry["prefix"] or ""
    norm = prefix if prefix.endswith("/") or not prefix else prefix + "/"
    files = [
        f
        for f in tree
        if f.get("type") == "file"
        and (not prefix or f["path"] == prefix or f["path"].startswith(norm))
        and not f["path"].lower().endswith((".md", ".gitattributes"))
    ]
    if not files:
        print(f"FAIL {label} subtree '{prefix}' is empty")
        return False

    normalized_prefix = prefix.rstrip("/")
    direct = normalized_prefix + "/" if normalized_prefix else ""
    relative = [f["path"][len(direct):].lower() for f in files]
    has_model = any(
        p.endswith((".aimodel", ".aimodelc"))
        or ".aimodel/" in p
        or ".aimodelc/" in p
        for p in relative
    )
    is_language = entry["category"] in {"officialRecipe", "chat"}
    # The language runtime receives the selected prefix itself. A metadata file
    # in some deeper sibling bundle is not sufficient; that was the production
    # bug that let parent trees install and then fail with BundleError 0.
    has_meta = (
        "metadata.json" in relative
        if is_language
        else any(p.endswith("metadata.json") for p in relative)
    )
    has_tokenizer = "tokenizer/tokenizer.json" in relative if is_language else True
    total = sum(size_of(f) for f in files)
    drift = abs(total - entry["bytes"]) / max(entry["bytes"], 1)

    problems = []
    if not has_model:
        problems.append("no .aimodel")
    if not has_meta:
        problems.append(
            "metadata.json is not at the selected bundle root"
            if is_language
            else "no metadata.json"
        )
    if not has_tokenizer:
        problems.append("tokenizer/tokenizer.json is not at the selected bundle root")
    if drift > 0.02:
        problems.append(f"size drift {drift:.1%} (tree {total:,} vs catalog {entry['bytes']:,})")

    biggest = max(files, key=size_of)
    ok, detail = probe_direct(entry["repo"], entry["rev"], biggest["path"])
    if not ok:
        problems.append(f"direct link failed: {detail}")

    status = "OK  " if not problems else "FAIL"
    print(
        f"{status} {label} {len(files):3d} files  {total/1e9:6.2f} GB  "
        f"direct={detail}  {'; '.join(problems)}"
    )
    return not problems


def main() -> int:
    entries = parse_catalog()
    wanted = set(sys.argv[1:])
    if wanted:
        entries = [e for e in entries if e["id"] in wanted]
    if not entries:
        print("no catalog entries matched")
        return 2

    print(f"verifying {len(entries)} catalog packs\n")
    failures = [e["id"] for e in entries if not verify(e)]
    print()
    if failures:
        print(f"{len(failures)} FAILED: {', '.join(failures)}")
        return 1
    print(f"all {len(entries)} packs verified downloadable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
