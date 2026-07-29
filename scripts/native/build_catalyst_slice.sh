#!/usr/bin/env bash

# Add an Apple-Silicon Mac Catalyst slice to a previously generated llama.cpp
# or whisper.cpp XCFramework. This is root-owned tooling: pinned submodules stay
# unchanged and clean-clone builds do not depend on untracked helper scripts.

set -euo pipefail

framework_name="${1:-}"
case "$framework_name" in
  llama|whisper) ;;
  *)
    echo "usage: $0 <llama|whisper>" >&2
    exit 64
    ;;
esac

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_root="${repository_root}/ThirdParty/${framework_name}.cpp"
xcframework="${source_root}/build-apple/${framework_name}.xcframework"
build_dir="${source_root}/build-maccatalyst"
catalyst_min_os_version="${CATALYST_MIN_OS_VERSION:-14.0}"
target_triple="arm64-apple-ios${catalyst_min_os_version}-macabi"

if [[ ! -d "$xcframework" ]]; then
  echo "error: ${xcframework} is missing; build the iOS XCFramework first" >&2
  exit 1
fi

cd "$source_root"
sysroot="$(xcrun --sdk macosx --show-sdk-path)"
common_flags="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
triple_flags="-target ${target_triple} -isysroot ${sysroot}"
cmake_args=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_SYSTEM_NAME=Darwin
  -DCMAKE_OSX_ARCHITECTURES=arm64
  -DCMAKE_OSX_SYSROOT="$sysroot"
  -DCMAKE_C_FLAGS="${common_flags} ${triple_flags}"
  -DCMAKE_CXX_FLAGS="${common_flags} ${triple_flags}"
  -DCMAKE_OBJC_FLAGS="$triple_flags"
  -DCMAKE_OBJCXX_FLAGS="$triple_flags"
  -DCMAKE_ASM_FLAGS="$triple_flags"
  -DCMAKE_EXE_LINKER_FLAGS="$triple_flags"
  -DCMAKE_SHARED_LINKER_FLAGS="$triple_flags"
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS_DEFAULT=ON
  -DGGML_METAL_USE_BF16=ON
  -DGGML_NATIVE=OFF
  -DGGML_OPENMP=OFF
)

if [[ "$framework_name" == llama ]]; then
  cmake_args+=(
    -DLLAMA_BUILD_APP=OFF
    -DLLAMA_BUILD_COMMON=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_MTMD=ON
    -DLLAMA_OPENSSL=OFF
    -DMTMD_VIDEO=OFF
  )
else
  cmake_args+=(
    -DWHISPER_BUILD_EXAMPLES=OFF
    -DWHISPER_BUILD_TESTS=OFF
    -DWHISPER_BUILD_SERVER=OFF
    -DWHISPER_COREML=OFF
  )
fi

echo "==> Configuring ${framework_name} for ${target_triple}"
cmake -B "$build_dir" -G "Unix Makefiles" "${cmake_args[@]}" -S .
cmake --build "$build_dir" --config Release -j"$(sysctl -n hw.ncpu)"

framework="${build_dir}/framework/${framework_name}.framework"
mkdir -p \
  "${framework}/Versions/A/Headers" \
  "${framework}/Versions/A/Modules" \
  "${framework}/Versions/A/Resources"
ln -sfn A "${framework}/Versions/Current"
ln -sfn Versions/Current/Headers "${framework}/Headers"
ln -sfn Versions/Current/Modules "${framework}/Modules"
ln -sfn Versions/Current/Resources "${framework}/Resources"
ln -sfn "Versions/Current/${framework_name}" "${framework}/${framework_name}"

headers="${framework}/Versions/A/Headers"
if [[ "$framework_name" == llama ]]; then
  header_sources=(
    include/llama.h
    ggml/include/ggml.h
    ggml/include/ggml-opt.h
    ggml/include/ggml-alloc.h
    ggml/include/ggml-backend.h
    ggml/include/ggml-metal.h
    ggml/include/ggml-cpu.h
    ggml/include/ggml-blas.h
    ggml/include/gguf.h
    tools/mtmd/mtmd.h
    tools/mtmd/mtmd-helper.h
  )
  static_libraries=(
    "${build_dir}/src/libllama.a"
    "${build_dir}/ggml/src/libggml.a"
    "${build_dir}/ggml/src/libggml-base.a"
    "${build_dir}/ggml/src/libggml-cpu.a"
    "${build_dir}/ggml/src/ggml-metal/libggml-metal.a"
    "${build_dir}/ggml/src/ggml-blas/libggml-blas.a"
    "${build_dir}/tools/mtmd/libmtmd.a"
  )
