#!/system/bin/sh
# Tag the framework's dex2oat bind mount and mapped zygisk libraries as "sus"
# objects, then enable SUSFS filtering of sus mounts for non-su processes.
#
# add_sus_mount only works after the mount exists, so wait for it first.
# The whole sequence is applied again 60s later in case another module resets
# the hide flag during boot.

BIN=/data/adb/ksu/bin/ksu_susfs
[ -x "$BIN" ] || exit 0

apply() {
  "$BIN" hide_sus_mnts_for_non_su_procs 1 >/dev/null 2>&1
  "$BIN" add_sus_mount /apex/com.android.art/bin/dex2oat64 >/dev/null 2>&1
  "$BIN" add_sus_mount /apex/com.android.art/bin/dex2oat32 >/dev/null 2>&1
  "$BIN" add_sus_map /data/adb/modules/zygisk_lsposed/zygisk/arm64-v8a.so >/dev/null 2>&1
  "$BIN" add_sus_map /data/adb/modules/zygisk_lsposed/zygisk/armeabi-v7a.so >/dev/null 2>&1
}

i=0
while [ "$i" -lt 90 ]; do
  grep -q dex2oat /proc/self/mountinfo && break
  sleep 2
  i=$((i + 1))
done

apply

( sleep 60; apply ) >/dev/null 2>&1 &
