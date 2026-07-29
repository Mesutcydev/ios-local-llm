#!/usr/bin/env bash
# export_fastvlm_coreml.sh
#
# Exports FastVLM model components from apple/ml-fastvlm for use with CodeLens.
#
# WHAT THIS SCRIPT PRODUCES
# ──────────────────────────────────────────────────────────────────────────────
#   GeneratedFastVLMModels/FastVLM-0.5B-CoreML/
#     fastvithd.mlpackage          — Core ML vision encoder (iOS 16+ mlprogram)
#     preprocessor_config.json    — image pre-processing config (for mlx-vlm)
#     processor_config.json       — patch size / image token config
#     tokenizer_config.json       — Qwen2 tokenizer + <image> token added
#     config.json                 — image_token_index added
#     llava-fastvithd_0.5b_stage3_llm.fp16/   — MLX LLM weights (FP16)
#
# WHAT THIS SCRIPT DOES NOT PRODUCE
# ──────────────────────────────────────────────────────────────────────────────
#   language_model_kvcache.mlpackage — apple/ml-fastvlm does NOT provide a
#   Core ML decoder export.  The LLM decoder runs via MLX Swift (MLXLLM).
#   See scripts/FASTVLM_EXPORT_NOTES.md for details.
#
# REQUIREMENTS
# ──────────────────────────────────────────────────────────────────────────────
#   • macOS 14+ with Apple Silicon (MPS required by export_vision_encoder.py)
#   • Homebrew Python 3.11  (coremltools 8.x is incompatible with Python 3.12+)
#   • ~10 GB free disk space
#   • git, curl or wget, unzip
#
# USAGE
# ──────────────────────────────────────────────────────────────────────────────
#   chmod +x scripts/export_fastvlm_coreml.sh
#   bash scripts/export_fastvlm_coreml.sh
#
# Run from anywhere — the script resolves paths from its own location.

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/GeneratedFastVLMModels/FastVLM-0.5B-CoreML"
WORK_DIR="$SCRIPT_DIR/.fastvlm_work"
VENV_DIR="$WORK_DIR/venv"
ML_FASTVLM_DIR="$WORK_DIR/ml-fastvlm"
MLX_VLM_DIR="$WORK_DIR/mlx-vlm"
CHECKPOINTS_DIR="$WORK_DIR/checkpoints"

# Exact checkpoint name used by apple/ml-fastvlm get_models.sh
MODEL_ARCHIVE="llava-fastvithd_0.5b_stage3"
MODEL_DIR="$CHECKPOINTS_DIR/$MODEL_ARCHIVE"

# MLX export output name (matches get_pretrained_mlx_model.sh convention)
MLX_OUTPUT_NAME="llava-fastvithd_0.5b_stage3_llm.fp16"

# Specific mlx-vlm commit that the fastvlm_mlx-vlm.patch was authored against
MLX_VLM_COMMIT="1884b551bc741f26b2d54d68fa89d4e934b9a3de"

PYTHON311="${PYTHON311:-}"
if [ -z "$PYTHON311" ]; then
    PYTHON311="$(command -v python3.11 || true)"
fi
if [ -z "$PYTHON311" ] && command -v brew >/dev/null 2>&1; then
    PYTHON311_BREW_PREFIX="$(brew --prefix python@3.11 2>/dev/null || true)"
    if [ -n "$PYTHON311_BREW_PREFIX" ]; then
        PYTHON311="$PYTHON311_BREW_PREFIX/bin/python3.11"
    fi
fi

ts() { echo "[$(date '+%H:%M:%S')] $*"; }

echo "============================================================"
echo "  FastVLM Export Script — apple/ml-fastvlm"
echo "  Project root : $PROJECT_ROOT"
echo "  Output dir   : $OUTPUT_DIR"
echo "============================================================"
echo ""

# ── Step 1: Check Python 3.11 ──────────────────────────────────────────────────

ts "Checking Python 3.11..."
if [ -z "$PYTHON311" ] || [ ! -x "$PYTHON311" ]; then
    echo ""
    echo "ERROR: Python 3.11 not found on PATH or through Homebrew."
    echo ""
    echo "  coremltools 8.x is incompatible with Python 3.12+."
    echo "  You must use Python 3.11."
    echo ""
    echo "  Install with Homebrew:"
    echo "    brew install python@3.11"
    echo ""
    echo "  Then re-run this script."
    exit 1
fi
ts "Python 3.11 found: $($PYTHON311 --version)"

# ── Step 2: Create working directories ────────────────────────────────────────

mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$CHECKPOINTS_DIR"

# ── Step 3: Clone apple/ml-fastvlm ────────────────────────────────────────────

if [ ! -d "$ML_FASTVLM_DIR/.git" ]; then
    ts "Cloning apple/ml-fastvlm into $ML_FASTVLM_DIR ..."
    git clone https://github.com/apple/ml-fastvlm "$ML_FASTVLM_DIR"
