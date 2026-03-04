#!/bin/bash
# test.sh - QEMUでpcinfo-classic.isoをテスト起動し、結果をログに保存する
# Usage: bash build/test.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ISO="$SCRIPT_DIR/pcinfo-classic.iso"
KERNEL="$SCRIPT_DIR/work/iso_extract/boot/vmlinuz64"
INITRD="$SCRIPT_DIR/work/iso_extract/boot/corepure64.gz"
LOG="$SCRIPT_DIR/test_result.log"
TIMEOUT=240

die() { echo "[ERROR] $*" >&2; exit 1; }

[ -f "$KERNEL" ] || die "カーネルが見つかりません。先に build.sh を実行してください: $KERNEL"
[ -f "$INITRD" ] || die "initrdが見つかりません。先に build.sh を実行してください: $INITRD"
command -v qemu-system-x86_64 > /dev/null 2>&1 || die "qemu-system-x86_64 がインストールされていません"

echo "[test] QEMU でテスト起動します（最大 ${TIMEOUT} 秒）..."
echo "[test] ログ保存先: $LOG"

rm -f "$LOG"

timeout "$TIMEOUT" qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "loglevel=3 console=ttyS0" \
    -m 512M \
    -display none \
    -serial file:"$LOG" \
    -no-reboot \
    2>/dev/null || true

if [ -s "$LOG" ]; then
    echo ""
    echo "========================================"
    echo "  テスト結果"
    echo "========================================"
    cat "$LOG"
    echo ""
    echo "[test] ログファイル: $LOG"
else
    die "ログが空です。タイムアウトか起動失敗の可能性があります"
fi
