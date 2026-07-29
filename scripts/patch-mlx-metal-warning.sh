#!/bin/sh

set -eu

# Xcode 26.5 compiles mlx-swift 0.31.4's generated Metal source as a
# pre-C++17 dialect and emits four warnings for valid `if constexpr` uses.
# Swift package targets do not inherit MTL_COMPILER_FLAGS from the app project,
# so apply the narrow diagnostic suppression directly to the resolved source.
# The checkout may be recreated by package resolution; this script is therefore
# idempotent and runs as a scheme pre-action before every build.

if [ -z "${BUILD_DIR:-}" ]; then
    exit 0
fi

derived_data_root="${BUILD_DIR%%/Build/*}"
source_file="${derived_data_root}/SourcePackages/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/attn/kernels/steel_attention.metal"
marker="CodeLens: suppress Xcode 26.5 C++17 extension warning"

if [ ! -f "${source_file}" ] || /usr/bin/grep -Fq "${marker}" "${source_file}"; then
    exit 0
fi

/usr/bin/perl -0pi -e \
    's/\A/#pragma clang diagnostic ignored "-Wc++17-extensions" \/\/ CodeLens: suppress Xcode 26.5 C++17 extension warning\n/' \
    "${source_file}"
