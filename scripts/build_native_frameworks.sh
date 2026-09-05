#!/usr/bin/env bash

# Reproducibly build the native llama.cpp and whisper.cpp XCFrameworks from
# pinned submodules. Generated frameworks remain ignored by Git.

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
include_catalyst=0

if [[ "${1:-}" == "--with-catalyst" ]]; then
  include_catalyst=1
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--with-catalyst]" >&2
  exit 64
fi

git -C "$repository_root" submodule update --init --recursive

llama_root="${repository_root}/ThirdParty/llama.cpp"
if [[ -e "${llama_root}/build-apple/llama.xcframework" ]]; then
  echo "error: generated llama.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi
if [[ -e "${repository_root}/ThirdParty/whisper.cpp/build-apple/whisper.xcframework" ]]; then
  echo "error: generated whisper.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi

echo "==> Building llama.cpp iOS XCFramework"
(cd "$llama_root" && ./build-xcframework.sh ios-sim ios-device)

echo "==> Building whisper.cpp iOS XCFramework"
"${repository_root}/scripts/native/build_whisper_ios.sh"

if [[ "$include_catalyst" == 1 ]]; then
  "${repository_root}/scripts/native/build_catalyst_slice.sh" llama
  "${repository_root}/scripts/native/build_catalyst_slice.sh" whisper
fi

echo "==> Native frameworks are ready"
