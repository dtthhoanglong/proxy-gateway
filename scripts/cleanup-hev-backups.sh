#!/bin/bash
set -euo pipefail

KEEP_CONFIG_BACKUPS=10
KEEP_REMOVED_INSTANCES=5

cleanup_files() {
    local pattern="$1"
    local keep="$2"

    mapfile -t files < <(
        find "$(dirname "$pattern")" \
            -maxdepth 1 \
            -type f \
            -name "$(basename "$pattern")" \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    if [ "${#files[@]}" -le "$keep" ]; then
        return 0
    fi

    for ((i=keep; i<${#files[@]}; i++)); do
        rm -f -- "${files[$i]}"
    done
}

cleanup_directories() {
    local parent="$1"
    local name_pattern="$2"
    local keep="$3"

    mapfile -t dirs < <(
        find "$parent" \
            -maxdepth 1 \
            -mindepth 1 \
            -type d \
            -name "$name_pattern" \
            -printf '%T@ %p\n' 2>/dev/null |
        sort -nr |
        cut -d' ' -f2-
    )

    if [ "${#dirs[@]}" -le "$keep" ]; then
        return 0
    fi

    for ((i=keep; i<${#dirs[@]}; i++)); do
        rm -rf -- "${dirs[$i]}"
    done
}

# DHCP backups.
cleanup_files \
    "/etc/dhcp/dhcpd.conf.bak-*" \
    "$KEEP_CONFIG_BACKUPS"

# HEV config backups của từng instance.
for instance_dir in /etc/hev/[0-9]*; do
    [ -d "$instance_dir" ] || continue

    cleanup_files \
        "${instance_dir}/config.yml.bak-*" \
        "$KEEP_CONFIG_BACKUPS"

    cleanup_files \
        "${instance_dir}/instance.conf.bak-*" \
        "$KEEP_CONFIG_BACKUPS"
done

# Backup instance đã bị xóa.
cleanup_directories \
    "/root" \
    "hev-removed-*" \
    "$KEEP_REMOVED_INSTANCES"

exit 0
