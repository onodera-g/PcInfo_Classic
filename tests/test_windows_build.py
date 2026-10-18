"""依存解決・Linux属性保持・破損検知を、固定の合成データで検査する。"""
import io
import json
import struct
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from pcinfo_build.alpine import Package, resolve, satisfies
from pcinfo_build.downloads import Downloads
from pcinfo_build.image import boot_sectors, create_image, verify_image, OFFSET
from pcinfo_build.overlay import Overlay, gpu_databases
from pcinfo_build.versions import compare
from pyfatfs.PyFatFS import PyFatFS


class BuildTests(unittest.TestCase):
    def setUp(self):
        directory = ROOT / ".cache/verification"
        directory.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=directory, prefix="test-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def test_cleanup_only_removes_marked_build_temporary_directories(self):
        import build_windows
        marked, unmarked = self.work / "build-marked", self.work / "build-user-folder"
        marked.mkdir()
        unmarked.mkdir()
        (marked / ".pcinfo-build-temp").write_text("PCInfoClassic-WindowsBuild-v1", "ascii")
        (unmarked / "keep.txt").write_text("preserve", "ascii")
        with patch.object(build_windows, "WORK", self.work):
            build_windows.clean_abandoned()
        self.assertFalse(marked.exists())
        self.assertEqual((unmarked / "keep.txt").read_text(), "preserve")

    def test_dependencies_include_shared_libraries_and_fail_if_missing(self):
        app = Package("app", "1.0-r0", "main", {"D": "so:libsample.so.1=1"})
        lib = Package("libsample", "2.0-r0", "main", {"p": "so:libsample.so.1=1"})
        self.assertEqual([p.name for p in resolve([app, lib], ["app"])], ["app", "libsample"])
        with self.assertRaisesRegex(ValueError, "依存を解決"):
            resolve([app], ["app"])

    def test_conflicting_packages_are_rejected(self):
        a = Package("a", "1-r0", "main", {"D": "!b"})
        b = Package("b", "1-r0", "main", {})
        with self.assertRaisesRegex(ValueError, "衝突"):
            resolve([a, b], ["a", "b"])

    def test_alpine_versions(self):
        for old, new in (("1.2.3_git20230424", "1.2.5-r11"), ("1.2_rc1", "1.2"),
                         ("1.2", "1.2_p1"), ("1.2-r0", "1.2-r1"),
                         ("1.2.01", "1.2.1"), ("1.2_alpha1", "1.2_beta1")):
            with self.subTest(old=old, new=new):
                self.assertLess(compare(old, new), 0)
                self.assertGreater(compare(new, old), 0)
        self.assertEqual(compare("1.2.5-r11", "1.2.5-r11"), 0)
        self.assertTrue(satisfies("1.2.5-r11", ">=", "1.2.3_git20230424"))
        self.assertFalse(satisfies("1.3-r0", "~", "1.2"))

    def test_overlay_preserves_case_permissions_and_absolute_linux_links(self):
        overlay = Overlay()
        overlay.add("opt/pcinfo/menu.sh", b"#!/bin/sh\n", 0o755)
        overlay.add("opt/pcinfo/GPU.txt", b"UPPER\n")
        overlay.add("opt/pcinfo/gpu.txt", b"lower\n")
        overlay.add("etc/runlevels/default/local", mode=0o777, link="/etc/init.d/local")
        target = self.work / "overlay.tar.gz"
        overlay.write(target)
        with tarfile.open(target) as archive:
            self.assertEqual(archive.getmember("opt/pcinfo/menu.sh").mode, 0o755)
            self.assertEqual(archive.extractfile("opt/pcinfo/GPU.txt").read(), b"UPPER\n")
            self.assertEqual(archive.extractfile("opt/pcinfo/gpu.txt").read(), b"lower\n")
            self.assertEqual(archive.getmember("etc/runlevels/default/local").linkname, "/etc/init.d/local")
        with self.assertRaises(ValueError):
            overlay.add("../../escape", b"bad")

    def test_gpu_tables_match_fixed_pci_ids(self):
        pci = b"1002  AMD\n\t731f  Sample GPU\n\t\t1234 5678  Sample Board\n1234  Other\n\t0001  Skip\n"
        devices, subsystems = gpu_databases(pci)
        self.assertIn(b"0x1002|0x731f|AMD|Sample GPU|\n", devices)
        self.assertIn(b"0x1002|0x731f|0x1234|0x5678|AMD|Sample Board|\n", subsystems)
        self.assertNotIn(b"Skip", devices)

    def test_cached_download_corruption_and_offline_missing_are_rejected(self):
        target = self.work / "artifact.zip"
        target.write_bytes(b"corrupted")
        target.with_name(target.name + ".json").write_text(json.dumps({
            "url": "https://example.invalid/artifact", "sha256": "0" * 64}), "utf-8")
        cache = Downloads(self.work, offline=True)
        with self.assertRaisesRegex(ValueError, "ハッシュ"):
            cache.get("https://example.invalid/artifact", "artifact.zip")
        with self.assertRaises(FileNotFoundError):
            cache.get("https://example.invalid/missing", "missing")

    def test_mbr_embedding_boundaries_and_fat_corruption(self):
        boot = bytes(510) + b"\x55\xaa"
        core = bytes(2048)
        mbr, embedded = boot_sectors(boot, core, 131072)
        self.assertEqual(struct.unpack_from("<Q", mbr, 0x5C)[0], 1)
        self.assertEqual(struct.unpack_from("<QHH", embedded, 500), (2, 3, 0x820))
        with self.assertRaises(ValueError):
            boot_sectors(boot, bytes(1048576), 131072)
        data = self.work / "hello.txt"
        data.write_bytes(b"expected payload")
        image = self.work / "test.img"
        manifest = create_image(image, {"boot/hello.txt": data}, boot, core, 64, "PCINFO")
        verify_image(image, manifest)
        with PyFatFS(str(image), offset=OFFSET) as filesystem:
            filesystem.writebytes("boot/hello.txt", b"damaged payload!")
        with self.assertRaisesRegex(ValueError, "ハッシュ"):
            verify_image(image, manifest)

    def test_failed_publish_restores_previous_output(self):
        import build_windows
        destination = self.work / "output"
        destination.mkdir()
        image, record = self.work / "current.img", self.work / "current.json"
        image.write_bytes(b"new image")
        record.write_bytes(b"new record")
        (destination / image.name).write_bytes(b"previous image")
        (destination / record.name).write_bytes(b"previous record")
        replace = build_windows.os.replace
        count = 0
        def fail_second(source, target):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("synthetic publish failure")
            return replace(source, target)
        with patch.object(build_windows, "OUTPUT", destination), patch.object(build_windows.os, "replace", fail_second):
            with self.assertRaises(OSError):
                build_windows.publish(image, record)
        self.assertEqual((destination / image.name).read_bytes(), b"previous image")
        self.assertEqual((destination / record.name).read_bytes(), b"previous record")


if __name__ == "__main__":
    unittest.main()
