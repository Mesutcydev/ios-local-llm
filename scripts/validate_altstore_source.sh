#!/usr/bin/env bash
set -euo pipefail

source_path="${1:-altstore/source.json}"

if ! command -v jq >/dev/null 2>&1; then
  printf 'error: jq is required to validate %s\n' "$source_path" >&2
  exit 2
fi

jq -e '
  def nonempty_string: (type == "string" and length > 0);
  . as $source
  | ($source.name | nonempty_string)
  and (($source.apps | type) == "array")
  and (($source.apps | length) > 0)
  and (($source.apps | map(.bundleIdentifier) | unique | length) == ($source.apps | length))
  and all($source.apps[];
      (.name | nonempty_string)
      and (.bundleIdentifier | nonempty_string)
      and ((.versions | type) == "array")
      and ((.versions | length) > 0)
      and ((.appPermissions | type) == "object")
      and all(.versions[];
          (.version | nonempty_string)
          and (.buildVersion | nonempty_string)
          and (.downloadURL | startswith("https://"))
          and ((.size | type) == "number")
          and (.size > 0)
          and (.sha256 | test("^[A-Fa-f0-9]{64}$"))
      )
  )
' "$source_path" >/dev/null

printf 'AltStore source is valid: %s\n' "$source_path"
