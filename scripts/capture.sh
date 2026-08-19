#!/usr/bin/env bash
# Manage packet captures for Rogue DHCP Guard lab.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage()
{
    cat <<'USAGE'
Usage:
  capture.sh start
  capture.sh stop
  capture.sh status
USAGE
}

start_capture()
{
    local timestamp
    local rogue_pcap
    local victim_pcap
    local rogue_log
    local victim_log
    local ext="pcap"
    local cap_tool="tcpdump"
    local rogue_pid
    local victim_pid

    require_root
    validate_namespace_ready "${NS_ATK}" "${ROGUE_IF}"
    validate_namespace_ready "${NS_LAN}" "${VICTIM_IF}"

    stop_capture

    timestamp="$(date +%Y%m%d_%H%M%S)"

    if command -v "${TCPDUMP_BIN}" >/dev/null 2>&1; then
        cap_tool="tcpdump"
        ext="pcap"
    elif command -v "${TSHARK_BIN}" >/dev/null 2>&1; then
        cap_tool="tshark"
        ext="pcapng"
    else
        die "Neither tcpdump (${TCPDUMP_BIN}) nor tshark (${TSHARK_BIN}) is installed."
    fi

    rogue_pcap="${CAPTURE_DIR}/rogue_${timestamp}.${ext}"
    victim_pcap="${CAPTURE_DIR}/victim_${timestamp}.${ext}"
    rogue_log="${STATE_DIR}/cap_rogue.log"
    victim_log="${STATE_DIR}/cap_victim.log"

    if [[ "${cap_tool}" == "tcpdump" ]]; then
        nohup ip netns exec "${NS_ATK}" "${TCPDUMP_BIN}" \
            -ni "${ROGUE_IF}" -s 0 -U -w "${rogue_pcap}" \
            'udp port 67 or udp port 68' \
            > "${rogue_log}" 2>&1 &
        rogue_pid="$!"
        printf '%s\n' "${rogue_pid}" > "${STATE_DIR}/cap_rogue.pid"

        nohup ip netns exec "${NS_LAN}" "${TCPDUMP_BIN}" \
            -ni "${VICTIM_IF}" -s 0 -U -w "${victim_pcap}" \
            'udp port 67 or udp port 68' \
            > "${victim_log}" 2>&1 &
        victim_pid="$!"
        printf '%s\n' "${victim_pid}" > "${STATE_DIR}/cap_victim.pid"
    else
        nohup ip netns exec "${NS_ATK}" "${TSHARK_BIN}" \
            -i "${ROGUE_IF}" -f 'udp port 67 or udp port 68' -l \
            -w "${rogue_pcap}" \
            > "${rogue_log}" 2>&1 &
        rogue_pid="$!"
        printf '%s\n' "${rogue_pid}" > "${STATE_DIR}/cap_rogue.pid"

        nohup ip netns exec "${NS_LAN}" "${TSHARK_BIN}" \
            -i "${VICTIM_IF}" -f 'udp port 67 or udp port 68' -l \
            -w "${victim_pcap}" \
            > "${victim_log}" 2>&1 &
        victim_pid="$!"
        printf '%s\n' "${victim_pid}" > "${STATE_DIR}/cap_victim.pid"
    fi

    # Verify processes started successfully
    sleep 0.5

    if ! is_pidfile_running "${STATE_DIR}/cap_rogue.pid"; then
        log_error "Rogue capture failed to start. Log output:"
        tail -n 20 "${rogue_log}" >&2 || true
        stop_capture
        die "Failed to start capture on ${NS_ATK}/${ROGUE_IF}."
    fi

    if ! is_pidfile_running "${STATE_DIR}/cap_victim.pid"; then
        log_error "Victim capture failed to start. Log output:"
        tail -n 20 "${victim_log}" >&2 || true
        stop_capture
        die "Failed to start capture on ${NS_LAN}/${VICTIM_IF}."
    fi

    # Remote DUT capture (optional)
    local remote_pcap=""
    if [[ -n "${DUT_SSH_HOST:-}" ]]; then
        remote_pcap="/tmp/rogue_dhcp_${timestamp}.pcap"
        local remote_cmd="nohup ${TCPDUMP_BIN} -ni '${DUT_CAPTURE_IF}' -s 0 -w '${remote_pcap}' 'udp port 67 or udp port 68' >/tmp/rogue_dhcp_cap.log 2>&1 & echo \$!"
        local dut_pid
        dut_pid="$(run_dut_cmd "${remote_cmd}" || true)"
        if [[ -n "${dut_pid}" ]]; then
            printf '%s\n' "${dut_pid}" > "${STATE_DIR}/cap_dut.pid"
            printf '%s\n' "${remote_pcap}" > "${STATE_DIR}/cap_dut.remote"
        fi
    fi

    {
        printf 'LAST_TIMESTAMP=%q\n' "${timestamp}"
        printf 'ROGUE_PCAP=%q\n' "${rogue_pcap}"
        printf 'VICTIM_PCAP=%q\n' "${victim_pcap}"
        printf 'DUT_PCAP=%q\n' "${remote_pcap}"
    } > "${STATE_DIR}/last_capture.env"

    log_info "Captures started (${cap_tool}):"
    log_info "  Rogue capture:  ${rogue_pcap}"
    log_info "  Victim capture: ${victim_pcap}"
    if [[ -n "${DUT_SSH_HOST:-}" && -f "${STATE_DIR}/cap_dut.remote" ]]; then
        log_info "  DUT capture:    $(cat "${STATE_DIR}/cap_dut.remote")"
    fi
}

