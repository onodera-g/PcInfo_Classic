"""Linuxバイナリを実行せず、ELFの必要ライブラリをtar内で照合する。"""
import posixpath
import struct


def dependencies(data: bytes) -> tuple[list[str], str | None]:
    if not data.startswith(b"\x7fELF"):
        return [], None
    if data[5] != 1 or data[4] not in (1, 2) or struct.unpack_from("<H", data, 18)[0] not in (3, 62):
        raise ValueError("x86/x86_64 little-endian以外のELFが同梱されています")
    wide = data[4] == 2
    start = struct.unpack_from("<Q" if wide else "<I", data, 32 if wide else 28)[0]
    stride, count = struct.unpack_from("<HH", data, 54 if wide else 42)
    headers = []
    for i in range(count):
        fields = struct.unpack_from("<IIQQQQQQ" if wide else "<IIIIIIII", data, start + i * stride)
        if not wide:
            kind, offset, address, physical, size, memory, flags, alignment = fields
            fields = kind, flags, offset, address, physical, size, memory, alignment
        headers.append(fields)
    interpreter = None
    for kind, _, offset, _, _, size, _, _ in headers:
        if kind == 3:
            interpreter = data[offset:offset + size].rstrip(b"\0").decode("ascii")
    names, table = [], None
    for kind, _, offset, _, _, size, _, _ in headers:
        if kind == 2:
            for at in range(offset, offset + size, 16 if wide else 8):
                tag, value = struct.unpack_from("<QQ" if wide else "<II", data, at)
                if tag == 0:
                    break
                if tag == 1:
                    names.append(value)
                if tag == 5:
                    table = value
    if not names:
        return [], interpreter
    for kind, _, offset, address, _, size, _, _ in headers:
        if kind == 1 and address <= table < address + size:
            table = table - address + offset
            break
    else:
        raise ValueError("ELFの文字列表を解決できません")
    return [data[table + name:].split(b"\0", 1)[0].decode("ascii") for name in names], interpreter


def verify_libraries(archive):
    members = {m.name: m for m in archive}
    def exists(name, seen=()):
        name = name.lstrip("/")
        if name in seen or name not in members:
            return False
        member = members[name]
        if member.issym():
            target = member.linkname
            if not target.startswith("/"):
                target = posixpath.join(posixpath.dirname(name), target)
            return exists(posixpath.normpath(target), seen + (name,))
        if member.islnk():
            return exists(member.linkname.removeprefix("./"), seen + (name,))
        return member.isfile()
    for name, member in members.items():
        if not member.isfile():
            continue
        stream = archive.extractfile(member)
        prefix = stream.read(4)
        if prefix != b"\x7fELF":
            continue
        try:
            needed, interpreter = dependencies(prefix + stream.read())
        except ValueError as error:
            raise ValueError(f"{name}: {error}") from error
        if interpreter and not exists(interpreter):
            raise ValueError(f"ELFローダーが欠落: {name}: {interpreter}")
        for library in needed:
            if not any(exists(directory + library) for directory in ("lib/", "usr/lib/", "usr/local/lib/")):
                raise ValueError(f"ELFライブラリが欠落: {name}: {library}")
