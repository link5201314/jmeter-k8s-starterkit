#!/usr/bin/env bash

set -euo pipefail

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

usage() {
  cat <<'EOF'
Usage:
  ./reset_pvc.sh [-n namespace] [-r helm_release] [-p pvc_name] [--skip-scale-report] [--restore-report-server] [--recreate-runtime] [--helm-chart chart_path]

Options:
  -n <namespace>        Namespace (default: performance-test)
  -r <helm_release>     Runtime helm release name (default: jmeter-runtime)
  -p <pvc_name>         PVC name to reset (default: jmeter-data-dir-pvc)
  --skip-scale-report   Do not scale report-server deployment
  --restore-report-server  Scale report-server back to 1 after reset
  --recreate-runtime    Recreate runtime release after reset (recreates PVC)
  --helm-chart <path>   Helm chart path for runtime recreation (default: k8s/helm/charts/jmeter)
  -h                    Show help

Behavior:
  1) Uninstall runtime Helm release
  2) Scale report-server to 0 (optional)
  3) Delete PVC
  4) If stuck in Terminating, remove PVC/PV finalizers and retry deletion
  5) (Optional) Recreate runtime release to recreate PVC
  6) Print verification result
EOF
}

namespace="performance-test"
helm_release="jmeter-runtime"
pvc_name="jmeter-data-dir-pvc"
skip_scale_report=0
restore_report_server=0
recreate_runtime=0
helm_chart_path="k8s/helm/charts/jmeter"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      namespace="$2"
      shift 2
      ;;
    -r)
      helm_release="$2"
      shift 2
      ;;
    -p)
      pvc_name="$2"
      shift 2
      ;;
    --skip-scale-report)
      skip_scale_report=1
      shift
      ;;
    --restore-report-server)
      restore_report_server=1
      shift
      ;;
    --recreate-runtime)
      recreate_runtime=1
      shift
      ;;
    --helm-chart)
      helm_chart_path="$2"
      shift 2
      ;;
    -h)
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

if ! command -v helm >/dev/null 2>&1; then
  log WARN "helm command not found, skip helm uninstall step"
fi

log INFO "Namespace=${namespace}, Release=${helm_release}, PVC=${pvc_name}"

if [[ "${skip_scale_report}" -eq 1 && "${restore_report_server}" -eq 1 ]]; then
  log ERROR "--restore-report-server cannot be used with --skip-scale-report"
  exit 1
fi

if [[ "${recreate_runtime}" -eq 1 ]] && ! command -v helm >/dev/null 2>&1; then
  log ERROR "--recreate-runtime requires helm command"
  exit 1
fi

pv_name=""
if kubectl -n "${namespace}" get pvc "${pvc_name}" >/dev/null 2>&1; then
  pv_name="$(kubectl -n "${namespace}" get pvc "${pvc_name}" -o jsonpath='{.spec.volumeName}' || true)"
  log INFO "Detected bound PV: ${pv_name:-<none>}"
else
  log WARN "PVC ${pvc_name} not found in namespace ${namespace}"
fi

if command -v helm >/dev/null 2>&1; then
  log INFO "Uninstalling helm release ${helm_release} (if exists)"
  helm uninstall "${helm_release}" -n "${namespace}" >/dev/null 2>&1 || true
fi

if [[ "${skip_scale_report}" -eq 0 ]]; then
  if kubectl -n "${namespace}" get deploy report-server >/dev/null 2>&1; then
    log INFO "Scaling report-server to 0"
    kubectl -n "${namespace}" scale deploy report-server --replicas=0 >/dev/null
  else
    log WARN "report-server deployment not found in namespace ${namespace}"
  fi
fi

if kubectl -n "${namespace}" get pvc "${pvc_name}" >/dev/null 2>&1; then
  log INFO "Deleting PVC ${pvc_name}"
  kubectl -n "${namespace}" delete pvc "${pvc_name}" --wait=false >/dev/null || true
  sleep 2
fi

if kubectl -n "${namespace}" get pvc "${pvc_name}" >/dev/null 2>&1; then
  phase="$(kubectl -n "${namespace}" get pvc "${pvc_name}" -o jsonpath='{.status.phase}' || true)"
  deletion_ts="$(kubectl -n "${namespace}" get pvc "${pvc_name}" -o jsonpath='{.metadata.deletionTimestamp}' || true)"
  if [[ -n "${deletion_ts}" ]]; then
    log WARN "PVC ${pvc_name} is stuck Terminating, patching PVC finalizers"
    kubectl -n "${namespace}" patch pvc "${pvc_name}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
  else
    log WARN "PVC ${pvc_name} still exists (phase=${phase}), continue force cleanup"
  fi
fi

if [[ -n "${pv_name}" ]] && kubectl get pv "${pv_name}" >/dev/null 2>&1; then
  pv_deletion_ts="$(kubectl get pv "${pv_name}" -o jsonpath='{.metadata.deletionTimestamp}' || true)"
  if [[ -n "${pv_deletion_ts}" ]]; then
    log WARN "PV ${pv_name} is Terminating, patching PV finalizers"
    kubectl patch pv "${pv_name}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null || true
  fi

  log INFO "Deleting PV ${pv_name}"
  kubectl delete pv "${pv_name}" --wait=false >/dev/null || true
fi

kubectl -n "${namespace}" delete pvc "${pvc_name}" --ignore-not-found=true >/dev/null || true

if [[ "${recreate_runtime}" -eq 1 ]]; then
  log INFO "Recreating runtime release ${helm_release} from chart ${helm_chart_path}"
  if [[ ! -d "${helm_chart_path}" ]]; then
    log ERROR "Helm chart path not found: ${helm_chart_path}"
    exit 1
  fi

  helm upgrade --install "${helm_release}" "${helm_chart_path}" \
    -n "${namespace}" --create-namespace \
    --set slaves.parallelism=0 >/dev/null

  log INFO "Runtime release recreated"
fi

log INFO "Verification"
if kubectl -n "${namespace}" get pvc "${pvc_name}" >/dev/null 2>&1; then
  log INFO "PVC ${pvc_name} exists"
  kubectl -n "${namespace}" get pvc "${pvc_name}"
else
  if [[ "${recreate_runtime}" -eq 1 ]]; then
    log ERROR "PVC ${pvc_name} was not recreated"
    exit 1
  fi
fi

if [[ -n "${pv_name}" ]] && kubectl get pv "${pv_name}" >/dev/null 2>&1; then
  log WARN "PV ${pv_name} still exists (check StorageClass reclaim policy and cloud disk manually)"
  kubectl get pv "${pv_name}"
else
  log INFO "PVC reset completed"
fi

if [[ "${restore_report_server}" -eq 1 ]]; then
  if kubectl -n "${namespace}" get deploy report-server >/dev/null 2>&1; then
    log INFO "Restoring report-server replicas to 1"
    kubectl -n "${namespace}" scale deploy report-server --replicas=1 >/dev/null
  else
    log WARN "report-server deployment not found, skip restore"
  fi
fi
