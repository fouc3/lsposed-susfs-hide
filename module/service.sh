#!/system/bin/sh
# Late-start service: hide the framework's dex2oat bind mount from apps.
# shellcheck source=common.sh
. "${0%/*}/common.sh"
hide_main