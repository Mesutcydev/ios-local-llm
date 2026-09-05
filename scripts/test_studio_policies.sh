#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc IOSLocalLLM/Models/StudioTextBlocks.swift scripts/tests/StudioPolicyChecks.swift -o "$test_dir/checks"
"$test_dir/checks"
