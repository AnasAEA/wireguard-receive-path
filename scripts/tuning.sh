#!/bin/bash
# Variance-control helpers for reproducible measurement on Apple M1 Pro (Asahi).
#
# The M1 Pro has 8 performance ("Firestorm") + 2 efficiency ("Icestorm") cores.
# Work landing on the efficiency cores runs at ~half throughput, which is a
# large, uncontrolled source of run-to-run variance. These helpers remove that
# variance by offlining the efficiency cores, and optionally lock the cpufreq
# governor to "performance" so frequency scaling does not add jitter.
#
# Source this file; do not execute it:
#     source "$(dirname "$0")/tuning.sh"
#     tuning_apply            # offline E-cores + performance governor
#     ...run measurement...
#     tuning_restore          # bring every core back online, restore governor
#
# For bottleneck-induction experiments, use tuning_leave_only instead:
#     tuning_leave_only "0 1"   # keep only CPU 0 and 1 online; offline the rest
#
# All functions are idempotent and tolerate sysfs write failures (some cores —
# notably cpu0 — may refuse to go offline; that is reported, not fatal).

CPU_BASE=/sys/devices/system/cpu

# Print the ids of the efficiency cores (capacity below the maximum capacity).
# Falls back to empty if cpu_capacity is not exposed.
tuning_detect_ecores() {
    local maxcap=0 cap c id
    for c in "$CPU_BASE"/cpu[0-9]*/cpu_capacity; do
        [ -r "$c" ] || continue
        cap=$(cat "$c")
        [ "$cap" -gt "$maxcap" ] && maxcap=$cap
    done
    [ "$maxcap" -eq 0 ] && return 0
    for c in "$CPU_BASE"/cpu[0-9]*/cpu_capacity; do
        [ -r "$c" ] || continue
        cap=$(cat "$c")
        id=$(basename "$(dirname "$c")")
        id=${id#cpu}
        [ "$cap" -lt "$maxcap" ] && echo "$id" || true
    done
    return 0
}

_tuning_set_online() {
    local id=$1 val=$2 path="$CPU_BASE/cpu$id/online"
    [ -w "$path" ] || { echo "  cpu$id: online not writable (skipped)"; return 0; }
    if echo "$val" | tee "$path" >/dev/null 2>&1; then
        echo "  cpu$id -> online=$val"
    else
        echo "  cpu$id: failed to set online=$val (skipped)"
    fi
}

tuning_set_governor() {
    local gov=${1:-performance} g found=0
    for g in "$CPU_BASE"/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -w "$g" ] || continue
        if echo "$gov" | tee "$g" >/dev/null 2>&1; then found=1; fi
    done
    if [ "$found" = "1" ]; then
        echo "  governor -> $gov (where available)"
    else
        echo "  cpufreq governor not controllable on this kernel (skipped)"
    fi
}

# Offline the efficiency cores and lock the governor. Records the E-core list
# in TUNING_ECORES so tuning_restore can bring exactly those back.
tuning_apply() {
    TUNING_ECORES=$(tuning_detect_ecores | tr '\n' ' ' | sed 's/ $//' || true)
    echo "[tuning] applying variance control"
    if [ -n "$TUNING_ECORES" ]; then
        echo "  efficiency cores detected: $TUNING_ECORES"
        local id
        for id in $TUNING_ECORES; do _tuning_set_online "$id" 0; done
    else
        echo "  no efficiency cores detected (cpu_capacity unavailable) - leaving all online"
    fi
    tuning_set_governor performance
    echo "  online CPUs now: $(_tuning_online_list)"
}

# Keep only the listed CPUs online; offline all others. Used to force
# contention for bottleneck-induction experiments.
tuning_leave_only() {
    local keep=" $* " id
    echo "[tuning] leaving only CPUs:$keep online"
    TUNING_LEAVE_OFFLINED=""
    for id in $(_tuning_all_ids); do
        if [[ "$keep" == *" $id "* ]]; then
            _tuning_set_online "$id" 1
        else
            _tuning_set_online "$id" 0
            TUNING_LEAVE_OFFLINED="$TUNING_LEAVE_OFFLINED $id"
        fi
    done
    tuning_set_governor performance
    echo "  online CPUs now: $(_tuning_online_list)"
}

# Bring every CPU back online and restore the ondemand/schedutil governor.
tuning_restore() {
    echo "[tuning] restoring all cores online"
    local id
    for id in $(_tuning_all_ids); do
        [ "$id" = "0" ] && continue
        _tuning_set_online "$id" 1
    done
    # Best-effort restore of a dynamic governor.
    for g in schedutil ondemand powersave; do
        if grep -qw "$g" "$CPU_BASE"/cpu0/cpufreq/scaling_available_governors 2>/dev/null; then
            tuning_set_governor "$g"
            break
        fi
    done
    echo "  online CPUs now: $(_tuning_online_list)"
}

_tuning_all_ids() {
    local c id
    for c in "$CPU_BASE"/cpu[0-9]*; do
        id=$(basename "$c"); echo "${id#cpu}"
    done | sort -n
}

_tuning_online_list() {
    local c id out=""
    for c in "$CPU_BASE"/cpu[0-9]*; do
        id=$(basename "$c"); id=${id#cpu}
        if [ "$id" = "0" ] || [ "$(cat "$c/online" 2>/dev/null)" = "1" ]; then
            out="$out $id"
        fi
    done
    echo "${out# }"
}
