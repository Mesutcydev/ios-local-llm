# Local image content safeguards

Generated images pass through a local sexual-content classifier before the app
sets its preview/share image. Explicit prompt checks run before downloads or
inference. Missing models, malformed scores, classification failures and
cancellation do not publish an image. The parental PIN remains a separate feature
lock and cannot disable these checks. The classifier is CPU-only and released
after each check; diffusion's MLX cache is drained before it runs.

## Prepare a release build

Model weights are not in Git. Download
<https://github.com/GantMan/nsfw_model/releases/download/1.1.0/nsfw_mobilenet_v2_140_224.zip>
and verify SHA-256
`57278dd5a158b7ad8cb4f8d32f26c5f836d0d038044a2119f76fecff7aa241e9`.
Extract `mobilenet_v2_140_224/frozen_graph.pb`. Its SHA-256 must be
`5b59e8562d54c53d5948a9fc25d0c3d9b27e4797026ca7cb0248fb20f0e09987`.

Use Python 3.12 in a separate virtual environment with `coremltools==9.0`,
`numpy==1.26.4` and `Pillow==12.3.0`:

```bash
python scripts/convert_image_safety_model.py \
  --graph /path/to/frozen_graph.pb \
  --output /tmp/GeneratedImageSafety.mlmodel
xcrun coremlcompiler compile /tmp/GeneratedImageSafety.mlmodel \
  IOSLocalLLM/Resources/BundledSafety
```

The converter rejects an unexpected graph and unsupported reachable operations.
It compares four procedural fixtures with a NumPy evaluation of the original
graph before saving. Xcode copies the compiled classifier into the signed app.
The build and App Store preflight refuse a Release artifact without it. Keep
both upstream MIT and Apache-2.0 notices in the app's license resource.

## Limitations and release evaluation

These checks reduce risk; they do not establish that every output is safe.
The classifier primarily detects sexual content, not every form of violence,
hate, or abuse. Prompt checks are supplemental and can miss paraphrases and
languages, and both checks can refuse legitimate prompts. Language-model
safety instructions are guidance to downloaded models, not a content classifier.
Don't advertise the app as child-safe or as fully moderated.

Before submitting, a maintainer must evaluate representative ordinary prompts,
portraits, art, classifier false positives/negatives, supported languages and
evasion attempts on the actual devices/models offered. Conversion parity and
probability-policy unit tests verify integration, not content-detection accuracy.
Do not save, publish or include objectionable evaluation outputs in Git or store
metadata. Report unsafe behavior through Support without posting private content.
Reassess App Store age-rating answers for the final capabilities; an adult rating
does not permit prohibited content.
