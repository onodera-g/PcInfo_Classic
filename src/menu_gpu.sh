#!/bin/sh
# menu_gpu.sh - GPUテスト画面

. /opt/common.sh

printf '\033[2J\033[H' > "$TTY" 2>/dev/null
printf "[GPUテスト]\n\nnot implemented\n\nq でトップに戻る\n" | "$FBPRINT" "$FONT" "$FB"
while true; do read_key; case "$key" in q|Q) break ;; esac; done
