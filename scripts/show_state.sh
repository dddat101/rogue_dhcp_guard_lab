#!/usr/bin/env bash
# Display current topology, namespace, server, and capture state.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

show_namespace()
{
    local ns="$1"
    local iface="$2"

    printf '\n== Namespace: %s ==\n' "${ns}"
    if ! ns_exists "${ns}"; then
        printf '  <not present>\n'
        return 0
    fi

    ip netns exec "${ns}" ip -br link show dev "${iface}" 2>/dev/null || printf '  Interface %s not present\n' "${iface}"
    ip netns exec "${ns}" ip -4 addr show dev "${iface}" 2>/dev/null || true
    ip netns exec "${ns}" ip route show 2>/dev/null || true
}

main()
{
    load_config
    require_command ip

    printf '========================================\n'
    printf '       Rogue DHCP Guard Lab State       \n'
    printf '========================================\n'

    show_namespace "${NS_ATK}" "${ROGUE_IF}"
    show_namespace "${NS_LAN}" "${VICTIM_IF}"

    printf '\n== Rogue Server ==\n'
    if is_pidfile_running "${STATE_DIR}/dnsmasq.pid"; then
        printf '  dnsmasq: RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/dnsmasq.pid")"
    else
        printf '  dnsmasq: STOPPED\n'
    fi

    if [[ -f "${STATE_DIR}/dnsmasq.log" ]]; then
        printf '\n== dnsmasq Log (last 10 lines) ==\n'
        tail -n 10 "${STATE_DIR}/dnsmasq.log" || true
    fi

    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        printf '\n'
        "${SCRIPT_DIR}/capture.sh" status || true
    fi

    if [[ -n "${DUT_SSH_HOST:-}" ]]; then
        printf '\n== DUT Status & Counters ==\n'
        if [[ -n "${DUT_STATUS_CMD:-}" ]]; then
            printf '\n--- Feature Status ---\n'
            run_dut_cmd "${DUT_STATUS_CMD}" || true
        fi
        if [[ -n "${DUT_DHCP_STATUS_CMD:-}" ]]; then
            printf '\n--- DHCP Status ---\n'
            run_dut_cmd "${DUT_DHCP_STATUS_CMD}" || true
        fi
        if [[ -n "${DUT_GUARD_COUNTER_CMD:-}" ]]; then
            printf '\n--- Guard Counters ---\n'
            run_dut_cmd "${DUT_GUARD_COUNTER_CMD}" || true
        fi
    fi
}

main "$@"
