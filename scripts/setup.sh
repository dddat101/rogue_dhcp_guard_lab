#!/usr/bin/env bash
# Set up isolated network namespaces for Rogue DHCP Guard testing.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

SETUP_ACTIVE=0

remove_owned_resources()
{
    log_info "Removing owned lab resources."
    restore_if_from_ns "${NS_ATK}" "${ROGUE_IF}"
    restore_if_from_ns "${NS_LAN}" "${VICTIM_IF}"

    if ns_exists "${NS_ATK}"; then
        ip netns del "${NS_ATK}" || true
    fi
    if ns_exists "${NS_LAN}"; then
        ip netns del "${NS_LAN}" || true
    fi

    rm -f "${STATE_DIR}/dnsmasq.conf" "${STATE_DIR}"/*.pid
}

rollback_setup()
{
    local exit_code="$1"
    local line_number="$2"

    if (( SETUP_ACTIVE == 0 )); then
        return
    fi

    trap - ERR
    log_error "Setup failed near line ${line_number}; rolling back partial configuration."

    remove_owned_resources

    log_error "Rollback complete. Original error code: ${exit_code}"
    exit "${exit_code}"
}

main()
{
    require_root
    load_config

    require_command ip
    require_command "${DNSMASQ_BIN}"
    require_command awk
    require_command install

    validate_test_interfaces

    log_info "Rogue interface:  ${ROGUE_IF} -> namespace ${NS_ATK}"
    log_info "Victim interface: ${VICTIM_IF} -> namespace ${NS_LAN}"

    SETUP_ACTIVE=1
    trap 'rollback_setup $? ${LINENO}' ERR

    # Create namespaces
    log_info "Creating namespaces: ${NS_ATK}, ${NS_LAN}"
    ns_create "${NS_ATK}"
    ns_create "${NS_LAN}"

    # Move interfaces into namespaces
    log_info "Moving interfaces into namespaces."
    move_if_to_ns "${ROGUE_IF}" "${NS_ATK}"
    move_if_to_ns "${VICTIM_IF}" "${NS_LAN}"

    # Configure Rogue namespace
    log_info "Configuring ${ROGUE_IF} in ${NS_ATK} with IP ${ROGUE_SERVER_IP}/${ROGUE_PREFIX}."
    ip -n "${NS_ATK}" addr flush dev "${ROGUE_IF}"
    ip -n "${NS_ATK}" addr add "${ROGUE_SERVER_IP}/${ROGUE_PREFIX}" dev "${ROGUE_IF}"
    ip -n "${NS_ATK}" link set dev "${ROGUE_IF}" up

    # Configure Victim namespace
    log_info "Configuring ${VICTIM_IF} in ${NS_LAN}."
    ip -n "${NS_LAN}" addr flush dev "${VICTIM_IF}"
    ip -n "${NS_LAN}" link set dev "${VICTIM_IF}" up

    # Generate dnsmasq configuration
    cat > "${STATE_DIR}/dnsmasq.conf" <<EOC
interface=${ROGUE_IF}
bind-interfaces
port=0
log-dhcp
log-facility=-
dhcp-authoritative
dhcp-range=${ROGUE_POOL_START},${ROGUE_POOL_END},${ROGUE_LEASE}
dhcp-option=3,${ROGUE_SERVER_IP}
dhcp-option=6,${ROGUE_SERVER_IP}
pid-file=${STATE_DIR}/dnsmasq.pid
leasefile-ro
EOC

    validate_namespace_ready "${NS_ATK}" "${ROGUE_IF}"
    validate_namespace_ready "${NS_LAN}" "${VICTIM_IF}"

    SETUP_ACTIVE=0
    trap - ERR

    log_info "Setup completed successfully."
    printf '\nTopology Summary:\n'
    printf '  Rogue server: %s/%s -> DUT LAN port A (Pool: %s - %s)\n' "${NS_ATK}" "${ROGUE_IF}" "${ROGUE_POOL_START}" "${ROGUE_POOL_END}"
    printf '  Victim client: %s/%s -> DUT LAN port B\n' "${NS_LAN}" "${VICTIM_IF}"
    printf '\nRecommended workflow:\n'
    printf '  sudo ./scripts/capture.sh start\n'
    printf '  sudo ./scripts/client_request.sh\n'
    printf '  sudo ./scripts/rogue.sh start\n'
    printf '  sudo ./scripts/show_state.sh\n'
    printf '  sudo ./scripts/scenario.sh\n'
}

main "$@"
