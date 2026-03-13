from pathlib import Path
import os


def _detect_repo_root() -> Path:
	env_root = os.getenv("JMETER_K8S_REPO_ROOT")
	if env_root:
		return Path(env_root).resolve()

	docker_root = Path("/workspace")
	if (docker_root / "start_test.sh").exists():
		return docker_root

	return Path(__file__).resolve().parents[3]


REPO_ROOT = _detect_repo_root()

START_SCRIPT = REPO_ROOT / "start_test.sh"
STOP_SCRIPT = REPO_ROOT / "stop_test.sh"

SCENARIO_DIR = REPO_ROOT / "scenario"
SCENARIO_TEMPLATE_DIR = SCENARIO_DIR / "_template"
PROJECT_TEMPLATE_FALLBACK_DIR = REPO_ROOT / "webapp" / "app" / "project_template_defaults"
DATASET_DIR = SCENARIO_DIR / "dataset"
REPORT_DIR = REPO_ROOT / "report"
CONFIG_DIR = REPO_ROOT / "config"
HELM_ENV_DIR = REPO_ROOT / "k8s" / "helm" / "environments"
