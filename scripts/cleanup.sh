#!/usr/bin/env bash
# Remove lab namespaces, stop background processes, and restore interfaces to host.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

main()
{
    require_root
    load_config
    require_command ip

    # Stop captures if running
    if [[ -x "${SCRIPT_DIR}/capture.sh" ]]; then
        "${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true
    fi

    # Stop rogue DHCP server if running
    if [[ -x "${SCRIPT_DIR}/rogue.sh" ]]; then
        "${SCRIPT_DIR}/rogue.sh" stop >/dev/null 2>&1 || true
    fi

    log_info "Restoring interfaces from namespaces to root namespace."
    restore_if_from_ns "${NS_ATK}" "${ROGUE_IF}"
    restore_if_from_ns "${NS_LAN}" "${VICTIM_IF}"

    if ns_exists "${NS_ATK}"; then
        log_info "Removing namespace: ${NS_ATK}"
        ip netns del "${NS_ATK}" || true
    fi

    if ns_exists "${NS_LAN}"; then
        log_info "Removing namespace: ${NS_LAN}"
        ip netns del "${NS_LAN}" || true
    fi

    if iface_exists_root "${ROGUE_IF}"; then
        ip addr flush dev "${ROGUE_IF}" 2>/dev/null || true
        ip link set dev "${ROGUE_IF}" down || true
    fi

    if iface_exists_root "${VICTIM_IF}"; then
        ip addr flush dev "${VICTIM_IF}" 2>/dev/null || true
        ip link set dev "${VICTIM_IF}" down || true
    fi

    # Clean up state artifacts
    rm -f "${STATE_DIR}"/*.pid "${STATE_DIR}"/*.remote "${STATE_DIR}/dnsmasq.conf" "${STATE_DIR}/last_capture.env"

    log_info "Cleanup completed successfully."
    printf '\nHost interface status (in root namespace):\n'
    if iface_exists_root "${ROGUE_IF}"; then
        printf '  %s: ' "${ROGUE_IF}"; ip -br link show dev "${ROGUE_IF}"
    else
        printf '  %s: <not detected>\n' "${ROGUE_IF}"
    fi

    if iface_exists_root "${VICTIM_IF}"; then
        printf '  %s: ' "${VICTIM_IF}"; ip -br link show dev "${VICTIM_IF}"
    else
        printf '  %s: <not detected>\n' "${VICTIM_IF}"
    fi

    printf '\nNote: Test interfaces are kept DOWN to prevent unmanaged traffic.\n'
    printf '      Use "ifconfig -a" or "ip link" to view all interfaces (including DOWN).\n'
}

main "$@"
