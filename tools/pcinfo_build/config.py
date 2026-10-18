"""ビルド・完成IMGの照合で共用する設定読込みと整合性検査。"""
import json
import re
from pathlib import Path


def load_config(root: Path) -> dict:
    config = json.loads((root / "tools/packaging/build_config.json").read_text("utf-8"))
    for key in ("alpine_version", "grub_version", "memtest_version"):
        if not re.fullmatch(r"\d+(?:\.\d+){1,2}", config[key]):
            raise ValueError(f"版指定が不正です: {key}")
    if config["architecture"] != "x86_64" or config["volume_label"] != "PCINFO":
        raise ValueError("既存診断アプリはx86_64・PCINFOラベルを前提にしています")
    if not 512 <= config["minimum_image_mb"] <= 32768:
        raise ValueError("IMGの最小サイズは512～32768MiBにしてください")
    for name in config["packages"] + config["overlay_packages"]:
        if not re.fullmatch(r"[A-Za-z0-9+_.-]+", name):
            raise ValueError(f"パッケージ名が不正です: {name}")
    if not re.fullmatch(r"\d+\.\d+", config["grub_repository_branch"]):
        raise ValueError("GRUB部品のリポジトリ系列が不正です")
    menu = (root / "src/menu_memtest.sh").read_text("utf-8")
    if f'Memtest86+ {config["memtest_version"]}' not in menu:
        raise ValueError("Memtestの設定版とsrc/menu_memtest.shの表示版を揃えてください")
    return config
