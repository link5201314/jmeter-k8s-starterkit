#!/usr/bin/env bash

# Purpose:
#   啟動 JMeter 分散式測試（建立/更新 runtime、同步 scenario、啟動 master/slave）。
#
# Examples:
#   ./start_test.sh -j demoweb.jmx -n performance-test --min-slaves 2 --max-threads 300 -c -m -r --helm-env lab --helm-release jmeter-runtime
#   ./start_test.sh -j demoweb.jmx -n performance-test --min-slaves 3 --max-threads 100 -c -m -r -E prod -V "tip-web=1.0.1;gemfire=2.2.3" -N "baseline"

#=== FUNCTION ================================================================
#        NAME: logit
# DESCRIPTION: Log into file and screen.
# PARAMETER - 1 : Level (ERROR, INFO)
#           - 2 : Message
#
#===============================================================================
logit()
{
    case "$1" in
        "INFO")
            echo -e " [\e[94m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ] $2 \e[0m" ;;
        "WARN")
            echo -e " [\e[93m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ]  \e[93m $2 \e[0m " && sleep 2 ;;
        "ERROR")
            echo -e " [\e[91m $1 \e[0m] [ $(date '+%d-%m-%y %H:%M:%S') ]  $2 \e[0m " ;;
    esac
}

#=== FUNCTION ================================================================
#        NAME: usage
# DESCRIPTION: Helper of the function
# PARAMETER - None
#
#===============================================================================
usage()
{
  logit "INFO" "-j <filename.jmx>"
  logit "INFO" "-n <namespace>"
  logit "INFO" "-c flag to split and copy csv if you use csv in your test"
  logit "INFO" "-m flag to copy fragmented jmx present in scenario/project/module if you use include controller and external test fragment"
    logit "INFO" "-i <injectorNumber> (legacy) equals --min-slaves"
    logit "INFO" "--min-slaves <number> minimum JMeter slaves to start"
    logit "INFO" "--max-threads <number> max total threads per slave for auto scaling"
  logit "INFO" "-r flag to enable report generation at the end of the test"
  logit "INFO" "-E <env> test environment (e.g. prod/uat/sit/pt)"
  logit "INFO" "-V <versions> app versions, ';' separated (e.g. tip-web=1.0.1;gemfire=2.2.3)"
  logit "INFO" "-N <note> free-form notes"
  logit "INFO" "-F <file> meta env file (REPORT_ENV/REPORT_VERSIONS/REPORT_NOTE)"
    logit "INFO" "--helm-env <name> helm env values name under k8s/helm/environments/values (default: lab)"
  logit "INFO" "--helm-release <name> helm release name for jmeter chart (default: jmeter-runtime)"
  logit "INFO" "--helm-chart <path> helm chart path for jmeter resources (default: k8s/helm/charts/jmeter)"
  logit "INFO" "--jmeter-env-file <path> explicit env file for JVM/resource overrides"
  logit "INFO" "--pvc-enabled <true|false> 是否由 helm 建立 PVC (預設: true)"
  exit 1
}

report_env=""
report_versions=""
report_note=""
meta_file="report-meta.env"
seen_args=0
helm_env="lab"
helm_release="jmeter-runtime"
helm_chart_path="${PWD}/k8s/helm/charts/jmeter"
jmeter_env_file_override=""
min_slaves=""
max_threads=""
legacy_injectors=""

###############################################################################
# 1) Parse CLI arguments
#
# Notes:
# - -i is kept for backward compatibility and mapped to min_slaves.
# - --max-threads enables adaptive JMX thread distribution when > 0.
###############################################################################
### Parsing the arguments ###
while [[ $# -gt 0 ]]; do
  seen_args=1
  case "$1" in
    -n) namespace="$2"; shift 2 ;;
    -c) csv=1; shift ;;
    -m) module=1; shift ;;
    -r) enable_report=1; shift ;;
    -j) jmx="$2"; shift 2 ;;
    -i) legacy_injectors="$2"; shift 2 ;;
    -E) report_env="$2"; shift 2 ;;
    -V) report_versions="$2"; shift 2 ;;
    -N) report_note="$2"; shift 2 ;;
    --min-slaves) min_slaves="$2"; shift 2 ;;
    --max-threads) max_threads="$2"; shift 2 ;;
    --helm-env) helm_env="$2"; shift 2 ;;
    --helm-release) helm_release="$2"; shift 2 ;;
    --helm-chart) helm_chart_path="$2"; shift 2 ;;
    --jmeter-env-file) jmeter_env_file_override="$2"; shift 2 ;;
    --pvc-enabled)
      if [[ "$2" == "true" || "$2" == "false" ]]; then
        pvc_enabled="$2"; shift 2
      else
        logit "ERROR" "--pvc-enabled 需指定 true 或 false"; usage
      fi
      ;;
    -F)
      if [[ -n "$2" && "$2" != -* ]]; then
        meta_file="$2"; shift 2
      else
        meta_file="report-meta.env"; shift
      fi
      ;;
    -h) usage ;;
    *) logit "ERROR" "Unknown option: $1"; usage ;;
  esac
done

if [ "${seen_args}" -eq 0 ]; then
  usage
fi

###############################################################################
# 2) Validate and normalize runtime options
#
# - Resolve min_slaves from legacy -i when needed.
# - Ensure numeric constraints before any cluster-side action.
###############################################################################
### CHECKING VARS ###
if [ -z "${namespace}" ]; then
    logit "ERROR" "Namespace not provided!"
    usage
    namespace=$(awk '{print $NF}' "${PWD}/namespace_export")
fi

if [ -z "${jmx}" ]; then
    #read -rp 'Enter the name of the jmx file ' jmx
    logit "ERROR" "jmx jmeter project not provided!"
    usage
fi

if [ -z "${min_slaves}" ] && [ -n "${legacy_injectors}" ]; then
    min_slaves="${legacy_injectors}"
fi
if [ -z "${min_slaves}" ]; then
    min_slaves=1
    logit "WARN" "Min Slaves not provided, default to 1"
fi
if ! [[ "${min_slaves}" =~ ^[0-9]+$ ]] || [ "${min_slaves}" -lt 1 ]; then
    logit "ERROR" "Invalid --min-slaves: ${min_slaves} (must be integer >= 1)"
    exit 1
fi

if [ -z "${max_threads}" ]; then
    max_threads=0
fi
if ! [[ "${max_threads}" =~ ^[0-9]+$ ]]; then
    logit "ERROR" "Invalid --max-threads: ${max_threads} (must be integer >= 0)"
    exit 1
