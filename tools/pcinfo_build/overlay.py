"""Linux用ファイル属性をtarの中で組み立てる（Windowsへの展開はしない）。"""
from __future__ import annotations

import copy
import io
import tarfile
import zlib
from pathlib import Path, PurePosixPath

from .alpine import apk_streams


class Overlay:
    """パスをキーにしたtarエントリー。後で追加した設定を優先する。"""

    def __init__(self):
        self.entries: dict[str, tuple[tarfile.TarInfo, bytes | None]] = {}

    def add(self, name: str, data: bytes = b"", mode: int = 0o644,
            *, link: str | None = None, directory: bool = False):
        name = name.removeprefix("./").rstrip("/")
        if not name or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
            raise ValueError(f"不正なoverlayパス: {name}")
        parent = PurePosixPath(name).parent
        if str(parent) != "." and str(parent) not in self.entries:
            self.add(str(parent), mode=0o755, directory=True)
        info = tarfile.TarInfo(name)
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mode = mode
        if directory:
            info.type = tarfile.DIRTYPE
        elif link is not None:
            info.type, info.linkname = tarfile.SYMTYPE, link
        else:
            info.size = len(data)
        self.entries[name] = (info, data if info.isfile() else None)

    def package(self, path: Path):
        """APK payloadの所有者・実行権限・リンクをそのまま保持する。"""
        _, payload = apk_streams(path.read_bytes())
        with tarfile.open(fileobj=io.BytesIO(zlib.decompress(payload, 31))) as archive:
            for member in archive:
                name = member.name.removeprefix("./").rstrip("/")
                if not name or name == ".":
                    continue
                if PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
                    raise ValueError(f"APK内の不正パス: {name}")
                if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                    raise ValueError(f"APK内の未対応ファイル形式: {name}")
                member = copy.copy(member)
                member.name = name
                data = archive.extractfile(member).read() if member.isfile() else None
                self.entries[name] = (member, data)

    def write(self, output: Path):
        """実行属性や大文字小文字を失わず、Alpine apkovl形式で保存する。"""
        with tarfile.open(output, "w:gz", format=tarfile.PAX_FORMAT) as archive:
            # Linuxで展開する際、hardlink先の通常ファイルが先に存在する順序にする。
            def order(name):
                info = self.entries[name][0]
                return (0 if info.isdir() else 3 if info.islnk() else 2 if info.issym() else 1,
                        name.count("/") if info.isdir() else 0, name)
            for name in sorted(self.entries, key=order):
                info, data = self.entries[name]
                archive.addfile(info, io.BytesIO(data) if data is not None else None)


def gpu_databases(raw: bytes) -> tuple[bytes, bytes]:
    """pci.idsから従来と同じvendor|device形式の参照表を生成する。"""
    vendors = {"1002": "AMD", "10de": "NVIDIA", "8086": "Intel"}
    devices = ["# vendor_id|device_id|manufacturer|model|vram_hint"]
    subsystems = ["# vendor_id|device_id|subvendor_id|subdevice_id|manufacturer|model|vram_hint"]
    vendor = device = ""
    import re
    for line in raw.decode("utf-8", errors="replace").splitlines():
        if re.match(r"^[0-9a-fA-F]{4}  ", line):
            vendor, device = line[:4].lower(), ""
        elif vendor in vendors and re.match(r"^\t[0-9a-fA-F]{4}  ", line):
            device = line[1:5].lower()
            name = line[7:].strip()
            if name:
                devices.append(f"0x{vendor}|0x{device}|{vendors[vendor]}|{name}|")
        elif vendor in vendors and device and re.match(r"^\t\t[0-9a-fA-F]{4} [0-9a-fA-F]{4}  ", line):
            name = line[13:].strip()
            if name:
                subsystems.append(f"0x{vendor}|0x{device}|0x{line[2:6].lower()}|0x{line[7:11].lower()}|{vendors[vendor]}|{name}|")
    if len(devices) < 2 or len(subsystems) < 2:
        raise ValueError("GPU参照表の生成結果が空です")
    return tuple(("\n".join(lines) + "\n").encode() for lines in (devices, subsystems))
