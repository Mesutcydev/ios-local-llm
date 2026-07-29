#!/usr/bin/env bash
# download_voice_models.sh
# Downloads KittenTTS CoreML (Nano or Mini) and optionally Kokoro CoreML
# into the app's Documents/VoiceModels/ folder via the iOS Simulator file path,
# or into a local staging directory for device deployment.
#
# Usage:
#   ./scripts/download_voice_models.sh [nano|mini] [--kokoro] [--staging-dir PATH]
#
# Options:
#   nano              Download KittenTTS Nano (~61 MB)   [default]
#   mini              Download KittenTTS Mini (~280 MB)
#   --kokoro          Also download Kokoro-82M (experimental, ~82 MB)
#   --staging-dir     Copy files here instead of simulator Documents
#
# Requirements: git lfs, curl, unzip

set -euo pipefail

# One bounded temporary root for every sparse clone. The EXIT trap also runs
# on download failures and interrupts, so large LFS checkouts never linger.
VOICE_DOWNLOAD_TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$VOICE_DOWNLOAD_TEMP_ROOT"' EXIT

VARIANT="${1:-nano}"
DOWNLOAD_KOKORO=false
STAGING_DIR=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --kokoro)       DOWNLOAD_KOKORO=true ;;
    --staging-dir=*) STAGING_DIR="${arg#*=}" ;;
  esac
done

# Find simulator app Documents directory (latest booted iPhone sim)
find_sim_docs() {
  xcrun simctl get_app_container booted com.codelens.CodeLens data 2>/dev/null \
    | sed 's|$|/Documents|' || echo ""
}

if [ -z "$STAGING_DIR" ]; then
  SIM_DOCS=$(find_sim_docs)
  if [ -z "$SIM_DOCS" ]; then
    echo "⚠️  No booted simulator found. Using local ./VoiceModels/ staging dir."
    STAGING_DIR="$(pwd)/VoiceModels"
  else
    STAGING_DIR="$SIM_DOCS"
  fi
fi

VOICE_ROOT="$STAGING_DIR/VoiceModels"
KITTEN_DIR="$VOICE_ROOT/KittenTTS"
KOKORO_DIR="$VOICE_ROOT/Kokoro"

mkdir -p "$KITTEN_DIR" "$KOKORO_DIR"

echo "==> Voice models will be placed in: $VOICE_ROOT"

# ── KittenTTS ──────────────────────────────────────────────────────────────────
# Source: https://huggingface.co/alexwengg/kittentts-coreml
KITTEN_REPO="https://huggingface.co/alexwengg/kittentts-coreml"
KITTEN_BRANCH="main"

if [ "$VARIANT" = "mini" ]; then
  KITTEN_MODEL="kitten_tts_mini.mlpackage"
  echo "==> Downloading KittenTTS Mini (~280 MB)…"
else
  KITTEN_MODEL="kitten_tts_nano.mlpackage"
  echo "==> Downloading KittenTTS Nano (~61 MB)…"
fi

# Clone sparse checkout — model package + voices.npz only
KITTEN_CLONE_DIR="$VOICE_DOWNLOAD_TEMP_ROOT/kittentts-coreml"
git clone \
  --depth 1 \
  --filter=blob:none \
  --sparse \
  "$KITTEN_REPO" \
  "$KITTEN_CLONE_DIR"

(
  cd "$KITTEN_CLONE_DIR"
  git sparse-checkout set "$KITTEN_MODEL" "voices.npz"
  git lfs pull --include="$KITTEN_MODEL/**" --include="voices.npz"
)

if [ -d "$KITTEN_CLONE_DIR/$KITTEN_MODEL" ]; then
  cp -R "$KITTEN_CLONE_DIR/$KITTEN_MODEL" "$KITTEN_DIR/"
  echo "   ✅ $KITTEN_MODEL → $KITTEN_DIR"
else
  echo "   ❌ $KITTEN_MODEL not found in cloned repo. Check git lfs installation."
fi

if [ -f "$KITTEN_CLONE_DIR/voices.npz" ]; then
  cp "$KITTEN_CLONE_DIR/voices.npz" "$KITTEN_DIR/"
  echo "   ✅ voices.npz → $KITTEN_DIR"
else
  echo "   ❌ voices.npz not found. Check git lfs installation."
fi

# ── Kokoro (optional) ──────────────────────────────────────────────────────────
if [ "$DOWNLOAD_KOKORO" = "true" ]; then
  echo "==> Downloading Kokoro-82M CoreML (experimental, ~82 MB)…"
  KOKORO_REPO="https://huggingface.co/hexgrad/Kokoro-82M"
  KOKORO_CLONE_DIR="$VOICE_DOWNLOAD_TEMP_ROOT/kokoro-82m"
  git clone \
    --depth 1 \
    --filter=blob:none \
    --sparse \
    "$KOKORO_REPO" \
    "$KOKORO_CLONE_DIR"
  (
    cd "$KOKORO_CLONE_DIR"
    git sparse-checkout set "kokoro.mlpackage"
    git lfs pull --include="kokoro.mlpackage/**"
  )
  if [ -d "$KOKORO_CLONE_DIR/kokoro.mlpackage" ]; then
    cp -R "$KOKORO_CLONE_DIR/kokoro.mlpackage" "$KOKORO_DIR/"
    echo "   ✅ kokoro.mlpackage → $KOKORO_DIR"
  else
    echo "   ❌ kokoro.mlpackage not found. The Kokoro CoreML export may not be available yet."
    echo "      See: https://github.com/hexgrad/kokoro for conversion scripts."
  fi
fi

echo ""
echo "==> Done. Restart the app (or re-install) for Documents to be visible."
echo "    Model root: $VOICE_ROOT"
echo ""
echo "    Expected layout:"
echo "    VoiceModels/"
echo "    ├── KittenTTS/"
echo "    │   ├── $KITTEN_MODEL/"
echo "    │   └── voices.npz"
if [ "$DOWNLOAD_KOKORO" = "true" ]; then
echo "    └── Kokoro/"
echo "        └── kokoro.mlpackage/"
fi
