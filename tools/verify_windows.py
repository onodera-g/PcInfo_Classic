"""Windows用回帰テストと、生成済みIMGの内容照合を実行する。"""
from pathlib import Path
import argparse
import hashlib
import io
import json
import sys
import unittest

from pcinfo_build.image import verify_image
from pyfatfs.PyFatFS import PyFatFS
from pcinfo_build.config import load_config
from pcinfo_build.payload import verify_overlay
from pcinfo_build.inputs import verify_source_snapshot

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tests-only", action="store_true", help="単体テストだけ実行し、完成IMGにはアクセスしない")
    args = parser.parse_args()
    suite = unittest.defaultTestLoader.discover(str(ROOT / "tests"))
    if not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful():
        return 1
    if args.tests_only:
        print("単体テスト: 合格（IMG生成・IMG検証・実機確認は未実施です）")
        return 0
    image = ROOT / "build/output/pcinfo-classic.img"
    record = image.with_name("pcinfo-classic.manifest.json")
    if not image.is_file() or not record.is_file():
        print("生成済みIMGがありません。先にビルドしてください。", file=sys.stderr)
        return 1
    manifest = json.loads(record.read_text("utf-8"))
    verify_source_snapshot(ROOT, manifest.get("source_inputs"))
    if manifest.get("config") != load_config(ROOT):
        raise ValueError("IMGのビルド設定が現在のソースと異なります。再ビルド後に検証してください")
    with image.open("rb") as source:
        if hashlib.file_digest(source, "sha256").hexdigest() != manifest["image_sha256"]:
            raise ValueError("IMG全体のSHA-256がビルド記録と一致しません")
    verify_image(image, manifest)
    with PyFatFS(str(image), offset=1048576, read_only=True) as filesystem:
        overlay = filesystem.readbytes("pcinfo.apkovl.tar.gz")
    verify_overlay(ROOT, io.BytesIO(overlay))
    print("IMG整合性確認: 合格（実機起動・診断は別PCで確認してください）")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"検証失敗: {error}", file=sys.stderr)
        raise SystemExit(1)
