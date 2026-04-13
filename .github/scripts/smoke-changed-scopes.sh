#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./.github/scripts/smoke-changed-scopes.sh [--file changed-files.txt] [path1 path2 ...]

Examples:
  ./.github/scripts/smoke-changed-scopes.sh src/public/Get-Thing.ps1 tests/unit/Get-Thing.Tests.ps1
  ./.github/scripts/smoke-changed-scopes.sh --file .github/sample-changes.txt
EOF
}

changed_files=()

if [[ $# -gt 0 && "$1" == "--file" ]]; then
  [[ $# -ge 2 ]] || { usage; exit 1; }
  mapfile -t changed_files < "$2"
  shift 2
fi

if [[ $# -gt 0 ]]; then
  changed_files+=("$@")
fi

if [[ ${#changed_files[@]} -eq 0 ]]; then
  usage
  exit 1
fi

module_changed=false
script_changed=false
tests_changed=false
workflow_changed=false
pester_test_files=()
script_files=()
module_files=()

for file in "${changed_files[@]}"; do
  file="${file%$'\r'}"
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

any_validation_needed=false
if [[ "$module_changed" == true || "$script_changed" == true || "$tests_changed" == true || "$workflow_changed" == true ]]; then
  any_validation_needed=true
fi

printf 'module_changed=%s\n' "$module_changed"
printf 'script_changed=%s\n' "$script_changed"
printf 'tests_changed=%s\n' "$tests_changed"
printf 'workflow_changed=%s\n' "$workflow_changed"
printf 'any_validation_needed=%s\n' "$any_validation_needed"
printf '\nchanged_files:\n'
printf '  %s\n' "${changed_files[@]}"

if [[ ${#module_files[@]} -gt 0 ]]; then
  printf '\nmodule_files:\n'
  printf '  %s\n' "${module_files[@]}"
fi

if [[ ${#script_files[@]} -gt 0 ]]; then
  printf '\nscript_files:\n'
  printf '  %s\n' "${script_files[@]}"
fi

if [[ ${#pester_test_files[@]} -gt 0 ]]; then
  printf '\npester_test_files:\n'
  printf '  %s\n' "${pester_test_files[@]}"
fi
