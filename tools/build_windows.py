#!/usr/bin/env python3
"""Windows上で空のIMGからAlpine・BIOS/UEFI GRUB・診断アプリを組み立てる。"""
from __future__ import annotations

import argparse
import errno
import hashlib
import io
import json
import msvcrt
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
import zlib
from contextlib import contextmanager
from pathlib import Path

import pycdlib

from pcinfo_build.alpine import read_index, resolve, verify_apk, apk_streams
from pcinfo_build.downloads import Downloads, sha256
from pcinfo_build.image import create_image, verify_image
from pcinfo_build.overlay import Overlay, gpu_databases
from pcinfo_build.inputs import source_snapshot, verify_source_snapshot
from pcinfo_build.config import load_config
from pcinfo_build.payload import add_application_files, verify_overlay

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build/work/windows"
OUTPUT = ROOT / "build/output"


def log(message: str):
    print(message, flush=True)


def clean_abandoned():
    """排他ロック取得後、自分の印がある前回の中断一時領域だけを片付ける。"""
    for path in WORK.glob("build-*"):
        if path.is_symlink() or path.resolve().parent != WORK.resolve() or not path.is_dir():
            continue
        marker = path / ".pcinfo-build-temp"
        if marker.is_file() and marker.read_text("ascii") == "PCInfoClassic-WindowsBuild-v1":
            shutil.rmtree(path)


def clean_generated():
    """取得物・展開ツールは毎回片付ける。完成IMGとソースには触れない。"""
    parent = ROOT / "build/work"
    validate_work_paths()
    for path in (parent / "downloads", WORK / "toolchain"):
        if not path.exists():
            continue
        if path.is_symlink() or path.is_junction() or not path.resolve().is_relative_to(parent.resolve()):
            raise ValueError(f"ビルド作業領域のパスが不正です: {path}")
        shutil.rmtree(path)


def validate_work_paths():
    for path in (ROOT / "build", ROOT / "build/work", WORK):
        if path.is_symlink() or path.is_junction() or not path.resolve().is_relative_to(ROOT.resolve()):
            raise ValueError(f"ビルド作業領域のパスが不正です: {path}")


def prune_empty_work():
    for path in (WORK, WORK.parent):
        try:
            path.rmdir()
        except FileNotFoundError:
            pass
        except OSError as error:
            if error.errno not in (errno.ENOTEMPTY, errno.EEXIST):
                raise


