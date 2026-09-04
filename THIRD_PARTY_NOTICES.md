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

## Git submodules

| Component | Upstream | License |
| --- | --- | --- |
| llama.cpp | <https://github.com/ggml-org/llama.cpp> | MIT |
| whisper.cpp | <https://github.com/ggerganov/whisper.cpp> | MIT |

Each submodule retains its upstream notices and license.

## Direct package dependencies

iOS Local LLM resolves these dependencies through Swift Package Manager or
CocoaPods. Their source and license files are not copied into this repository.

| Dependency | Source | License |
| --- | --- | --- |
| MLX Swift (PrismML fork) | <https://github.com/PrismML-Eng/mlx-swift> | MIT |
| MLX Swift LM | <https://github.com/ml-explore/mlx-swift-lm> | MIT |
| swift-transformers-mlx | <https://github.com/DePasqualeOrg/swift-transformers-mlx> | MIT |
| ONNX Runtime 1.29.0 | <https://github.com/microsoft/onnxruntime> | MIT |

Transitive packages are recorded in `Package.resolved` and retain their own
licenses in their source distributions. The source-distribution inventory is
also recorded in [SBOM.spdx.json](SBOM.spdx.json).

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

ONNX Runtime 1.29.0 is resolved from the official `onnxruntime-objc` and
`onnxruntime-c` CocoaPods (Microsoft, MIT). The runtime environment disables
optional POSIX telemetry before initialization with `ORT_DISABLE_TELEMETRY=1`.
The upstream license from the resolved pod is preserved in
[`LICENSES/ONNX-Runtime-MIT.txt`](LICENSES/ONNX-Runtime-MIT.txt).
