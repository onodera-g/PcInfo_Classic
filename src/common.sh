#!/bin/sh
# Shared initialization for diagnostic screens and startup.

BOOT_STATUS_FILE="/opt/pcinfo/.cache/runtime/boot-status"

. /opt/pcinfo/lib/display.sh
. /opt/pcinfo/lib/media.sh
. /opt/pcinfo/lib/gpu.sh
. /opt/pcinfo/lib/storage.sh
