#!/bin/sh
# menu_memtest.sh - メモリテスト画面

. /opt/common.sh

CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# grubenvにsaved_entry=memtestを設定してmemtest86+を自動起動
set_next_boot_memtest() {
    # EFIパーティション（ラベル: EFI）をマウントしてgrubenvを書き換え
    for dev in /dev/sd[a-z][0-9]* /dev/nvme*p[0-9]*; do
        [ -b "$dev" ] || continue
        label=$(blkid -s LABEL -o value "$dev" 2>/dev/null)
        if [ "$label" = "EFI" ]; then
            mnt="/tmp/efi_mnt_$$"
            mkdir -p "$mnt"
            if mount -o rw "$dev" "$mnt" 2>/dev/null; then
                grubenv="$mnt/boot/grub/grubenv"
                if [ -f "$grubenv" ]; then
                    # grubenv書き換え（1024バイト固定、#でパディング）
                    dd if=/dev/zero bs=1024 count=1 2>/dev/null | tr '\000' '#' > "$grubenv"
                    printf '# GRUB Environment Block\nsaved_entry=memtest\n' | \
                        dd of="$grubenv" conv=notrunc 2>/dev/null
                    sync
                    umount "$mnt" 2>/dev/null
                    rmdir "$mnt" 2>/dev/null
                    return 0
                fi
                umount "$mnt" 2>/dev/null
            fi
            rmdir "$mnt" 2>/dev/null
        fi
    done
    return 1
}

# メイン処理
printf '\033[2J\033[H' > "$TTY" 2>/dev/null
{
    printf "\n${BOLD}${CYAN}[メモリテスト]${RESET}\n\n"
    printf "  memtest86+ によりメモリをテストします。\n\n"
    printf "  - 再起動後、自動的にテストを開始します。\n"
    printf "  - テスト終了後は Esc で PCInfo classic に自動復帰します。\n\n"
    printf "  Enter: 開始   q: キャンセル\n"
} | "$FBPRINT" "$FONT" "$FB"

while true; do
    read_key
    case "$key" in
        q|Q) break ;;
        ''|' ')
            printf '\033[2J\033[H' > "$TTY" 2>/dev/null
            printf "\n${BOLD}${CYAN}[メモリテスト]${RESET}\n\n起動準備中...\n" | "$FBPRINT" "$FONT" "$FB"
            
            if set_next_boot_memtest; then
                sleep 1
                reboot
                exit 0
            else
                printf '\033[2J\033[H' > "$TTY" 2>/dev/null
                {
                    printf "\n${BOLD}${CYAN}[メモリテスト]${RESET}\n\n"
                    printf "自動起動に対応していません。\n"
                    printf "(USBイメージ形式で書き込んでください)\n\n"
                    printf "q: 戻る\n"
                } | "$FBPRINT" "$FONT" "$FB"
                while true; do read_key; case "$key" in q|Q) break 2 ;; esac; done
            fi
            ;;
    esac
done
