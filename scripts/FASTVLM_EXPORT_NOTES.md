# FastVLM Export Notes

Confirmed from apple/ml-fastvlm source as of May 2025.  
Repository: https://github.com/apple/ml-fastvlm

---

## 1. What apple/ml-fastvlm actually provides

The repository contains:

| Path | Purpose |
|------|---------|
| `model_export/export_vision_encoder.py` | Exports the FastViTHD vision tower to Core ML |
| `model_export/fastvlm_mlx-vlm.patch` | Patch for mlx-vlm to add FastVLM model type and `--only-llm` flag |
| `model_export/README.md` | Export instructions |
| `get_models.sh` | Downloads PyTorch checkpoints from Apple CDN |
| `app/get_pretrained_mlx_model.sh` | Downloads pre-converted MLX LLM weights from Apple CDN |
| `predict.py` | CPU/GPU inference using the original LLaVA pipeline |

There is **no** script to export the multimodal projector or the LLM decoder to Core ML.

---

## 2. What IS exportable to Core ML

### Vision encoder: `fastvithd.mlpackage`

**Script:** `model_export/export_vision_encoder.py`

**Exact command:**
```bash
cd /path/to/ml-fastvlm
python model_export/export_vision_encoder.py \
    --model-path /path/to/llava-fastvithd_0.5b_stage3 \
    --conv-mode qwen_2
```

**What it does (confirmed from source):**
1. Loads the full LLaVA model on MPS (`device="mps"`)
2. Writes metadata files back into the checkpoint directory:
   - `preprocessor_config.json` — image preprocessing settings
   - `processor_config.json` — `patch_size=64`, `image_token="<image>"`
   - `tokenizer_config.json` — adds `<image>` as a special token
   - `config.json` — adds `image_token_index`
3. Extracts the vision tower (`model.get_vision_tower()`)
4. Traces it with `torch.jit.trace` using a random `(1, 3, H, W)` input
5. Converts with `coremltools.convert()`:
   - `convert_to="mlprogram"`
   - `compute_units=CPU_AND_GPU`
   - `minimum_deployment_target=coremltools.target.iOS16`
   - `compute_precision=FLOAT32`
6. Saves `fastvithd.mlpackage` into the checkpoint directory

**Input:** `images` — shape `(1, 3, H, W)` where H=W=`image_processor.size['shortest_edge']`  
**Output:** `image_features` — float32 tensor of vision features

**Dependencies (from `pyproject.toml`):**
```
coremltools==8.2
torch==2.6.0
torchvision==0.21.0
transformers==4.48.3
numpy==1.26.4   # must stay < 2.0; coremltools 8.x breaks with numpy 2.x
timm==1.0.15
einops==0.6.1
```

---

## 3. What is NOT in Core ML format

### Multimodal projector

There is no standalone `export_projector.py` or equivalent in the repo.  
The projector weights are included in the LLaVA checkpoint but there is no export path for a standalone `multimodal_projector.mlpackage`.

In the MLX pipeline, the patch (`fastvlm_mlx-vlm.patch`) adds a `fastvlm.py` that implements the projector in MLX alongside the LLM.

### LLM decoder (`language_model_kvcache.mlpackage`)

**This does not exist.** The apple/ml-fastvlm repo provides no mechanism to convert the Qwen2-0.5B decoder to Core ML format.

**Exact blocker:** See section 5.

---

## 4. What the repo DOES provide for the LLM decoder

The intended path for the LLM is **MLX Swift via mlx-vlm**:

### Option A: Download pre-converted MLX weights from Apple CDN

```bash
# From inside the ml-fastvlm repo
bash app/get_pretrained_mlx_model.sh --model 0.5b --dest /your/output/dir
```

Downloads `llava-fastvithd_0.5b_stage3_llm.fp16.zip` from:
```
https://ml-site.cdn-apple.com/datasets/fastvlm/llava-fastvithd_0.5b_stage3_llm.fp16.zip
```

Available variants:
- `0.5b` → `llava-fastvithd_0.5b_stage3_llm.fp16` (FP16, ~1 GB)
- `1.5b` → `llava-fastvithd_1.5b_stage3_llm.int8` (INT8)
- `7b`   → `llava-fastvithd_7b_stage3_llm.int4` (INT4)

### Option B: Convert from PyTorch checkpoint using patched mlx-vlm

