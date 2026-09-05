#!/usr/bin/env bash
set -euo pipefail

# Package a device-signed .app without rewriting its embedded profile or
# entitlements. The source repository intentionally does not contain a signed
# installer; this helper is for a developer who has already archived with
# their own Apple team and wants a checked IPA for sideloading.

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  echo "Usage: $0 /path/to/App.app [output.ipa]" >&2
}

[[ $# -ge 1 && $# -le 2 ]] || { usage; exit 2; }

app_path="$1"
[[ -d "$app_path" ]] || die "app bundle not found: $app_path"
case "$app_path" in
  *.app) ;;
  *) die "first argument must be an .app bundle" ;;
esac

command -v codesign >/dev/null || die "codesign is required (run on macOS with Xcode tools)"
command -v security >/dev/null || die "security is required (run on macOS)"
command -v plutil >/dev/null || die "plutil is required (run on macOS)"
command -v zip >/dev/null || die "zip is required"

app_name="$(basename "$app_path")"
profile="$app_path/embedded.mobileprovision"
[[ -f "$profile" ]] || die "embedded.mobileprovision is missing; refusing to create an unsigned IPA"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ios-local-llm-ipa.XXXXXX")"
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT

entitlements="$work_dir/entitlements.plist"
profile_plist="$work_dir/profile.plist"

echo "Verifying code signature: $app_name"
codesign --verify --deep --strict --verbose=2 "$app_path" || die "code signature verification failed"

codesign -d --entitlements :- "$app_path" > "$entitlements" 2> "$work_dir/codesign-details.txt" || die "could not extract code-signing entitlements"
plutil -lint "$entitlements" >/dev/null || die "the code-signing entitlements blob is invalid"

security cms -D -i "$profile" -o "$profile_plist" 2>/dev/null || die "embedded provisioning profile could not be decoded"
plutil -lint "$profile_plist" >/dev/null || die "decoded provisioning profile is invalid"

app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$entitlements" 2>/dev/null || true)"
profile_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
if [[ -n "$app_identifier" && -n "$profile_identifier" && "$app_identifier" != "$profile_identifier" ]]; then
  die "application-identifier mismatch between entitlements ($app_identifier) and profile ($profile_identifier)"
fi

output_path="${2:-$PWD/build/$app_name.ipa}"
output_dir="$(cd "$(dirname "$output_path")" && pwd)"
output_abs="$output_dir/$(basename "$output_path")"
[[ ! -e "$output_abs" ]] || die "output already exists: $output_abs (remove it intentionally, then retry)"

mkdir -p "$work_dir/Payload"
ditto "$app_path" "$work_dir/Payload/$app_name"

(
  cd "$work_dir"
  zip -qry "$output_abs" Payload
)

# Materialize the listing before matching: `grep -q` in a pipe under
# `set -o pipefail` can hand unzip a SIGPIPE and fail a healthy IPA.
ipa_listing="$(unzip -l "$output_abs")"
grep -q "Payload/$app_name/embedded.mobileprovision" <<< "$ipa_listing" || die "IPA is missing the embedded provisioning profile"
grep -q "Payload/$app_name/_CodeSignature/CodeResources" <<< "$ipa_listing" || die "IPA is missing CodeResources"

echo "Created verified IPA: $output_abs"
echo "Entitlements and embedded profile were preserved byte-for-byte from the input app bundle."
