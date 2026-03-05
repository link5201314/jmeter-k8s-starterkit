from __future__ import annotations

import hashlib
import json
import subprocess
import zipfile
from datetime import datetime
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse

from webapp.app.core.config import (
    CONFIG_DIR,
    DATASET_DIR,
    HELM_ENV_DIR,
    REPO_ROOT,
    REPORT_DIR,
    SCENARIO_DIR,
    START_SCRIPT,
    STOP_SCRIPT,
)
from webapp.app.services.file_service import ensure_subpath, read_text, write_text
from webapp.app.services.process_service import get_jobs_status, run_background
from webapp.app.services.report_service import make_report_zip
from webapp.app.services.auth_service import require_authenticated, require_drive_tests

router = APIRouter(prefix="/api", dependencies=[Depends(require_authenticated)])


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


@router.get("/configs/helm")
def get_helm_values(name: str):
    target = ensure_subpath(HELM_ENV_DIR, HELM_ENV_DIR / name)
    return {"name": name, "content": read_text(target)}


@router.post("/configs/helm")
def save_helm_values(name: str = Form(...), content: str = Form(...)):
    target = ensure_subpath(HELM_ENV_DIR, HELM_ENV_DIR / name)
    write_text(target, content)
    return {"ok": True}


@router.get("/configs/system-properties")
def get_system_properties(project: str):
    target = _safe_project_file(project, "jmeter-system.properties")
    return {"project": project, "content": read_text(target)}


@router.post("/configs/system-properties")
def save_system_properties(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, "jmeter-system.properties")
    write_text(target, content)
    return {"ok": True}


@router.get("/projects/env")
def get_project_env(project: str):
    target = _safe_project_file(project, ".env")
    return {"project": project, "content": read_text(target)}


@router.post("/projects/env")
def save_project_env(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, ".env")
    write_text(target, content)
    return {"ok": True}


@router.get("/projects/report-meta")
def get_project_report_meta(project: str):
    target = _safe_project_file(project, "report-meta.env")
    return {"project": project, "content": read_text(target)}


@router.post("/projects/report-meta")
def save_project_report_meta(project: str = Form(...), content: str = Form(...)):
    target = _safe_project_file(project, "report-meta.env")
    write_text(target, content)
    return {"ok": True}


@router.post("/projects/upload-jmx")
async def upload_project_jmx(
    project: str = Form(...),
    file: UploadFile = File(...),
    confirm_overwrite: bool = Form(False),
):
    if not file.filename.endswith(".jmx"):
        raise HTTPException(400, "Only .jmx files are allowed")

    target = _safe_project_file(project, file.filename)
    if target.exists() and not confirm_overwrite:
        raise HTTPException(409, "File already exists. Please confirm overwrite in UI.")
    target.parent.mkdir(parents=True, exist_ok=True)
    content = await file.read()
    target.write_bytes(content)
    return {"ok": True, "path": str(target.relative_to(REPO_ROOT))}


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


@router.get("/projects/jmx")
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


@router.get("/projects/download-jmx")
def download_project_jmx(project: str, name: str):
    if not name.endswith(".jmx"):
        raise HTTPException(400, "Only .jmx files are allowed")

    target = _safe_project_file(project, name)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "JMX file not found")

    return FileResponse(str(target), filename=name)


@router.post("/datasets/upload")
async def upload_dataset(
    file: UploadFile = File(...),
    project: str = Form("Others"),
    confirm_overwrite: bool = Form(False),
):
    if not file.filename.endswith(".csv"):
        raise HTTPException(400, "Only .csv files are allowed")

    selected_project = (project or "Others").strip() or "Others"
    projects = _list_projects()
    if selected_project != "Others" and selected_project not in projects:
        raise HTTPException(400, f"Unknown project: {selected_project}")

    if selected_project != "Others" and not file.filename.startswith(f"{selected_project}_"):
        raise HTTPException(400, f"Filename must start with '{selected_project}_' when project is '{selected_project}'")

    target = ensure_subpath(DATASET_DIR, DATASET_DIR / file.filename)
    if target.exists() and not confirm_overwrite:
        raise HTTPException(409, "File already exists. Please confirm overwrite in UI.")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(await file.read())
    return {"ok": True, "path": str(target.relative_to(REPO_ROOT))}


@router.get("/datasets/download")
def download_dataset(name: str):
    if not name.endswith(".csv"):
        raise HTTPException(400, "Only .csv files are allowed")

    target = ensure_subpath(DATASET_DIR, DATASET_DIR / name)
    if not target.exists() or not target.is_file():
        raise HTTPException(404, "Dataset file not found")

    return FileResponse(str(target), filename=name)


@router.get("/datasets/download-zip")
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
