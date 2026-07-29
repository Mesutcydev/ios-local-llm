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
llama_patch="${repository_root}/Patches/llama.cpp-ios-only-xcframework.patch"

if grep -q 'IOS_ONLY:-0' "${llama_root}/build-xcframework.sh"; then
  echo "==> llama.cpp iOS-only build support is already present"
elif git -C "$llama_root" apply --check "$llama_patch" >/dev/null 2>&1; then
  echo "==> Applying the tracked llama.cpp iOS-only build patch"
  git -C "$llama_root" apply "$llama_patch"
else
  echo "error: the llama.cpp build patch does not match the pinned submodule" >&2
  echo "       restore or inspect ThirdParty/llama.cpp/build-xcframework.sh" >&2
  exit 1
fi

if [[ -e "${llama_root}/build-apple/llama.xcframework" ]]; then
  echo "error: generated llama.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi
if [[ -e "${repository_root}/ThirdParty/whisper.cpp/build-apple/whisper.xcframework" ]]; then
  echo "error: generated whisper.xcframework already exists; remove it before rebuilding" >&2
  exit 1
fi

echo "==> Building llama.cpp iOS XCFramework"
(cd "$llama_root" && IOS_ONLY=1 ./build-xcframework.sh)

echo "==> Building whisper.cpp iOS XCFramework"
"${repository_root}/scripts/native/build_whisper_ios.sh"

if [[ "$include_catalyst" == 1 ]]; then
  "${repository_root}/scripts/native/build_catalyst_slice.sh" llama
  "${repository_root}/scripts/native/build_catalyst_slice.sh" whisper
fi

echo "==> Native frameworks are ready"
