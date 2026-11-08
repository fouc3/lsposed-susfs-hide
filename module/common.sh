# shellcheck shell=sh
# Shared logic for the System Helper module.
#
# The framework (LSPosed) bind-mounts <moddir>/bin/dex2oat onto
# /apex/com.android.art/bin/dex2oat{32,64} inside PID 1's mount namespace,
# which makes the mount (and its /data/adb/modules/<id> source path) visible to
# every app through /proc/self/mountinfo. SUSFS can hide such mounts from
# non-root processes, but only after they exist and only when its runtime
# switch is enabled.

SUSFS_BIN=${SUSFS_BIN:-/data/adb/ksu/bin/ksu_susfs}
LOG_FILE=${LOG_FILE:-/data/adb/system_helper.log}
LOG_MAX_BYTES=${LOG_MAX_BYTES:-65536}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE" 2>/dev/null
}

rotate_log() {
    [ -f "$LOG_FILE" ] || return 0
    size=$(wc -c <"$LOG_FILE" 2>/dev/null | tr -d ' \n')
    case "$size" in
        ''|*[!0-9]*) return 0 ;;
    esac
    [ "$size" -gt "$LOG_MAX_BYTES" ] && mv -f "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null
    return 0
}

# The framework is the only module shipping bin/dex2oat, so locate it by that
# file instead of hardcoding a module id.
find_framework_dir() {
    # shellcheck disable=SC2043
    for dir in /data/adb/modules/*; do
        [ -f "$dir/bin/dex2oat" ] || continue
        printf '%s\n' "$dir"
        return 0
    done
    return 1
}

wrapper_mount_points() {
    awk '$5 ~ /\/apex\/com\.android\.art\/bin\/dex2oat/ { print $5 }' \
        /proc/self/mountinfo 2>/dev/null
}

wait_for_wrapper() {
    limit=${1:-180}
    elapsed=0
    while [ "$elapsed" -lt "$limit" ]; do
        # shellcheck disable=SC2046
        [ -n "$(wrapper_mount_points)" ] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

apply_hiding() {
    [ -x "$SUSFS_BIN" ] || { log "ksu_susfs not executable: $SUSFS_BIN"; return 1; }

    moddir=$(find_framework_dir) || { log "framework module dir not found"; return 1; }

    "$SUSFS_BIN" hide_sus_mnts_for_non_su_procs 1 >/dev/null 2>&1 ||
        log "hide_sus_mnts_for_non_su_procs not supported by kernel"

    # shellcheck disable=SC2046
    for mp in $(wrapper_mount_points); do
        "$SUSFS_BIN" add_sus_mount "$mp" >/dev/null 2>&1 &&
            log "add_sus_mount $mp"
    done

    for so in "$moddir"/zygisk/*.so; do
        [ -f "$so" ] || continue
        "$SUSFS_BIN" add_sus_map "$so" >/dev/null 2>&1 &&
            log "add_sus_map $so"
    done

    return 0
}

hide_main() {
    rotate_log

    if [ ! -x "$SUSFS_BIN" ]; then
        log "susfs cli missing: $SUSFS_BIN"
        return 0
    fi

    if ! wait_for_wrapper 180; then
        log "dex2oat wrapper mount not found, nothing to hide"
        return 0
    fi

    apply_hiding

    # Another module may reset the global switch during boot-completed, so
    # re-apply once after boot settles.
    ( sleep 60; apply_hiding ) >/dev/null 2>&1 &
}
