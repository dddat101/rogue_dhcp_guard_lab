#!/usr/bin/env bash
# Request a DHCP lease from inside the victim namespace.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage()
{
    cat <<'USAGE'
Usage:
  client_request.sh [--fresh]
USAGE
}

main()
{
    local client
    local rc=0
    local acquired_ip=""

    require_root
    load_config

    require_command ip
    require_command timeout

    validate_namespace_ready "${NS_LAN}" "${VICTIM_IF}"

    log_info "Flushing existing addresses and routes in ${NS_LAN} on ${VICTIM_IF}."
    ip -n "${NS_LAN}" addr flush dev "${VICTIM_IF}"
    ip -n "${NS_LAN}" route flush dev "${VICTIM_IF}" 2>/dev/null || true

    client="$(select_dhcp_client)"
    log_info "Requesting DHCP lease with ${client} (timeout: ${DHCP_ACQUIRE_TIMEOUT_SEC}s)..."

    set +e
    case "${client}" in
        udhcpc)
            local udhcpc_script="${SCRIPT_DIR}/lib/udhcpc.script"
            timeout --foreground "${DHCP_ACQUIRE_TIMEOUT_SEC}" \
                ip netns exec "${NS_LAN}" \
                udhcpc -f -q -n -i "${VICTIM_IF}" -s "${udhcpc_script}"
            rc=$?
            ;;
        dhclient)
            local lease_file="${STATE_DIR}/dhclient-${NS_LAN}.leases"
            local pid_file="${STATE_DIR}/dhclient-${NS_LAN}.pid"
            rm -f "${lease_file}" "${pid_file}"
            touch "${lease_file}"

            timeout --foreground "${DHCP_ACQUIRE_TIMEOUT_SEC}" \
                ip netns exec "${NS_LAN}" \
                dhclient -4 -v -1 -lf "${lease_file}" -pf "${pid_file}" "${VICTIM_IF}"
            rc=$?
            ;;
        *)
            die "Internal error: unsupported DHCP client ${client}"
            ;;
    esac
    set -e

    printf '\n'
    log_info "Victim interface status (${NS_LAN}/${VICTIM_IF}):"
    ip netns exec "${NS_LAN}" ip -4 addr show dev "${VICTIM_IF}" || true
    ip netns exec "${NS_LAN}" ip route show || true

    acquired_ip="$(ip netns exec "${NS_LAN}" ip -4 -o addr show dev "${VICTIM_IF}" | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
    if [[ -n "${acquired_ip}" ]]; then
        log_info "Obtained IP: ${acquired_ip}"
        if [[ "${acquired_ip}" =~ ^10\.10\.0\. ]]; then
            log_warn "SECURITY ALERT: Victim acquired an address from ROGUE DHCP SERVER (${acquired_ip})!"
        else
            log_info "Victim acquired address from legitimate DHCP server (${acquired_ip})."
        fi
    else
        log_info "No IPv4 address acquired."
    fi

    return "${rc}"
}

main "$@"
