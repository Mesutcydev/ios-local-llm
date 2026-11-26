# Ternary Bonsai 2.5 runtime comparison

Audit of the local OnDevice LLM and OnDeviceMax working trees, 26 November 2026.
This is a source and existing-evidence review, not a new model benchmark.

## Current paths

- OnDevice LLM offers the pinned 7.67 GB Q2_0 GGUF as a Mac-only text model.
  Its llama.cpp source is b12662 and includes Q2_0 and Hadamard support.
  The catalog uses a pinned revision and a specific file list; the runtime
  admits the actual file size through the existing GGUF memory policy. The
  code alone does not establish model quality, speed, or successful
  end-to-end inference with this exact checkpoint.
- OnDeviceMax has an optional 5.99 GB PTQ1_0 text preset behind a build flag.
  It relies on a 29-file patch to llama.cpp b11960, including CPU and Metal
  support. Its local port notes report Metal operator comparisons and Mac
  token parity against the PrismML fork. Its phone fit and speed are estimates,
  not physical iPhone results. That patch does not apply cleanly to OnDevice LLM's
  newer llama.cpp and must not be paired with an unpatched framework.
- The separate OnDeviceMax-uifix working tree contains an MLX adapter for the
  8.6 GB Bonsai 2.5 model, with text and image paths. Its local harness report
  records exact greedy-token parity in seven short cases on a 16 GB M4 Mac,
  plus a text-only check. Reported peak footprints were about 9.5 GB for text
  and 12.4 GB for vision. These results used a Debug harness and an uncommitted
  working tree; they are not a OnDevice LLM app test or a speed comparison. The
  reference shared Swift-prepared inputs and did not run all publisher loader
  extras, so preprocessing and full reference coverage remain limited.

## Findings and next steps

1. **Download completeness:** the downloader previously accepted any nonempty
   subset of an allowlist. A missing model, license, or projector could produce
   a partial download reported as ready. It now checks every file or directory
   rule against the repository listing before transferring anything and uses
   the same exact paths as its readiness check. A regression test covers a
   missing model and a same-named file in another directory.
2. **Pinned revisions (fixed):** a missing pinned revision now fails with an
   actionable error. Listings, model-info fallback, size probes and transfers
   all retain the selected revision, including after retry. Unpinned `main`
   downloads keep their existing workflow.
3. **Variant selection (fixed):** curated GGUF Assistant loads and installed
   probes now resolve the catalog's exact model paths. Native audio projectors
   follow the same allowlist. Missing or invalid selected files cannot be
   substituted with another quantization in the folder. Generic imports retain
   their existing recursive selection and ranking.
4. **MLX port:** the OnDeviceMax-uifix adapter is the strongest candidate for
   adding native image input on Mac. Port it as a coordinated change including
   format and geometry validation, pinned downloads, license notices, model
   residency, thermal and memory checks, cancellation, text/vision routing,
   and the existing parity harness. Measure app-level peak memory and validate
   text, images, cleanup and low-memory refusal before offering the model.
5. **PTQ1_0:** rebase and audit the patch against the exact OnDevice LLM submodule
   revision and reproduce CPU/Metal operator and token-parity tests before
   exposing a PTQ1_0 preset. Confirm framework provenance and regression-test
   LFM3. Physical-device memory, thermals, cancellation and sustained inference
   must be measured before claiming iPhone support.

No model weights or generated frameworks are included in this audit.

## OnDevice LLM adaptation

The reliability fixes are implemented within OnDevice LLM's existing download,
file-validation and Assistant services. They do not import Token's services,
navigation or branding, or change runtime dependencies and model defaults.
Regression coverage includes unavailable pins and retry, revision-preserving
metadata fallback, mixed GGUF directories, invalid selected files, native audio
projector selection, and generic import compatibility.

Validation on 26 November 2026: the selected iOS Simulator suites completed with
117 passing tests, 3 skipped tests and no failures. These cover HF metadata and
readiness, download lifecycle, local-runtime foundations, model category mapping,
GGUF generation profiles and Assistant loading policy. The repository validator
also passed. This does not establish inference parity or physical-device memory
behavior for a new Bonsai runtime.
