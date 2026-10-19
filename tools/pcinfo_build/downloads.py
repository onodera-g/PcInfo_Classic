"""HTTPS取得をプロジェクト内に閉じ込め、取得途中のファイルを完成物と区別する。"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


def sha256(path: Path) -> str:
    """大きなIMGやISOも一括でメモリへ載せずハッシュを計算する。"""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


class Downloads:
    """URLと内容の一致を記録するキャッシュ。offline時は通信しない。"""

    def __init__(self, directory: Path, *, offline: bool = False, refresh: bool = False):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.offline, self.refresh = offline, refresh
        self.used: dict[str, dict] = {}

    def get(self, url: str, name: str, expected: str | None = None,
            *, mutable: bool = False) -> Path:
        if not url.startswith("https://") or Path(name).name != name:
            raise ValueError("HTTPS URLと単一のキャッシュファイル名を指定してください")
        target = self.directory / name
        receipt = target.with_name(target.name + ".json")
        previous = json.loads(receipt.read_text("utf-8")) if receipt.exists() else {}
        reuse = target.is_file() and previous.get("url") == url
        reuse = reuse and not (mutable and self.refresh and not self.offline)
        if reuse:
            actual = sha256(target)
            if actual != previous.get("sha256") or (expected and actual != expected.lower()):
                raise ValueError(f"取得物のハッシュが不一致です: {target}")
        else:
            if self.offline:
                raise FileNotFoundError(f"オフライン用取得物がありません: {name}")
            partial = target.with_name(target.name + ".part")
            print(f"取得: {name}", flush=True)
            try:
                request = urllib.request.Request(url, headers={"User-Agent": "PCInfoClassic-WindowsBuild/1"})
                system_root = os.environ.get("SystemRoot")
                curl = Path(system_root) / "System32/curl.exe" if system_root else None
                if os.name == "nt" and curl is not None and curl.is_file():
                    self._curl(curl, url, partial)
                else:
                    for attempt in range(3):
                        try:
                            with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as out:
                                shutil.copyfileobj(response, out, 64 * 1024)
                            break
                        except (OSError, TimeoutError):
                            if attempt == 2:
                                raise
                            time.sleep(1)
                if not partial.stat().st_size:
                    raise ValueError(f"取得したファイルが空です: {url}")
                actual = sha256(partial)
                if expected and actual != expected.lower():
                    raise ValueError(f"公開ハッシュと不一致です: {name}")
                partial.replace(target)
                previous = {"url": url, "sha256": actual, "size": target.stat().st_size}
                receipt.write_text(json.dumps(previous, indent=2) + "\n", "utf-8")
            finally:
                partial.unlink(missing_ok=True)
        self.used[name] = previous
        return target

    def _curl(self, curl: Path, url: str, partial: Path):
        """大きな取得物は範囲を分割する。結合後の公開ハッシュ照合は省略しない。"""
        command = [str(curl), "--fail", "--location", "--retry", "2",
                   "--connect-timeout", "30", "--speed-time", "60", "--speed-limit", "1024",
                   "--proto", "=https", "--proto-redir", "=https", "--silent", "--show-error"]
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=30) as response:
            length = int(response.headers.get("Content-Length", 0))
            ranged = response.headers.get("Accept-Ranges", "").lower() == "bytes"
        if not ranged or length <= 16 * 1024 * 1024:
            subprocess.run(command + ["--output", partial.name, "--url", url], cwd=self.directory, check=True)
            return
        chunk_size = 8 * 1024 * 1024
        chunks = []
        for start in range(0, length, chunk_size):
            end = min(start + chunk_size, length) - 1
            chunks.append((start, end, partial.with_name(f"{partial.name}-{start}")))
        def fetch(chunk):
            start, end, path = chunk
            subprocess.run(command + ["--range", f"{start}-{end}", "--output", path.name, "--url", url],
                           cwd=self.directory, check=True)
            if path.stat().st_size != end - start + 1:
                raise ValueError(f"範囲取得のサイズ不一致: {path.name}")
            return path
        try:
            with ThreadPoolExecutor(max_workers=3) as executor, partial.open("wb") as out:
                for path in executor.map(fetch, chunks):
                    with path.open("rb") as source:
                        shutil.copyfileobj(source, out, 1024 * 1024)
                    path.unlink()
        finally:
            for _, _, path in chunks:
                path.unlink(missing_ok=True)
