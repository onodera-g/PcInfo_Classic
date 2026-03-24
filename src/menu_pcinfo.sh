#!/bin/sh
# menu_pcinfo.sh - PC Info screen

. /opt/pcinfo/common.sh

/opt/pcinfo/pcinfo.sh 2>/dev/null | show_paged_blocks
