# Third-party notices

The top-level MIT license covers original iOS Local LLM code and documentation. It
does not replace the licenses of the components below.

## Source included in this repository

| Component | Location | License |
| --- | --- | --- |
| FastVLM sample implementation | `IOSLocalLLM/Services/FastVLM.swift` | [Apple Sample Code License](LICENSES/Apple-Sample-Code-License.txt) |
| MLX Stable Diffusion implementation | `IOSLocalLLM/Vendor/StableDiffusion/` | [MIT](IOSLocalLLM/Vendor/StableDiffusion/LICENSE) |
| CMU Pronouncing Dictionary | `IOSLocalLLM/Resources/Voice/cmudict.txt` | [CMUdict license](IOSLocalLLM/Resources/Voice/LICENSE) |
| thinking-orbs adaptations | `Packages/VoiceAgentOrb/` | [MIT](ThirdParty/thinking-orbs/LICENSE) |

The MIT license for iOS Local LLM applies only to the original changes and
integration around these components.

The Hugging Face metadata helpers, model-storage recovery, and installed-build
entitlement policies adapted from the sibling OnDevice Core project retain
the same MIT copyright notice in the root `LICENSE` (2026 Mesut and iOS Local
LLM contributors). Source revisions, selected files, and adaptation details
are recorded in [Docs/COREAI_COMPARISON.md](Docs/COREAI_COMPARISON.md).
The neutral theme, shared screen controls, and Models library presentation
are also adapted from the sibling OnDevice Core working tree at base revision
`6b145d5cfece26a244141582c4f38e62934a085e` (20 October 2026). They retain the
same root MIT notice; no sibling runtime, model weights, artwork, or additional
dependencies are included in this design adaptation.

## Git submodules

| Component | Upstream | License |
| --- | --- | --- |
| llama.cpp LFM3 support (`19ff817fb25e9a1b838b1d7f9f4325f7bf9779c4`) | <https://github.com/ggml-org/llama.cpp> | MIT |
| whisper.cpp | <https://github.com/ggerganov/whisper.cpp> | MIT |

Each submodule retains its upstream notices and license.

## Direct package dependencies

iOS Local LLM resolves these dependencies through Swift Package Manager or
CocoaPods. Their source and license files are not copied into this repository.

| Dependency | Source | License |
| --- | --- | --- |
| MLX Swift (PrismML fork) | <https://github.com/PrismML-Eng/mlx-swift> | MIT |
| MLX Swift LM | <https://github.com/ml-explore/mlx-swift-lm> | MIT |
| swift-transformers-mlx 0.2.0 | <https://github.com/DePasqualeOrg/swift-transformers-mlx> | Apache-2.0 |
| ONNX Runtime 1.29.0 | <https://github.com/microsoft/onnxruntime> | MIT |

Transitive packages are recorded in `Package.resolved` and retain their own
licenses in their source distributions. The source-distribution inventory is
also recorded in [SBOM.spdx.json](SBOM.spdx.json).

## App artwork

The silver eye app icon and matching in-app logo were supplied by the project
maintainer on 5 September 2026 for use as the app's branding. The checked-in
images are resized copies of that supplied artwork, not assets obtained from
a third-party catalog.

## Models and generated artifacts not included

Downloaded language, vision, speech, and image-generation models are separate
works. Their license is shown in the model catalog or at the download source.
Do not assume that a model is open source merely because its loader is.

The following are deliberately excluded from Git:

- Apple FastVLM weights and derived Core ML artifacts (Apple Machine Learning
  Research Model License; research use only)
- SmolVLM GGUF weights
- KittenTTS, Kokoro, and Silero compiled model artifacts
- Generated llama.cpp and whisper.cpp XCFrameworks
- CocoaPods, Ruby bundles, archives, installers, and signing material

Anyone redistributing a build is responsible for reviewing and satisfying the
licenses of every model and binary they add.

### Official KittenTTS 0.8 variants

The optional ONNX voice catalog pins these KittenML repositories:

