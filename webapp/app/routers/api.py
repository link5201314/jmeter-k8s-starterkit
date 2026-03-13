from __future__ import annotations
import hashlib
import json
import re
import subprocess
import zipfile
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, Request
from fastapi.responses import FileResponse

from webapp.app.core.config import (
    CONFIG_DIR,
    DATASET_DIR,
    HELM_ENV_DIR,
    PROJECT_TEMPLATE_FALLBACK_DIR,
    REPO_ROOT,
    REPORT_DIR,
    SCENARIO_DIR,
    SCENARIO_TEMPLATE_DIR,
    START_SCRIPT,
    STOP_SCRIPT,
)
from webapp.app.services.file_service import ensure_subpath, read_text, write_text
from webapp.app.services.process_service import get_jobs_status, run_background
from webapp.app.services.report_service import make_report_zip, make_reports_zip, discover_reports
from webapp.app.services.auth_service import (
    require_authenticated,
    require_drive_tests,
    can_manage_users,
    require_manage_configs,
    require_manage_projects,
)
from webapp.app.services.db_restore_service import (
    build_preview_request,
    get_flashback_endpoint,
    list_restore_envs,
    load_env_token,
)

router = APIRouter(prefix="/api", dependencies=[Depends(require_authenticated)])

@router.get("/helm-envs", summary="List available helm environment yaml files")
def list_helm_envs():
    env_dir = HELM_ENV_DIR
    if not env_dir.exists() or not env_dir.is_dir():
        return {"files": []}
    files = [f.name for f in env_dir.iterdir() if f.is_file() and f.suffix == ".yaml" and "webapp-bootstrap-admin-secret" not in f.stem]
    return {"files": sorted(files)}

_MAX_BATCH_REPORT_DOWNLOAD = 100
_UPLOAD_OWNER_STORE = REPO_ROOT / "webapp" / "data" / "upload_owners.json"
_PROJECT_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
_PROJECT_TEMPLATE_FILES = (".env", "jmeter-system.properties", "report-meta.env")


def require_config_management(request: Request) -> dict:
    return require_manage_configs(request)


def require_project_management(request: Request) -> dict:
    return require_manage_projects(request)


def _list_projects() -> list[str]:
    if not SCENARIO_DIR.exists():
        return []
    result: list[str] = []
    for path in sorted(SCENARIO_DIR.iterdir()):
        if not path.is_dir():
            continue
        if path.name.startswith("_"):
            continue
        if path.name in {"dataset", "module"}:
            continue
        result.append(path.name)
    return result


def _safe_project_file(project: str, filename: str) -> Path:
    project_dir = SCENARIO_DIR / project
    file_path = ensure_subpath(project_dir, project_dir / filename)
    return file_path


def _validate_project_name(name: str) -> str:
    project_name = (name or "").strip()
    if not project_name:
        raise HTTPException(400, "project name is required")
    if not _PROJECT_NAME_PATTERN.fullmatch(project_name):
        raise HTTPException(400, "project name format invalid: only letters/numbers/._- and max length 64")
    if project_name.startswith("_"):
        raise HTTPException(400, "project name cannot start with '_' ")
    if project_name in {"dataset", "module", "_template"}:
        raise HTTPException(400, f"project name '{project_name}' is reserved")
    return project_name


def _resolve_template_file(filename: str) -> tuple[Path | None, str]:
    primary = SCENARIO_TEMPLATE_DIR / filename
    if primary.exists() and primary.is_file():
        return primary, "scenario/_template"

    fallback = PROJECT_TEMPLATE_FALLBACK_DIR / filename
    if fallback.exists() and fallback.is_file():
        return fallback, "webapp built-in defaults"

    return None, ""


def _safe_jmeter_env_file(env: str) -> Path:
    env_name = (env or "").strip()
    if not env_name:
        raise HTTPException(400, "env is required")
    return ensure_subpath(CONFIG_DIR, CONFIG_DIR / f"jmeter.{env_name}.env")


