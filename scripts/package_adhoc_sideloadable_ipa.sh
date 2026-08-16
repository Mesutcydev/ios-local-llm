#!/usr/bin/env bash
set -euo pipefail

# Build the profile-less ad-hoc/re-signer IPA format used by the project's
# existing sideload release assets. This is intentionally separate from
# package_sideloadable_ipa.sh, which preserves a developer-signed app and its
# embedded provisioning profile.

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 /path/to/App.app [output.ipa] [entitlements.plist]" >&2
}

[[ $# -ge 1 && $# -le 3 ]] || { usage; exit 2; }

app_path="$1"
[[ -d "$app_path" ]] || die "app bundle not found: $app_path"
case "$app_path" in
  *.app) ;;
  *) die "first argument must be an .app bundle" ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
entitlements_path="${3:-$script_dir/sideload_entitlements.plist}"
[[ -f "$entitlements_path" ]] || die "entitlements plist not found: $entitlements_path"

command -v codesign >/dev/null || die "codesign is required (run on macOS with Xcode tools)"
command -v ditto >/dev/null || die "ditto is required (run on macOS)"
command -v plutil >/dev/null || die "plutil is required (run on macOS)"
command -v unzip >/dev/null || die "unzip is required"
command -v zip >/dev/null || die "zip is required"
command -v shasum >/dev/null || die "shasum is required"

app_name="$(basename "$app_path")"
profile_matches="$(find "$app_path" -name embedded.mobileprovision -print -quit)"
[[ -z "$profile_matches" ]] || die "input app contains embedded.mobileprovision; use the profile-preserving packager instead"

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist" 2>/dev/null || true)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Info.plist" 2>/dev/null || true)"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Info.plist" 2>/dev/null || true)"
[[ -n "$bundle_id" && -n "$version" && -n "$build_number" ]] || die "app Info.plist is missing bundle identity or version metadata"

output_path="${2:-$PWD/build/${app_name%.app}-${version}-${build_number}-sideload-entitled.ipa}"
output_dir="$(dirname "$output_path")"
mkdir -p "$output_dir"
output_abs="$(cd "$output_dir" && pwd)/$(basename "$output_path")"
[[ ! -e "$output_abs" ]] || die "output already exists: $output_abs (remove it intentionally, then retry)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ios-local-llm-adhoc-ipa.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

mkdir -p "$work_dir/Payload"
ditto "$app_path" "$work_dir/Payload/$app_name"
staged_app="$work_dir/Payload/$app_name"

sign_nested() {
  local target
  while IFS= read -r -d '' target; do
    echo "Signing nested code: $target"
    codesign --force --sign - --timestamp=none "$target"
  done < <(find "$staged_app" -type d -name '*.framework' -print0)

  while IFS= read -r -d '' target; do
    echo "Signing nested code: $target"
    codesign --force --sign - --timestamp=none "$target"
  done < <(find "$staged_app" -type f -name '*.dylib' -print0)

  while IFS= read -r -d '' target; do
    echo "Signing nested code: $target"
    codesign --force --sign - --timestamp=none "$target"
  done < <(find "$staged_app" -type d -name '*.appex' -print0)
}

sign_nested
echo "Signing app with sideload entitlements: $entitlements_path"
codesign --force --sign - --timestamp=none --entitlements "$entitlements_path" "$staged_app"

codesign --verify --deep --strict --verbose=2 "$staged_app" || die "ad-hoc signature verification failed"

actual_entitlements="$work_dir/actual-entitlements.plist"
codesign -d --entitlements :- "$staged_app" > "$actual_entitlements" 2> "$work_dir/codesign-details.txt" || die "could not extract signed entitlements"
plutil -lint "$actual_entitlements" >/dev/null || die "signed entitlements are invalid"
plutil -lint "$entitlements_path" >/dev/null || die "requested entitlements are invalid"
plutil -convert binary1 -o "$work_dir/expected-entitlements.plist" "$entitlements_path"
plutil -convert binary1 -o "$work_dir/actual-entitlements.plist.bin" "$actual_entitlements"
cmp -s "$work_dir/expected-entitlements.plist" "$work_dir/actual-entitlements.plist.bin" || die "signed entitlements differ from the requested sideload entitlements"

if find "$staged_app" -name embedded.mobileprovision -print -quit | rg -q .; then
  die "profile unexpectedly appeared in the staged app"
fi

(
  cd "$work_dir"
  zip -qry "$output_abs" Payload
)

unzip -l "$output_abs" | rg -q "Payload/$app_name/_CodeSignature/CodeResources" || die "IPA is missing the app CodeResources"
unzip -l "$output_abs" | rg -q "Payload/$app_name/PlugIns/.*\.appex/_CodeSignature/CodeResources" || die "IPA is missing the share extension CodeResources"
if unzip -l "$output_abs" | rg -q 'embedded\.mobileprovision'; then
  die "IPA unexpectedly contains a provisioning profile"
fi

echo "Created verified ad-hoc sideload IPA: $output_abs"
echo "Bundle: $bundle_id"
echo "Version: $version ($build_number)"
echo "Signing: ad-hoc / installer re-sign required"
echo "SHA256: $(shasum -a 256 "$output_abs" | awk '{print $1}')"
