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
  exit 1
}

### Parsing the arguments ###
while getopts 'i:mj:hcrn:' option;
    do
      case $option in
        n	)	namespace=${OPTARG}   ;;
        c   )   csv=1 ;;
        m   )   module=1 ;;
        r   )   enable_report=1 ;;
        j   )   jmx=${OPTARG} ;;
        i   )   nb_injectors=${OPTARG} ;;
        h   )   usage ;;
        ?   )   usage ;;
      esac
done

if [ "$#" -eq 0 ]
  then
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

if [ ! -f "scenario/${jmx_dir}/${jmx}" ]; then
    logit "ERROR" "Test script file was not found in scenario/${jmx_dir}/${jmx}"
    usage
fi

# Load JMeter resource env vars
if [ -f "${PWD}/config/jmeter.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "${PWD}/config/jmeter.env"
    set +a
else
    logit "WARN" "Missing config/jmeter.env; resources placeholders may not be substituted"
fi

# Recreating each pods
logit "INFO" "Recreating pod set"
kubectl -n "${namespace}" delete -f k8s/jmeter/jmeter-master.yaml -f k8s/jmeter/jmeter-slave.yaml 2> /dev/null

tmp_master="$(mktemp)"
tmp_slave="$(mktemp)"
envsubst < k8s/jmeter/jmeter-master.yaml > "${tmp_master}"
envsubst < k8s/jmeter/jmeter-slave.yaml > "${tmp_slave}"
kubectl -n "${namespace}" apply -f "${tmp_master}" -f "${tmp_slave}"
rm -f "${tmp_master}" "${tmp_slave}"

kubectl -n "${namespace}" patch job jmeter-slaves -p '{"spec":{"parallelism":0}}'
logit "INFO" "Waiting for all slaves pods to be terminated before recreating the pod set"
while [[ $(kubectl -n ${namespace} get pods -l jmeter_mode=slave -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "" ]]; do echo "$(kubectl -n ${namespace} get pods -l jmeter_mode=slave )" && sleep 1; done

# Starting jmeter slave pod 
if [ -z "${nb_injectors}" ]; then
    logit "WARNING" "Keeping number of injector to 1"
    kubectl -n "${namespace}" patch job jmeter-slaves -p '{"spec":{"parallelism":1}}'
else
    logit "INFO" "Scaling the number of pods to ${nb_injectors}. "
    kubectl -n "${namespace}" patch job jmeter-slaves -p '{"spec":{"parallelism":'${nb_injectors}'}}'
    logit "INFO" "Waiting for pods to be ready"

    end=${nb_injectors}
    for ((i=1; i<=end; i++))
    do
        validation_string=${validation_string}"True"
    done

    while [[ $(kubectl -n ${namespace} get pods -l jmeter_mode=slave -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}' | sed 's/ //g') != "${validation_string}" ]]; do echo "$(kubectl -n ${namespace} get pods -l jmeter_mode=slave )" && sleep 1; done
    logit "INFO" "Finish scaling the number of pods."
fi

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
            split -n l/${slave_num} -d -a "${slave_digit}" "${tmp_csv}" "${csvfilefull}"
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

                chunk_file="${csvfilefull}${j}"
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
source "scenario/${jmx_dir}/.env"

param_host="-Ghost=${host} -Gport=${port} -Gprotocol=${protocol}"
param_test="-GtimeoutConnect=${timeoutConnect} -GtimeoutResponse=${timeoutResponse}"
param_user="-Gthreads=${threads} -Gduration=${duration} -Grampup=${rampup}"


if [ -n "${enable_report}" ]; then
    report_command_line="--reportatendofloadtests --reportoutputfolder /report/${jmx_dir}/report-${jmx}-$(date +"%F_%H%M%S")"
fi

echo "slave_array=(${slave_array[@]}); index=${slave_num} && while [ \${index} -gt 0 ]; do for slave in \${slave_array[@]}; do if echo 'test open port' 2>/dev/null > /dev/tcp/\${slave}/1099; then echo \${slave}' ready' && slave_array=(\${slave_array[@]/\${slave}/}); index=\$((index-1)); else echo \${slave}' not ready'; fi; done; echo 'Waiting for slave readiness'; sleep 2; done" > "scenario/${jmx_dir}/load_test.sh"

{ 
    echo "echo \"Installing needed plugins for master\""
    echo "cd /opt/jmeter/apache-jmeter/bin" 
    echo "sh PluginsManagerCMD.sh install-for-jmx ${jmx}" 
    echo "echo \"Done installing plugins, launching test\""
    echo "mkdir -p /report/${jmx_dir}"
    echo "JVM_ARGS=\"${JMETER_MASTER_JVM_HEAP_ARGS}\""
    echo "export JVM_ARGS"
    echo "jmeter ${param_host} ${param_user} ${report_command_line} ${report_props_arg} ${system_property_arg} --logfile /report/${jmx_dir}/${jmx}_$(date +"%F_%H%M%S").jtl --nongui --testfile ${jmx} -Dserver.rmi.ssl.disable=true --remoteexit --remotestart ${slave_list} >> jmeter-master.out 2>> jmeter-master.err &"
    echo "trap 'kill -10 1' EXIT INT TERM"
    echo "java -jar /opt/jmeter/apache-jmeter/lib/jolokia-java-agent.jar start JMeter >> jmeter-master.out 2>> jmeter-master.err"
    echo "echo \"Starting load test at : $(date)\" && wait"
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