| Repository | Revision | Model-card license |
| --- | --- | --- |
| [kitten-tts-micro-0.8](https://huggingface.co/KittenML/kitten-tts-micro-0.8) | `1ccf72b2c2048fd17efac7de2fab32d10e225084` | Apache-2.0 |
| [kitten-tts-nano-0.8-int8](https://huggingface.co/KittenML/kitten-tts-nano-0.8-int8) | `84781d74e29ee25217551556398b42f80593a813` | Apache-2.0 |
| [kitten-tts-mini-0.8](https://huggingface.co/KittenML/kitten-tts-mini-0.8) | `c02725660cea441db4c383af69f1f26f5cd00947` | Apache-2.0 |

The model cards at these exact revisions declare Apache-2.0. Their verbatim
cards are preserved in `LICENSES/KittenTTS-MODEL-CARDS.txt`, with the license in
`LICENSES/Apache-2.0.txt`; both are included in the in-app notices. The pinned
repository inventories contain no separate LICENSE, NOTICE, or COPYING files.
Downloaded weights and voice arrays remain outside Git. Review new revisions
and preserve any additional notices before redistributing them.

### Paradee-8M and Supertonic 3 voices

The optional ONNX voice downloads pin these repositories:

| Repository | Revision | Selected artifacts | License |
| --- | --- | --- | --- |
| [Paradee-8M-v1.2](https://huggingface.co/sahilmahendrakar/Paradee-8M-v1.2) | `ed2934d4df8a4fd891e29584c5e1104649409765` | `onnx/paradee_int8.onnx`, `config.json`, `LICENSE` | Apache-2.0 |
| [supertonic-3](https://huggingface.co/Supertone/supertonic-3) | `3cadd1ee6394adea1bd021217a0e650ede09a323` | `onnx/`, `voice_styles/`, `LICENSE` | BigScience Open RAIL-M |

Paradee's license is in `LICENSES/Apache-2.0.txt`. Supertonic 3's Open RAIL-M
text is retained verbatim in `LICENSES/Supertonic-3-OpenRAIL-M.txt` and in the
in-app notices. It permits use and redistribution, but its Attachment A
use-based restrictions apply to anyone using the model and must be passed on
with any redistribution. The Supertonic inference port follows the archived
MIT reference at github.com/supertone-oss-archive/supertonic. Weights remain
outside Git and downloads remain user-initiated.

### SDXL Turbo and SD-Turbo

**Powered by Stability AI.** These optional image models use the Stability AI
Community License dated 5 July 2024. Commercial use requires registration and
revenue eligibility under that agreement, or a separate enterprise agreement;
the app's availability in the store does not establish that eligibility.

The identical license text was retrieved from these exact upstream revisions:

- `stabilityai/sdxl-turbo`: `71153311d3dbb46851df1931d3ca6e939de83304`
- `stabilityai/sd-turbo`: `b261bac6fd2cf515557d5d0707481eafa0485ec2`

Sources are each repository's `LICENSE.md` on Hugging Face. The retained license
SHA-256 is `d6f6b1a4dce5c852bd6d7d9482d002baf0ccdb71e662250b73be9eec8764ee8d`.
The agreement is preserved in
[`LICENSES/Stability-AI-Community-License.txt`](LICENSES/Stability-AI-Community-License.txt)
and its required attribution in
[`LICENSES/Stability-AI-NOTICE.txt`](LICENSES/Stability-AI-NOTICE.txt).
Both are included in the app's bundled license document. Model weights remain
outside the source distribution. New Turbo downloads use these pinned revisions;
existing installed models are retained. These snapshots do not certify the
licenses of the other image models or the developer's commercial eligibility.

### Local generated-image safety classifier

Release builds include a Core ML conversion of the MobileNet v2 1.4/224 model
from [GantMan/nsfw_model release 1.1.0](https://github.com/GantMan/nsfw_model/releases/tag/1.1.0).
The classifier is MIT-licensed; its TensorFlow Hub MobileNet backbone comes
from the [Apache-2.0 TensorFlow Models project](https://github.com/tensorflow/models/blob/master/LICENSE).
Full notices are retained in `LICENSES/Image-Safety-Model-MIT.txt`
and `LICENSES/Apache-2.0.txt` and included in the bundled license document.
The release archive SHA-256 is
`57278dd5a158b7ad8cb4f8d32f26c5f836d0d038044a2119f76fecff7aa241e9`;
the frozen graph SHA-256 is
`5b59e8562d54c53d5948a9fc25d0c3d9b27e4797026ca7cb0248fb20f0e09987`.
Conversion preserves the upstream class order and is checked against a NumPy
evaluation of its original frozen graph. The weights and generated Core ML
resources remain outside Git. See `Docs/IMAGE_CONTENT_SAFETY.md` for preparation,
limitations, and the additional release evaluation requirement.

The consumer app does not offer FastVLM research weights. The Apple sample-code
license does not grant permission to ship those weights or derived encoders.

Full resolved package licenses, embedded dependency notices, native runtime
licenses, and the Silero VAD notice are preserved in
[`IOSLocalLLM/Resources/ThirdPartyLicenses.txt`](IOSLocalLLM/Resources/ThirdPartyLicenses.txt)
and included in the app's Attributions screen. Regenerate after resolving or
updating dependencies:

```bash
python3 scripts/generate_bundle_notices.py --package-checkouts /path/to/SourcePackages/checkouts
```

The generator rejects package checkouts that do not match `Package.resolved`.
It does not certify licenses of arbitrary user-downloaded models.

ONNX Runtime 1.29.0 is resolved from the official `onnxruntime-objc` and
`onnxruntime-c` CocoaPods (Microsoft, MIT). The runtime environment disables
optional POSIX telemetry before initialization with `ORT_DISABLE_TELEMETRY=1`.
The upstream license from the resolved pod is preserved in
[`LICENSES/ONNX-Runtime-MIT.txt`](LICENSES/ONNX-Runtime-MIT.txt).

### Core AI text runtime (Apple coreai-models)

- Source: https://github.com/apple/coreai-models
- Revision: `938d0b8943b942ce66438b94ab017c5631d1aef4`, with the reference project's documented runtime patches (see `Packages/CoreAITextRuntime/COREAI_PIN_PATCH.md`).
- License: BSD-3-Clause; full text in `LICENSES/CoreAI-Models-BSD-3-Clause.txt` and the vendored package's `LICENSE`.
- Scope: text-generation source only, no model weights or generated artifacts. iOS Local LLM adds iOS 27 availability guards and physical-device-only compilation, offline tokenizer resolution, and content-safe diagnostics.
- XGrammar: https://github.com/mlc-ai/xgrammar at `4d145cc13d878c751ebeed36af1c013074be76bc` (Apache-2.0), used by the C grammar bridge. Full license text is in `LICENSES/Apache-2.0.txt`; resolved dependency notices are included in `IOSLocalLLM/Resources/ThirdPartyLicenses.txt`. The bundled DLPack 0.8 header (Copyright 2017 by Contributors) is Apache-2.0; its source header attribution is preserved.
- Model packs are explicit user downloads and retain their own model licenses; they are not redistributed with this source.

Core AI download catalog: the 15 exposed Qwen, MiniCPM5, Granite, and Nanbeige
conversions are pinned by commit in `CoreAIZooCatalog.swift`. Their pinned model
cards declare Apache-2.0; metadata and tokenizer configuration were checked on
2026-10-26. Full runtime/device validation is separate from artifact validation.
The catalog links each exact source subtree and downloads retain license files.

### Liquid AI LFM3

Optional GGUF downloads use Liquid AI's official repositories at these revisions:

| Repository | Revision | Selected artifacts |
| --- | --- | --- |
| [LFM3-1.7B-GGUF](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF) | `b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf` | `LFM3-1.7B-QAD-Q4_0.gguf`, `LICENSE` |
| [LFM3-VL-2B-GGUF](https://huggingface.co/LiquidAI/LFM3-VL-2B-GGUF) | `7c3b4a43c9023e80bf234fec5e826a3365c8dda8` | `LFM3-VL-2B-QAD-Q4_0.gguf`, `mmproj-LFM3-VL-2B-Q8_0.gguf`, `LICENSE` |

Both use the LFM Open License v1.0, retained in
[`LICENSES/LFM-Open-License-v1.0.txt`](LICENSES/LFM-Open-License-v1.0.txt)
and the bundled notices. The two upstream texts differ only in whitespace.
Redistribution is permitted subject to the agreement; commercial use at or
above its $10 million annual-revenue threshold requires a separate license.
Weights remain outside Git and downloads remain user-initiated. These model
licenses are separate from the app's MIT license.

The app uses a bounded 4K context for text and single-image vision. Audio/Omni accept up to 30 seconds of 16 kHz mono input and generate
24 kHz speech in Voice mode. Native XML tool calls use the existing tool
validation and approvals. Video input is not enabled by these catalog entries. The current default model is unchanged.

Additional LFM3 GGUF packages use the same reviewed LFM Open License v1.0:

| Repository | Revision | Selected artifacts |
| --- | --- | --- |
| [LFM3-Audio-2B-GGUF](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF) | `02355c1a141e464a064f2ab2c276638dbcb7f38a` | `LFM3-Audio-2B-Q4_K_M.gguf`, `mmproj-LFM3-Audio-2B-Q4_K_M.gguf`, `LICENSE` |
| [LFM3-Omni-2B-GGUF](https://huggingface.co/LiquidAI/LFM3-Omni-2B-GGUF) | `3d29af2ad166f8299c2d820937e47dc0add20ffc` | `LFM3-Omni-2B-Q4_K_M.gguf`, `mmproj-LFM3-Omni-2B-Q4_K_M.gguf`, `LICENSE` |

Both license texts match the retained LFM license apart from whitespace.
The runtime pin includes the merged upstream Audio/Omni integration (#31257).