else
    ts "apple/ml-fastvlm already cloned — pulling latest..."
    git -C "$ML_FASTVLM_DIR" pull --ff-only || true
fi

# ── Step 4: Set up Python 3.11 virtual environment ────────────────────────────

if [ ! -d "$VENV_DIR" ]; then
    ts "Creating Python 3.11 venv at $VENV_DIR ..."
    "$PYTHON311" -m venv "$VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
ts "Activated venv: $(python --version)"

# ── Step 5: Install dependencies ─────────────────────────────────────────────

ts "Upgrading pip..."
pip install --quiet --upgrade pip

ts "Installing coremltools 8.2 (pinned — matches ml-fastvlm pyproject.toml)..."
pip install --quiet "coremltools==8.2"

ts "Installing numpy<2.0 (coremltools 8.x breaks with numpy 2.x)..."
pip install --quiet "numpy<2.0"

ts "Installing PyTorch (CPU-only build — sufficient for export)..."
pip install --quiet torch==2.6.0 torchvision==0.21.0 \
    --index-url https://download.pytorch.org/whl/cpu

ts "Installing transformers and related packages (pinned to ml-fastvlm pyproject.toml versions)..."
pip install --quiet \
    "transformers==4.48.3" \
    "tokenizers==0.21.0" \
    "sentencepiece==0.1.99" \
    "accelerate==1.6.0" \
    "einops==0.6.1" \
    "timm==1.0.15"

ts "Installing huggingface_hub..."
pip install --quiet huggingface_hub

ts "Installing ml-fastvlm (editable install of the llava package)..."
pip install --quiet -e "$ML_FASTVLM_DIR"

# ── Step 6: Clone and patch mlx-vlm (required for --only-llm flag) ────────────

ts "Setting up patched mlx-vlm (commit $MLX_VLM_COMMIT)..."
if [ ! -d "$MLX_VLM_DIR/.git" ]; then
    git clone https://github.com/Blaizzy/mlx-vlm.git "$MLX_VLM_DIR"
fi
git -C "$MLX_VLM_DIR" checkout "$MLX_VLM_COMMIT" 2>/dev/null || {
    ts "WARNING: Could not checkout specific mlx-vlm commit. Using current HEAD."
    ts "The --only-llm flag may not be available if the patch was not applied."
}

# Apply the fastvlm patch (adds FastVLM model type and --only-llm flag)
PATCH_FILE="$ML_FASTVLM_DIR/model_export/fastvlm_mlx-vlm.patch"
if [ -f "$PATCH_FILE" ]; then
    ts "Applying fastvlm_mlx-vlm.patch to mlx-vlm..."
    git -C "$MLX_VLM_DIR" apply "$PATCH_FILE" 2>/dev/null || {
        ts "(Patch already applied or inapplicable — continuing)"
    }
fi

ts "Installing patched mlx-vlm..."
pip install --quiet -e "$MLX_VLM_DIR"

# MLX framework (Apple Silicon only)
ts "Installing mlx..."
pip install --quiet mlx

# ── Step 7: Download FastVLM 0.5B Stage 3 checkpoint ──────────────────────────

if [ ! -d "$MODEL_DIR" ]; then
    ts "Downloading FastVLM 0.5B Stage 3 checkpoint from Apple CDN..."
    DOWNLOAD_URL="https://ml-site.cdn-apple.com/datasets/fastvlm/${MODEL_ARCHIVE}.zip"
    ts "  URL: $DOWNLOAD_URL"
    ARCHIVE="$CHECKPOINTS_DIR/${MODEL_ARCHIVE}.zip"
    if command -v wget &>/dev/null; then
        wget --show-progress -q "$DOWNLOAD_URL" -O "$ARCHIVE"
    else
        curl -L --progress-bar "$DOWNLOAD_URL" -o "$ARCHIVE"
    fi
    ts "  Extracting..."
    unzip -q "$ARCHIVE" -d "$CHECKPOINTS_DIR"
    rm "$ARCHIVE"
    ts "  Extracted to: $MODEL_DIR"
else
    ts "Checkpoint already present: $MODEL_DIR"
fi

# ── Step 8: Export vision encoder to Core ML ─────────────────────────────────
#
#   Runs: model_export/export_vision_encoder.py
#   Source: apple/ml-fastvlm (confirmed script at that path)
#
#   The script:
#     - Loads the LLaVA model on MPS
#     - Updates config files in the checkpoint directory
#     - Traces the FastViTHD vision tower with torch.jit.trace
#     - Converts to Core ML mlprogram targeting iOS 16+
#     - Saves fastvithd.mlpackage into the checkpoint directory

ENCODER_MLPKG="$MODEL_DIR/fastvithd.mlpackage"

