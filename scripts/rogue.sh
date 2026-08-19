#!/usr/bin/env bash
# Manage the Rogue DHCP server (dnsmasq) in the attacker namespace.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage()
{
    cat <<'USAGE'
Usage:
  rogue.sh start
  rogue.sh stop
  rogue.sh status
USAGE
}

start_rogue()
{
    local conf_file="${STATE_DIR}/dnsmasq.conf"
    local pid_file="${STATE_DIR}/dnsmasq.pid"
    local log_file="${STATE_DIR}/dnsmasq.log"
    local pid

    require_root
    require_command "${DNSMASQ_BIN}"
    validate_namespace_ready "${NS_ATK}" "${ROGUE_IF}"

    if [[ ! -f "${conf_file}" ]]; then
        die "Configuration file ${conf_file} not found. Run setup.sh first."
    fi

    stop_rogue

    log_info "Starting rogue DHCP server in namespace ${NS_ATK}."

    ip netns exec "${NS_ATK}" "${DNSMASQ_BIN}" \
        --conf-file="${conf_file}" \
        --no-daemon \
        > "${log_file}" 2>&1 &

    pid="$!"
    printf '%s\n' "${pid}" > "${pid_file}"

    # Wait briefly and verify process is alive
    sleep 0.5

    if ! is_pidfile_running "${pid_file}"; then
        log_error "dnsmasq log tail:"
        tail -n 20 "${log_file}" >&2 || true
        rm -f "${pid_file}"
        die "dnsmasq failed to start. Inspect ${log_file}."
    fi

    log_info "Rogue DHCP active (PID ${pid})."
    log_info "  Offering range: ${ROGUE_POOL_START} - ${ROGUE_POOL_END}"
    log_info "  Gateway/DNS:    ${ROGUE_SERVER_IP}"
}

stop_rogue()
{
    require_root
    stop_pidfile "${STATE_DIR}/dnsmasq.pid"
    stop_pidfile "${STATE_DIR}/dnsmasq-wrapper.pid"
    rm -f "${STATE_DIR}/dnsmasq.pid" "${STATE_DIR}/dnsmasq-wrapper.pid"
    log_info "Rogue DHCP stopped."
}

show_status()
{
    printf '== Rogue DHCP Server Status ==\n'
    if is_pidfile_running "${STATE_DIR}/dnsmasq.pid"; then
        printf 'Status: RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/dnsmasq.pid")"
    else
        printf 'Status: STOPPED\n'
    fi

    if [[ -f "${STATE_DIR}/dnsmasq.log" ]]; then
        printf '\nRecent dnsmasq log entries:\n'
        tail -n 15 "${STATE_DIR}/dnsmasq.log"
    fi
}

main()
{
    local action="${1:-}"

    load_config

    case "${action}" in
        start)
            start_rogue
            ;;
        stop)
            stop_rogue
            ;;
        status)
            show_status
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