else
  header_sources=(
    include/whisper.h
    ggml/include/ggml.h
    ggml/include/ggml-alloc.h
    ggml/include/ggml-backend.h
    ggml/include/ggml-metal.h
    ggml/include/ggml-cpu.h
    ggml/include/ggml-blas.h
    ggml/include/gguf.h
  )
  static_libraries=(
    "${build_dir}/src/libwhisper.a"
    "${build_dir}/ggml/src/libggml.a"
    "${build_dir}/ggml/src/libggml-base.a"
    "${build_dir}/ggml/src/libggml-cpu.a"
    "${build_dir}/ggml/src/ggml-metal/libggml-metal.a"
    "${build_dir}/ggml/src/ggml-blas/libggml-blas.a"
  )
fi

for header in "${header_sources[@]}"; do
  cp "$header" "$headers/"
done
for library in "${static_libraries[@]}"; do
  [[ -f "$library" ]] || { echo "error: expected static library is missing: $library" >&2; exit 1; }
done

module_map="${framework}/Versions/A/Modules/module.modulemap"
{
  printf 'framework module %s {\n' "$framework_name"
  for header in "${header_sources[@]}"; do
    printf '    header "%s"\n' "$(basename "$header")"
  done
  printf '\n    link "c++"\n'
  printf '    link framework "Accelerate"\n'
  printf '    link framework "Metal"\n'
  printf '    link framework "Foundation"\n\n'
  printf '    export *\n}\n'
} >"$module_map"

info_plist="${framework}/Versions/A/Resources/Info.plist"
plutil -create xml1 "$info_plist"
plutil -insert CFBundleDevelopmentRegion -string en "$info_plist"
plutil -insert CFBundleExecutable -string "$framework_name" "$info_plist"
plutil -insert CFBundleIdentifier -string "org.ggml.${framework_name}" "$info_plist"
plutil -insert CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -insert CFBundleName -string "$framework_name" "$info_plist"
plutil -insert CFBundlePackageType -string FMWK "$info_plist"
plutil -insert CFBundleShortVersionString -string 1.0 "$info_plist"
plutil -insert CFBundleVersion -string 1 "$info_plist"
plutil -insert MinimumOSVersion -string "$catalyst_min_os_version" "$info_plist"
plutil -insert CFBundleSupportedPlatforms -json '["MacOSX"]' "$info_plist"
plutil -insert DTPlatformName -string macosx "$info_plist"
plutil -insert LSMinimumSystemVersion -string 11.0 "$info_plist"

temporary_dir="${build_dir}/merge-input"
mkdir -p "$temporary_dir" "${build_dir}/dSYMs"
xcrun libtool -static -o "${temporary_dir}/combined.a" "${static_libraries[@]}"

output_binary="${framework}/Versions/A/${framework_name}"
xcrun -sdk macosx clang++ -dynamiclib \
  -isysroot "$sysroot" \
  -target "$target_triple" \
  -Wl,-force_load,"${temporary_dir}/combined.a" \
  -framework Foundation -framework Metal -framework Accelerate \
  -install_name "@rpath/${framework_name}.framework/Versions/Current/${framework_name}" \
  -o "$output_binary"
xcrun dsymutil "$output_binary" -o "${build_dir}/dSYMs/${framework_name}.dSYM"

if ! vtool -show-build "$output_binary" 2>/dev/null | grep -Eqi 'MACCATALYST|catalyst'; then
  echo "error: generated ${framework_name} binary is not marked for Mac Catalyst" >&2
  exit 1
fi

xcframework_args=()
for slice in "$xcframework"/*/; do
  framework_path="${slice}${framework_name}.framework"
  [[ -d "$framework_path" ]] || continue
  xcframework_args+=(-framework "$framework_path")
  dsym_path="${slice}dSYMs/${framework_name}.dSYM"
  [[ -d "$dsym_path" ]] && xcframework_args+=(-debug-symbols "$dsym_path")
done
xcframework_args+=(-framework "$framework")
xcframework_args+=(-debug-symbols "${build_dir}/dSYMs/${framework_name}.dSYM")

merged_root="${source_root}/build-apple/.merge-${framework_name}"
merged_xcframework="${merged_root}/${framework_name}.xcframework"
mkdir -p "$merged_root"
xcrun xcodebuild -create-xcframework \
  "${xcframework_args[@]}" \
  -output "$merged_xcframework"

# Move the previous generated artifact aside until the replacement succeeds.
previous_xcframework="${source_root}/build-apple/.previous-${framework_name}.xcframework"
if [[ -e "$previous_xcframework" ]]; then
  echo "error: stale merge backup exists: $previous_xcframework" >&2
  exit 1
fi
mv "$xcframework" "$previous_xcframework"
mv "$merged_xcframework" "$xcframework"

echo "==> Added Mac Catalyst slice to ${xcframework}"
echo "    The previous generated artifact remains at ${previous_xcframework}"
