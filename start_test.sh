#!/usr/bin/env bash

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
  logit "INFO" "-i <injectorNumber> to scale slaves pods to the desired number of JMeter injectors"
  logit "INFO" "-r flag to enable report generation at the end of the test"
  logit "INFO" "-E <env> test environment (e.g. prod/uat/sit/pt)"
  logit "INFO" "-V <versions> app versions, ';' separated (e.g. tip-web=1.0.1;gemfire=2.2.3)"
  logit "INFO" "-N <note> free-form notes"
    logit "INFO" "-F <file> meta env file (REPORT_ENV/REPORT_VERSIONS/REPORT_NOTE)"
    logit "INFO" "--helm-env <name> helm env values name under k8s/helm/environments (default: lab)"
    logit "INFO" "--helm-release <name> helm release name for jmeter chart (default: jmeter-runtime)"
    logit "INFO" "--helm-chart <path> helm chart path for jmeter resources (default: k8s/helm/charts/jmeter)"
        logit "INFO" "--jmeter-env-file <path> explicit env file for JVM/resource overrides"
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

### Parsing the arguments ###
while [[ $# -gt 0 ]]; do
  seen_args=1
  case "$1" in
    -n) namespace="$2"; shift 2 ;;
    -c) csv=1; shift ;;
    -m) module=1; shift ;;
    -r) enable_report=1; shift ;;
    -j) jmx="$2"; shift 2 ;;
    -i) nb_injectors="$2"; shift 2 ;;
    -E) report_env="$2"; shift 2 ;;
    -V) report_versions="$2"; shift 2 ;;
    -N) report_note="$2"; shift 2 ;;
        --helm-env) helm_env="$2"; shift 2 ;;
        --helm-release) helm_release="$2"; shift 2 ;;
        --helm-chart) helm_chart_path="$2"; shift 2 ;;
        --jmeter-env-file) jmeter_env_file_override="$2"; shift 2 ;;
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

# 檢查 report-server 與 PVC 是否在同一 namespace
if ! kubectl -n "${namespace}" get pvc jmeter-data-dir-pvc >/dev/null 2>&1; then
    logit "WARN" "PVC jmeter-data-dir-pvc 不在 namespace=${namespace}，報表可能無法被 report-server 讀取"
fi
if ! kubectl -n "${namespace}" get deploy report-server >/dev/null 2>&1; then
    logit "WARN" "report-server 不在 namespace=${namespace}，report.example.com 可能讀不到報表"
fi

jmx_dir="${jmx%%.*}"
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

            # Add JMETERTEST_ prefix to variable name
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

# Function to preprocess report-meta.env file by adding JMETERREPORT_ prefix to variables
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

helm_env_file="${PWD}/k8s/helm/environments/${helm_env}.yaml"
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

# Recreating each pods via helm
if ! command -v helm >/dev/null 2>&1; then
    logit "ERROR" "helm command not found. Please install helm first."
    exit 1
fi

if [ ! -d "${helm_chart_path}" ]; then
    logit "ERROR" "Helm chart path not found: ${helm_chart_path}"
    exit 1
fi

target_injectors="${nb_injectors}"
if [ -z "${target_injectors}" ]; then
    target_injectors=1
    logit "WARN" "Injector number not provided, default to 1"
fi

run_values_file="$(mktemp)"
{
    echo "slaves:"
    echo "  parallelism: ${target_injectors}"

    if [ -n "${JMETER_MASTER_REQUEST_MEMORY}" ] || [ -n "${JMETER_MASTER_REQUEST_CPU}" ] || [ -n "${JMETER_MASTER_LIMIT_MEMORY}" ] || [ -n "${JMETER_MASTER_LIMIT_CPU}" ]; then
        echo "master:"
        echo "  resources:"
        echo "    requests:"
        echo "      memory: \"${JMETER_MASTER_REQUEST_MEMORY}\""
        echo "      cpu: \"${JMETER_MASTER_REQUEST_CPU}\""
        echo "    limits:"
        echo "      memory: \"${JMETER_MASTER_LIMIT_MEMORY}\""
        echo "      cpu: \"${JMETER_MASTER_LIMIT_CPU}\""
    fi

    if [ -n "${JMETER_SLAVE_REQUEST_MEMORY}" ] || [ -n "${JMETER_SLAVE_REQUEST_CPU}" ] || [ -n "${JMETER_SLAVE_LIMIT_MEMORY}" ] || [ -n "${JMETER_SLAVE_LIMIT_CPU}" ]; then
        echo "slave:"
        echo "  resources:"
        echo "    requests:"
        echo "      memory: \"${JMETER_SLAVE_REQUEST_MEMORY}\""
        echo "      cpu: \"${JMETER_SLAVE_REQUEST_CPU}\""
        echo "    limits:"
        echo "      memory: \"${JMETER_SLAVE_LIMIT_MEMORY}\""
        echo "      cpu: \"${JMETER_SLAVE_LIMIT_CPU}\""
    fi
} > "${run_values_file}"

