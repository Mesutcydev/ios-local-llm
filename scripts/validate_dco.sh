#!/usr/bin/env bash

set -euo pipefail

base_sha="${1:-}"
head_sha="${2:-HEAD}"

if [[ -z "$base_sha" ]]; then
  echo "usage: $0 <base-sha> [head-sha]" >&2
  exit 64
fi

failed=0
while IFS= read -r commit_sha; do
  [[ -n "$commit_sha" ]] || continue
  if ! git show -s --format=%B "$commit_sha" |
    grep -Eqi '^Signed-off-by: .+ <[^>]+>$'; then
    echo "error: commit lacks a valid Signed-off-by line: $commit_sha" >&2
    failed=1
  fi
done < <(git rev-list "${base_sha}..${head_sha}")

if [[ "$failed" == 1 ]]; then
  echo "Add sign-off with: git commit --amend --signoff" >&2
  exit 1
fi

echo "DCO sign-off checks passed."