@contextmanager
def build_lock():
    """同じ取得領域・出力を2つのビルドが同時更新しないようにする。"""
    validate_work_paths()
    WORK.mkdir(parents=True, exist_ok=True)
    lock_path = WORK / ".build.lock"
    acquired = False
    try:
        with lock_path.open("a+b") as lock:
            if lock.tell() == 0:
                lock.write(b"0")
                lock.flush()
            lock.seek(0)
            try:
                msvcrt.locking(lock.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError as error:
                raise RuntimeError("別のWindowsビルドが実行中です") from error
            acquired = True
            try:
                yield
            finally:
                lock.seek(0)
                msvcrt.locking(lock.fileno(), msvcrt.LK_UNLCK, 1)
    finally:
        if acquired:
            try:
                lock_path.unlink(missing_ok=True)
            except PermissionError as error:
                # 次のビルドが取得したファイルハンドルはWindowsの共有規則で保護される。
                if error.winerror != 32:
                    raise
            prune_empty_work()


def publish(image: Path, record: Path):
    """検証済みのIMGと記録を公開先へ移し、途中の失敗では前回分を復元する。"""
    paths = [image, record]
    backups = {}
    for path in paths:
        destination = OUTPUT / path.name
        if destination.exists():
            backup = image.parent / (path.name + ".previous")
            shutil.copyfile(destination, backup)
            backups[destination] = backup
    changed = []
    try:
        for path in paths:
            destination = OUTPUT / path.name
            os.replace(path, destination)
            changed.append(destination)
    except OSError:
        for destination in reversed(changed):
            if destination in backups:
                os.replace(backups[destination], destination)
            else:
                destination.unlink(missing_ok=True)
        raise


def unpack_grub(downloads: Downloads, config: dict) -> Path:
    """公式Windowsバイナリを照合し、プロジェクト内の専用領域に展開する。"""
    version = config["grub_version"]
    name = f"grub-{version}-for-windows.zip"
    archive = downloads.get(f"https://ftp.gnu.org/gnu/grub/{name}", name, config["grub_sha256"])
    tool_root = WORK / "toolchain/native"
    with zipfile.ZipFile(archive) as source:
        for item in source.infolist():
            # Windows生成ツールのみ使用。ターゲット部品はAlpine公式同版から取得する。
            if Path(item.filename).name not in ("grub-mkimage.exe", "grub-script-check.exe") and not item.filename.endswith(".dll"):
                continue
            target = (tool_root / item.filename).resolve()
            if not target.is_relative_to(tool_root.resolve()):
                raise ValueError("GRUBアーカイブ内のパスが不正です")
            source.extract(item, tool_root)
    return tool_root / f"grub-{version}-for-windows"


def target_grub(downloads: Downloads, config: dict, grub: Path) -> list[dict]:
    """Windowsツールと同じ版の公式ターゲット部品を取得する。Linux実行はしない。"""
    branch = config["grub_repository_branch"]
    base = f"{config['alpine_mirror']}/v{branch}/main/x86_64"
    index = downloads.get(f"{base}/APKINDEX.tar.gz", f"{branch}-main-APKINDEX.tar.gz", mutable=True)
    catalog = read_index(index, "main")
    records = []
    for name, platform in (("grub-bios", "i386-pc"), ("grub-efi", "x86_64-efi")):
        package = next((p for p in catalog if p.name == name), None)
        if package is None or package.version.split("-r")[0] != config["grub_version"]:
            raise ValueError(f"Windows生成ツールと同版の{name}がありません")
        archive = downloads.get(f"{base}/{package.filename}", package.filename)
        verify_apk(archive, package)
        destination = grub / "platforms" / platform
        if not destination.resolve().is_relative_to(WORK.resolve()):
            raise ValueError("GRUB部品の出力先がプロジェクトのビルド領域外です")
        if destination.exists():
            shutil.rmtree(destination)
        destination.mkdir(parents=True)
        _, data = apk_streams(archive.read_bytes())
        prefix = f"usr/lib/grub/{platform}/"
        with tarfile.open(fileobj=io.BytesIO(zlib.decompress(data, 31))) as source:
            for entry in source:
                if entry.isfile() and entry.name.startswith(prefix):
                    target = (destination / entry.name[len(prefix):]).resolve()
                    if not target.is_relative_to(destination.resolve()):
                        raise ValueError("GRUB部品のパスが不正です")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(source.extractfile(entry).read())
        if not (destination / "kernel.img").is_file():
            raise ValueError(f"GRUB kernel.imgがありません: {platform}")
        records.append({"name": package.name, "version": package.version, "branch": branch,
                        "url": f"{base}/{package.filename}", "sha256": sha256(archive)})
    return records


def boot_payload(downloads: Downloads, config: dict, stage: Path) -> dict[str, Path]:
    """公式Alpine ISOからカーネル・USB用initramfs・modloopを取り出す。"""
    version, arch = config["alpine_version"], config["architecture"]
    branch = ".".join(version.split(".")[:2])
    base = f"{config['alpine_mirror']}/v{branch}/releases/{arch}"
    name = f"alpine-standard-{version}-{arch}.iso"
    checksum = downloads.get(f"{base}/{name}.sha256", name + ".sha256")
    expected = checksum.read_text("ascii").split()[0]
    if not re.fullmatch(r"[0-9a-fA-F]{64}", expected):
        raise ValueError("Alpine ISOの公開チェックサムが不正です")
    archive = downloads.get(f"{base}/{name}", name, expected)
    payload = {}
    iso = pycdlib.PyCdlib()
    try:
        iso.open(str(archive))
        for name in ("vmlinuz-lts", "initramfs-lts", "modloop-lts"):
            target = stage / name
            iso.get_file_from_iso(str(target), rr_path=f"/boot/{name}")
            if not target.stat().st_size:
                raise ValueError(f"空の起動ファイル: {name}")
            payload[f"boot/{name}"] = target
        marker = stage / "boot_repository"
        iso.get_file_from_iso(str(marker), rr_path="/apks/.boot_repository")
        payload["apks/.boot_repository"] = marker
    finally:
        iso.close()
    return payload


def packages(downloads: Downloads, config: dict, payload: dict) -> tuple[list, dict]:
    """baseと診断ツールの全依存を取得し、公式indexのチェックサムを照合する。"""
    version = config["alpine_version"]
    branch = ".".join(version.split(".")[:2])
    base = f"{config['alpine_mirror']}/v{branch}"
    all_packages, indexes = [], {}
    for repo in ("main", "community"):
        path = downloads.get(f"{base}/{repo}/x86_64/APKINDEX.tar.gz",
                             f"{branch}-{repo}-APKINDEX.tar.gz", mutable=True)
        indexes[repo] = path
        all_packages.extend(read_index(path, repo))
    selected = resolve(all_packages, config["packages"] + config["overlay_packages"])
    files = {}
    log(f"パッケージ依存: {len(selected)}件")
    for package in selected:
        path = downloads.get(f"{base}/{package.repo}/x86_64/{package.filename}", package.filename)
        verify_apk(path, package)
        payload[f"apks/x86_64/{package.filename}"] = path
        files[package.name] = path
    # 初期起動のalpine-baseは署名付きmain indexから導入される。
    # community由来ツールはsetup.startで依存閉包のAPKを直接指定して導入する。
    payload["apks/x86_64/APKINDEX.tar.gz"] = indexes["main"]
    return selected, files


def memtest(downloads: Downloads, config: dict, stage: Path, payload: dict):
    version = config["memtest_version"]
    name = f"mt86plus_{version}.binaries.zip"
    path = downloads.get(f"https://memtest.org/download/v{version}/{name}", name)
    with zipfile.ZipFile(path) as source:
        matches = [n for n in source.namelist() if n.endswith("_x86_64")]
        if len(matches) != 1:
            raise ValueError("Memtest x86_64バイナリを特定できません")
        data = source.read(matches[0])
    # 公式x86_64バイナリはEFIとLinux boot protocol両用。
    if data[:2] != b"MZ" or data[0x202:0x206] != b"HdrS":
        raise ValueError("MemtestのEFI/Linux形式が不正です")
    for suffix in ("efi", "bin"):
        target = stage / f"memtest.{suffix}"
        target.write_bytes(data)
        payload[f"boot/memtest.{suffix}"] = target


def license_files(config: dict, selected: list, grub_records: list) -> dict[str, bytes]:
    """静的注意書きと、実際に選択したパッケージの一覧・出典をまとめる。"""
    result = {"LICENSE": (ROOT / "LICENSE").read_bytes()}
    for path in (ROOT / "licenses").rglob("*"):
        if path.is_file():
            result[path.relative_to(ROOT / "licenses").as_posix()] = path.read_bytes()
    for name in ("COPYING.GPL-2.0", "COPYING.GPL-3.0", "COPYING.LGPL-2.1", "COPYING.APACHE-2.0"):
        if name not in result or not result[name]:
            raise ValueError(f"同梱ライセンス本文がありません: {name}")
    branch = ".".join(config["alpine_version"].split(".")[:2])
    rows = ["package\tversion\torigin\trepo\tlicense"]
    locations = ["package\tversion\torigin\trepo\tlicense\tpackage_page\tapkbuild_tree"]
    for p in selected:
        origin = p.fields.get("o", p.name)
        fields = [p.name, p.version, origin, p.repo, p.fields.get("L", "")]
        rows.append("\t".join(fields))
        locations.append("\t".join(fields + [
            f"https://pkgs.alpinelinux.org/package/v{branch}/{p.repo}/x86_64/{p.name}",
            f"https://gitlab.alpinelinux.org/alpine/aports/-/tree/{branch}-stable/{p.repo}/{origin}"]))
    result["BUNDLED_PACKAGES.tsv"] = ("\n".join(rows) + "\n").encode()
    result["SOURCE_LOCATIONS"] = ("\n".join(locations) + "\n").encode()
    result["BOOT_COMPONENTS.txt"] = (
        f"Alpine standard {config['alpine_version']} (kernel, initramfs, modloop)\n"
        f"GNU GRUB {config['grub_version']} (BIOS and x86_64 UEFI), GPL-3.0-or-later\n"
        f"Source: https://ftp.gnu.org/gnu/grub/grub-{config['grub_version']}.tar.xz\n"
        f"Memtest86+ {config['memtest_version']}, GPL-2.0-only, https://memtest.org/\n"
        "pci.ids, GPL-2.0-or-later OR BSD-3-Clause, https://pci-ids.ucw.cz/\n"
        + "\n".join(f"{p['name']} {p['version']}: {p['url']}\n"
                    f"Alpine packaging: https://gitlab.alpinelinux.org/alpine/aports/-/tree/{p['branch']}-stable/main/grub"
                    for p in grub_records) + "\n"
    ).encode()
    return result


def build_overlay(downloads: Downloads, config: dict, stage: Path, selected: list,
                  apk_files: dict, grub_records: list) -> Path:
    overlay = Overlay()
    for package in resolve(selected, config["overlay_packages"]):
        overlay.package(apk_files[package.name])
    # 保持しているkexec向け調整を、Windowsでも同じバイト置換で適用する。
    binary = "usr/sbin/kexec"
    if binary not in overlay.entries:
        raise ValueError("kexecの同梱元が見つかりません")
    info, content = overlay.entries[binary]
    original, replacement = b"/sys/firmware/memmap", b"/sys/firmware/NOSCAN"
    if original not in content:
        raise ValueError("kexecの既知の調整対象が変わっています。パッチの見直しが必要です")
    overlay.entries[binary] = (info, content.replace(original, replacement))

    templates = ROOT / "tools/packaging/overlay"
    for path in templates.rglob("*"):
        if path.is_file():
            relative = path.relative_to(templates).as_posix()
            overlay.add(relative, path.read_bytes().replace(b"\r\n", b"\n"), 0o644)
    overlay.add("etc/hostname", b"pcinfo\n")
    add_application_files(overlay, ROOT)
    pci = downloads.get("https://pci-ids.ucw.cz/v2.2/pci.ids", "pci.ids", mutable=True).read_bytes()
    devices, subsystems = gpu_databases(pci)
    for name, data in (("pci.ids", pci), ("gpu_pci_ids.txt", devices),
                       ("gpu_pci_subsystem_ids.txt", subsystems)):
        overlay.add("opt/pcinfo/" + name, data)
    for name, data in license_files(config, selected, grub_records).items():
        overlay.add("usr/share/licenses/pcinfo-classic/" + name, data)
    output = stage / "pcinfo.apkovl.tar.gz"
    overlay.write(output)
    verify_overlay(ROOT, output)
    return output


def grub_files(config: dict, stage: Path, grub: Path, payload: dict) -> tuple[bytes, bytes]:
    """Windows版grub-mkimageでEFIとBIOS coreを両方生成する。"""
    early = "search --no-floppy --label --set=root PCINFO\nset prefix=($root)/boot/grub\nnormal\n"
    (grub / "pcinfo-early.cfg").write_text(early, "ascii", newline="\n")
    common = "fat normal boot configfile echo ls search search_label search_fs_uuid part_gpt part_msdos test loadenv linux".split()
    for target, out, extra in (("x86_64-efi", "pcinfo-BOOTX64.EFI", ["efi_gop", "efi_uga", "chain"]),
                               ("i386-pc", "pcinfo-core.img", ["biosdisk", "linux16"])):
        command = [str(grub / "grub-mkimage.exe"), "-d", "platforms/" + target, "-O", target,
                   "-p", "/boot/grub", "-c", "pcinfo-early.cfg", "-o", out] + common + extra
        subprocess.run(command, cwd=grub, check=True)
    efi = stage / "BOOTX64.EFI"
    shutil.copyfile(grub / "pcinfo-BOOTX64.EFI", efi)
    if efi.read_bytes()[:2] != b"MZ":
        raise ValueError("GRUB EFIのPEヘッダーが不正です")
    payload["EFI/BOOT/BOOTX64.EFI"] = efi
    # 公式ISOと同じ.boot_repositoryを使い、USBのデバイス名に依存させない。
    parameters = (f"modloop=/boot/modloop-lts modules={config['boot_modules']} "
                  f"{config['kernel_parameters']} quiet alpine_repo=auto usbdelay=3")
    text = f'''set default="pcinfo"
set timeout=0
load_env -f ($root)/grubenv
if [ "${{memtest_next}}" = "1" ]; then
    set memtest_next=0
    save_env -f ($root)/grubenv memtest_next
    set default="memtest"
fi
menuentry "PCInfo Classic" --id pcinfo {{
    if [ "$grub_platform" = "pc" ]; then
        linux /boot/vmlinuz-lts {parameters} memmap=640K@0
    else
        linux /boot/vmlinuz-lts {parameters}
    fi
    initrd /boot/initramfs-lts
}}
menuentry "Memtest86+" --id memtest {{
    if [ "$grub_platform" = "efi" ]; then
        chainloader /boot/memtest.efi
    else
        linux16 /boot/memtest.bin
    fi
}}
'''
    configfile = stage / "grub.cfg"
    configfile.write_text(text, "ascii", newline="\n")
    # 引数をASCII相対パスにし、日本語を含むプロジェクトパスでもGNUツールを使う。
    shutil.copyfile(configfile, grub / "pcinfo-grub.cfg")
    subprocess.run([str(grub / "grub-script-check.exe"), "pcinfo-grub.cfg"], cwd=grub, check=True)
    payload["boot/grub/grub.cfg"] = configfile
    env = stage / "grubenv"
    env.write_bytes(b"# GRUB Environment Block\nmemtest_next=0\n".ljust(1024, b"#"))
    payload["grubenv"] = env
    return (grub / "platforms/i386-pc/boot.img").read_bytes(), (grub / "pcinfo-core.img").read_bytes()


def run(args):
    if sys.platform != "win32":
        raise RuntimeError("ビルドはWindows 11上で実行してください")
    WORK.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    inputs = source_snapshot(ROOT)
    config = load_config(ROOT)
    downloads = Downloads(ROOT / "build/work/downloads", offline=args.offline, refresh=args.refresh)
    # tempファイルやGRUBの子プロセスもプロジェクト内に閉じ込める。
    with tempfile.TemporaryDirectory(prefix="build-", dir=WORK) as temporary:
        stage = Path(temporary)
        (stage / ".pcinfo-build-temp").write_text("PCInfoClassic-WindowsBuild-v1", "ascii")
        previous = {key: os.environ.get(key) for key in ("TEMP", "TMP", "TMPDIR")}
        try:
            for key in previous:
                os.environ[key] = str(stage)
            log("Windowsビルド: OS取得・依存解決・BIOS/UEFI生成・IMG組立て")
            grub = unpack_grub(downloads, config)
            grub_records = target_grub(downloads, config, grub)
            payload = boot_payload(downloads, config, stage)
            selected, apk_files = packages(downloads, config, payload)
            memtest(downloads, config, stage, payload)
            payload["pcinfo.apkovl.tar.gz"] = build_overlay(downloads, config, stage, selected, apk_files, grub_records)
            boot, core = grub_files(config, stage, grub, payload)
            image = stage / "pcinfo-classic.img"
            log("空のIMGへMBR・FAT32・同梱ファイルを生成しています")
            manifest = create_image(image, payload, boot, core, config["minimum_image_mb"], config["volume_label"])
            log("IMG内の全ファイルと起動領域を照合しています")
            verify_image(image, manifest)
            verify_source_snapshot(ROOT, inputs)
            manifest.update({"config": config, "image_sha256": sha256(image),
                             "source_inputs": inputs,
                             "grub_packages": grub_records,
                             "downloads": downloads.used, "hardware_boot_test": "not performed"})
            record = stage / "pcinfo-classic.manifest.json"
            record.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", "utf-8")
            # 全検査を通ってから出力へ昇格する。途中失敗で前回IMGを壊さない。
            publish(image, record)
            log(f"ビルド完了: {OUTPUT / image.name}")
            log(f"SHA-256: {manifest['image_sha256']}")
            log("別PCでのBIOS/UEFI起動・GPU・ストレージ・Memtest確認は未実施です")
        finally:
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offline", action="store_true", help="検証済み取得キャッシュのみ使用する")
    parser.add_argument("--refresh", action="store_true", help="APKINDEX・pci.idsを再取得する")
    args = parser.parse_args()
    if args.offline and args.refresh:
        parser.error("--offlineと--refreshは併用できません")
    try:
        with build_lock():
            try:
                clean_abandoned()
                run(args)
            finally:
                clean_generated()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"ビルド失敗: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