fi

# Quick preflight warnings for common report accessibility issues.
# 檢查 report-server 與 PVC 是否在同一 namespace
if ! kubectl -n "${namespace}" get pvc jmeter-data-dir-pvc >/dev/null 2>&1; then
    logit "WARN" "PVC jmeter-data-dir-pvc 不在 namespace=${namespace}，報表可能無法被 report-server 讀取"
fi
if ! kubectl -n "${namespace}" get deploy report-server >/dev/null 2>&1; then
    logit "WARN" "report-server 不在 namespace=${namespace}，report.example.com 可能讀不到報表"
fi

jmx_dir="${jmx%%.*}"

# Prefix scenario .env keys with JMETERTEST_ in a temporary file, so sourcing
# does not pollute unrelated shell variables.
preprocess_env_file() {
    local env_file="$1"
    local temp_file

    if [ ! -f "${env_file}" ]; then
        logit "WARN" "Environment file not found: ${env_file}"
        return 1
    fi

    temp_file=$(mktemp)
    logit "INFO" "Preprocessing ${env_file} with JMETERTEST_ prefix"

    # Process each line in the .env file
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        # Extract variable name and value
        if [[ "$line" =~ ^[[:space:]]*([^=]+)[[:space:]]*=(.*)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"

            # Trim whitespace from variable name
            var_name=$(echo "$var_name" | xargs)

            # Add JMETERTEST_ prefix only for shell-safe names. Keys like td-1
            # are kept for direct .env parsing in adaptive/global param logic.
            if ! [[ "${var_name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                logit "WARN" "Skip JMETERTEST_ export for non-shell key: ${var_name}"
                continue
            fi

            local prefixed_var="JMETERTEST_${var_name}"

            # Reconstruct the line with prefixed variable name
            echo "${prefixed_var}=${var_value}" >> "$temp_file"

            logit "INFO" "Converted: ${var_name} -> ${prefixed_var}"
        else
            # If line doesn't match variable pattern, keep as is
            echo "$line" >> "$temp_file"
        fi
    done < "${env_file}"

    PREPROCESSED_ENV_FILE="$temp_file"
}

# Prefix report metadata keys with JMETERREPORT_ for clean separation.
preprocess_report_meta_file() {
    local meta_file="$1"
    local temp_file

    if [ ! -f "${meta_file}" ]; then
        logit "WARN" "Report meta file not found: ${meta_file}"
        return 1
    fi

    temp_file=$(mktemp)
    logit "INFO" "Preprocessing ${meta_file} with JMETERREPORT_ prefix"

    # Process each line in the report-meta.env file
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
            echo "$line" >> "$temp_file"
            continue
        fi

        # Extract variable name and value
        if [[ "$line" =~ ^[[:space:]]*([^=]+)[[:space:]]*=(.*)$ ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local var_value="${BASH_REMATCH[2]}"

            # Trim whitespace from variable name
            var_name=$(echo "$var_name" | xargs)

            # Add JMETERREPORT_ prefix to variable name
            local prefixed_var="JMETERREPORT_${var_name}"

            # Reconstruct the line with prefixed variable name
            echo "${prefixed_var}=${var_value}" >> "$temp_file"

            logit "INFO" "Converted: ${var_name} -> ${prefixed_var}"
        else
            # If line doesn't match variable pattern, keep as is
            echo "$line" >> "$temp_file"
        fi
    done < "${meta_file}"

    PREPROCESSED_REPORT_META_FILE="$temp_file"
}

###############################################################################
# 3) Resolve scenario/report metadata inputs and runtime env files
###############################################################################
# Process meta_file if specified (after function definitions)
if [ -n "${meta_file}" ]; then
    # meta_file 路徑規則：若為相對路徑，預設放在 scenario/${jmx_dir}/
    if [[ "${meta_file}" != /* ]]; then
        meta_file="scenario/${jmx_dir}/${meta_file}"
    fi

    if [ -f "${meta_file}" ]; then
        preprocess_report_meta_file "${meta_file}"
        if [ -n "${PREPROCESSED_REPORT_META_FILE}" ] && [ -f "${PREPROCESSED_REPORT_META_FILE}" ]; then
            set -a
            # shellcheck disable=SC1090
            source "${PREPROCESSED_REPORT_META_FILE}"
            set +a
            rm -f "${PREPROCESSED_REPORT_META_FILE}"
            [ -n "${JMETERREPORT_REPORT_ENV}" ] && report_env="${JMETERREPORT_REPORT_ENV}"
            [ -n "${JMETERREPORT_REPORT_VERSIONS}" ] && report_versions="${JMETERREPORT_REPORT_VERSIONS}"
            [ -n "${JMETERREPORT_REPORT_NOTE}" ] && report_note="${JMETERREPORT_REPORT_NOTE}"
        fi
    else
        logit "WARN" "Meta file not found: ${meta_file}"
    fi
fi

if [ ! -f "scenario/${jmx_dir}/${jmx}" ]; then
    logit "ERROR" "Test script file was not found in scenario/${jmx_dir}/${jmx}"
    usage
fi

helm_env_file="${PWD}/k8s/helm/environments/values/${helm_env}.yaml"
if [ ! -f "${helm_env_file}" ]; then
    helm_env_file="${PWD}/k8s/helm/environments/${helm_env}.yaml"
fi
runtime_node_selector_values="${PWD}/k8s/helm/environments/runtime-overrides/${helm_env}.${namespace}.yaml"
runtime_node_selector_cm_name="jmeter-runtime-node-selector-override"
runtime_node_selector_values_tmp=""
project_deploy_values="scenario/${jmx_dir}/deploy.values.yaml"
jmeter_env_file=""

# Load JMeter resource env vars
if [ -n "${jmeter_env_file_override}" ]; then
    jmeter_env_file="${jmeter_env_file_override}"
elif [ -f "${PWD}/config/jmeter.${helm_env}.env" ]; then
    jmeter_env_file="${PWD}/config/jmeter.${helm_env}.env"
elif [ -f "${PWD}/config/jmeter.env" ]; then
    jmeter_env_file="${PWD}/config/jmeter.env"
fi

if [ -n "${jmeter_env_file}" ] && [ -f "${jmeter_env_file}" ]; then
    logit "INFO" "Loading jmeter runtime env file: ${jmeter_env_file}"
    set -a
    # shellcheck disable=SC1091
    source "${jmeter_env_file}"
    set +a
else
    logit "WARN" "No jmeter runtime env file found (checked: config/jmeter.${helm_env}.env, config/jmeter.env)"
fi

plugin_install_mode="${JMETER_PLUGIN_INSTALL_MODE:-auto}"
case "${plugin_install_mode}" in
    true) plugin_install_mode="always" ;;
    false) plugin_install_mode="never" ;;
    auto|always|never) ;;
    *)
        logit "WARN" "Invalid JMETER_PLUGIN_INSTALL_MODE=${plugin_install_mode}, fallback to auto"
        plugin_install_mode="auto"
        ;;
esac
logit "INFO" "Plugin install mode: ${plugin_install_mode} (auto|always|never)"

# Load scenario env early so adaptive thread calculation can resolve ${__P(...)} values.
scenario_env_file="scenario/${jmx_dir}/.env"
scenario_env_loaded=0
if preprocess_env_file "${scenario_env_file}"; then
    if [ -n "${PREPROCESSED_ENV_FILE}" ] && [ -f "${PREPROCESSED_ENV_FILE}" ]; then
        set -a
        # shellcheck disable=SC1090
        source "${PREPROCESSED_ENV_FILE}"
        set +a
        rm -f "${PREPROCESSED_ENV_FILE}"
        scenario_env_loaded=1
    fi
fi
if [ "${scenario_env_loaded}" -eq 0 ] && [ -f "${scenario_env_file}" ]; then
    logit "WARN" "Preprocessed env unavailable, fallback to source original .env for runtime params"
    set -a
    # shellcheck disable=SC1090
    source "${scenario_env_file}"
    set +a
fi

# Build per-slave scaled JMX files when adaptive mode is enabled.
#
# Strategy:
# - Parse supported thread group types only:
#   1) ThreadGroup.ThreadGroup.num_threads
#   2) ConcurrencyThreadGroup.TargetLevel
# - Resolve values from JMETERTEST_* env / __P defaults.
# - Compute target slave count by max(min_slaves, ceil(total_threads/max_threads)).
# - Distribute each thread group by ceil(threads/slaves), so each slave participates.
generate_scaled_jmx_files() {
    local source_jmx="$1"
    local output_dir="$2"
    local requested_min_slaves="$3"
    local requested_max_threads="$4"
    local scenario_env_file="$5"

    python3 - "$source_jmx" "$output_dir" "$requested_min_slaves" "$requested_max_threads" "$scenario_env_file" <<'PY'
import copy
import math
import os
import re
import sys
import xml.etree.ElementTree as ET

source_jmx = sys.argv[1]
output_dir = sys.argv[2]
min_slaves = int(sys.argv[3])
max_threads = int(sys.argv[4])
scenario_env_file = sys.argv[5]


def load_env_file(path: str):
    env_data = {}
    if not path or not os.path.isfile(path):
        return env_data
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            key = key.strip()
            value = value.strip()
            if not key:
                continue
            env_data[key] = value
    return env_data


file_env = load_env_file(scenario_env_file)


def resolve_from_sources(key: str):
    key = (key or "").strip()
    if not key:
        return None

    for candidate in (key, key.replace("_", "-"), key.replace("-", "_")):
        val = file_env.get(candidate)
        if val is not None and re.fullmatch(r"\d+", val.strip()):
            return int(val.strip())

    for candidate in (key, key.replace("_", "-"), key.replace("-", "_")):
        env_key = f"JMETERTEST_{candidate}"
        val = os.environ.get(env_key)
        if val is not None and re.fullmatch(r"\d+", val.strip()):
            return int(val.strip())

    return None

def parse_value(expr: str):
    text = (expr or "").strip()
    if re.fullmatch(r"\d+", text):
        return int(text)

    m = re.fullmatch(r"\$\{__P\(([^,\)]+),\s*([^\)]*)\)\}", text)
    if m:
        key = m.group(1).strip()
        default = m.group(2).strip()
        resolved = resolve_from_sources(key)
        if resolved is not None:
            return resolved

        var_default = re.fullmatch(r"\$\{([^\}]+)\}", default)
        if var_default:
            dkey = var_default.group(1).strip()
            resolved_default = resolve_from_sources(dkey)
            if resolved_default is not None:
                return resolved_default
        if re.fullmatch(r"\d+", default):
            return int(default)
        return None

    var = re.fullmatch(r"\$\{([^\}]+)\}", text)
    if var:
        key = var.group(1).strip()
        resolved = resolve_from_sources(key)
        if resolved is not None:
            return resolved
    return None

tree = ET.parse(source_jmx)
root = tree.getroot()
groups = []

for elem in root.iter():
    tag = elem.tag
    target_name = None
    if tag == "ThreadGroup":
        target_name = "ThreadGroup.num_threads"
    elif tag == "com.blazemeter.jmeter.threads.concurrency.ConcurrencyThreadGroup":
        target_name = "TargetLevel"

    if not target_name:
        continue

    target_prop = None
    for child in elem:
        if child.tag == "stringProp" and child.attrib.get("name") == target_name:
            target_prop = child
            break
    if target_prop is None:
        continue

    resolved = parse_value(target_prop.text or "")
    if resolved is None:
        print("ADAPTIVE_ERROR=1")
        print("ADAPTIVE_REASON=unresolved_thread_expression")
        print("TARGET_INJECTORS=%d" % min_slaves)
        print("ADAPTIVE_ENABLED=0")
        raise SystemExit(0)

    if resolved < 0:
        resolved = 0
    groups.append((target_name, resolved))

if not groups:
    print("ADAPTIVE_ERROR=0")
    print("ADAPTIVE_REASON=no_supported_groups")
    print("TARGET_INJECTORS=%d" % min_slaves)
    print("ADAPTIVE_ENABLED=0")
    raise SystemExit(0)

total_threads = sum(v for _, v in groups)
if total_threads <= 0:
    print("ADAPTIVE_ERROR=0")
    print("ADAPTIVE_REASON=zero_total_threads")
    print("TARGET_INJECTORS=%d" % min_slaves)
    print("ADAPTIVE_ENABLED=0")
    raise SystemExit(0)

required_by_max = 0
if max_threads > 0:
    required_by_max = int(math.ceil(total_threads / float(max_threads)))
target_slaves = max(min_slaves, required_by_max)
if target_slaves < 1:
    target_slaves = 1

allocations = []
group_effective_totals = []
group_breakdown = []
for idx, (_, value) in enumerate(groups, start=1):
    per_slave = int(math.ceil(value / float(target_slaves)))
    allocations.append([per_slave for _ in range(target_slaves)])
    effective_total = per_slave * target_slaves
    group_effective_totals.append(effective_total)
    group_breakdown.append(f"g{idx}:{value}->{per_slave}x{target_slaves}(actual={effective_total})")

effective_total_threads = sum(group_effective_totals)
inflation_ratio_pct = ((effective_total_threads - total_threads) / float(total_threads) * 100.0) if total_threads > 0 else 0.0

os.makedirs(output_dir, exist_ok=True)
for idx in range(target_slaves):
    cloned = copy.deepcopy(root)
    group_index = 0
    for elem in cloned.iter():
        tag = elem.tag
        target_name = None
        if tag == "ThreadGroup":
            target_name = "ThreadGroup.num_threads"
        elif tag == "com.blazemeter.jmeter.threads.concurrency.ConcurrencyThreadGroup":
            target_name = "TargetLevel"
        if not target_name:
            continue
        for child in elem:
            if child.tag == "stringProp" and child.attrib.get("name") == target_name:
                child.text = str(allocations[group_index][idx])
                group_index += 1
                break

    slave_dir = os.path.join(output_dir, f"slave_{idx}")
    os.makedirs(slave_dir, exist_ok=True)
    out_file = os.path.join(slave_dir, os.path.basename(source_jmx))
    ET.ElementTree(cloned).write(out_file, encoding="utf-8", xml_declaration=True)

slave_totals = [sum(group_alloc[i] for group_alloc in allocations) for i in range(target_slaves)]

print("ADAPTIVE_ERROR=0")
print("ADAPTIVE_REASON=ok")
print("ADAPTIVE_ENABLED=1")
print("ADAPTIVE_TOTAL_THREADS=%d" % total_threads)
print("ADAPTIVE_EFFECTIVE_TOTAL_THREADS=%d" % effective_total_threads)
print("ADAPTIVE_INFLATION_RATIO_PCT=%.2f" % inflation_ratio_pct)
print("ADAPTIVE_GROUP_BREAKDOWN=%s" % ";".join(group_breakdown))
print("TARGET_INJECTORS=%d" % target_slaves)
print("ADAPTIVE_SLAVE_TOTALS=%s" % ",".join(str(v) for v in slave_totals))
print("ADAPTIVE_OUTPUT_DIR=%s" % output_dir)
PY
}

###############################################################################
# 4) Compute target slave count and deploy runtime via Helm
###############################################################################
# Recreating each pods via helm
if ! command -v helm >/dev/null 2>&1; then
    logit "ERROR" "helm command not found. Please install helm first."
    exit 1
fi

if [ ! -d "${helm_chart_path}" ]; then
    logit "ERROR" "Helm chart path not found: ${helm_chart_path}"
    exit 1
fi

target_injectors="${min_slaves}"
adaptive_enabled=0
adaptive_total_threads=0
adaptive_effective_total_threads=0
adaptive_inflation_ratio_pct="0.00"
adaptive_reason="disabled"
adaptive_jmx_dir=""
adaptive_slave_totals=""
adaptive_group_breakdown=""

if [ "${max_threads}" -gt 0 ]; then
    adaptive_jmx_dir="$(mktemp -d)"
    while IFS='=' read -r key value; do
        case "${key}" in
            ADAPTIVE_ENABLED) adaptive_enabled="${value}" ;;
            ADAPTIVE_TOTAL_THREADS) adaptive_total_threads="${value}" ;;
            ADAPTIVE_EFFECTIVE_TOTAL_THREADS) adaptive_effective_total_threads="${value}" ;;
            ADAPTIVE_INFLATION_RATIO_PCT) adaptive_inflation_ratio_pct="${value}" ;;
            ADAPTIVE_GROUP_BREAKDOWN) adaptive_group_breakdown="${value}" ;;
            ADAPTIVE_REASON) adaptive_reason="${value}" ;;
            ADAPTIVE_SLAVE_TOTALS) adaptive_slave_totals="${value}" ;;
            TARGET_INJECTORS) target_injectors="${value}" ;;
            ADAPTIVE_OUTPUT_DIR) adaptive_jmx_dir="${value}" ;;
            ADAPTIVE_ERROR)
                if [ "${value}" != "0" ]; then
                    adaptive_enabled=0
                    target_injectors="${min_slaves}"
                    adaptive_reason="error"
                fi
                ;;
        esac
    done < <(generate_scaled_jmx_files "scenario/${jmx_dir}/${jmx}" "${adaptive_jmx_dir}" "${min_slaves}" "${max_threads}" "${scenario_env_file}")
fi

if [ "${adaptive_enabled}" = "1" ]; then
    inflation_prefix="+"
    case "${adaptive_inflation_ratio_pct}" in
        -*) inflation_prefix="" ;;
    esac

    logit "INFO" "Adaptive distribution enabled: total_threads=${adaptive_total_threads}, min_slaves=${min_slaves}, max_threads=${max_threads}, target_slaves=${target_injectors}"
    logit "INFO" "Adaptive summary: slaves=${target_injectors}, inflation=${inflation_prefix}${adaptive_inflation_ratio_pct}% (${adaptive_total_threads} -> ${adaptive_effective_total_threads})"
    logit "INFO" "Adaptive totals: original_total_threads=${adaptive_total_threads}, effective_total_threads=${adaptive_effective_total_threads}, inflation_pct=${adaptive_inflation_ratio_pct}%"
    logit "INFO" "Adaptive group breakdown: ${adaptive_group_breakdown}"
    logit "INFO" "Adaptive per-slave total threads: ${adaptive_slave_totals}"
else
    logit "INFO" "Adaptive distribution disabled: reason=${adaptive_reason}, target_slaves=${target_injectors}"
fi

# Generate one-off runtime values to control slave parallelism and optional
# resource overrides from config/jmeter*.env.
run_values_file="$(mktemp)"
{
    echo "slaves:"
    echo "  parallelism: ${target_injectors}"

    need_global_resources=0
    if [ -n "${JMETER_MASTER_REQUEST_MEMORY}" ] || [ -n "${JMETER_MASTER_REQUEST_CPU}" ] || [ -n "${JMETER_MASTER_LIMIT_MEMORY}" ] || [ -n "${JMETER_MASTER_LIMIT_CPU}" ] || \
       [ -n "${JMETER_SLAVE_REQUEST_MEMORY}" ] || [ -n "${JMETER_SLAVE_REQUEST_CPU}" ] || [ -n "${JMETER_SLAVE_LIMIT_MEMORY}" ] || [ -n "${JMETER_SLAVE_LIMIT_CPU}" ]; then
        need_global_resources=1
    fi

    if [ "${need_global_resources}" -eq 1 ]; then
        echo "global:"
    fi

    if [ -n "${JMETER_MASTER_REQUEST_MEMORY}" ] || [ -n "${JMETER_MASTER_REQUEST_CPU}" ] || [ -n "${JMETER_MASTER_LIMIT_MEMORY}" ] || [ -n "${JMETER_MASTER_LIMIT_CPU}" ]; then
        echo "  master:"
        echo "    resources:"
        echo "      requests:"
        echo "        memory: \"${JMETER_MASTER_REQUEST_MEMORY}\""
        echo "        cpu: \"${JMETER_MASTER_REQUEST_CPU}\""
        echo "      limits:"
        echo "        memory: \"${JMETER_MASTER_LIMIT_MEMORY}\""
        echo "        cpu: \"${JMETER_MASTER_LIMIT_CPU}\""
    fi

    if [ -n "${JMETER_SLAVE_REQUEST_MEMORY}" ] || [ -n "${JMETER_SLAVE_REQUEST_CPU}" ] || [ -n "${JMETER_SLAVE_LIMIT_MEMORY}" ] || [ -n "${JMETER_SLAVE_LIMIT_CPU}" ]; then
        echo "  slave:"
        echo "    resources:"
        echo "      requests:"
        echo "        memory: \"${JMETER_SLAVE_REQUEST_MEMORY}\""
        echo "        cpu: \"${JMETER_SLAVE_REQUEST_CPU}\""
        echo "      limits:"
        echo "        memory: \"${JMETER_SLAVE_LIMIT_MEMORY}\""
        echo "        cpu: \"${JMETER_SLAVE_LIMIT_CPU}\""
    fi
} > "${run_values_file}"

logit "INFO" "Deleting previous jmeter jobs before helm upgrade"
kubectl -n "${namespace}" delete job jmeter-master jmeter-slaves --ignore-not-found >/dev/null 2>&1 || true


# pvc.enabled 預設 true，除非參數指定 false
if [ -z "${pvc_enabled}" ]; then
    pvc_enabled=true
fi

helm_cmd=(
    helm upgrade --install "${helm_release}" "${helm_chart_path}"
    -n "${namespace}"
    --set global.pvc.enabled=${pvc_enabled}
    --set global.master.enabled=true
    --set global.slave.enabled=true
)

if [ "$(kubectl auth can-i create namespaces 2>/dev/null || echo no)" = "yes" ]; then
    helm_cmd+=( --create-namespace )
else
    logit "INFO" "No permission to create namespaces (or not needed); skip --create-namespace"
fi

if [ -f "${helm_env_file}" ]; then
    logit "INFO" "Using helm environment values: ${helm_env_file}"
    helm_cmd+=( -f "${helm_env_file}" )
else
    logit "WARN" "Helm environment file not found: ${helm_env_file} (skipped)"
fi

if [ -f "${project_deploy_values}" ]; then
    logit "INFO" "Using project deploy values: ${project_deploy_values}"
    helm_cmd+=( -f "${project_deploy_values}" )
fi

if [ -f "${runtime_node_selector_values}" ]; then
    logit "INFO" "Using runtime node selector override: ${runtime_node_selector_values}"
    helm_cmd+=( -f "${runtime_node_selector_values}" )
else
    runtime_cm_payload=""
    if runtime_cm_payload=$(kubectl -n "${namespace}" get configmap "${runtime_node_selector_cm_name}" -o jsonpath='{.data.override\.yaml}' 2>/dev/null); then
        if [ -n "${runtime_cm_payload}" ]; then
            runtime_node_selector_values_tmp="$(mktemp)"
            printf '%s\n' "${runtime_cm_payload}" > "${runtime_node_selector_values_tmp}"
            logit "INFO" "Using runtime node selector override from ConfigMap: ${runtime_node_selector_cm_name}"
            helm_cmd+=( -f "${runtime_node_selector_values_tmp}" )
        fi
    fi
fi

helm_cmd+=( -f "${run_values_file}" )

logit "INFO" "Helm command: prepare!"
logit "INFO" "Deploying jmeter resources via helm release=${helm_release}"
# log helm command before執行
logit "INFO" "Helm command: ${helm_cmd[@]}"
if ! "${helm_cmd[@]}"; then
    logit "ERROR" "Helm deploy failed for release=${helm_release}, aborting test startup"
    if [ -n "${runtime_node_selector_values_tmp}" ] && [ -f "${runtime_node_selector_values_tmp}" ]; then
        rm -f "${runtime_node_selector_values_tmp}"
    fi
    rm -f "${run_values_file}"
    exit 1
fi
rm -f "${run_values_file}"
if [ -n "${runtime_node_selector_values_tmp}" ] && [ -f "${runtime_node_selector_values_tmp}" ]; then
    rm -f "${runtime_node_selector_values_tmp}"
fi

###############################################################################
# 5) Wait for runtime readiness and discover pod identities
###############################################################################
logit "INFO" "Waiting for pods to be ready"
end=${target_injectors}
validation_string=""
for ((i=1; i<=end; i++))
do
    validation_string=${validation_string}"True"
done

while [[ $(kubectl -n ${namespace} get pods -l jmeter_mode=slave -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | sed 's/ //g') != "${validation_string}" ]]; do echo "$(kubectl -n ${namespace} get pods -l jmeter_mode=slave )" && sleep 1; done
logit "INFO" "Finish scaling the number of pods."

#Get Master pod details
logit "INFO" "Waiting for master pod to be available"
while [[ $(kubectl -n ${namespace} get pods -l jmeter_mode=master -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do echo "$(kubectl -n ${namespace} get pods -l jmeter_mode=master )" && sleep 1; done

master_pod=$(kubectl get pod -n "${namespace}" | grep jmeter-master | awk '{print $1}')


#Get Slave pod details
slave_pods=($(kubectl get pods -n "${namespace}" | grep jmeter-slave | grep Running | awk '{print $1}'))
slave_num=${#slave_pods[@]}
slave_digit="${#slave_num}"

# jmeter directory in pods
jmeter_directory="/opt/jmeter/apache-jmeter/bin"

logit "Ready to copy files and start the test"
# system properties file (optional)
system_properties_file="scenario/${jmx_dir}/jmeter-system.properties"
system_property_arg=""
if [ -f "${system_properties_file}" ]; then
    logit "INFO" "Found system properties: ${system_properties_file}"
    system_property_arg="-S ${jmeter_directory}/jmeter-system.properties"
else 
    logit "INFO" "No system properties file found in scenario/${jmx_dir}/jmeter-system.properties, skipping copying system properties file"
fi

# -J injection for report properties (optional)
report_props_arg=""
if [ -f "${system_properties_file}" ]; then
    get_prop() {
        grep -E "^[[:space:]]*$1=" "${system_properties_file}" | tail -n 1 | cut -d'=' -f2-
    }
    add_prop_arg() {
        local key="$1"
        local val
        val="$(get_prop "${key}")"
        if [ -n "${val}" ]; then
            report_props_arg="${report_props_arg} -J${key}=${val}"
            logit "INFO" "Using ${key}: ${val}"
        fi
    }

    add_prop_arg "jmeter.reportgenerator.overall_granularity"
    add_prop_arg "jmeter.reportgenerator.apdex_satisfied_threshold"
    add_prop_arg "jmeter.reportgenerator.apdex_tolerated_threshold"
    add_prop_arg "jmeter.save.saveservice.subresults"
fi

# Copying module and config to pods
if [ -n "${module}" ]; then
    logit "INFO" "Using modules (test fragments), uploading them in the pods"
    module_dir="scenario/module"

    logit "INFO" "Number of slaves is ${slave_num}"
    logit "INFO" "Processing directory.. ${module_dir}"

    for modulePath in $(ls ${module_dir}/*.jmx)
    do
        module=$(basename "${modulePath}")

        for ((i=0; i<end; i++))
        do
            printf "Copy %s to %s on %s\n" "${module}" "${jmeter_directory}/${module}" "${slave_pods[$i]}"
            kubectl -n "${namespace}" cp -c jmslave "${modulePath}" "${slave_pods[$i]}":"${jmeter_directory}/${module}" &
        done            
        kubectl -n "${namespace}" cp -c jmmaster "${modulePath}" "${master_pod}":"${jmeter_directory}/${module}" &
    done

    logit "INFO" "Finish copying modules in slave pod"
fi

logit "INFO" "Copying ${jmx} to slaves pods"
logit "INFO" "Number of slaves is ${slave_num}"

# In distributed mode, master testfile is the source plan pushed to all slaves.
# So adaptive thread scaling must also be applied to the JMX copied into master.
master_jmx_source="scenario/${jmx_dir}/${jmx}"
if [ "${adaptive_enabled}" = "1" ] && [ -f "${adaptive_jmx_dir}/slave_0/${jmx}" ]; then
    master_jmx_source="${adaptive_jmx_dir}/slave_0/${jmx}"
fi

for ((i=0; i<end; i++))
do
    slave_jmx_source="scenario/${jmx_dir}/${jmx}"
    if [ "${adaptive_enabled}" = "1" ] && [ -f "${adaptive_jmx_dir}/slave_${i}/${jmx}" ]; then
        slave_jmx_source="${adaptive_jmx_dir}/slave_${i}/${jmx}"
    fi

    logit "INFO" "Copying ${slave_jmx_source} to ${slave_pods[$i]} as ${jmx}"
    kubectl cp -c jmslave "${slave_jmx_source}" -n "${namespace}" "${slave_pods[$i]}:/opt/jmeter/apache-jmeter/bin/${jmx}" &
    if [ -n "${system_property_arg}" ]; then
        logit "INFO" "Copying ${system_properties_file} to ${slave_pods[$i]}"
        kubectl cp -c jmslave "${system_properties_file}" -n "${namespace}" "${slave_pods[$i]}:${jmeter_directory}/jmeter-system.properties" &
    fi
done # for i in "${slave_pods[@]}"
logit "INFO" "Finish copying scenario in slaves pod"

logit "INFO" "Copying ${master_jmx_source} into ${master_pod} as ${jmx}"
kubectl cp -c jmmaster "${master_jmx_source}" -n "${namespace}" "${master_pod}:/opt/jmeter/apache-jmeter/bin/${jmx}" &
if [ -n "${system_property_arg}" ]; then
    logit "INFO" "Copying ${system_properties_file} into ${master_pod}"
    kubectl cp -c jmmaster "${system_properties_file}" -n "${namespace}" "${master_pod}:${jmeter_directory}/jmeter-system.properties" &
fi

###############################################################################
# 7) Build startup scripts, datasets, and launch slave engines
###############################################################################
logit "INFO" "Installing needed plugins on slave pods"
## Starting slave pod 

{
    echo "PLUGIN_INSTALL_MODE=\"${plugin_install_mode}\""
    echo "cd ${jmeter_directory}"
    echo "if [ \"\${PLUGIN_INSTALL_MODE}\" = \"never\" ]; then"
    echo "  echo 'Skip plugin install on slave: mode=never' > plugins-install.out"
    echo "elif [ \"\${PLUGIN_INSTALL_MODE}\" = \"always\" ]; then"
    echo "  if ! sh PluginsManagerCMD.sh install-for-jmx ${jmx} > plugins-install.out 2> plugins-install.err; then"
    echo "    echo 'WARN: plugin install failed on slave (mode=always), continue with bundled plugins' >> plugins-install.err"
    echo "  fi"
    echo "else"
    echo "  if command -v getent >/dev/null 2>&1 && getent hosts jmeter-plugins.org >/dev/null 2>&1; then"
    echo "    if ! sh PluginsManagerCMD.sh install-for-jmx ${jmx} > plugins-install.out 2> plugins-install.err; then"
    echo "      echo 'WARN: plugin install failed on slave (mode=auto), continue with bundled plugins' >> plugins-install.err"
    echo "    fi"
    echo "  else"
    echo "    echo 'Skip plugin install on slave: jmeter-plugins.org DNS not reachable (mode=auto)' > plugins-install.out"
    echo "  fi"
    echo "fi"
    echo "JVM_ARGS=\"${JMETER_SLAVE_JVM_HEAP_ARGS}\""
    echo "export JVM_ARGS"
    echo "jmeter-server -Dserver.rmi.localport=50000 -Dserver_port=1099 -Jserver.rmi.ssl.disable=true ${system_property_arg} >> jmeter-injector.out 2>> jmeter-injector.err &"
    echo "trap 'kill -10 1' EXIT INT TERM"
    echo "java -jar /opt/jmeter/apache-jmeter/lib/jolokia-java-agent.jar start JMeter >> jmeter-injector.out 2>> jmeter-injector.err"
    echo "wait"
} > "scenario/${jmx_dir}/jmeter_injector_start.sh"

# Split dataset CSV by slave count, preserve header in each chunk, and upload.
if [ -n "${csv}" ]; then
    logit "INFO" "Splitting and uploading csv to pods"
    dataset_dir=./scenario/dataset
    split_dir="${dataset_dir}/_split"

    # 每次處理前清空 _split 目錄
    mkdir -p "${split_dir}"
    rm -f "${split_dir}"/*

    for csvfilefull in $(ls ${dataset_dir}/*.csv)
        do
            logit "INFO" "csvfilefull=${csvfilefull}"
            csvfile="${csvfilefull##*/}"
            logit "INFO" "Processing file.. $csvfile"

            header_line="$(head -n 1 "${csvfilefull}")"

            # 排除首行標題，避免進入分割
            tmp_csv="$(mktemp)"
            tail -n +2 "${csvfilefull}" > "${tmp_csv}"

            logit "INFO" "Shuffling data rows before split"
            shuf -o "${tmp_csv}" "${tmp_csv}"

            logit "INFO" "split (exclude header) into ${slave_num} parts"
            split -n l/${slave_num} -d -a "${slave_digit}" "${tmp_csv}" "${split_dir}/${csvfile}"
            rm -f "${tmp_csv}"

            for ((i=0; i<end; i++))
            do
                if [ ${slave_digit} -eq 2 ] && [ ${i} -lt 10 ]; then
                    j=0${i}
                elif [ ${slave_digit} -eq 2 ] && [ ${i} -ge 10 ]; then
                    j=${i}
                elif [ ${slave_digit} -eq 3 ] && [ ${i} -lt 10 ]; then
                    j=00${i}
                elif [ ${slave_digit} -eq 3 ] && [ ${i} -ge 10 ]; then
                    j=0${i}
                elif [ ${slave_digit} -eq 3 ] && [ ${i} -ge 100 ]; then
                    j=${i}
                else 
                    j=${i}                    
                fi

                chunk_file="${split_dir}/${csvfile}${j}"
                if [ -f "${chunk_file}" ]; then
                    { printf '%s\n' "${header_line}"; cat "${chunk_file}"; } > "${chunk_file}.tmp" && mv "${chunk_file}.tmp" "${chunk_file}"
                fi

                printf "Copy %s to %s on %s\n" "${chunk_file}" "${csvfile}" "${slave_pods[$i]}"
                kubectl -n "${namespace}" cp -c jmslave "${chunk_file}" "${slave_pods[$i]}":"${jmeter_directory}/${csvfile}" &
            done
    done
fi

wait

for ((i=0; i<end; i++))
do
        logit "INFO" "Starting jmeter server on ${slave_pods[$i]} in parallel"
        kubectl cp -c jmslave "scenario/${jmx_dir}/jmeter_injector_start.sh" -n "${namespace}" "${slave_pods[$i]}:/opt/jmeter/jmeter_injector_start"
        kubectl exec -c jmslave -i -n "${namespace}" "${slave_pods[$i]}" -- /bin/bash "/opt/jmeter/jmeter_injector_start" &  
done


slave_list=$(kubectl -n ${namespace} describe endpoints jmeter-slaves-svc | grep ' Addresses' | awk -F" " '{print $2}')
logit "INFO" "JMeter slave list : ${slave_list}"
slave_array=($(echo ${slave_list} | sed 's/,/ /g'))


###############################################################################
# 8) Build master load_test script and launch distributed test
###############################################################################
## Starting Jmeter load test
# .env was already preprocessed/sourced before adaptive slave calculation.

# Function to build JMeter global parameters from scenario .env.
# This keeps original property names (e.g. td-1) so __P(td-1,...) works.
build_jmeter_global_params() {
    local all_params=""

    if [ -f "${scenario_env_file}" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            if [[ "$line" =~ ^[[:space:]]*# ]] || [[ -z "$line" ]]; then
                continue
            fi

            if [[ "$line" =~ ^[[:space:]]*([^=]+)[[:space:]]*=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                key=$(echo "$key" | xargs)
                value=$(echo "$value" | sed 's/[[:space:]]*$//')

                if [ -n "${value}" ]; then
                    local param="-G${key}=${value}"
                    all_params="${all_params} ${param}"
                    logit "INFO" "Global parameter: ${param}"
                fi
            fi
        done < "${scenario_env_file}"
    fi

    param_all="${all_params}"
}

# Build global parameters from .env file
build_jmeter_global_params

report_enabled=0
if [ -n "${enable_report}" ]; then
    report_enabled=1
    report_command_line="--reportatendofloadtests --reportoutputfolder /report/${jmx_dir}/report-${jmx}-\$(date +\"%F_%H%M%S\")"
fi

echo "slave_array=(${slave_array[@]}); index=${slave_num} && while [ \${index} -gt 0 ]; do for slave in \${slave_array[@]}; do if echo 'test open port' 2>/dev/null > /dev/tcp/\${slave}/1099; then echo \${slave}' ready' && slave_array=(\${slave_array[@]/\${slave}/}); index=\$((index-1)); else echo \${slave}' not ready'; fi; done; echo 'Waiting for slave readiness'; sleep 2; done" > "scenario/${jmx_dir}/load_test.sh"

{
    echo "REPORT_ENABLED=${report_enabled}"
    printf 'REPORT_ENV=%q\n' "${report_env}"
    printf 'REPORT_VERSIONS=%q\n' "${report_versions}"
    printf 'REPORT_NOTE=%q\n' "${report_note}"

    echo "report_ts=\$(date +\"%F_%H%M%S\")"
    echo "report_dir=\"/report/${jmx_dir}/report-${jmx}-\${report_ts}\""

    echo "echo \"[DEBUG] report_ts=\${report_ts}\""
    echo "echo \"[DEBUG] report_dir=\${report_dir}\""

    echo "echo \"Installing needed plugins for master\""
    echo "cd /opt/jmeter/apache-jmeter/bin"
    echo "if [ \"${plugin_install_mode}\" = \"never\" ]; then"
    echo "  echo 'Skip plugin install on master: mode=never' > plugins-install.out"
    echo "elif [ \"${plugin_install_mode}\" = \"always\" ]; then"
    echo "  if ! sh PluginsManagerCMD.sh install-for-jmx ${jmx} > plugins-install.out 2> plugins-install.err; then"
    echo "    echo 'WARN: plugin install failed on master (mode=always), continue with bundled plugins' >> plugins-install.err"
    echo "  fi"
    echo "else"
    echo "  if command -v getent >/dev/null 2>&1 && getent hosts jmeter-plugins.org >/dev/null 2>&1; then"
    echo "    if ! sh PluginsManagerCMD.sh install-for-jmx ${jmx} > plugins-install.out 2> plugins-install.err; then"
    echo "      echo 'WARN: plugin install failed on master (mode=auto), continue with bundled plugins' >> plugins-install.err"
    echo "    fi"
    echo "  else"
    echo "    echo 'Skip plugin install on master: jmeter-plugins.org DNS not reachable (mode=auto)' > plugins-install.out"
    echo "  fi"
    echo "fi"
    echo "echo \"Done installing plugins, launching test\""
    echo "mkdir -p /report/${jmx_dir}"
    echo "JVM_ARGS=\"${JMETER_MASTER_JVM_HEAP_ARGS}\""
    echo "export JVM_ARGS"
    echo "jmeter ${param_all} --reportatendofloadtests --reportoutputfolder \${report_dir} ${report_props_arg} ${system_property_arg} --logfile /report/${jmx_dir}/${jmx}_\${report_ts}.jtl --nongui --testfile ${jmx} -Dserver.rmi.ssl.disable=true --remoteexit --remotestart ${slave_list} >> jmeter-master.out 2>> jmeter-master.err &"
    echo "trap 'kill -10 1' EXIT INT TERM"
    echo "java -jar /opt/jmeter/apache-jmeter/lib/jolokia-java-agent.jar start JMeter >> jmeter-master.out 2>> jmeter-master.err"
    echo "echo \"Starting load test at : \$(date)\" && wait"

    echo "if [ \"\${REPORT_ENABLED}\" = \"1\" ]; then"
    echo "  index_file=\"\${report_dir}/index.html\""
    echo "  echo \"[DEBUG] index_file=\${index_file}\""
    echo "  if [ -f \"\${index_file}\" ]; then"
    echo "    html_escape() { awk '{gsub(/&/,\"&amp;\"); gsub(/</,\"&lt;\"); gsub(/>/,\"&gt;\"); gsub(/\\\"/,\"&quot;\"); gsub(/\\047/,\"&#39;\"); printf \"%s\", \$0 }'; }"
    echo "    env_val=\$(printf '%s' \"\${REPORT_ENV}\" | html_escape)"
    echo "    ver_val=\$(printf '%s' \"\${REPORT_VERSIONS}\" | html_escape)"
    echo "    note_val=\$(printf '%s' \"\${REPORT_NOTE}\" | html_escape | awk 'BEGIN{RS=\"\"; ORS=\"\"} {gsub(/\\n/,\"<br/>\"); print}')"
    echo "    echo \"[DEBUG] env_val=\${env_val}\""
    echo "    echo \"[DEBUG] ver_val=\${ver_val}\""
    echo "    echo \"[DEBUG] note_val_len=\$(printf '%s' \"\${note_val}\" | wc -c)\""
    echo "    [ -z \"\${env_val}\" ] && env_val=\"(empty)\""
    echo "    [ -z \"\${ver_val}\" ] && ver_val=\"(empty)\""
    echo "    [ -z \"\${note_val}\" ] && note_val=\"(empty)\""
    echo "    inject_file=\$(mktemp)"
    echo "    echo \"[DEBUG] inject_file=\${inject_file}\""
    echo "    cat > \"\${inject_file}\" <<HTML"
    echo "<div class=\"row\">"
    echo "  <div class=\"col-lg-12\">"
    echo "    <div class=\"panel panel-default\">"
    echo "      <div class=\"panel-heading\" style=\"text-align:center;\">"
    echo "        <p class=\"dashboard-title\">Custom Test Metadata</p>"
    echo "      </div>"
    echo "      <div class=\"panel-body\">"
    echo "        <table class=\"table table-bordered table-condensed\">"
    echo "          <tr><td>Environment</td><td>\${env_val}</td></tr>"
    echo "          <tr><td>App Versions</td><td>\${ver_val}</td></tr>"
    echo "          <tr><td>Notes</td><td>\${note_val}</td></tr>"
    echo "        </table>"
    echo "      </div>"
    echo "    </div>"
    echo "  </div>"
    echo "</div>"
    echo "HTML"
    echo "    echo \"[DEBUG] inject_file_size=\$(wc -c < \"\${inject_file}\")\""
    echo "    tmp_index=\$(mktemp)"
    echo "    echo \"[DEBUG] tmp_index=\${tmp_index}\""
    echo "    awk -v inj=\"\${inject_file}\" 'BEGIN{while((getline l<inj)>0) buf=buf l \"\\n\"; close(inj)} {print} /<div id=\"page-wrapper\"[^>]*>/{printf \"%s\", buf}' \"\${index_file}\" > \"\${tmp_index}\""
    echo "    mv \"\${tmp_index}\" \"\${index_file}\""
    echo "    chmod 644 \"\${index_file}\""
    echo "    echo \"[DEBUG] injected into \${index_file}\""
    echo "    rm -f \"\${inject_file}\""
    echo "  else"
    echo "    echo \"[DEBUG] index.html not found\""
    echo "  fi"
    echo "fi"
} >> "scenario/${jmx_dir}/load_test.sh"

logit "INFO" "Copying scenario/${jmx_dir}/load_test.sh into  ${master_pod}:/opt/jmeter/load_test"
kubectl cp -c jmmaster "scenario/${jmx_dir}/load_test.sh" -n "${namespace}" "${master_pod}:/opt/jmeter/load_test"

logit "INFO" "Starting the performance test"
logit "INFO" "##################################################"
logit "INFO" "You can follow test execution summary on the master pod by running :"
logit "INFO" "         kubectl logs -f -c jmmaster -n ${namespace} ${master_pod}"
logit "INFO" "##################################################"
logit "INFO" "Also using Grafana : kubectl ${namespace} port-forward svc/grafana 8443:443"
GRAFANA_LOGIN=$(kubectl -n "${namespace}" get secret grafana-creds -o yaml | grep GF_SECURITY_ADMIN_USER: | awk -F" " '{print $2}' | base64 --decode)
GRAFANA_PASSWORD=$(kubectl -n "${namespace}" get secret grafana-creds -o yaml | grep GF_SECURITY_ADMIN_PASSWORD: | awk -F" " '{print $2}' | base64 --decode)
logit "INFO" " LOGIN : ${GRAFANA_LOGIN}"
logit "INFO" " PASSWORD : ${GRAFANA_PASSWORD}"
logit "INFO" "################################################"

# Cleanup temporary adaptive artifacts generated for per-slave JMX.
if [ -n "${adaptive_jmx_dir}" ] && [ -d "${adaptive_jmx_dir}" ]; then
    rm -rf "${adaptive_jmx_dir}"
fi

