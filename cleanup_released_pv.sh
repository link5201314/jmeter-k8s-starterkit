#!/usr/bin/env bash

# Purpose:
#   清理符合條件的 Released PV（預設 dry-run，避免誤刪）。
#
# Examples:
#   ./cleanup_released_pv.sh -n performance-test -c jmeter-data-dir-pvc --storage-class nfs-csi
#   ./cleanup_released_pv.sh -n performance-test -c jmeter-data-dir-pvc --storage-class nfs-csi --execute

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./cleanup_released_pv.sh [-n namespace] [-c claim_name] [--storage-class name] [--execute]

Options:
  -n <namespace>         Target namespace in claimRef (default: performance-test)
  -c <claim_name>        Target PVC claim name (default: jmeter-data-dir-pvc)
  --storage-class <name> Optional storageClass filter (e.g. nfs-csi)
  --execute              Actually patch finalizers and delete PVs (default: dry-run)
  -h, --help             Show help

Behavior:
  - Only targets PV with status=Released
  - Filters by claimRef.namespace + claimRef.name
  - Optional storageClass filter for extra safety
  - Dry-run by default
EOF
}

log() {
  local level="$1"
  local msg="$2"
  case "$level" in
    INFO)  echo -e "[\e[94mINFO\e[0m] ${msg}" ;;
    WARN)  echo -e "[\e[93mWARN\e[0m] ${msg}" ;;
    ERROR) echo -e "[\e[91mERROR\e[0m] ${msg}" ;;
    *)     echo "[${level}] ${msg}" ;;
  esac
}

namespace="performance-test"
claim_name="jmeter-data-dir-pvc"
storage_class=""
execute=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      namespace="$2"
      shift 2
      ;;
    -c)
      claim_name="$2"
      shift 2
      ;;
    --storage-class)
      storage_class="$2"
      shift 2
      ;;
    --execute)
      execute=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log ERROR "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if ! command -v kubectl >/dev/null 2>&1; then
  log ERROR "kubectl command not found"
  exit 1
fi

log INFO "Scan criteria: status=Released, claimRef=${namespace}/${claim_name}${storage_class:+, storageClass=${storage_class}}"

mapfile -t candidates < <(
  kubectl get pv \
    -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,CLAIM_NS:.spec.claimRef.namespace,CLAIM_NAME:.spec.claimRef.name,SC:.spec.storageClassName \
    --no-headers \
  | awk -v ns="$namespace" -v claim="$claim_name" -v sc="$storage_class" '
      $2=="Released" && $3==ns && $4==claim {
        if (sc=="" || $5==sc) print $1
      }
    '
)

if [[ ${#candidates[@]} -eq 0 ]]; then
  log INFO "No matching Released PV found"
  exit 0
fi

log WARN "Found ${#candidates[@]} matching Released PV(s):"
for pv in "${candidates[@]}"; do
  echo "  - ${pv}"
done

if [[ "$execute" -eq 0 ]]; then
  log INFO "Dry-run mode. Add --execute to actually delete these PVs."
  exit 0
fi

for pv in "${candidates[@]}"; do
  log INFO "Cleaning PV: ${pv}"
  kubectl patch pv "${pv}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
  kubectl delete pv "${pv}" --wait=false >/dev/null
done

log INFO "Done. You can verify by running: kubectl get pv"
