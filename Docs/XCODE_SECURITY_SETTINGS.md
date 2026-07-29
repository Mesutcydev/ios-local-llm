# Xcode security settings

Security build-setting decisions for iOS Local LLM. `project.yml` is the source
of truth; generated Xcode project files mirror it.

## Enabled settings

- `GCC_WARN_ABOUT_RETURN_TYPE` to `YES_ERROR`: missing returns are defects.
- `GCC_WARN_UNINITIALIZED_AUTOS` to `YES_AGGRESSIVE`: catches unsafe reads.
- `CLANG_WARN_IMPLICIT_FALLTHROUGH` to `YES`: catches switch logic errors.
- `GCC_WARN_64_TO_32_BIT_CONVERSION` to `YES`: reports truncation.
- `GCC_TREAT_IMPLICIT_FUNCTION_DECLARATIONS_AS_ERRORS` to `YES`: prevents
  incorrect C function assumptions.
- `CLANG_ANALYZER_SECURITY_FLOATLOOPCOUNTER` to `YES`.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_RAND` to `YES`.
- `CLANG_ANALYZER_SECURITY_INSECUREAPI_STRCPY` to `YES`.

These checks are high-confidence and have no runtime cost.

## Disabled settings

None are explicitly disabled as a project policy.

## Deferred

- `ENABLE_ENHANCED_SECURITY` and its hardened-process entitlements: defer until
  the app target, extensions, Catalyst entitlements, CocoaPods, and generated
  llama.cpp/whisper.cpp frameworks have a complete device and Catalyst test
  matrix.
- `ENABLE_POINTER_AUTHENTICATION`: external XCFramework slices are currently
  built for arm64, not a verified arm64e distribution. Enabling this only for
  app code would not establish end-to-end compatibility.
- C bounds safety and C++ unsafe-buffer adoption: native inference code is
  pinned in upstream submodules and compiled into external frameworks. Adopt
  with upstream-compatible annotations and dedicated testing.
- Hardware memory tagging: hardware support and performance impact require a
  staged physical-device rollout.
- Higher-noise conversion, enum, sign-compare, and experimental buffer
  diagnostics: evaluate after the baseline warnings remain clean.

## Dependency compatibility risk

SwiftPM currently warns that the direct `PrismML-Eng/mlx-swift` fork and the
upstream `ml-explore/mlx-swift` dependency requested transitively share one
package identity. The fork is intentionally pinned for the one-bit kernels
used by catalog presets. SwiftPM states that this warning may become an error
in a future release. Resolve it by aligning all MLX-dependent packages on one
upstream/fork lineage; do not suppress or misrepresent the warning.
