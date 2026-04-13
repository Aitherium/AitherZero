#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

zero_sha="0000000000000000000000000000000000000000"
event_name="${GITHUB_EVENT_NAME:-}"
event_path="${GITHUB_EVENT_PATH:-}"
base_ref="${GITHUB_BASE_REF:-}"
head_sha="${GITHUB_SHA:-HEAD}"

changed_files=()

load_changed_files() {
  if [[ "$event_name" == "pull_request" || "$event_name" == "pull_request_target" ]]; then
    if [[ -n "$base_ref" ]]; then
      git fetch --no-tags --prune --depth=1 origin "$base_ref"
      mapfile -t changed_files < <(git diff --name-only --diff-filter=ACMR "origin/$base_ref...HEAD")
      return
    fi
  fi

  if [[ "$event_name" == "push" && -f "$event_path" ]]; then
    local before_sha
    before_sha="$({ python - <<'PY'
import json
import os

path = os.environ.get("GITHUB_EVENT_PATH")
if not path:
    print("")
else:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    print(data.get("before", ""))
PY
    } | tr -d '\r')"

    if [[ -n "$before_sha" && "$before_sha" != "$zero_sha" ]]; then
      mapfile -t changed_files < <(git diff --name-only --diff-filter=ACMR "$before_sha..$head_sha")
      return
    fi
  fi

  if git rev-parse HEAD^ >/dev/null 2>&1; then
    mapfile -t changed_files < <(git diff --name-only --diff-filter=ACMR HEAD^..HEAD)
  else
    mapfile -t changed_files < <(git ls-files)
  fi
}

write_bool() {
  echo "$1=$2" >> "$GITHUB_OUTPUT"
}

write_multiline() {
  local key="$1"
  shift || true
  {
    echo "$key<<EOF"
    if [[ $# -gt 0 ]]; then
      printf '%s\n' "$@"
    fi
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
}

load_changed_files

module_changed=false
script_changed=false
tests_changed=false
workflow_changed=false

pester_test_files=()
script_files=()
module_files=()

for file in "${changed_files[@]}"; do
  [[ -n "$file" ]] || continue

  case "$file" in
    .github/workflows/*|.github/scripts/*)
      workflow_changed=true
      ;;
  esac

  case "$file" in
    src/*|AitherZero.psd1|AitherZero.psm1|build.ps1|metadata.json|plugins/*|plugins/*/*|config/*|config/*/*)
      module_changed=true
      module_files+=("$file")
      ;;
  esac

  case "$file" in
    library/automation-scripts/*|library/automation-scripts/*/*)
      script_changed=true
      script_files+=("$file")
      ;;
  esac

  case "$file" in
    tests/*.Tests.ps1|tests/*/*.Tests.ps1|tests/*/*/*.Tests.ps1)
      tests_changed=true
      pester_test_files+=("$file")
      ;;
  esac
done

write_bool module_changed "$module_changed"
write_bool script_changed "$script_changed"
write_bool tests_changed "$tests_changed"
write_bool workflow_changed "$workflow_changed"
write_bool any_validation_needed "$([[ "$module_changed" == true || "$script_changed" == true || "$tests_changed" == true || "$workflow_changed" == true ]] && echo true || echo false)"
write_multiline changed_files "${changed_files[@]}"
write_multiline pester_test_files "${pester_test_files[@]}"
write_multiline script_files "${script_files[@]}"
write_multiline module_files "${module_files[@]}"
