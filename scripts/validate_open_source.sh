#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

required_files=(
  AGENTS.md
  LICENSE
  README.md
  CONTRIBUTING.md
  SECURITY.md
  THIRD_PARTY_NOTICES.md
  Docs/AGENT_INTEGRATION.md
  codemeta.json
  llms.txt
  .github/copilot-instructions.md
  CodeLens/Vendor/StableDiffusion/LICENSE
  CodeLens/Resources/Voice/LICENSE
  LICENSES/Apple-Sample-Code-License.txt
)

for required_file in "${required_files[@]}"; do
  if [[ ! -f "$required_file" ]]; then
    echo "error: required file is missing: $required_file" >&2
    exit 1
  fi
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: run this check inside the Git repository" >&2
  exit 1
fi

blocked_pattern='(^|/)(Pods|vendor|DerivedData|XcodePublisher_Logs|xcuserdata|BundledVLM|BundledVoiceModels|FastVLM-0\.5B-fp16)(/|$)|\.(p8|p12|mobileprovision|ipa|xcarchive|pkg|gguf|safetensors|onnx|npz)$|(^|/)(ExportOptions\.plist|MEMORY\.md|CLAUDE\.rtf)$'
blocked_files="$(git ls-files | grep -E "$blocked_pattern" || true)"
if [[ -n "$blocked_files" ]]; then
  echo "error: publish-unsafe files are tracked:" >&2
  echo "$blocked_files" >&2
  exit 1
fi

oversized_files="$(
  git ls-files -z |
    xargs -0 -I{} sh -c 'if [ -f "$1" ]; then size=$(wc -c < "$1"); if [ "$size" -gt 50000000 ]; then printf "%s %s\n" "$size" "$1"; fi; fi' _ {} |
    sort -nr
)"
if [[ -n "$oversized_files" ]]; then
  echo "error: tracked files exceed the 50 MB repository limit:" >&2
  echo "$oversized_files" >&2
  exit 1
fi

secret_pattern='AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{50,}|glpat-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
secret_matches="$(git grep -Il -E "$secret_pattern" -- . ':!scripts/validate_open_source.sh' || true)"
if [[ -n "$secret_matches" ]]; then
  echo "error: possible credentials found in tracked files:" >&2
  echo "$secret_matches" >&2
  exit 1
fi

echo "Open-source repository checks passed."
