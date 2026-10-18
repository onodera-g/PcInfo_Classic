"""同梱するlsblk JSON解析をWindows上のjqで実行する。"""
import json
import unittest
from pathlib import Path

import jq

ROOT = Path(__file__).resolve().parents[1]


class StorageInventoryTests(unittest.TestCase):
    def setUp(self):
        self.program = jq.compile((ROOT / "src/storage_devices.jq").read_text("utf-8"))

    def test_fields_source_order_and_large_capacities_are_preserved(self):
        devices = [
            {"name": "nvme0n1", "model": "Sample NVMe", "size": 2000398934016,
             "tran": "nvme", "type": "disk"},
            {"name": "sda", "model": "USB Drive", "size": "64000000000", "tran": "usb", "type": "disk"},
            {"name": "sr0", "model": "DVD", "size": 0, "tran": "sata", "type": "rom"},
        ]
        expected = [{**device, "size": str(device["size"])} for device in devices]
        self.assertEqual(self.program.input_value({"blockdevices": devices}).all(), expected)

    def test_missing_values_do_not_shift_fields_or_drop_zero(self):
        data = {"blockdevices": [
            {"name": "sda", "model": None, "size": 0, "tran": None, "type": "disk"},
            {"name": "mmcblk0", "type": "disk"},
            {"name": "", "type": "disk"}, {"name": "loop0"}, None,
        ]}
        self.assertEqual(self.program.input_value(data).all(), [
            {"name": "sda", "model": "", "size": "0", "tran": "", "type": "disk"},
            {"name": "mmcblk0", "model": "", "size": "", "tran": "", "type": "disk"},
        ])

    def test_quoted_and_escaped_names_remain_intact(self):
        model = 'ACME "Pro" \\ disk\t2'
        data = {"blockdevices": [{"name": "sda", "model": model, "size": 12345,
                                   "tran": "sata", "type": "disk"}]}
        record = self.program.input_text(json.dumps(data)).first()
        self.assertEqual(record["model"], model)
        self.assertEqual(record["name"], "sda")

    def test_empty_inventory_is_valid_and_malformed_inventory_is_rejected(self):
        self.assertEqual(self.program.input_value({"blockdevices": []}).all(), [])
        for text in ("not-json", "[]", "null", "{}", '{"blockdevices":{}}',
                     '{"blockdevices":[]} trailing-garbage'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.program.input_text(text).all()


if __name__ == "__main__":
    unittest.main()
