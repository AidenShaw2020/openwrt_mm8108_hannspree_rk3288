#!/bin/sh
# File-backed persistent variables for the USB MM8108 Hannspree image.
# Deliberately does not use fw_printenv/fw_setenv or U-Boot environment storage.

set -u
STORE=/etc/morse-persistent-vars
ALL_KEYS="device_password default_wifi_key dpp_priv_key mm_region mm_sku mm_region_unlocked mm_virtual_wire mm_mode dropbear_authorized_keys dropbear_ed25519_host_key dropbear_rsa_host_key"

usage() {
    echo "Usage: $0 OPERATION(READ|READALL|WRITE|ERASE) KEY [VALUE]" >&2
    return 1
}

valid_key() {
    case "$1" in
        ''|*[!A-Za-z0-9_]* ) return 1 ;;
        *) return 0 ;;
    esac
}

safe_key() {
    valid_key "$1" || { echo "Invalid key" >&2; return 1; }
    printf '%s/%s' "$STORE" "$1"
}

generate_wifi_key() {
    # od consumes the complete fixed-size input, so this cannot produce the
    # tr/head SIGPIPE seen with the original pipeline.
    od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n\r\t' | cut -c1-8
}

operation=${1-}
key=${2-}

case "$operation" in
    READ)
        valid_key "$key" || { usage; exit 1; }
        path=$(safe_key "$key") || exit 1
        if [ -r "$path" ]; then
            cat "$path"
        elif [ "$key" = mm_region ]; then
            printf 'EU\n'
        elif [ "$key" = default_wifi_key ]; then
            mkdir -p "$STORE"
            value=$(generate_wifi_key)
            [ "${#value}" -eq 8 ] || value=MM8108EU
            printf '%s\n' "$value" > "$path"
            cat "$path"
        fi
        ;;
    READALL)
        for key in $ALL_KEYS; do
            printf '%s=%s\n' "$key" "$($0 READ "$key")"
        done
        ;;
    WRITE)
        [ "$#" -ge 3 ] || { usage; exit 1; }
        valid_key "$key" || { usage; exit 1; }
        [ -n "$3" ] || { echo 'ERROR: empty values require ERASE' >&2; exit 3; }
        mkdir -p "$STORE"
        path=$(safe_key "$key") || exit 1
        tmp="$path.tmp.$$"
        printf '%s\n' "$3" > "$tmp" && mv -f "$tmp" "$path"
        ;;
    ERASE)
        valid_key "$key" || { usage; exit 1; }
        path=$(safe_key "$key") || exit 1
        rm -f "$path"
        ;;
    *)
        usage
        ;;
esac
