# Coding-agent implementation handoff

Use this document when asking a coding agent to implement an OnDeviceiOS
component in another iOS local-LLM app. It gives the agent enough context to
select the right files, preserve safety behavior, carry the license correctly,
and verify the result.

## Fastest handoff

Send your coding agent this URL:

<https://github.com/Mesutcydev/ondeviceios/blob/main/Docs/CODING_AGENT_IMPLEMENTATION.md>

Then add one sentence:

> Implement **[component or capability]** in **[target repository/app]** using
> OnDeviceiOS as the reference. My deployment target is **[iOS version]**, my
> inference backend is **[MLX / llama.cpp / other]**, and success means
> **[observable result]**.

The agent should read the linked repository documents rather than assuming the
whole app is a drop-in SDK.

## Copy-paste implementation prompt

Replace the bracketed values and provide this block to the coding agent:

```text
Implement the following local-AI capability in my iOS project:

Capability: [for example: UTF-8 token streaming, model-file validation,
thermal/RAM admission, model downloads, RAG, or llama.cpp inference]
Target repository: [path or URL]
Deployment target: [for example: iOS 18+]
Inference backend: [MLX, llama.cpp, Core ML, other, or none]
Target devices: [for example: iPhone 15 and newer]
Success criteria: [specific user-visible and testable outcome]

Use OnDeviceiOS as the reference implementation:
https://github.com/Mesutcydev/ondeviceios

Read these files before editing:
1. Docs/REUSABLE_COMPONENTS.md
2. ARCHITECTURE.md
3. Docs/CODING_AGENT_IMPLEMENTATION.md
4. The exact source files and tests linked for the selected component
5. LICENSE and THIRD_PARTY_NOTICES.md

Implementation requirements:
- Inspect my target project and its existing architecture before changing it.
- State whether the selected component is Extractable, Adaptable, or
  Integrated according to the catalog.
- Reuse the smallest coherent subsystem. Do not copy the full app or preserve
  CodeLens-specific singletons, UI state, storage paths, or model types unless
  they are genuinely required.
- Put app-specific behavior behind protocols or adapters.
- Preserve cancellation, cleanup, model-file validation, memory admission,
  thermal refusal, lifecycle handling, privacy, and authentication invariants
  that apply to the selected component.
- Never add model weights, credentials, signing files, generated frameworks,
  or user data to Git.
- Preserve the OnDeviceiOS MIT copyright and permission notice for copied or
  substantial portions. Check every dependency and model under its own terms.
- Port the relevant tests and add target-project integration tests.
- For thermal or memory work, validate on physical devices and clearly label
  Simulator-only results as insufficient for Jetsam or sustained-thermal
  claims.
- Follow the target repository's own agent instructions and conventions.
- Do not make unrelated refactors.

Before implementation, report:
1. selected OnDeviceiOS files;
2. dependencies and licenses;
3. target-project files to change;
4. safety invariants and test plan.

Then implement the change, run the most relevant available checks, and finish
with:
1. files changed;
2. behavior implemented;
3. tests and results;
4. device testing performed or still required;
5. remaining integration or licensing risks.

If an assumption would materially change the architecture, licensing, privacy,
or supported devices, stop and ask me instead of guessing.
```

## Choosing what to ask for

| Goal | Capability value to use | Reference section |
| --- | --- | --- |
| Stream partial tokens without broken Unicode | `UTF-8 token streaming and response coalescing` | Streaming and runtime primitives |
| Reject corrupt or incomplete model files | `GGUF, VLM-pair, and safetensors validation` | Model-file validation |
| Prevent unsafe model loads | `device-tier and memory admission` | Memory, thermal, and lifecycle safety |
| Coordinate unloads and background cleanup | `runtime safety, residency, and lifecycle` | Memory, thermal, and lifecycle safety |
| Search and download models | `Hugging Face search and model download` | Model management |
| Add an MLX backend | `MLX language/vision runtime adapter` | Inference backends |
| Add a GGUF backend | `llama.cpp GGUF runtime adapter` | Inference backends |
| Expose a local client API | `authenticated OpenAI-compatible local API` | Local APIs and agent tools |
| Index and retrieve local documents | `local embeddings and RAG pipeline` | Retrieval and embeddings |
| Add voice turn-taking | `voice activity and turn-end pipeline` | Voice pipeline utilities |

The matching source and test links are in
[Reusable components](REUSABLE_COMPONENTS.md).

## Recommended implementation sequence

The coding agent should work in this order:

1. **Discover** — inspect the target app, deployment target, package manager,
   concurrency model, storage, and existing runtime abstractions.
2. **Select** — choose one catalog component and its tests. Identify all
   transitive app-type and framework dependencies.
3. **Design the boundary** — define portable value types and small protocols
   for device facts, storage, runtime load/unload, and policy decisions.
4. **Port behavior** — adapt names and dependencies while retaining the
   original invariants and attribution.
5. **Test failure paths** — cancellation, corrupt files, partial downloads,
   memory pressure, thermal escalation, backgrounding, and authentication as
   applicable.
6. **Integrate** — connect the component to UI or a concrete inference backend
   only after the portable layer passes.
7. **Verify on device** — profile memory, sustained temperature, cancellation,
   and recovery on the oldest supported physical device.
8. **Document** — record copied/adapted source, licenses, supported devices,
   limitations, and commands used to verify the implementation.

## Special instructions by reuse level

### Extractable

- Copy the implementation and its focused tests.
- Adjust access control and module names.
- Remove unnecessary UIKit imports.
- Keep the extracted unit small enough to become a Swift package target.

### Adaptable

- Extract policy and state transitions, not the app's service graph.
- Introduce protocols for device information, persistence, notifications,
  logging, and runtime control.
- Replace CodeLens observable/singleton state with target-owned dependency
  injection.
- Add an integration test for every adapter.

### Integrated

- Do not copy one large service file and expect it to compile independently.
- First create a narrow backend protocol in the target app.
- Isolate MLX, llama.cpp, Network, and native C bindings in dedicated targets.
- Translate target messages and model metadata at the boundary.
- Preserve the admission/generation gate and deterministic cancellation and
  unload paths.

## Definition of done

An implementation is complete only when:

- the target app builds without relying on untracked local files;
- relevant source attribution and third-party notices are present;
- model artifacts and credentials remain outside Git;
- success and failure-path tests pass;
- cancellation and cleanup are deterministic;
- privacy and authentication behavior is documented;
- physical-device validation is reported for thermal/RAM claims; and
- known limitations and unsupported options fail explicitly.

## Example: thermal and RAM management

```text
Implement OnDeviceiOS-style device-tier, RAM admission, thermal monitoring,
model residency, cancellation, and background cleanup in my iOS local-LLM
app. Use Docs/CODING_AGENT_IMPLEMENTATION.md as the operating instructions and
Docs/REUSABLE_COMPONENTS.md to select the relevant files. Adapt the policy
behind protocols for my runtime rather than copying CodeLens singleton state.
Port the policy tests, add lifecycle integration tests, and report physical
device measurements separately from Simulator checks.
```

## Example: one portable utility

```text
Extract the OnDeviceiOS UTF-8 streaming decoder and response coordinator into
a Foundation-only Swift package in my project. Follow
Docs/CODING_AGENT_IMPLEMENTATION.md, port the matching tests, preserve the MIT
notice, and verify split multi-byte Unicode, cancellation, and coalesced
delivery.
```