if [ ! -d "$ENCODER_MLPKG" ]; then
    ts "Exporting vision encoder to Core ML (this may take several minutes)..."
    cd "$ML_FASTVLM_DIR"
    python model_export/export_vision_encoder.py \
        --model-path "$MODEL_DIR" \
        --conv-mode qwen_2
    ts "  Vision encoder exported to: $ENCODER_MLPKG"
else
    ts "Vision encoder already exported: $ENCODER_MLPKG"
fi

ts "Copying fastvithd.mlpackage to output directory..."
rm -rf "$OUTPUT_DIR/fastvithd.mlpackage"
cp -r "$ENCODER_MLPKG" "$OUTPUT_DIR/fastvithd.mlpackage"

# ── Step 9: Export LLM to MLX format (--only-llm from patched mlx-vlm) ────────
#
#   The fastvlm_mlx-vlm.patch adds:
#     - FastVLM model type to mlx-vlm
#     - --only-llm flag to mlx_vlm.convert (skips vision components)
#
#   Core ML decoder export is NOT available from apple/ml-fastvlm.
#   The decoder runs in the app via MLX Swift (MLXLLM).

MLX_OUTPUT="$OUTPUT_DIR/$MLX_OUTPUT_NAME"

if [ ! -d "$MLX_OUTPUT" ]; then
    ts "Converting LLM decoder to MLX FP16 format..."
    python -m mlx_vlm.convert \
        --hf-path "$MODEL_DIR" \
        --mlx-path "$MLX_OUTPUT" \
        --only-llm
    ts "  MLX weights saved to: $MLX_OUTPUT"
else
    ts "MLX weights already present: $MLX_OUTPUT"
fi

# ── Step 10: Copy config and tokenizer files ──────────────────────────────────

ts "Copying metadata and tokenizer files..."
for f in \
    preprocessor_config.json \
    processor_config.json \
    tokenizer_config.json \
    tokenizer.json \
    config.json \
    vocab.json \
    special_tokens_map.json \
    merges.txt
do
    SRC="$MODEL_DIR/$f"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$OUTPUT_DIR/$f"
        ts "  Copied: $f"
    fi
done

# ── Step 11: Verify outputs ───────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Output verification"
echo "  Directory: $OUTPUT_DIR"
echo "============================================================"

check_path() {
    local label="$1"
    local path="$2"
    if [ -e "$path" ]; then
        echo "  ✅  $label"
    else
        echo "  ❌  $label — not found"
    fi
}

check_path "fastvithd.mlpackage (Core ML vision encoder)" \
    "$OUTPUT_DIR/fastvithd.mlpackage"

check_path "$MLX_OUTPUT_NAME/ (MLX LLM weights)" \
    "$OUTPUT_DIR/$MLX_OUTPUT_NAME"

check_path "tokenizer_config.json" \
    "$OUTPUT_DIR/tokenizer_config.json"

check_path "preprocessor_config.json" \
    "$OUTPUT_DIR/preprocessor_config.json"

check_path "processor_config.json" \
    "$OUTPUT_DIR/processor_config.json"

# ── Core ML decoder warning ───────────────────────────────────────────────────

echo ""
echo "  ⚠️   Core ML decoder export is not available from apple/ml-fastvlm."
echo "      The LLM decoder runs via MLX Swift (MLXLLM) in the app."
echo "      See scripts/FASTVLM_EXPORT_NOTES.md for details."
echo ""

# ── Next steps ────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Next steps"
echo "============================================================"
echo ""
echo "  1. Add the GeneratedFastVLMModels/FastVLM-0.5B-CoreML/ folder to"
echo "     your Xcode project:"
echo ""
echo "     a. In Xcode, right-click the CodeLens group in the Project navigator"
echo "     b. Choose 'Add Files to CodeLens...'"
echo "     c. Select GeneratedFastVLMModels/FastVLM-0.5B-CoreML/"
echo "     d. Check 'Copy items if needed' and 'Create folder references'"
echo "     e. Click Add"
echo ""
echo "  2. fastvithd.mlpackage — add to the app bundle target."
echo "     The FastVLMVisionEncoder class loads it from the main bundle."
echo ""
echo "  3. MLX model directory ($MLX_OUTPUT_NAME/) — either:"
echo "     a. Bundle it in the app (large: ~1 GB for FP16)"
echo "     b. Copy to the device's Documents/FastVLMModels/ at runtime"
echo ""
echo "  4. Build and run CodeLens. The FastVLM pipeline status in Settings"
echo "     will show green indicators when all components are detected."
echo ""
echo "  5. See scripts/FASTVLM_EXPORT_NOTES.md for architecture details"
echo "     and alternative paths (INT4/INT8 quantized MLX models)."
echo ""
echo "============================================================"
ts "Export script complete."
