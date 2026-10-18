"""診断アプリの同梱配置・権限を定義し、生成時と検証時に共用する。"""
import tarfile
from pathlib import Path

from .elf import verify_libraries
from .overlay import Overlay


# プロジェクト内の原本: (IMG内の配置先, Linux権限)。改行は同梱時にLFへ揃える。
APPLICATION_FILES = {
    **{f"src/{name}": (f"opt/pcinfo/{name}", 0o755) for name in (
        "common.sh", "menu.sh", "menu_pcinfo.sh", "menu_storage.sh",
        "menu_gpu.sh", "menu_memtest.sh", "pcinfo.sh")},
    "src/boot/setup.sh": ("etc/local.d/00-pcinfo-setup.start", 0o755),
    "src/boot/autologin.sh": ("usr/sbin/autologin", 0o755),
    **{f"src/lib/{name}.sh": (f"opt/pcinfo/lib/{name}.sh", 0o755) for name in (
        "display", "media", "gpu", "storage", "hardware")},
    **{f"src/{name}": (f"opt/pcinfo/{name}", 0o644) for name in (
        "smart_health.jq", "gpu_logs.jq", "storage_devices.jq")},
    **{f"data/gpu/{name}": (f"opt/pcinfo/{name}", 0o644) for name in (
        "gpu_disambiguation_rules.txt", "gpu_amd_cu_vram_rules.txt",
        "gpu_nvidia_literal_rules.txt", "gpu_nvidia_vram_rules.txt")},
}
APPLICATION_LINKS = {
    "etc/runlevels/default/local": "/etc/init.d/local",
    "etc/runlevels/sysinit/modloop": "/etc/init.d/modloop",
    "opt/pcinfo/start": "/opt/pcinfo/menu.sh",
}


def add_application_files(overlay: Overlay, root: Path) -> None:
    for destination, link in APPLICATION_LINKS.items():
        overlay.add(destination, mode=0o777, link=link)
    for name, (destination, mode) in APPLICATION_FILES.items():
        overlay.add(destination, (root / name).read_bytes().replace(b"\r\n", b"\n"), mode)


def verify_overlay(root: Path, path) -> None:
    """本体・ルール・実行属性・必須リンクを元ファイルと照合する。"""
    options = {"fileobj": path} if hasattr(path, "read") else {"name": path}
    with tarfile.open(mode="r:gz", **options) as source:
        for name, (destination, mode) in APPLICATION_FILES.items():
            target = source.getmember(destination)
            expected = (root / name).read_bytes().replace(b"\r\n", b"\n")
            if source.extractfile(target).read() != expected:
                raise ValueError(f"apkovl同梱内容の不一致: {name}")
            if mode & 0o111 and target.mode & 0o111 != 0o111:
                raise ValueError(f"apkovl実行権限の不一致: {name}")
        for name, link in APPLICATION_LINKS.items():
            entry = source.getmember(name)
            if not entry.issym() or entry.linkname != link:
                raise ValueError(f"apkovlリンクの不一致: {name}")
        if source.getmember("usr/sbin/kexec").mode & 0o111 == 0:
            raise ValueError("kexecが実行可能になっていません")
        verify_libraries(source)