stop_capture()
{
    require_root
    stop_pidfile "${STATE_DIR}/cap_rogue.pid"
    stop_pidfile "${STATE_DIR}/cap_victim.pid"

    if [[ -f "${STATE_DIR}/cap_dut.pid" && -n "${DUT_SSH_HOST:-}" ]]; then
        local dut_pid
        dut_pid="$(cat "${STATE_DIR}/cap_dut.pid" 2>/dev/null || true)"
        if [[ -n "${dut_pid}" && "${dut_pid}" =~ ^[0-9]+$ ]]; then
            run_dut_cmd "kill ${dut_pid} 2>/dev/null || true" || true
        fi
        rm -f "${STATE_DIR}/cap_dut.pid"
    fi

    log_info "Captures stopped."
}

show_status()
{
    printf '== Capture Status ==\n'
    if is_pidfile_running "${STATE_DIR}/cap_rogue.pid"; then
        printf 'Rogue capture:  RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_rogue.pid")"
    else
        printf 'Rogue capture:  STOPPED\n'
    fi

    if is_pidfile_running "${STATE_DIR}/cap_victim.pid"; then
        printf 'Victim capture: RUNNING (PID %s)\n' "$(cat "${STATE_DIR}/cap_victim.pid")"
    else
        printf 'Victim capture: STOPPED\n'
    fi

    if [[ -f "${STATE_DIR}/cap_dut.pid" ]]; then
        printf 'DUT capture:    PID %s\n' "$(cat "${STATE_DIR}/cap_dut.pid")"
    else
        printf 'DUT capture:    STOPPED\n'
    fi

    if [[ -f "${STATE_DIR}/last_capture.env" ]]; then
        # shellcheck disable=SC1090
        source "${STATE_DIR}/last_capture.env"
        printf '\nLatest Capture Files:\n'
        printf '  Rogue:  %s\n' "${ROGUE_PCAP:-<none>}"
        printf '  Victim: %s\n' "${VICTIM_PCAP:-<none>}"
        if [[ -n "${DUT_PCAP:-}" ]]; then
            printf '  DUT:    %s\n' "${DUT_PCAP}"
        fi
    fi
}

main()
{
    local action="${1:-}"

    load_config
    require_command date
    require_command install

    case "${action}" in
        start)
            start_capture
            ;;
        stop)
            stop_capture
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
