"""IMGを生成せず、入力の追加・削除・変更と旧記録の拒否を検査する。"""
import copy
import tempfile
import unittest
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from pcinfo_build.inputs import FIXED_INPUTS, INPUT_TREES, source_snapshot, verify_source_snapshot


class InputSnapshotTests(unittest.TestCase):
    def setUp(self):
        work = ROOT / ".cache/verification"
        work.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=work, prefix="input-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in FIXED_INPUTS:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixed input\n")
        for name in (*INPUT_TREES, "tools/pcinfo_build"):
            path = self.root / name
            path.mkdir(parents=True, exist_ok=True)
            (path / ("sample.py" if name == "tools/pcinfo_build" else "sample.txt")).write_bytes(b"original\n")
        self.record = source_snapshot(self.root)

    def test_unchanged_inputs_are_accepted(self):
        verify_source_snapshot(self.root, self.record)

    def test_template_and_builder_changes_require_rebuild(self):
        for name in ("tools/packaging/sample.txt", "tools/build_windows.py", "tools/pcinfo_build/sample.py",
                     "src/sample.txt", "data/sample.txt", "licenses/sample.txt", "requirements-dev.txt"):
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_bytes()
                path.write_bytes(original + b"changed\n")
                with self.assertRaisesRegex(ValueError, "変更"):
                    verify_source_snapshot(self.root, self.record)
                path.write_bytes(original)

    def test_current_project_records_boot_settings_and_generation_code(self):
        files = source_snapshot(ROOT)["files"]
        for name in ("src/boot/setup.sh", "src/menu_memtest.sh", "src/lib/display.sh", "src/lib/gpu.sh",
                     "src/lib/storage.sh", "src/lib/hardware.sh", "src/storage_devices.jq",
                     "tools/packaging/overlay/etc/inittab",
                     "tools/packaging/overlay/etc/apk/world", "tools/packaging/overlay/root/.profile",
                     "tools/pcinfo_build/image.py", "tools/build_windows.py", "requirements-dev.txt"):
            self.assertIn(name, files)

    def test_missing_mandatory_input_is_not_ignored(self):
        (self.root / "tools/build_windows.py").unlink()
        with self.assertRaisesRegex(ValueError, "ビルド入力がありません"):
            verify_source_snapshot(self.root, self.record)

    def test_added_and_deleted_inputs_require_rebuild(self):
        path = self.root / "src/new_script.sh"
        path.write_bytes(b"new\n")
        with self.assertRaisesRegex(ValueError, "追加"):
            verify_source_snapshot(self.root, self.record)
        path.unlink()
        (self.root / "src/sample.txt").unlink()
        with self.assertRaisesRegex(ValueError, "削除"):
            verify_source_snapshot(self.root, self.record)

    def test_legacy_and_invalid_records_are_rejected(self):
        for record in (None, {}, {"format": 2, "files": {}}, {"format": True, "files": {}},
                       {"format": 1, "files": {"../outside": "invalid"}}):
            with self.subTest(record=record), self.assertRaises(ValueError):
                verify_source_snapshot(self.root, record)

    def test_verifier_never_opens_a_recorded_external_path(self):
        record = copy.deepcopy(self.record)
        record["files"]["../outside"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "削除"):
            verify_source_snapshot(self.root, record)

    def test_documentation_and_cache_are_not_image_inputs(self):
        for name in ("docs/note.md", "src/.cache/runtime/status", "tools/pcinfo_build/__pycache__/module.pyc"):
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"not an image input")
        verify_source_snapshot(self.root, self.record)


if __name__ == "__main__":
    unittest.main()
