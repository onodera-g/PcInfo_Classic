#!/bin/sh
# menu_pcinfo.sh - PC情報画面

. /opt/common.sh

/opt/pcinfo.sh 2>/dev/null | show_paged
