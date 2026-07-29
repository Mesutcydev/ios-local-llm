#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
manifest_path="${1:-${repo_root}/BackgroundAssets/Manifests/offline-voice-models.json}"
output_dir="${2:-${repo_root}/build/background-assets}"
pack_id="com.mesutcydev.ioslocalllm.offline-voice-models"
pack_version="${ASSET_PACK_VERSION:-1}"
source_dir="${repo_root}/IOSLocalLLM/Resources/BundledVoiceModels"

if [[ ! -f "${manifest_path}" ]]; then
  echo "error: Background Assets manifest not found: ${manifest_path}" >&2
  exit 1
fi

if [[ ! -d "${source_dir}" ]]; then
  echo "error: bundled voice-model directory not found: ${source_dir}" >&2
  exit 1
fi

if ! find "${source_dir}" -type f -size +0c -print -quit | grep -q .; then
  echo "error: bundled voice-model directory contains no non-empty files" >&2
  exit 1
fi

ba_package="$(xcrun --find ba-package)"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/ioslocalllm-background-assets.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT

temporary_archive="${temporary_dir}/${pack_id}-v${pack_version}.aar"
final_archive="${output_dir}/${pack_id}-v${pack_version}.aar"
checksum_file="${final_archive}.sha256"

mkdir -p "${output_dir}"

(
  cd "${repo_root}"
  "${ba_package}" package "${manifest_path}" \
    --output-path "${temporary_archive}" \
    --quiet
)

if [[ ! -s "${temporary_archive}" ]]; then
  echo "error: ba-package produced an empty archive" >&2
  exit 1
fi

mv "${temporary_archive}" "${final_archive}"
(
  cd "${output_dir}"
  shasum -a 256 "$(basename "${final_archive}")" \
    > "$(basename "${checksum_file}")"
)

echo "Packaged ${final_archive}"
echo "Checksum ${checksum_file}"
