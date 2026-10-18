"""設定と診断アプリの同梱照合を、IMG生成なしで検査する。"""
import io
import json
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from pcinfo_build.config import load_config
from pcinfo_build.overlay import Overlay
from pcinfo_build.payload import APPLICATION_FILES, APPLICATION_LINKS, add_application_files, verify_overlay


class BuildPayloadTests(unittest.TestCase):
    def setUp(self):
        directory = ROOT / ".cache/verification"
        directory.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(dir=directory, prefix="payload-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.root = self.work / "source"
        for name in (*APPLICATION_FILES, "tools/packaging/build_config.json"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / name).read_bytes())
        self.archive = self.work / "overlay.tar.gz"

    def application_overlay(self):
        overlay = Overlay()
        add_application_files(overlay, self.root)
        # 実行権限検査のための合成データ。実際のkexecを実行する試験ではない。
        overlay.add("usr/sbin/kexec", b"synthetic executable\n", 0o755)
        return overlay

    def test_config_accepts_current_values_and_rejects_invalid_or_mismatched_values(self):
        path = self.root / "tools/packaging/build_config.json"
        original = json.loads(path.read_text("utf-8"))
        self.assertEqual(load_config(self.root), original)
        for key, invalid in (
            ("alpine_version", "3.21/latest"), ("grub_version", "current"),
            ("memtest_version", "8.01"), ("architecture", "aarch64"),
            ("volume_label", "OTHER"), ("minimum_image_mb", 511),
            ("minimum_image_mb", 32769), ("packages", ["bad/name"]),
            ("overlay_packages", ["bad name"]), ("grub_repository_branch", "latest"),
        ):
            with self.subTest(key=key, value=invalid):
                path.write_text(json.dumps({**original, key: invalid}), "utf-8")
                with self.assertRaises(ValueError):
                    load_config(self.root)

    def test_application_payload_matches_sources_and_linux_attributes(self):
        # 新しい診断ソースを同梱一覧へ追加し忘れた場合も検出する。
        sources = {path.relative_to(ROOT).as_posix()
                   for path in (ROOT / "src").rglob("*") if path.suffix in (".sh", ".jq")}
        sources.update(path.relative_to(ROOT).as_posix() for path in (ROOT / "data/gpu").glob("*.txt"))
        self.assertEqual(set(APPLICATION_FILES), sources)
        overlay = self.application_overlay()
        overlay.write(self.archive)
        verify_overlay(self.root, self.archive)
        verify_overlay(self.root, io.BytesIO(self.archive.read_bytes()))
        with tarfile.open(self.archive) as archive:
            for name, (destination, mode) in APPLICATION_FILES.items():
                with self.subTest(name=name):
                    entry = archive.getmember(destination)
                    self.assertEqual(entry.mode, mode)
                    self.assertEqual(archive.extractfile(entry).read(),
                                     (self.root / name).read_bytes().replace(b"\r\n", b"\n"))

    def test_changed_source_and_archive_content_are_rejected(self):
        overlay = self.application_overlay()
        overlay.write(self.archive)
        path = self.root / "src/common.sh"
        original = path.read_bytes()
        path.write_bytes(original + b"# changed\n")
        with self.assertRaisesRegex(ValueError, "同梱内容の不一致"):
            verify_overlay(self.root, self.archive)
        path.write_bytes(original)
        overlay.add("opt/pcinfo/common.sh", b"damaged\n", 0o755)
        overlay.write(self.archive)
        with self.assertRaisesRegex(ValueError, "同梱内容の不一致"):
            verify_overlay(self.root, self.archive)

    def test_missing_execution_permissions_are_rejected(self):
        for name, mode in (("opt/pcinfo/common.sh", 0o644),
                           ("usr/sbin/autologin", 0o744), ("usr/sbin/kexec", 0o644)):
            with self.subTest(name=name, mode=oct(mode)):
                overlay = self.application_overlay()
                overlay.entries[name][0].mode = mode
                overlay.write(self.archive)
                with self.assertRaisesRegex(ValueError, "実行権限|実行可能"):
                    verify_overlay(self.root, self.archive)

    def test_missing_or_retargeted_boot_links_are_rejected(self):
        for name in APPLICATION_LINKS:
            for missing in (True, False):
                with self.subTest(name=name, missing=missing):
                    overlay = self.application_overlay()
                    if missing:
                        del overlay.entries[name]
                    else:
                        overlay.add(name, link="/wrong/target")
                    overlay.write(self.archive)
                    with self.assertRaises((KeyError, ValueError)):
                        verify_overlay(self.root, self.archive)


if __name__ == "__main__":
    unittest.main()