logit "INFO" "Deleting previous jmeter jobs before helm upgrade"
kubectl -n "${namespace}" delete job jmeter-master jmeter-slaves --ignore-not-found >/dev/null 2>&1 || true

helm_cmd=(
    helm upgrade --install "${helm_release}" "${helm_chart_path}"
    -n "${namespace}" --create-namespace
)

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

helm_cmd+=( -f "${run_values_file}" )

logit "INFO" "Deploying jmeter resources via helm release=${helm_release}"
if ! "${helm_cmd[@]}"; then
    logit "ERROR" "Helm deploy failed for release=${helm_release}, aborting test startup"
    rm -f "${run_values_file}"
    exit 1
fi
rm -f "${run_values_file}"

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

for ((i=0; i<end; i++))
do
    logit "INFO" "Copying scenario/${jmx_dir}/${jmx} to ${slave_pods[$i]}"
    kubectl cp -c jmslave "scenario/${jmx_dir}/${jmx}" -n "${namespace}" "${slave_pods[$i]}:/opt/jmeter/apache-jmeter/bin/" &
    if [ -n "${system_property_arg}" ]; then
        logit "INFO" "Copying ${system_properties_file} to ${slave_pods[$i]}"
        kubectl cp -c jmslave "${system_properties_file}" -n "${namespace}" "${slave_pods[$i]}:${jmeter_directory}/jmeter-system.properties" &
    fi
done # for i in "${slave_pods[@]}"
logit "INFO" "Finish copying scenario in slaves pod"

logit "INFO" "Copying scenario/${jmx_dir}/${jmx} into ${master_pod}"
kubectl cp -c jmmaster "scenario/${jmx_dir}/${jmx}" -n "${namespace}" "${master_pod}:/opt/jmeter/apache-jmeter/bin/" &
if [ -n "${system_property_arg}" ]; then
    logit "INFO" "Copying ${system_properties_file} into ${master_pod}"
    kubectl cp -c jmmaster "${system_properties_file}" -n "${namespace}" "${master_pod}:${jmeter_directory}/jmeter-system.properties" &
fi

logit "INFO" "Installing needed plugins on slave pods"
## Starting slave pod 

{
    echo "cd ${jmeter_directory}"
    echo "sh PluginsManagerCMD.sh install-for-jmx ${jmx} > plugins-install.out 2> plugins-install.err"
    echo "JVM_ARGS=\"${JMETER_SLAVE_JVM_HEAP_ARGS}\""
    echo "export JVM_ARGS"
    echo "jmeter-server -Dserver.rmi.localport=50000 -Dserver_port=1099 -Jserver.rmi.ssl.disable=true ${system_property_arg} >> jmeter-injector.out 2>> jmeter-injector.err &"
    echo "trap 'kill -10 1' EXIT INT TERM"
    echo "java -jar /opt/jmeter/apache-jmeter/lib/jolokia-java-agent.jar start JMeter >> jmeter-injector.out 2>> jmeter-injector.err"
    echo "wait"
} > "scenario/${jmx_dir}/jmeter_injector_start.sh"

# Copying dataset on slave pods
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


## Starting Jmeter load test
# Preprocess .env file to add JMETERTEST_ prefix to avoid variable pollution
preprocess_env_file "scenario/${jmx_dir}/.env"
if [ -n "${PREPROCESSED_ENV_FILE}" ] && [ -f "${PREPROCESSED_ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${PREPROCESSED_ENV_FILE}"
    set +a
    rm -f "${PREPROCESSED_ENV_FILE}"
else
    logit "WARN" "Preprocessed env file unavailable, fallback to source original .env"
    source "scenario/${jmx_dir}/.env"
fi

# Function to build JMeter global parameters from JMETERTEST_ prefixed environment variables
build_jmeter_global_params() {
    local all_params=""

    # Iterate through all environment variables that start with JMETERTEST_
    for var in $(env | grep '^JMETERTEST_' | cut -d'=' -f1); do
        # Remove JMETERTEST_ prefix to get the JMeter variable name
        local jmeter_var="${var#JMETERTEST_}"
        # Get the value of the variable
        local var_value="${!var}"

        if [ -n "${var_value}" ]; then
            # Build JMeter parameter
            local param="-G${jmeter_var}=${var_value}"
            all_params="${all_params} ${param}"
            logit "INFO" "Global parameter: ${param}"
        fi
    done

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
    echo "sh PluginsManagerCMD.sh install-for-jmx ${jmx}"
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