def _path_modified_text(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return ""
    return datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")


def _file_md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tail_text(path: Path, lines: int) -> str:
    if not path.exists() or not path.is_file():
        return ""
    with path.open("r", encoding="utf-8", errors="replace") as fp:
        content_lines = fp.readlines()
    return "".join(content_lines[-max(1, lines):])


def _dataset_matches_project(filename: str, selected_project: str, projects: list[str]) -> bool:
    if selected_project == "Others":
        return not any(filename.startswith(f"{name}_") for name in projects)
    return filename.startswith(f"{selected_project}_")


def _safe_date_text(value: str) -> str:
    return value.strip() if value else ""


def _parse_filter_dates(start_date: str, end_date: str) -> tuple[datetime | None, datetime | None, str, str]:
    selected_start_date = _safe_date_text(start_date)
    selected_end_date = _safe_date_text(end_date)
    start_at = None
    end_at = None

    if selected_start_date:
        try:
            start_at = datetime.strptime(selected_start_date, "%Y-%m-%d")
        except ValueError as exc:
            raise HTTPException(400, "start_date 格式錯誤，需為 YYYY-MM-DD") from exc

    if selected_end_date:
        try:
            end_at = datetime.strptime(selected_end_date, "%Y-%m-%d")
            end_at = end_at.replace(hour=23, minute=59, second=59)
        except ValueError as exc:
            raise HTTPException(400, "end_date 格式錯誤，需為 YYYY-MM-DD") from exc

    if start_at and end_at and start_at > end_at:
        raise HTTPException(400, "開始日期不可晚於結束日期")

    return start_at, end_at, selected_start_date, selected_end_date


def _read_upload_owner_store() -> dict:
    if not _UPLOAD_OWNER_STORE.exists():
        return {"project_jmx": {}, "dataset": {}}
    with _UPLOAD_OWNER_STORE.open("r", encoding="utf-8") as fp:
        data = json.load(fp)
    if not isinstance(data, dict):
        return {"project_jmx": {}, "dataset": {}}
    if not isinstance(data.get("project_jmx"), dict):
        data["project_jmx"] = {}
    if not isinstance(data.get("dataset"), dict):
        data["dataset"] = {}
    return data


def _write_upload_owner_store(data: dict) -> None:
    _UPLOAD_OWNER_STORE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = _UPLOAD_OWNER_STORE.with_suffix(".tmp")
    with tmp_path.open("w", encoding="utf-8") as fp:
        json.dump(data, fp, ensure_ascii=False, indent=2)
    tmp_path.replace(_UPLOAD_OWNER_STORE)


def _normalized_username(user: dict) -> str:
    return str(user.get("username", "")).strip().lower()


def _owner_record(store: dict, section: str, key: str) -> dict | None:
    section_data = store.get(section, {})
    if not isinstance(section_data, dict):
        return None
    value = section_data.get(key)
    if not isinstance(value, dict):
        return None
    return value


def _set_owner_record(store: dict, section: str, key: str, username: str) -> None:
    section_data = store.get(section)
    if not isinstance(section_data, dict):
        section_data = {}
        store[section] = section_data
    section_data[key] = {
        "owner": username,
        "updated_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    }


def _assert_overwrite_allowed(target_exists: bool, confirm_overwrite: bool, user: dict, owner: dict | None) -> None:
    if not target_exists:
        return
    if not confirm_overwrite:
        raise HTTPException(409, "File already exists. Please confirm overwrite in UI.")
    if can_manage_users(user):
        return

    current_user = _normalized_username(user)
    owner_name = str((owner or {}).get("owner", "")).strip().lower()
    if not owner_name:
        raise HTTPException(403, "非 Admin 不可覆蓋既有檔案（缺少上傳者資訊）")
    if owner_name != current_user:
        raise HTTPException(403, "非 Admin 不可覆蓋他人上傳的檔案")


def _kubectl_json(namespace: str, args: list[str]) -> dict | list | None:
    cmd = ["kubectl", "-n", namespace, *args, "-o", "json"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=15)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def _kubectl_logs(namespace: str, pod: str, container: str, lines: int) -> str:
    cmd = [
        "kubectl",
        "-n",
        namespace,
        "logs",
        pod,
        "-c",
        container,
        "--tail",
        str(max(1, lines)),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=20)
    if proc.returncode != 0:
        err = (proc.stderr or "").strip()
        return f"[ERROR] {err or 'failed to read logs'}"
    return proc.stdout


@router.post("/tests/start", dependencies=[Depends(require_drive_tests)])
def start_test(
    project: str = Form(...),
    jmx_file: str | None = Form(None),
    namespace: str = Form("performance-test"),
    injectors: int = Form(2),
    helm_env: str = Form("lab"),
    helm_release: str = Form("jmeter-runtime"),
    copy_csv: bool = Form(True),
    copy_module: bool = Form(True),
    enable_report: bool = Form(True),
):
    if not START_SCRIPT.exists():
        raise HTTPException(500, "start_test.sh not found")

    jmx_name = (jmx_file or "").strip()
    if not jmx_name.endswith(".jmx"):
        jmx_name = f"{project}.jmx"

    expected_jmx = _safe_project_file(project, jmx_name)
    if not expected_jmx.exists() or not expected_jmx.is_file():
        raise HTTPException(
            status_code=400,
            detail=f"JMX file not found: scenario/{project}/{jmx_name}",
        )

    cmd = [
        "bash",
        str(START_SCRIPT),
        "-j",
        jmx_name,
        "-n",
        namespace,
        "-i",
        str(injectors),
        "--helm-env",
        helm_env,
        "--helm-release",
        helm_release,
        "--pvc-enabled",
        "false",
    ]
    if copy_csv:
        cmd.append("-c")
    if copy_module:
        cmd.append("-m")
    if enable_report:
        cmd.append("-r")

    log_path = REPO_ROOT / "webapp" / "logs" / "start_test.log"
    run_background("start_test", cmd, REPO_ROOT, log_path)
    return {"ok": True, "cmd": cmd}


@router.post("/tests/stop", dependencies=[Depends(require_drive_tests)])
def stop_test(
    namespace: str = Form("performance-test"),
    uninstall_runtime: bool = Form(False),
    helm_release: str = Form("jmeter-runtime"),
):
    if not STOP_SCRIPT.exists():
        raise HTTPException(500, "stop_test.sh not found")

    cmd = ["bash", str(STOP_SCRIPT), "-n", namespace]
    if uninstall_runtime:
        cmd.extend(["-u", "--helm-release", helm_release])

    log_path = REPO_ROOT / "webapp" / "logs" / "stop_test.log"
    run_background("stop_test", cmd, REPO_ROOT, log_path)
    return {"ok": True, "cmd": cmd}


@router.get("/tests/status", dependencies=[Depends(require_drive_tests)])
def test_status():
    return get_jobs_status()


@router.get("/tests/runtime-status", dependencies=[Depends(require_drive_tests)])
def runtime_status(namespace: str = "performance-test"):
    jobs_status = get_jobs_status()
    start_job_status = jobs_status.get("start_test", "idle")
    stop_job_status = jobs_status.get("stop_test", "idle")

    master_job = _kubectl_json(namespace, ["get", "job", "jmeter-master"])
    slave_job = _kubectl_json(namespace, ["get", "job", "jmeter-slaves"])
    pod_list = _kubectl_json(namespace, ["get", "pods", "-l", "jmeter_mode=master"]) or {"items": []}

    master_active = int((master_job or {}).get("status", {}).get("active", 0)) if isinstance(master_job, dict) else 0
    master_succeeded = int((master_job or {}).get("status", {}).get("succeeded", 0)) if isinstance(master_job, dict) else 0
    master_failed = int((master_job or {}).get("status", {}).get("failed", 0)) if isinstance(master_job, dict) else 0
    slave_active = int((slave_job or {}).get("status", {}).get("active", 0)) if isinstance(slave_job, dict) else 0

    master_pod_phase = "N/A"
    master_pod_name = ""
    if isinstance(pod_list, dict) and pod_list.get("items"):
        pod = pod_list["items"][0]
        master_pod_name = pod.get("metadata", {}).get("name", "")
        master_pod_phase = pod.get("status", {}).get("phase", "Unknown")

    running = (
        start_job_status == "running"
        or master_active > 0
        or master_pod_phase == "Running"
    )

    return {
        "namespace": namespace,
        "running": running,
        "summary": "執行中" if running else "未執行",
        "start_test_job": start_job_status,
        "stop_test_job": stop_job_status,
        "master_job": {
            "active": master_active,
            "succeeded": master_succeeded,
            "failed": master_failed,
        },
        "slave_job": {
            "active": slave_active,
        },
        "master_pod": {
            "name": master_pod_name,
            "phase": master_pod_phase,
        },
    }


@router.post("/db-restore/preview", dependencies=[Depends(require_drive_tests)])
def db_restore_preview(
    env: str = Form(...),
    action: str = Form(...),
    task_id: str = Form(""),
    project: str = Form(""),
    note: str = Form(""),
):
    env_name = env.strip()
    valid_envs = list_restore_envs(CONFIG_DIR)
    if env_name not in valid_envs:
        raise HTTPException(400, f"Unknown env: {env_name}")

    endpoint = get_flashback_endpoint(CONFIG_DIR, env_name)
    secret_file = REPO_ROOT / "webapp" / "data" / "secrets" / "db_restore_tokens.json"
    token = load_env_token(secret_file, env_name)

    try:
        preview = build_preview_request(
            endpoint=endpoint,
            token=token,
            action=action,
            task_id=task_id,
            project=project,
            note=note,
        )
    except ValueError as exc:
        raise HTTPException(400, str(exc)) from exc

    warnings: list[str] = []
    if not token:
        warnings.append(f"Token not found for env={env_name}. Please set {secret_file.relative_to(REPO_ROOT)}")

    return {
        "ok": True,
        "env": env_name,
        "preview": preview,
        "warnings": warnings,
    }


@router.get("/configs/helm", dependencies=[Depends(require_config_management)])
def get_helm_values(name: str):
    target = ensure_subpath(HELM_ENV_DIR, HELM_ENV_DIR / name)
    return {
        "name": name,
        "content": read_text(target),
        "modified_at": _path_modified_text(target),
    }


@router.post("/configs/helm", dependencies=[Depends(require_config_management)])
def save_helm_values(name: str = Form(...), content: str = Form(...)):
    target = ensure_subpath(HELM_ENV_DIR, HELM_ENV_DIR / name)
    write_text(target, content)
    return {
        "ok": True,
        "name": name,
        "modified_at": _path_modified_text(target),
    }


@router.get("/configs/jmeter-env", dependencies=[Depends(require_config_management)])
def get_jmeter_env_config(env: str):
    target = _safe_jmeter_env_file(env)
    return {
        "env": env,
        "content": read_text(target),
        "modified_at": _path_modified_text(target),
    }


@router.post("/configs/jmeter-env", dependencies=[Depends(require_config_management)])
def save_jmeter_env_config(env: str = Form(...), content: str = Form(...)):
    target = _safe_jmeter_env_file(env)
    write_text(target, content)
    return {
        "ok": True,
        "env": env,
        "modified_at": _path_modified_text(target),
    }


@router.get("/projects/env", dependencies=[Depends(require_project_management)])
def get_project_env(project: str):
    target = _safe_project_file(project, ".env")
    return {
        "project": project,
        "content": read_text(target),
        "modified_at": _path_modified_text(target),
    }


@router.post("/projects/env", dependencies=[Depends(require_project_management)])
def save_project_env(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, ".env")
    write_text(target, content)
    return {
        "ok": True,
        "project": project,
        "modified_at": _path_modified_text(target),
    }


@router.get("/projects/report-meta", dependencies=[Depends(require_project_management)])
def get_project_report_meta(project: str):
    target = _safe_project_file(project, "report-meta.env")
    return {
        "project": project,
        "content": read_text(target),
        "modified_at": _path_modified_text(target),
    }


@router.post("/projects/report-meta", dependencies=[Depends(require_project_management)])
def save_project_report_meta(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, "report-meta.env")
    write_text(target, content)
    return {
        "ok": True,
        "project": project,
        "modified_at": _path_modified_text(target),
    }


@router.get("/projects/system-properties", dependencies=[Depends(require_project_management)])
def get_project_system_properties(project: str):
    target = _safe_project_file(project, "jmeter-system.properties")
    return {
        "project": project,
        "content": read_text(target),
        "modified_at": _path_modified_text(target),
    }


@router.post("/projects/system-properties", dependencies=[Depends(require_project_management)])
def save_project_system_properties(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, "jmeter-system.properties")
    write_text(target, content)
    return {
        "ok": True,
        "project": project,
        "modified_at": _path_modified_text(target),
    }


@router.post("/projects/upload-jmx", dependencies=[Depends(require_project_management)])
async def upload_project_jmx(
    request: Request,
    project: str = Form(...),
    file: UploadFile = File(...),
    confirm_overwrite: bool = Form(False),
):
    user = require_project_management(request)

    if not file.filename.endswith(".jmx"):
        raise HTTPException(400, "Only .jmx files are allowed")

    target = _safe_project_file(project, file.filename)
    owner_key = f"{project.strip().lower()}/{file.filename.strip().lower()}"
    owner_store = _read_upload_owner_store()
    existing_owner = _owner_record(owner_store, "project_jmx", owner_key)
    _assert_overwrite_allowed(target.exists(), confirm_overwrite, user, existing_owner)

    target.parent.mkdir(parents=True, exist_ok=True)
    content = await file.read()
    target.write_bytes(content)

    _set_owner_record(owner_store, "project_jmx", owner_key, str(user.get("username", "")))
    _write_upload_owner_store(owner_store)

    return {
        "ok": True,
        "path": str(target.relative_to(REPO_ROOT)),
        "modified_at": _path_modified_text(target),
    }


@router.post("/projects/create", dependencies=[Depends(require_project_management)])
def create_project(project: str = Form(...)):
    project_name = _validate_project_name(project)
    project_dir = ensure_subpath(SCENARIO_DIR, SCENARIO_DIR / project_name)
    if project_dir.exists():
        raise HTTPException(409, f"project already exists: {project_name}")

    project_dir.mkdir(parents=True, exist_ok=False)

    copied_files: list[str] = []
    sources: dict[str, str] = {}

    try:
        for filename in _PROJECT_TEMPLATE_FILES:
            source, source_name = _resolve_template_file(filename)
            if source is None:
                raise HTTPException(
                    500,
                    f"template file not found: {filename} (checked scenario/_template and webapp defaults)",
                )
            target = ensure_subpath(project_dir, project_dir / filename)
            content = source.read_text(encoding="utf-8")
            write_text(target, content)
            copied_files.append(filename)
            sources[filename] = source_name
    except Exception:
        if project_dir.exists() and project_dir.is_dir():
            for path in project_dir.iterdir():
                if path.is_file():
                    path.unlink(missing_ok=True)
            project_dir.rmdir()
        raise

    return {
        "ok": True,
        "project": project_name,
        "copied_files": copied_files,
        "template_sources": sources,
        "modified_at": _path_modified_text(project_dir / ".env"),
    }


@router.get("/logs/start-test")
def get_start_test_log(lines: int = 300):
    log_path = REPO_ROOT / "webapp" / "logs" / "start_test.log"
    return {
        "path": str(log_path.relative_to(REPO_ROOT)),
        "lines": max(1, lines),
        "content": _tail_text(log_path, lines),
        "exists": log_path.exists(),
        "updated_at": datetime.fromtimestamp(log_path.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S") if log_path.exists() else "",
    }


@router.get("/logs/jmeter")
def get_jmeter_logs(namespace: str = "performance-test", target: str = "all", lines: int = 300):
    pods_data = _kubectl_json(namespace, ["get", "pods", "-l", "jmeter_mode in (master,slave)"])
    if not isinstance(pods_data, dict):
        raise HTTPException(500, "Failed to query jmeter pods")

    items = pods_data.get("items", [])
    logs: list[dict[str, str]] = []

    for item in items:
        labels = item.get("metadata", {}).get("labels", {})
        mode = labels.get("jmeter_mode", "")
        if target == "master" and mode != "master":
            continue
        if target == "slave" and mode != "slave":
            continue
        if target not in {"all", "master", "slave"}:
            raise HTTPException(400, "target must be one of: all, master, slave")

        pod_name = item.get("metadata", {}).get("name", "")
        container = "jmmaster" if mode == "master" else "jmslave"
        content = _kubectl_logs(namespace, pod_name, container, lines)
        logs.append(
            {
                "mode": mode,
                "pod": pod_name,
                "container": container,
                "content": content,
            }
        )

    logs.sort(key=lambda x: (x["mode"], x["pod"]))
    return {
        "namespace": namespace,
        "target": target,
        "lines": max(1, lines),
        "logs": logs,
    }


@router.get("/projects/jmx", dependencies=[Depends(require_project_management)])
def list_project_jmx(project: str):
    project_dir = ensure_subpath(SCENARIO_DIR, SCENARIO_DIR / project)
    files: list[dict[str, str | int]] = []

    if project_dir.exists() and project_dir.is_dir():
        for path in sorted(project_dir.glob("*.jmx")):
            stat = path.stat()
            files.append(
                {
                    "name": path.name,
                    "size": stat.st_size,
                    "modified_at": datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S"),
                    "md5": _file_md5(path),
                }
            )

    return {"project": project, "files": files}


@router.get("/projects/download-jmx", dependencies=[Depends(require_project_management)])
def download_project_jmx(project: str, name: str):
    if not name.endswith(".jmx"):
        raise HTTPException(400, "Only .jmx files are allowed")

    target = _safe_project_file(project, name)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "JMX file not found")

    return FileResponse(str(target), filename=name)


@router.post("/datasets/upload", dependencies=[Depends(require_project_management)])
async def upload_dataset(
    request: Request,
    file: UploadFile = File(...),
    project: str = Form("Others"),
    confirm_overwrite: bool = Form(False),
):
    user = require_project_management(request)

    if not file.filename.endswith(".csv"):
        raise HTTPException(400, "Only .csv files are allowed")

    selected_project = (project or "Others").strip() or "Others"
    projects = _list_projects()
    if selected_project != "Others" and selected_project not in projects:
        raise HTTPException(400, f"Unknown project: {selected_project}")

    if selected_project != "Others" and not file.filename.startswith(f"{selected_project}_"):
        raise HTTPException(400, f"Filename must start with '{selected_project}_' when project is '{selected_project}'")

    target = ensure_subpath(DATASET_DIR, DATASET_DIR / file.filename)
    owner_key = file.filename.strip().lower()
    owner_store = _read_upload_owner_store()
    existing_owner = _owner_record(owner_store, "dataset", owner_key)
    _assert_overwrite_allowed(target.exists(), confirm_overwrite, user, existing_owner)

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(await file.read())

    _set_owner_record(owner_store, "dataset", owner_key, str(user.get("username", "")))
    _write_upload_owner_store(owner_store)

    return {"ok": True, "path": str(target.relative_to(REPO_ROOT))}


@router.get("/datasets/download", dependencies=[Depends(require_project_management)])
def download_dataset(name: str):
    if not name.endswith(".csv"):
        raise HTTPException(400, "Only .csv files are allowed")

    target = ensure_subpath(DATASET_DIR, DATASET_DIR / name)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "Dataset file not found")

    return FileResponse(str(target), filename=name)


@router.get("/datasets/download-zip", dependencies=[Depends(require_project_management)])
def download_datasets_zip(project: str = "Others"):
    selected_project = (project or "Others").strip() or "Others"
    projects = _list_projects()
    if selected_project != "Others" and selected_project not in projects:
        raise HTTPException(400, f"Unknown project: {selected_project}")

    files = sorted(
        [
            path
            for path in DATASET_DIR.glob("*.csv")
            if _dataset_matches_project(path.name, selected_project, projects)
        ]
    )
    if not files:
        raise HTTPException(404, "No dataset files found for selected project")

    safe_project = selected_project.lower().replace("/", "_").replace(" ", "_")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    zip_filename = f"datasets-{safe_project}-{timestamp}.zip"
    zip_path = REPO_ROOT / "webapp" / "tmp" / zip_filename
    zip_path.parent.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, arcname=path.name)

    return FileResponse(str(zip_path), filename=zip_filename)


