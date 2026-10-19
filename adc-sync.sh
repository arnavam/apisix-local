#!/usr/bin/env bash
# Usage: ./adc-sync.sh [lint|diff|sync] [central|<app-adc.yaml> ...]
#   ./adc-sync.sh diff central
#   ./adc-sync.sh sync ../frappe_local/frappe-bench/apps/oan_grievance_service/apisix/adc.yaml
# Central file: DevOps types only. App files: services, routes and consumers, scoped by
# the app label, so one app's sync never deletes another's resources.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/adc-env.sh"
cmd="${1:?lint|diff|sync}"; shift
target="${1:-central}"; shift || true

if [ "$target" = central ]; then
  file="$here/adc.yaml"
  filters=(--include-resource-type global_rule --include-resource-type plugin_metadata
    --include-resource-type ssl)
else
  file="$target"
  app="$(sed -n 's/^    app: //p' "$file" | head -1)"
  filters=(--label-selector "app=$app"
    --include-resource-type service --include-resource-type route
    --include-resource-type consumer)
fi
# lint only checks the file; it has no backend filters.
[ "$cmd" = lint ] && filters=()
exec adc "$cmd" -f "$file" ${filters[@]+"${filters[@]}"}
