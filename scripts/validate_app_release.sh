#!/usr/bin/env bash
# Run after native framework generation and `pod install --deployment`.
set -euo pipefail
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"
audit_derived_data="${AUDIT_DERIVED_DATA:-${TMPDIR:-/tmp}/ondevice-release-validation}"
audit_simulator="${AUDIT_SIMULATOR_ID:-}"
if [[ -z "$audit_simulator" ]]; then
  audit_simulator="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
for runtime, devices in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices:
        if device["name"].startswith("iPhone") and device.get("isAvailable"):
            print(device["udid"])
            sys.exit(0)
sys.exit("No installed iPhone Simulator runtime")
')"
fi
xcodebuild test -workspace IOSLocalLLM.xcworkspace -scheme IOSLocalLLM \
  -destination "platform=iOS Simulator,id=$audit_simulator" \
  -derivedDataPath "$audit_derived_data" -disableAutomaticPackageResolution
xcodebuild build -workspace IOSLocalLLM.xcworkspace -scheme IOSLocalLLM \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$audit_derived_data" -disableAutomaticPackageResolution
