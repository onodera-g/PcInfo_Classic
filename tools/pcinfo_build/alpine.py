"""Alpine APKINDEXとAPKをWindows上で読む。Linuxのapk実行は不要。"""
from __future__ import annotations

import base64
import hashlib
import io
import re
import tarfile
import zlib
from dataclasses import dataclass


@dataclass(frozen=True)
class Package:
    name: str
    version: str
    repo: str
    fields: dict[str, str]

    @property
    def filename(self) -> str:
        return f"{self.name}-{self.version}.apk"


def read_index(path, repo: str) -> list[Package]:
    """署名を含む公式APKINDEXの中からパッケージ一覧を読む。"""
    with tarfile.open(path, "r:gz") as archive:
        content = archive.extractfile("APKINDEX").read().decode("utf-8")
    packages = []
    for record in content.split("\n\n"):
        fields = dict(line.split(":", 1) for line in record.splitlines() if ":" in line)
        if "P" in fields and "V" in fields:
            packages.append(Package(fields["P"], fields["V"], repo, fields))
    return packages


def split_gzip(data: bytes) -> list[bytes]:
    """APK v2の署名・制御情報・データという連結gzipを分離する。"""
    members = []
    while data:
        decoder = zlib.decompressobj(31)
        decoder.decompress(data)
        if not decoder.eof:
            raise ValueError("APKのgzipが途中で切れています")
        consumed = len(data) - len(decoder.unused_data)
        members.append(data[:consumed])
        data = decoder.unused_data
    return members


def apk_streams(data: bytes) -> tuple[bytes, bytes]:
    """APKのcontrol/dataを取り出す。署名なしAPKにも対応する。"""
    members = split_gzip(data)
    if len(members) == 3:
        return members[1], members[2]
    if len(members) == 2:
        return members[0], members[1]
    raise ValueError("未対応のAPK形式です（APK v2が必要）")


def verify_apk(path, package: Package) -> None:
    """公式indexのcontrol checksumと、control内のdatahashを照合する。"""
    control, payload = apk_streams(path.read_bytes())
    expected = package.fields["C"]
    actual = "Q1" + base64.b64encode(hashlib.sha1(control).digest()).decode()
    if expected != actual:
        raise ValueError(f"APK control checksum不一致: {package.filename}")
    with tarfile.open(fileobj=io.BytesIO(zlib.decompress(control, 31))) as archive:
        pkginfo = archive.extractfile(".PKGINFO").read().decode()
    values = dict(line.split(" = ", 1) for line in pkginfo.splitlines() if " = " in line)
    if values.get("pkgname") != package.name or values.get("pkgver") != package.version:
        raise ValueError(f"APK識別情報の不一致: {package.filename}")
    if hashlib.sha256(payload).hexdigest() != values.get("datahash"):
        raise ValueError(f"APK datahash不一致: {package.filename}")


def parse_dependency(value: str) -> tuple[str, str, str]:
    match = re.fullmatch(r"([^<>=~]+)([<>=~]*)(.*)", value)
    if not match:
        raise ValueError(f"未対応の依存指定: {value}")
    return match.groups()


def satisfies(actual: str, operation: str, required: str) -> bool:
    """曖昧な大小比較をしない。使用indexで必要な同一版・互換指定を照合する。"""
    if not operation:
        return True
    if operation == "=":
        return actual == required
    if operation in ("~", "~=", "=~"):
        return actual == required or actual.startswith(required + ".") or actual.startswith(required + "-r")
    from .versions import compare
    result = compare(actual, required)
    return {">": result > 0, ">=": result >= 0, "<": result < 0, "<=": result <= 0}[operation]


def resolve(packages: list[Package], roots: list[str]) -> list[Package]:
    """名前と共有ライブラリ等の提供名から、依存閉包を作る。未解決は失敗にする。"""
    names = {p.name: p for p in reversed(packages)}  # mainをcommunityより優先
    providers: dict[str, list[tuple[Package, str]]] = {}
    for package in packages:
        for token in package.fields.get("p", "").split():
            name, _, version = parse_dependency(token)
            providers.setdefault(name, []).append((package, version))
    selected: dict[str, Package] = {}
    queue = list(roots)
    while queue:
        token = queue.pop(0)
        if token.startswith("!"):
            continue  # 選択が終わってから衝突も確認する
        name, operation, version = parse_dependency(token)
        candidates = [(names[name], names[name].version)] if name in names else providers.get(name, [])
        candidates = [(p, v) for p, v in candidates if satisfies(v, operation, version)]
        if not candidates:
            raise ValueError(f"依存を解決できません: {token}")
        # 既に選択した提供元を優先し、仮想名の複数実装を無用に入れない。
        package = next((p for p, _ in candidates if p.name in selected), candidates[0][0])
        if package.name in selected:
            if selected[package.name].version != package.version:
                raise ValueError(f"依存バージョンが衝突しました: {token}")
            continue
        selected[package.name] = package
        queue.extend(package.fields.get("D", "").split())
    for package in selected.values():
        for token in package.fields.get("D", "").split():
            if token.startswith("!"):
                name, operation, version = parse_dependency(token[1:])
                for other in selected.values():
                    provided = [(other.name, other.version)]
                    provided += [(n, v) for n, _, v in map(parse_dependency, other.fields.get("p", "").split())]
                    if any(n == name and satisfies(v, operation, version) for n, v in provided):
                        raise ValueError(f"依存が衝突しています: {package.name}: {token}")
    return sorted(selected.values(), key=lambda p: p.name)
