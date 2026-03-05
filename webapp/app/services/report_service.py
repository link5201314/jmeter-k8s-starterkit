from __future__ import annotations

import re
import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional


def list_report_dirs(report_root: Path) -> list[str]:
    if not report_root.exists():
        return []
    return sorted([p.name for p in report_root.iterdir() if p.is_dir()], reverse=True)


def make_report_zip(report_root: Path, report_dir_name: str, output_zip: Path) -> Path:
    report_dir = report_root / report_dir_name
    if not report_dir.exists() or not report_dir.is_dir():
        raise FileNotFoundError(report_dir_name)

    output_zip.parent.mkdir(parents=True, exist_ok=True)
    if output_zip.exists():
        output_zip.unlink()

    shutil.make_archive(str(output_zip.with_suffix("")), "zip", root_dir=str(report_dir))
    return output_zip


def _project_from_legacy_dirname(dirname: str) -> Optional[str]:
    if not dirname.startswith("report-"):
        return None
    remaining = dirname[len("report-") :]
    if ".jmx-" in remaining:
        return remaining.split(".jmx-", 1)[0]
    return None


def _extract_report_datetime(report_dir: Path) -> datetime:
    name = report_dir.name
    match = re.search(r"\.jmx-(\d{4}-\d{2}-\d{2}_\d{6})$", name)
    if match:
        try:
            return datetime.strptime(match.group(1), "%Y-%m-%d_%H%M%S")
        except ValueError:
            pass
    return datetime.fromtimestamp(report_dir.stat().st_mtime)


def discover_reports(
    report_root: Path,
    project: Optional[str] = None,
    start_at: Optional[datetime] = None,
    end_at: Optional[datetime] = None,
) -> list[dict[str, str]]:
    if not report_root.exists():
        return []

    results: list[dict[str, str]] = []
    seen: set[str] = set()

    for stats in report_root.rglob("statistics.json"):
        report_dir = stats.parent
        rel_path = report_dir.relative_to(report_root).as_posix()
        if rel_path in seen:
            continue
        seen.add(rel_path)

        parts = rel_path.split("/")
        if len(parts) >= 2:
            report_project = parts[0]
        else:
            report_project = _project_from_legacy_dirname(parts[0]) or "unknown"

        if project and project != "all" and report_project != project:
            continue

        report_dt = _extract_report_datetime(report_dir)
        if start_at and report_dt < start_at:
            continue
        if end_at and report_dt > end_at:
            continue

        results.append(
            {
                "project": report_project,
                "name": report_dir.name,
                "rel_path": rel_path,
                "mtime": str(report_dir.stat().st_mtime),
                "generated_at": report_dt.strftime("%Y-%m-%d %H:%M:%S"),
            }
        )

    results.sort(key=lambda item: item["mtime"], reverse=True)
    for item in results:
        item.pop("mtime", None)
    return results

