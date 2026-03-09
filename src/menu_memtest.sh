#!/bin/sh
# menu_memtest.sh - メモリテスト画面

. /opt/common.sh

MEMTESTER=/usr/local/bin/memtester
KEXEC=/usr/local/bin/kexec
MEMTEST86=/boot/memtest86plus.bin

CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# 利用可能メモリ（MB）を取得、OSが使うので控えめに
get_available_memory_mb() {
    avail_kb=$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt 1024 ]; then
        avail_kb=$(grep '^MemFree:' /proc/meminfo 2>/dev/null | awk '{print $2}')
    fi
    avail_kb=${avail_kb:-0}
    # 安全マージンとして 128MB を引く
    avail_mb=$(( (avail_kb / 1024) - 128 ))
    [ "$avail_mb" -lt 64 ] && avail_mb=64
    echo "$avail_mb"
}

# メモリテスト選択
show_menu() {
    printf '\033[2J\033[H' > "$TTY" 2>/dev/null
    {
        printf "\n${BOLD}${CYAN}[メモリテスト]${RESET}\n\n"
        printf "  1. 簡易テスト (memtester)\n"
        printf "     OS上で動作。テスト後にこのメニューへ戻ります。\n"
        printf "     (OSが使用中のメモリはテスト対象外)\n\n"
        printf "  2. 本格テスト (memtest86+)\n"
        printf "     全物理メモリをテスト。テスト後は自動的に\n"
        printf "     PcInfo Classic へ戻ります。\n"
        printf "     (一時的にシステムが再起動します)\n\n"
        printf "  q. トップメニューへ戻る\n\n"
        printf "  Select [1-2/q]: "
    } | "$FBPRINT" "$FONT" "$FB"
}

# memtester 実行
run_memtester() {
    if [ ! -x "$MEMTESTER" ]; then
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        printf "\n${BOLD}${CYAN}[メモリテスト - 簡易テスト]${RESET}\n\nエラー: memtester が見つかりません\n\nq でメモリテスト選択へ戻る\n" | "$FBPRINT" "$FONT" "$FB"
        while true; do read_key; case "$key" in q|Q) return ;; esac; done
        return
    fi

    mem_mb=$(get_available_memory_mb)
    RESULT_FILE="/tmp/memtester_result.txt"
    
    printf '\033[2J\033[H' > "$TTY" 2>/dev/null
    {
        printf "\n${BOLD}${CYAN}[メモリテスト - 簡易テスト]${RESET}\n\n"
        printf "テスト対象: %s MB (1回ループ)\n" "$mem_mb"
        printf "テスト中... (Ctrl+C で中断)\n\n"
    } | "$FBPRINT" "$FONT" "$FB"

    # memtester を実行し、出力をファイルに保存しつつフレームバッファにも流す
    "$MEMTESTER" "${mem_mb}M" 1 2>&1 | tee "$RESULT_FILE" | "$FBPRINT" "$FONT" "$FB"
    
    # 結果を解析
    if grep -q "FAILURE" "$RESULT_FILE" 2>/dev/null; then
        result_status="エラーが検出されました"
        error_count=$(grep -c "FAILURE" "$RESULT_FILE" 2>/dev/null || echo "0")
    else
        result_status="全てのテストに合格しました"
        error_count=0
    fi

    # 結果表示（画面をクリアせず、続きに表示）
    {
        printf "\n----------------------------------------\n"
        printf "${BOLD}${CYAN}[結果]${RESET} %s\n" "$result_status"
        if [ "$error_count" -gt 0 ]; then
            printf "検出されたエラー: %s 件\n" "$error_count"
        fi
        printf "----------------------------------------\n"
        printf "q でメモリテスト選択へ戻る\n"
    } | "$FBPRINT" "$FONT" "$FB"
    
    rm -f "$RESULT_FILE"
    while true; do read_key; case "$key" in q|Q) return ;; esac; done
}

# memtest86+ 確認・実行
run_memtest86() {
    printf '\033[2J\033[H' > "$TTY" 2>/dev/null
    {
        printf "\n${BOLD}${CYAN}[メモリテスト - 本格テスト]${RESET}\n\n"
        printf "  memtest86+ を起動します。\n\n"
        printf "  - システムは一時的に再起動します\n"
        printf "  - テスト完了後は自動的に PcInfo Classic\n"
        printf "    へ戻ります (Esc キーで終了)\n\n"
        printf "  Enter: 開始   q: キャンセル\n"
    } | "$FBPRINT" "$FONT" "$FB"

    while true; do
        read_key
        case "$key" in
            q|Q) return ;;
            ''|' ')
                # Enter or Spaceで開始
                break
                ;;
        esac
    done

    # kexec でmemtest86+を起動
    if [ -x "$KEXEC" ] && [ -f "$MEMTEST86" ]; then
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        printf "\n${BOLD}${CYAN}[メモリテスト - 本格テスト]${RESET}\n\nmemtest86+ を起動しています...\n" | "$FBPRINT" "$FONT" "$FB"
        
        # kexecで直接起動を試みる (複数の方法を試す)
        kexec_ok=0
        for ktype in "" "--type=multiboot" "--type=elf-x86_64"; do
            "$KEXEC" -l "$MEMTEST86" $ktype 2>/dev/null && kexec_ok=1 && break
        done
        
        if [ "$kexec_ok" -eq 1 ]; then
            sync
            "$KEXEC" -e
            # kexec -e が成功した場合、ここには戻らない
        fi
        
        # kexecが失敗した場合、rebootにフォールバック
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        {
            printf "\n${BOLD}${CYAN}[メモリテスト - 本格テスト]${RESET}\n\n"
            printf "再起動後、GRUBメニューが表示されます。\n"
            printf "矢印キーで Memtest86+ を選択し、\n"
            printf "Enterを押してください。\n\n"
            printf "(5秒以内に選択しないと PcInfo Classic が起動します)\n\n"
            printf "Enter: 再起動   q: キャンセル\n"
        } | "$FBPRINT" "$FONT" "$FB"

        while true; do
            read_key
            case "$key" in
                q|Q) return ;;
                ''|' ')
                    reboot
                    ;;
            esac
        done
    else
        printf '\033[2J\033[H' > "$TTY" 2>/dev/null
        {
            printf "\n${BOLD}${CYAN}[メモリテスト - 本格テスト]${RESET}\n\n"
            printf "エラー: memtest86+ または kexec が\n"
            printf "見つかりません。\n\n"
            printf "q でメモリテスト選択へ戻る\n"
        } | "$FBPRINT" "$FONT" "$FB"
        while true; do read_key; case "$key" in q|Q) return ;; esac; done
    fi
}

# メインループ
while true; do
    show_menu
    read_key
    case "$key" in
        1) run_memtester ;;
        2) run_memtest86 ;;
        q|Q) break ;;
    esac
done
