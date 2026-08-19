#!/usr/bin/env bash
# Print test-resource state and environment diagnostics without modifying the host.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main()
{
    load_config
    require_command ip

    printf '========================================\n'
    printf '        Lab Environment Diagnostics     \n'
    printf '========================================\n'

    printf '\n== Root Namespace Interfaces ==\n'
    printf -- '-- %s (ROGUE_IF) --\n' "${ROGUE_IF}"
    if iface_exists_root "${ROGUE_IF}"; then
        ip -d link show dev "${ROGUE_IF}" 2>/dev/null || true
        ip addr show dev "${ROGUE_IF}" 2>/dev/null || true
    else
        printf '<not present in root namespace>\n'
    fi

    printf -- '\n-- %s (VICTIM_IF) --\n' "${VICTIM_IF}"
    if iface_exists_root "${VICTIM_IF}"; then
        ip -d link show dev "${VICTIM_IF}" 2>/dev/null || true
        ip addr show dev "${VICTIM_IF}" 2>/dev/null || true
    else
        printf '<not present in root namespace>\n'
    fi

    printf '\n== Namespaces ==\n'
    for ns in "${NS_ATK}" "${NS_LAN}"; do
        printf -- '-- %s --\n' "${ns}"
        if ns_exists "${ns}"; then
            ip netns exec "${ns}" ip -br link 2>/dev/null || true
            ip netns exec "${ns}" ip -4 addr 2>/dev/null || true
        else
            printf '<not present>\n'
        fi
    done

    printf '\n== Host Default Route ==\n'
    ip route show default 2>/dev/null || printf '<no default route>\n'

    printf '\n== Running Lab Processes ==\n'
    if is_pidfile_running "${STATE_DIR}/dnsmasq.pid"; then
        printf '  dnsmasq (rogue): RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/dnsmasq.pid")"
    else
        printf '  dnsmasq (rogue): NOT RUNNING\n'
    fi

    if is_pidfile_running "${STATE_DIR}/cap_rogue.pid"; then
        printf '  capture (rogue): RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_rogue.pid")"
    else
        printf '  capture (rogue): NOT RUNNING\n'
    fi

    if is_pidfile_running "${STATE_DIR}/cap_victim.pid"; then
        printf '  capture (victim): RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_victim.pid")"
    else
        printf '  capture (victim): NOT RUNNING\n'
    fi

    printf '\n== State Directory Contents ==\n'
    ls -la "${STATE_DIR}" 2>/dev/null || true
}

main "$@"
