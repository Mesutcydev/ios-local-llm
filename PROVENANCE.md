# Source provenance

This record separates original work from imported or adapted material. It is
not a substitute for the license texts.

## Maintainer attestation

As of 2026-07-29, the maintainer represents that the original project code and
documentation were created for this project or contributed under the MIT
license, except where a file, notice, history entry, or the table below states
otherwise. No App Store signing keys, provisioning profiles, user data, model
weights, generated native frameworks, or private service credentials are part
of the source distribution.

## Known imported or adapted material

| Material | Repository location | Origin | Terms |
| --- | --- | --- | --- |
| FastVLM sample implementation | `IOSLocalLLM/Services/FastVLM.swift` | Apple ml-fastvlm | Apple Sample Code License |
| MLX Stable Diffusion implementation | `IOSLocalLLM/Vendor/StableDiffusion/` | Apple/ml-stable-diffusion lineage | MIT; local license retained |
| CMU Pronouncing Dictionary | `IOSLocalLLM/Resources/Voice/cmudict.txt` | CMUdict | CMUdict license retained |
| Voice orb inspiration/adaptations | `Packages/VoiceAgentOrb/` | thinking-orbs | MIT; notice retained |
| llama.cpp | `ThirdParty/llama.cpp` submodule | ggml-org | MIT |
| whisper.cpp | `ThirdParty/whisper.cpp` submodule | ggerganov | MIT |

Model weights and generated artifacts are intentionally excluded. Their terms
must be reviewed at their source before download or redistribution.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [REUSE.toml](REUSE.toml),
and the retained license files for machine- and human-readable detail.
