"""IMG生成や実機操作なしで、実際に同梱するjqプログラムを検証する。"""
import json
import unittest
from pathlib import Path

import jq

ROOT = Path(__file__).resolve().parents[1]
CASES = json.loads((ROOT / "tests/fixtures/diagnostics.json").read_text("utf-8"))


class DiagnosticParserTests(unittest.TestCase):
    def test_smart_health_and_metadata(self):
        source = (ROOT / "src/smart_health.jq").read_text("utf-8")
        for case in CASES["smart"]:
            with self.subTest(case=case["name"]):
                result = jq.compile(source, args={"exit_status": case["exit"]}).input_value(case["input"]).first()
                for key, expected in case["expected"].items():
                    self.assertEqual(result[key], expected)
                self.assertTrue(result["reason"])

    def test_pci_card_and_legacy_gpu_logs(self):
        source = (ROOT / "src/gpu_logs.jq").read_text("utf-8")
        for case in CASES["gpu"]:
            with self.subTest(case=case["name"]):
                program = jq.compile(source, args={"mode": "cu", **{key: case[key] for key in ("pci", "card", "single")}})
                self.assertEqual(program.input_value(case["log"]).all(),
                                 [] if case["expected"] is None else [case["expected"]])

    def test_malformed_smart_json_does_not_produce_a_verdict(self):
        source = (ROOT / "src/smart_health.jq").read_text("utf-8")
        program = jq.compile(source, args={"exit_status": 0})
        for text in ("not-json", '[]', '{"smart_status":{"passed":true}} trailing-garbage'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                program.input_text(text).all()

    def test_each_existing_amd_rule_cu_remains_readable(self):
        """原本の全CU数を、従来の単一GPUログ・PCI付きログの両方から取得する。"""
        source = (ROOT / "src/gpu_logs.jq").read_text("utf-8")
        program = jq.compile(source, args={"mode": "cu", "pci": "0000:01:00.0", "card": "card2", "single": "1"})
        for row in (ROOT / "data/gpu/gpu_amd_cu_vram_rules.txt").read_text("utf-8").splitlines():
            if not row or row.startswith("#"):
                continue
            device, cu, _, name = row.split("|")
            for log in (f"amdgpu: active_cu_number {cu}",
                        f"amdgpu: {cu} CU per SH",
                        f"amdgpu 0000:01:00.0: active_cu_number {cu}"):
                with self.subTest(device=device, model=name, log=log):
                    self.assertEqual(program.input_value(log).all(), [int(cu)])

    def test_vram_logs_are_from_the_target_gpu(self):
        source = (ROOT / "src/gpu_logs.jq").read_text("utf-8")
        for case in CASES["vram"]:
            with self.subTest(case=case["name"]):
                program = jq.compile(source, args={"mode": "vram", **{key: case[key] for key in ("pci", "card", "single")}})
                self.assertEqual(program.input_value(case["log"]).all(), case["expected"])


if __name__ == "__main__":
    unittest.main()