```bash
# 1. Download PyTorch checkpoint
bash get_models.sh   # downloads llava-fastvithd_0.5b_stage3.zip from Apple CDN

# 2. Clone mlx-vlm at the exact commit the patch targets
git clone https://github.com/Blaizzy/mlx-vlm.git
cd mlx-vlm
git checkout 1884b551bc741f26b2d54d68fa89d4e934b9a3de

# 3. Apply the FastVLM patch (adds FastVLM model type and --only-llm flag)
git apply ../model_export/fastvlm_mlx-vlm.patch
pip install -e .

# 4. Convert (--only-llm flag skips re-exporting the vision encoder)
python -m mlx_vlm.convert \
    --hf-path checkpoints/llava-fastvithd_0.5b_stage3 \
    --mlx-path /output/llava-fastvithd_0.5b_stage3_llm.fp16 \
    --only-llm

# Optional: 8-bit or 4-bit quantization
python -m mlx_vlm.convert \
    --hf-path checkpoints/llava-fastvithd_0.5b_stage3 \
    --mlx-path /output/llava-fastvithd_0.5b_stage3_llm.int8 \
    --only-llm --q-bits 8
```

---

## 5. Exact blocker for `language_model_kvcache.mlpackage`

The Qwen2-0.5B language model has:
- 24 transformer decoder layers
- Grouped-query attention (14 query heads, 2 KV heads)
- Dynamic sequence lengths (KV-cache grows with each generated token)

Core ML does support KV-cache models — Apple uses this for on-device LLMs — but it requires either:

1. **Stateful Core ML models** (iOS 18+): the KV-cache is stored as Core ML state tensors with `MLMultiArray` backed state. Requires authoring the model architecture in coremltools with `ct.StateType`. Apple's own models do this, but ml-fastvlm does not provide this export path.

2. **Passing KV-cache as explicit inputs/outputs**: every decode step passes the full cache as tensor inputs and receives updated cache as outputs. Works on iOS 16+, but requires rewriting the model in a way that coremltools can trace.

Neither path exists in the ml-fastvlm repo. Converting it would require:
- Rewriting the Qwen2 model's attention layers to accept explicit KV-cache inputs, OR
- Using `ct.StateType` for iOS 18 stateful inference
- Then tracing or `torch.export()`-ing the result through coremltools

This is non-trivial engineering and is outside what apple/ml-fastvlm provides.

---

## 6. Where exported files go in this project

```
CodeLens/
  GeneratedFastVLMModels/
    FastVLM-0.5B-CoreML/
      fastvithd.mlpackage                    ← Core ML vision encoder
      preprocessor_config.json
      processor_config.json
      tokenizer_config.json
      tokenizer.json
      config.json
      vocab.json
      special_tokens_map.json
      llava-fastvithd_0.5b_stage3_llm.fp16/ ← MLX LLM weights
        config.json
        model.safetensors (or shards)
        tokenizer.json
        tokenizer_config.json
        ...
```

The `export_fastvlm_coreml.sh` script in this directory produces exactly this layout.

---

## 7. How to add to Xcode

1. In Xcode's Project navigator, right-click the **CodeLens** group.
2. Choose **Add Files to "CodeLens"...**.
3. Navigate to `GeneratedFastVLMModels/FastVLM-0.5B-CoreML/`.
4. Select:
   - `fastvithd.mlpackage` — add to the app **target** (will be compiled at build time).
   - The MLX model directory — either add as a folder reference or handle at runtime via file copy to Documents.
5. Check **"Copy items if needed"** for `fastvithd.mlpackage`.
6. Click **Add**.

Xcode automatically compiles `.mlpackage` files using coremlc during the build.  
The compiled model appears in the app bundle as `fastvithd.mlmodelc`.

**Note on MLX model size:** `llava-fastvithd_0.5b_stage3_llm.fp16` is approximately 1 GB.  
Bundling it directly in the app is possible but produces a large IPA. The alternative is to ship the Core ML encoder in the bundle and load the MLX weights from the device's Documents directory on first launch.

---

## 8. FastVLMModelBundleValidator — what the app checks at runtime

Based on the CodeLens codebase, `FastVLMModelBundleValidator` verifies:

- `fastvithd.mlpackage` (or compiled `.mlmodelc`) is present and loadable via the Core ML framework
- The MLX model directory contains a valid `config.json` with `model_type: "llava_qwen2"`
- `tokenizer.json` or `tokenizer_config.json` is present alongside the MLX weights
- `preprocessor_config.json` contains the expected `image_processor_type` and `size` keys

If any required file is missing, the validator reports the component as unavailable and the pipeline disables the corresponding feature.

---

## 9. Alternative inference paths (not requiring this export)

| Approach | Effort | Notes |
|----------|--------|-------|
| Use pre-built MLX weights from Apple CDN | Low | `app/get_pretrained_mlx_model.sh --model 0.5b --dest ...` inside the ml-fastvlm repo |
| Run MLX inference directly via mlx-vlm | Low | Works on Apple Silicon, requires patched mlx-vlm |
| ONNX export of Qwen2 decoder | Medium | `transformers.onnx` can export Qwen2, but the CoreML conversion step is manual |
| Manual stateful Core ML KV-cache model | High | Requires rewriting attention layers for coremltools StateType API |
| Use a different on-device VLM with existing Core ML export | Medium | e.g., moondream, phi-3-vision (Microsoft provides ONNX/CoreML exports) |
