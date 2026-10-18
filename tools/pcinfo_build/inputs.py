"""IMGの入力原本と生成処理を記録し、更新漏れ・生成中の変更を検出する。"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path


FIXED_INPUTS = ("LICENSE", ".gitattributes", "requirements-dev.txt", "ビルド.cmd",
                "tools/build_windows.py", "tools/setup_windows.ps1")
INPUT_TREES = ("src", "data", "licenses", "tools/packaging")


def source_snapshot(root: Path) -> dict:
    root = root.resolve()
    paths = set()
    for name in FIXED_INPUTS:
        path = root / name
        if not path.is_file():
            raise ValueError(f"ビルド入力がありません: {name}")
        paths.add(path)
    for name in (*INPUT_TREES, "tools/pcinfo_build"):
        directory = root / name
        if not directory.is_dir():
            raise ValueError(f"ビルド入力フォルダがありません: {name}")
        pattern = "*.py" if name == "tools/pcinfo_build" else "*"
        for path in directory.rglob(pattern):
            if path.is_file() and not {"__pycache__", ".cache"}.intersection(path.relative_to(root).parts):
                paths.add(path)
    files = {}
    for path in sorted(paths):
        if path.is_symlink() or not path.resolve().is_relative_to(root):
            raise ValueError(f"ビルド入力のリンク又は範囲が不正です: {path.relative_to(root)}")
        with path.open("rb") as source:
            files[path.relative_to(root).as_posix()] = hashlib.file_digest(source, "sha256").hexdigest()
    return {"format": 1, "files": files}


def verify_source_snapshot(root: Path, recorded: dict | None) -> None:
    if not isinstance(recorded, dict) or type(recorded.get("format")) is not int or recorded["format"] != 1:
        raise ValueError("IMGに対応する入力記録がありません。再ビルド後に検証してください")
    files = recorded.get("files")
    if not isinstance(files, dict) or not files or any(
        not isinstance(name, str) or not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
        for name, value in files.items()
    ):
        raise ValueError("IMGの入力記録が不正です。再ビルド後に検証してください")
    current = source_snapshot(root)["files"]
    added = sorted(current.keys() - files.keys())
    removed = sorted(files.keys() - current.keys())
    changed = sorted(name for name in current.keys() & files.keys() if current[name] != files[name])
    details = [f"{label}: {', '.join(names[:8])}" for label, names in
               (("追加", added), ("削除", removed), ("変更", changed)) if names]
    if details:
        raise ValueError("ビルド入力が記録と異なります（" + " / ".join(details) + "）。再ビルドしてください")
