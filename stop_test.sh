#!/usr/bin/env bash

usage()
{
	echo "Usage: ./stop_test.sh [-n <namespace>]"
	echo "  -n, --namespace   Namespace where jmeter-master pod is running (default: default)"
	exit 1
}

namespace=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		-n|--namespace)
			if [[ -z "$2" || "$2" == -* ]]; then
				echo "[ERROR] Missing value for $1"
				usage
			fi
			namespace="$2"
			shift 2
			;;
		-h|--help)
			usage
			;;
		*)
			echo "[ERROR] Unknown option: $1"
			usage
			;;
	esac
done

if [[ -z "${namespace}" ]]; then
	namespace="default"
	echo "[INFO] Namespace not provided, using default namespace: ${namespace}"
fi

master_pod=$(kubectl get pod -n "${namespace}" | grep jmeter-master | awk '{print $1}')

if [[ -z "${master_pod}" ]]; then
	echo "[ERROR] No jmeter-master pod found in namespace: ${namespace}"
	exit 1
fi

kubectl -n "${namespace}" exec -c jmmaster -ti "${master_pod}" -- bash /opt/jmeter/apache-jmeter/bin/stoptest.sh
