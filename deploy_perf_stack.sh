#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  ./deploy_perf_stack.sh -n <namespace> --helm-env <env> [options]

Required:
  -n, --namespace <name>            Target namespace for perf-stack
  --helm-env <name>                 Environment values name under k8s/helm/environments/values

Host options (choose one strategy):
  --base-domain <domain>            Auto-generate hosts from namespace
  --report-host <host>              Explicit report host
  --grafana-host <host>             Explicit grafana host
  --webapp-host <host>              Explicit webapp host

Optional:
  -r, --release <name>              Helm release name (default: perf-stack)
  --chart <path>                    Helm chart path (default: k8s/helm)
  --report-prefix <prefix>          Auto host prefix (default: jmeter-report)
  --grafana-prefix <prefix>         Auto host prefix (default: jmeter-grafana)
  --webapp-prefix <prefix>          Auto host prefix (default: jmeter-web)
  --telegraf-cluster-rbac <bool>    true for primary namespace, false for secondary (default: false)
  --skip-dependency-build           Skip helm dependency build
  --no-create-namespace             Do not pass --create-namespace
  --dry-run                         Render/validate only (adds --dry-run --debug)
  -h, --help                        Show this help

Examples:
  # Primary namespace: create cluster-scoped telegraf RBAC once
  ./deploy_perf_stack.sh -n performance-test --helm-env dr-prod \
    --base-domain mgnt.mvdis.gov.tw --telegraf-cluster-rbac true

  # Secondary namespace: avoid RBAC ownership conflicts
  ./deploy_perf_stack.sh -n performance-test2 --helm-env dr-prod \
    --base-domain mgnt.mvdis.gov.tw --telegraf-cluster-rbac false
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
release="perf-stack"
chart_path="${repo_root}/k8s/helm"
namespace=""
helm_env=""

report_prefix="jmeter-report"
grafana_prefix="jmeter-grafana"
webapp_prefix="jmeter-web"

base_domain=""
report_host=""
grafana_host=""
webapp_host=""

telegraf_cluster_rbac="false"
skip_dependency_build=0
create_namespace=1
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      namespace="$2"; shift 2 ;;
    --helm-env)
      helm_env="$2"; shift 2 ;;
    -r|--release)
      release="$2"; shift 2 ;;
    --chart)
      chart_path="$2"; shift 2 ;;
    --base-domain)
      base_domain="$2"; shift 2 ;;
    --report-prefix)
      report_prefix="$2"; shift 2 ;;
    --grafana-prefix)
      grafana_prefix="$2"; shift 2 ;;
    --webapp-prefix)
      webapp_prefix="$2"; shift 2 ;;
    --report-host)
      report_host="$2"; shift 2 ;;
    --grafana-host)
      grafana_host="$2"; shift 2 ;;
    --webapp-host)
      webapp_host="$2"; shift 2 ;;
    --telegraf-cluster-rbac)
      telegraf_cluster_rbac="$2"; shift 2 ;;
    --skip-dependency-build)
      skip_dependency_build=1; shift ;;
    --no-create-namespace)
      create_namespace=0; shift ;;
    --dry-run)
      dry_run=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "[ERROR] Unknown option: $1" >&2
      usage
      exit 1 ;;
  esac
done

if [[ -z "${namespace}" ]]; then
  echo "[ERROR] --namespace is required" >&2
  usage
  exit 1
fi
if [[ -z "${helm_env}" ]]; then
  echo "[ERROR] --helm-env is required" >&2
  usage
  exit 1
fi
if [[ "${telegraf_cluster_rbac}" != "true" && "${telegraf_cluster_rbac}" != "false" ]]; then
  echo "[ERROR] --telegraf-cluster-rbac must be true or false" >&2
  exit 1
fi

values_file="${repo_root}/k8s/helm/environments/values/${helm_env}.yaml"
if [[ ! -f "${values_file}" ]]; then
  echo "[ERROR] Values file not found: ${values_file}" >&2
  exit 1
fi

if [[ -z "${report_host}" || -z "${grafana_host}" || -z "${webapp_host}" ]]; then
  if [[ -z "${base_domain}" ]]; then
    echo "[ERROR] Provide either all explicit hosts or --base-domain for auto host generation" >&2
    exit 1
  fi
  [[ -z "${report_host}" ]] && report_host="${report_prefix}-${namespace}.${base_domain}"
  [[ -z "${grafana_host}" ]] && grafana_host="${grafana_prefix}-${namespace}.${base_domain}"
  [[ -z "${webapp_host}" ]] && webapp_host="${webapp_prefix}-${namespace}.${base_domain}"
fi

if [[ "${skip_dependency_build}" -eq 0 ]]; then
  echo "[INFO] helm dependency build ${chart_path}"
  helm dependency build "${chart_path}" >/dev/null
fi

cmd=(
  helm upgrade --install "${release}" "${chart_path}"
  -n "${namespace}"
  -f "${values_file}"
  --set-string "report-server.ingress.host=${report_host}"
  --set-string "grafana.ingress.host=${grafana_host}"
  --set-string "webapp.ingress.host=${webapp_host}"
  --set "telegraf.rbac.createClusterScopedResources=${telegraf_cluster_rbac}"
)

if [[ "${create_namespace}" -eq 1 ]]; then
  cmd+=(--create-namespace)
fi
if [[ "${dry_run}" -eq 1 ]]; then
  cmd+=(--dry-run --debug)
fi

echo "[INFO] namespace=${namespace} helm_env=${helm_env} release=${release}"
echo "[INFO] report host : ${report_host}"
echo "[INFO] grafana host: ${grafana_host}"
echo "[INFO] webapp host : ${webapp_host}"
echo "[INFO] telegraf cluster RBAC create=${telegraf_cluster_rbac}"

echo "[INFO] Running Helm command..."
"${cmd[@]}"
