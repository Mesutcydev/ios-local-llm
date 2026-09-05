#!/bin/bash
# Preflight: verify every FoundationModels symbol the app imports is safe to
# load on a shipping device OS — catching the "SDK .tbd declares it, device
# binary doesn't export it" class of dyld launch abort.
#
# WHY: linking resolves against Xcode's .tbd stub, which still lists
# deprecated-renamed API. Newer OS builds drop those symbols from the real
# framework binary, so dyld aborts the process BEFORE main() — no crash log,
# no in-app crash reporter, just a bounce.
#
# Usage:
#   scripts/verify_foundationmodels_symbols.sh <path-to-.app-or-binary> [framework] [sdk-path]
#
# Exit 0 = clean, 1 = a deprecated or genuinely-missing import was found.

set -uo pipefail

TARGET="${1:?usage: $0 <path-to-.app-or-binary> [framework] [sdk-path]}"
FWNAME="${2:-FoundationModels}"

# Resolve an SDK. IMPORTANT: sort by the SDK's own version number, not by the
# full path. `ls -d /Applications/Xcode*.app/.../iPhoneOS*.sdk | sort -V | tail -1`
# sorts on the whole string, so "/Applications/Xcode.app/...iPhoneOS26.5.sdk"
# lands AFTER "/Applications/Xcode-beta.app/...iPhoneOS27.0.sdk" ('.' > '-')
# and the older stub wins. Against the 26.5 stub every iOS-27-only symbol looks
# missing — 23 false "NOT IN SDK TBD" lines that hide the one real finding.
if [[ -n "${3:-}" ]]; then
  SDK="$3"
else
  SDK="$(
    for d in /Applications/Xcode*.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS[0-9]*.sdk; do
      [[ -d "$d" ]] || continue
      v="$(basename "$d")"; v="${v#iPhoneOS}"; v="${v%.sdk}"
      printf '%s\t%s\n' "$v" "$d"
    done | sort -V | tail -1 | cut -f2
  )"
fi
[[ -d "$SDK" ]] || { echo "error: no iPhoneOS SDK found (pass one as arg 3)" >&2; exit 1; }
echo "SDK: $SDK"

FW="$SDK/System/Library/Frameworks/$FWNAME.framework"
TBD="$FW/$FWNAME.tbd"
[[ -f "$TBD" ]] || { echo "error: no $FWNAME.tbd in $SDK" >&2; exit 1; }

# Swift mangles module names length-prefixed: FoundationModels -> 16FoundationModels
MANGLED_MODULE="${#FWNAME}$FWNAME"

# Accept an .app bundle or a Mach-O directly. Debug builds keep the real code
# in a side .debug.dylib — the thin executable imports nothing, so check both
# or the scan silently passes.
if [[ -d "$TARGET" ]]; then
  NAME="$(basename "$TARGET" .app)"
  BIN="$TARGET/$NAME"
  EXTRA_BIN="$TARGET/$NAME.debug.dylib"
else
  BIN="$TARGET"
  EXTRA_BIN=""
fi
[[ -f "$BIN" ]] || { echo "error: no Mach-O at $BIN" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# `|| true` on every grep: a legitimate zero-match must not kill the script.
{
  nm -u "$BIN" 2>/dev/null || true
  if [[ -n "$EXTRA_BIN" && -f "$EXTRA_BIN" ]]; then
    nm -u "$EXTRA_BIN" 2>/dev/null || true
  fi
} | { grep "$MANGLED_MODULE" || true; } | sed 's/^ *//' | sort -u > "$WORK/imported.txt"

COUNT="$(wc -l < "$WORK/imported.txt" | tr -d ' ')"
echo "$FWNAME symbols imported: $COUNT"
if [[ "$COUNT" == "0" ]]; then
  echo "Nothing to check."
  exit 0
fi

STATUS=0

# --- Check 1: present in the SDK stub at all -------------------------------
# -F: mangled names contain '$' and '.', which are regex metacharacters.
MISSING=0
while IFS= read -r sym; do
  grep -qF -- "${sym#_}" "$TBD" || { echo "NOT IN SDK TBD: $sym"; MISSING=1; STATUS=1; }
done < "$WORK/imported.txt"
[[ "$MISSING" == "0" ]] && echo "All imported symbols exist in the SDK stub."

# --- Check 2: not a deprecated-renamed declaration -------------------------
# The .swiftinterface carries the `renamed:` hints the .tbd lacks. Anything on
# that list is a launch-abort candidate on a newer OS build.
SI="$(ls "$FW/Modules/$FWNAME.swiftmodule/"*.swiftinterface 2>/dev/null | head -1)"
if [[ -n "$SI" && -f "$SI" ]]; then
  { grep -A3 '@available(\*, deprecated' "$SI" || true; } \
    | { grep -E 'public (init|func|var|static)' || true; } \
    | sed 's/^[0-9]*[-:]*//; s/^ *//' > "$WORK/deprecated_decls.txt"

  if [[ -s "$WORK/deprecated_decls.txt" ]]; then
    echo
    echo "Deprecated-renamed $FWNAME declarations in this SDK (risk surface):"
    sed 's/^/  /' "$WORK/deprecated_decls.txt"
    echo
    echo "Checking whether the app imports any of them…"

    while IFS= read -r sym; do
      xcrun swift-demangle "${sym#_}" 2>/dev/null | sed 's/.*---> //'
    done < "$WORK/imported.txt" > "$WORK/demangled.txt"

    FOUND=0
    while IFS= read -r decl; do
      # Distinguishing key is the first argument label — that is what differs
      # between the old and new spellings (`init(capabilities:)` vs `init(_:)`).
      label="$(echo "$decl" | sed -n 's/.*public init(\([a-zA-Z_][a-zA-Z0-9_]*\):.*/\1/p')"
      [[ -z "$label" ]] && continue
      if grep -qF "init($label:" "$WORK/demangled.txt"; then
        echo "DEPRECATED IMPORT: init($label:)  ← $decl"
        echo "  → switch to the renamed spelling; shipping OS builds may not"
        echo "    export the deprecated symbol and dyld will abort at load."
        FOUND=1
        STATUS=1
      fi
    done < "$WORK/deprecated_decls.txt"
    [[ "$FOUND" == "0" ]] && echo "None imported."
  fi
fi

# NOTE: deliberately no comparison against
# ~/Library/Developer/Xcode/iOS DeviceSupport/**/Symbols/.../<FW>. That file is
# a dyld-shared-cache extract with ObjC/C symbols only — zero Swift exports —
# so "not found there" is meaningless for Swift API.

echo
if [[ "$STATUS" == "0" ]]; then
  echo "OK — no deprecated or missing $FWNAME imports."
else
  echo "FAILED — fix the symbols above before installing on device."
fi
exit "$STATUS"