@router.get("/reports/download-index")
def download_report_index(report_dir: str):
    target = ensure_subpath(REPORT_DIR, REPORT_DIR / report_dir / "index.html")
    if not target.exists():
        raise HTTPException(404, "index.html not found")
    return FileResponse(str(target), filename=f"{report_dir}-index.html")


@router.get("/reports/download-zip")
def download_report_zip(report_dir: str):
    safe_dir = ensure_subpath(REPORT_DIR, REPORT_DIR / report_dir)
    if not safe_dir.exists() or not safe_dir.is_dir():
        raise HTTPException(404, "Report directory not found")

    safe_zip_name = report_dir.replace("/", "__")
    zip_path = REPO_ROOT / "webapp" / "tmp" / f"{safe_zip_name}.zip"
    make_report_zip(REPORT_DIR, report_dir, zip_path)
    return FileResponse(str(zip_path), filename=f"{safe_zip_name}.zip")


@router.get("/reports/download-zip-batch")
def download_report_batch_zip(
    project: str = "all",
    start_date: str = "",
    end_date: str = "",
):
    start_at, end_at, selected_start_date, selected_end_date = _parse_filter_dates(start_date, end_date)

    reports = discover_reports(REPORT_DIR, project=project, start_at=start_at, end_at=end_at)
    if not reports:
        raise HTTPException(404, "目前篩選條件沒有可下載的報告")
    if len(reports) > _MAX_BATCH_REPORT_DOWNLOAD:
        raise HTTPException(400, "最大單次下載100個報告，請調整篩選範圍")

    report_dirs = [r["rel_path"] for r in reports]
    safe_project = (project or "all").strip().lower().replace("/", "_").replace(" ", "_")
    safe_start = (selected_start_date or "na").replace("-", "")
    safe_end = (selected_end_date or "na").replace("-", "")
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    zip_filename = f"reports-{safe_project}-{safe_start}-{safe_end}-{timestamp}.zip"
    zip_path = REPO_ROOT / "webapp" / "tmp" / zip_filename

    make_reports_zip(REPORT_DIR, report_dirs, zip_path)
    return FileResponse(str(zip_path), filename=zip_filename)
