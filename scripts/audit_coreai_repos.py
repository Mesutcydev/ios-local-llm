#!/usr/bin/env python3
"""Audit Hugging Face Core AI repos: which trees exist, how big, and are they
a complete pack (metadata.json + tokenizer + .aimodel)?

Used to build/validate `CoreAIZooCatalog`. Read-only: it only calls the public
Hugging Face tree API.

    python3 scripts/audit_coreai_repos.py                 # audit default repo list
    python3 scripts/audit_coreai_repos.py repo1 repo2 ... # audit specific repos
"""
from __future__ import annotations

import json
import sys
import urllib.error
import urllib.request
from collections import defaultdict

API = "https://huggingface.co/api/models/{repo}/tree/{rev}?recursive=1"

DEFAULT_REPOS = [
    # Official-recipe conversions (Apple's own export recipes, stock runtime).
    "mlboydaisuke/qwen3-0.6b-CoreAI-official",
    "mlboydaisuke/qwen3-4b-CoreAI-official",
    "mlboydaisuke/qwen3-8b-CoreAI-official",
    "mlboydaisuke/gemma-3-4b-it-CoreAI-official",
    "mlboydaisuke/mistral-7b-v0.3-CoreAI-official",
    "mlboydaisuke/whisper-large-v3-turbo-CoreAI-official",
    # Community zoo language models.
    "mlboydaisuke/qwen3.5-0.8B-CoreAI",
    "mlboydaisuke/qwen3.5-2B-CoreAI",
    "mlboydaisuke/qwen3.5-4B-CoreAI",
    "mlboydaisuke/gemma-4-E2B-CoreAI",
    "mlboydaisuke/gemma-4-E4B-CoreAI",
    "mlboydaisuke/LFM2.5-1.2B-CoreAI",
    "mlboydaisuke/LFM2.5-2.6B-CoreAI",
    "mlboydaisuke/LFM2.5-8B-A1B-CoreAI",
    "mlboydaisuke/granite-4.0-h-CoreAI",
    "mlboydaisuke/MiniCPM5-1B-CoreAI",
    "mlboydaisuke/Nanbeige4.1-3B-CoreAI",
    "ukint-vs/Nanbeige4.2-3B-CoreAI",
    "mlboydaisuke/Youtu-LLM-2B-CoreAI",
    "mlboydaisuke/Nemotron-3-Nano-4B-CoreAI",
    "mlboydaisuke/RWKV7-Goose-1.5B-CoreAI",
    "mlboydaisuke/BitCPM-8B-CoreAI",
    "mlboydaisuke/FastContext-1.0-4B-CoreAI",
    # Vision-language.
    "mlboydaisuke/Qwen3-VL-2B-CoreAI",
    "mlboydaisuke/Qwen3-VL-4B-CoreAI",
    "mlboydaisuke/Qwen3-VL-8B-CoreAI",
    "mlboydaisuke/LFM2.5-VL-450M-CoreAI",
    "mlboydaisuke/LFM2.5-VL-3B-CoreAI",
    # Embedding / rerank / ASR.
    "mlboydaisuke/Qwen3-Embedding-0.6B-CoreAI",
    "mlboydaisuke/embeddinggemma-300m-CoreAI",
    "mlboydaisuke/Qwen3-Reranker-0.6B-CoreAI",
    "mlboydaisuke/Qwen3-ASR-1.7B-CoreAI",
    "mlboydaisuke/Parakeet-TDT-0.6B-CoreAI",
    # Third-party single-pack repos seen in the wild.
    "kevinqz/Qwen2.5-Coder-1.5B-Instruct-CoreAI",
]


def fetch_tree(repo: str, rev: str = "main") -> list[dict] | None:
    req = urllib.request.Request(
        API.format(repo=repo, rev=rev),
        headers={"Accept": "application/json", "User-Agent": "coreai-audit/1.0"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        print(f"  !! HTTP {exc.code} for {repo}")
        return None
    except Exception as exc:  # noqa: BLE001 - audit script, report and continue
        print(f"  !! {type(exc).__name__} for {repo}: {exc}")
        return None


def size_of(entry: dict) -> int:
    lfs = entry.get("lfs") or {}
    return int(lfs.get("size") or entry.get("size") or 0)


def audit(repo: str) -> dict | None:
    tree = fetch_tree(repo)
    if tree is None:
        return None
    files = [e for e in tree if e.get("type") == "file"]
    if not files:
        print(f"  !! empty tree for {repo}")
        return None

    # Group by first path component so a repo shipping macos/ + ios-*/ trees
    # reports each variant separately.
    groups: dict[str, list[dict]] = defaultdict(list)
    for f in files:
        parts = f["path"].split("/")
        groups[parts[0] if len(parts) > 1 else "<root>"].append(f)

    print(f"\n=== {repo}")
    result = {"repo": repo, "groups": {}}
    for name, entries in sorted(groups.items()):
        total = sum(size_of(e) for e in entries)
        paths = [e["path"] for e in entries]
        lower = [p.lower() for p in paths]
        has_model = any(".aimodel" in p or ".aimodelc" in p for p in lower)
        has_meta = any(p.endswith("metadata.json") for p in lower)
        has_tok = any("tokenizer" in p for p in lower)
        flags = "".join(
            [
                "M" if has_model else "-",
                "J" if has_meta else "-",
                "T" if has_tok else "-",
            ]
        )
        gb = total / 1_000_000_000
        print(f"  {flags}  {name:34s} {len(entries):4d} files  {gb:8.3f} GB")
        result["groups"][name] = {
            "files": len(entries),
            "bytes": total,
            "has_aimodel": has_model,
            "has_metadata": has_meta,
            "has_tokenizer": has_tok,
        }
    return result


def main() -> int:
    repos = sys.argv[1:] or DEFAULT_REPOS
    out = []
    for repo in repos:
        r = audit(repo)
        if r:
            out.append(r)
    with open("/tmp/coreai_repo_audit.json", "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2)
    print(f"\nwrote /tmp/coreai_repo_audit.json ({len(out)} repos)")
    print("flags: M=.aimodel present  J=metadata.json present  T=tokenizer present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
