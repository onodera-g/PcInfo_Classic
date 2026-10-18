"""物理ドライブを開かず、MBRとFAT32を持つ通常のIMGファイルを生成する。"""
from __future__ import annotations

import hashlib
import shutil
import struct
import warnings
from pathlib import Path

from pyfatfs.PyFat import PyFat
with warnings.catch_warnings():
    # fsの既知の非推奨APIはsetuptools<81に固定して使用する。他の警告は隠さない。
    warnings.filterwarnings("ignore", message=r"pkg_resources is deprecated as an API.*",
                            category=UserWarning, module=r"^fs$")
    from pyfatfs.PyFatFS import PyFatFS

SECTOR = 512
PARTITION_START = 2048
OFFSET = PARTITION_START * SECTOR


def boot_sectors(boot: bytes, core: bytes, total_sectors: int) -> tuple[bytes, bytes]:
    """GRUBの公開形式に従い、固定のMBR埋込み領域にcore.imgを配置する。

    レイアウトの根拠はGRUB include/grub/i386/pc/boot.h・offsets.h。
    coreはファイルシステム外の連続領域に置くため、FATの再配置に依存しない。
    """
    if len(boot) != SECTOR or boot[510:] != b"\x55\xaa" or len(core) < 1024:
        raise ValueError("GRUBのboot.img/core.img形式が不正です")
    count = (len(core) + SECTOR - 1) // SECTOR
    if count >= PARTITION_START or count - 1 > 0xFFFF:
        raise ValueError("BIOS core.imgがMBR埋込み領域に収まりません")
    mbr, embedded = bytearray(boot), bytearray(core.ljust(count * SECTOR, b"\0"))
    struct.pack_into("<Q", mbr, 0x5C, 1)  # boot.imgが読むcore先頭LBA
    mbr[0x64] = 0xFF  # BIOSから渡された起動ドライブ番号を使用
    # diskboot先頭512バイトの末尾に、残りのcoreのLBA・長さ・ロードセグメント。
    struct.pack_into("<QHH", embedded, 500, 2, count - 1, 0x820)
    embedded[488:500] = b"\0" * 12  # ブロックリスト終端
    # 先頭1MiBはGRUB用。残りを起動可能なFAT32 LBAパーティションにする。
    mbr[440:510] = b"\0" * 70
    struct.pack_into("<I", mbr, 440, 0x5043494E)
    struct.pack_into("<B3sB3sII", mbr, 446, 0x80, b"\x20\x21\0", 0x0C,
                     b"\xfe\xff\xff", PARTITION_START, total_sectors - PARTITION_START)
    return bytes(mbr), bytes(embedded)


def create_image(output: Path, payload: dict[str, Path], boot: bytes, core: bytes,
                 minimum_mb: int, label: str) -> dict:
    """空ファイルから生成し、FAT内に全同梱ファイルを書き込む。"""
    size_mb = max(minimum_mb, (sum(p.stat().st_size for p in payload.values()) * 13 // 10
                              + 64 * 1024 * 1024 + 1048575) // 1048576)
    size = size_mb * 1048576
    with output.open("wb") as stream:
        stream.truncate(size)
    fat = PyFat(offset=OFFSET)
    try:
        fat.mkfs(str(output), PyFat.FAT_TYPE_FAT32, size=size - OFFSET, label=label)
        fat.bpb_header["BPB_HiddSec"] = PARTITION_START
        fat._write_bpb_header()
    finally:
        fat.close()
    manifest = {}
    with PyFatFS(str(output), offset=OFFSET, preserve_case=True) as filesystem:
        for name, source in sorted(payload.items()):
            parent = str(Path(name).parent).replace("\\", "/")
            if parent != ".":
                filesystem.makedirs(parent, recreate=True)
            with source.open("rb") as src, filesystem.openbin(name, "w") as dest:
                shutil.copyfileobj(src, dest, 1024 * 1024)
            with source.open("rb") as src:
                manifest[name] = {"size": source.stat().st_size,
                                  "sha256": hashlib.file_digest(src, "sha256").hexdigest()}
    mbr, embedded = boot_sectors(boot, core, size // SECTOR)
    with output.open("r+b") as stream:
        stream.write(mbr)
        stream.write(embedded)
    return {"size": size, "partition_offset": OFFSET, "files": manifest,
            "bios_mbr_sha256": hashlib.sha256(mbr).hexdigest(),
            "bios_core_sha256": hashlib.sha256(embedded).hexdigest(),
            "bios_core_size": len(embedded)}


def verify_image(image: Path, manifest: dict) -> None:
    """別ハンドルで開き直し、MBR・埋込みcore・全FATファイルを照合する。"""
    if image.stat().st_size != manifest["size"]:
        raise ValueError("IMGサイズが不一致です")
    with image.open("rb") as stream:
        mbr = stream.read(SECTOR)
        core = stream.read(manifest["bios_core_size"])
    partition = struct.unpack_from("<B3sB3sII", mbr, 446)
    if mbr[510:] != b"\x55\xaa" or partition[0] != 0x80 or partition[2] != 0x0C:
        raise ValueError("MBRパーティションが不正です")
    if partition[4] != PARTITION_START or (partition[4] + partition[5]) * SECTOR != manifest["size"]:
        raise ValueError("パーティション範囲が不正です")
    if hashlib.sha256(mbr).hexdigest() != manifest["bios_mbr_sha256"]:
        raise ValueError("MBR内容の不一致")
    if hashlib.sha256(core).hexdigest() != manifest["bios_core_sha256"]:
        raise ValueError("BIOS core内容の不一致")
    if struct.unpack_from("<Q", mbr, 0x5C)[0] != 1 or struct.unpack_from("<QHH", core, 500) != (
        2, len(core) // SECTOR - 1, 0x820
    ):
        raise ValueError("BIOSのcore配置情報が不正です")
    with PyFatFS(str(image), offset=OFFSET, read_only=True, preserve_case=True) as filesystem:
        actual_files = {str(p).lstrip("/") for p in filesystem.walk.files()}
        if actual_files != set(manifest["files"]):
            raise ValueError("IMGの同梱ファイル一覧が不一致です")
        for name, record in manifest["files"].items():
            with filesystem.openbin(name) as source:
                if hashlib.file_digest(source, "sha256").hexdigest() != record["sha256"]:
                    raise ValueError(f"IMG内ファイルのハッシュ不一致: {name}")
            if filesystem.getsize(name) != record["size"]:
                raise ValueError(f"IMG内ファイルのサイズ不一致: {name}")
