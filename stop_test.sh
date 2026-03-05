#!/usr/bin/env bash

usage()
{
	echo "Usage: ./stop_test.sh [-n <namespace>] [-R <release>] [-u]"
	echo "  -n, --namespace   Namespace where jmeter-master pod is running (default: default)"
	echo "  -R, --helm-release Helm release name for jmeter runtime (default: jmeter-runtime)"
	echo "  -u, --helm-uninstall Uninstall helm release after stop test"
	exit 1
}

namespace=""
helm_release="jmeter-runtime"
helm_uninstall=0

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
		-R|--helm-release)
			if [[ -z "$2" || "$2" == -* ]]; then
				echo "[ERROR] Missing value for $1"
				usage
			fi
			helm_release="$2"
			shift 2
			;;
		-u|--helm-uninstall)
			helm_uninstall=1
			shift
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
	if [[ "${helm_uninstall}" -eq 1 ]]; then
		echo "[WARN] No jmeter-master pod found in namespace: ${namespace}, skip stoptest and continue helm uninstall"
	else
	    echo "[ERROR] No jmeter-master pod found in namespace: ${namespace}"
	    exit 1
	fi
else
	kubectl -n "${namespace}" exec -c jmmaster -ti "${master_pod}" -- bash /opt/jmeter/apache-jmeter/bin/stoptest.sh
fi

if [[ "${helm_uninstall}" -eq 1 ]]; then
	if ! command -v helm >/dev/null 2>&1; then
		echo "[ERROR] helm command not found, cannot uninstall release ${helm_release}"
		exit 1
	fi

	echo "[INFO] Uninstalling helm release ${helm_release} in namespace ${namespace}"
	helm uninstall "${helm_release}" -n "${namespace}" || {
		echo "[ERROR] Failed to uninstall helm release ${helm_release} in namespace ${namespace}"
		exit 1
	}
fi
