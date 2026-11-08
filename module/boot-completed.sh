#!/system/bin/sh
# Boot completed: re-apply in case the switch was reset after service.sh ran.
# shellcheck source=common.sh
. "${0%/*}/common.sh"
hide_main