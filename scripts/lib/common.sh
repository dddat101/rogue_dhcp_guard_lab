#!/usr/bin/env bash
# Common helpers for the Rogue DHCP Guard test project.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_LIB_DIR}/../.." && pwd)"
readonly CONFIG_FILE="${PROJECT_ROOT}/config.env"
readonly LOG_TAG="ROGUE-DHCP-GUARD"

log_info()
{
    printf '[INFO] %s\n' "$*"
}

log_warn()
{
    printf '[WARN] %s\n' "$*" >&2
}

log_error()
{
    printf '[ERROR] %s\n' "$*" >&2
}

die()
{
    log_error "$*"
    exit 1
}

require_root()
{
    if (( EUID != 0 )); then
        die "Run this command with sudo/root privileges."
    fi
}

require_command()
{
    local command_name
    command_name="$1"

    if ! command -v "${command_name}" >/dev/null 2>&1; then
        die "Required command is not installed: ${command_name}"
    fi
}

load_config()
{
    if [[ ! -f "${CONFIG_FILE}" ]]; then
        die "Missing ${CONFIG_FILE}. Copy config.env.example to config.env first."
    fi

    # shellcheck disable=SC1090
    source "${CONFIG_FILE}"

    : "${ROGUE_IF:?ROGUE_IF is required}"
    : "${VICTIM_IF:?VICTIM_IF is required}"
    : "${NS_ATK:?NS_ATK is required}"
    : "${NS_LAN:?NS_LAN is required}"
    : "${ROGUE_SERVER_IP:?ROGUE_SERVER_IP is required}"
    : "${ROGUE_PREFIX:?ROGUE_PREFIX is required}"
    : "${ROGUE_POOL_START:?ROGUE_POOL_START is required}"
    : "${ROGUE_POOL_END:?ROGUE_POOL_END is required}"
    : "${ROGUE_LEASE:?ROGUE_LEASE is required}"
    : "${DETECT_WAIT_SEC:?DETECT_WAIT_SEC is required}"
    : "${CLEAR_WAIT_SEC:?CLEAR_WAIT_SEC is required}"
    : "${DHCP_ACQUIRE_TIMEOUT_SEC:?DHCP_ACQUIRE_TIMEOUT_SEC is required}"
    : "${CAPTURE_DIR:?CAPTURE_DIR is required}"
    : "${STATE_DIR:?STATE_DIR is required}"
    : "${DHCP_CLIENT:?DHCP_CLIENT is required}"

    # Tools defaults
    TSHARK_BIN="${TSHARK_BIN:-tshark}"
    TCPDUMP_BIN="${TCPDUMP_BIN:-tcpdump}"
    DNSMASQ_BIN="${DNSMASQ_BIN:-dnsmasq}"

    # Resolve paths relative to project root
    if [[ "${CAPTURE_DIR}" != /* ]]; then
        CAPTURE_DIR="${PROJECT_ROOT}/${CAPTURE_DIR}"
    fi
    if [[ "${STATE_DIR}" != /* ]]; then
        STATE_DIR="${PROJECT_ROOT}/${STATE_DIR}"
    fi

    ensure_runtime_dirs
}

ensure_runtime_dirs()
{
    install -d -m 0755 "${CAPTURE_DIR}" "${STATE_DIR}"
}

iface_exists_root()
{
    local iface="$1"
    ip link show dev "${iface}" >/dev/null 2>&1
}

iface_exists_ns()
{
    local ns="$1"
    local iface="$2"
    ip netns exec "${ns}" ip link show dev "${iface}" >/dev/null 2>&1
}

ns_exists()
{
    local ns="$1"
    ip netns list | awk '{print $1}' | grep -Fxq "${ns}"
}

assert_safe_test_if()
{
    local iface="$1"

    if [[ "${iface}" == "lo" ]]; then
        die "Refusing to use loopback interface."
    fi

    if ip route show default 2>/dev/null | grep -Eq "dev[[:space:]]+${iface}([[:space:]]|$)"; then
        die "Interface ${iface} carries the default route; use a dedicated Ethernet adapter."
    fi

    if ip -4 addr show dev "${iface}" | grep -q 'inet '; then
        die "Interface ${iface} already has an IPv4 address; remove host configuration first."
    fi
}

validate_test_interfaces()
{
    if [[ "${ROGUE_IF}" == "${VICTIM_IF}" ]]; then
        die "ROGUE_IF and VICTIM_IF must be different interfaces."
    fi

    if iface_exists_root "${ROGUE_IF}"; then
        assert_safe_test_if "${ROGUE_IF}"
    elif ! iface_exists_ns "${NS_ATK}" "${ROGUE_IF}"; then
        die "Configured ROGUE_IF (${ROGUE_IF}) not found in root namespace or ${NS_ATK}."
    fi

    if iface_exists_root "${VICTIM_IF}"; then
        assert_safe_test_if "${VICTIM_IF}"
    elif ! iface_exists_ns "${NS_LAN}" "${VICTIM_IF}"; then
        die "Configured VICTIM_IF (${VICTIM_IF}) not found in root namespace or ${NS_LAN}."
    fi
}

validate_namespace_ready()
{
    local ns="$1"
    local iface="$2"

    if ! ns_exists "${ns}"; then
        die "Namespace does not exist: ${ns}. Run scripts/setup.sh first."
    fi

    if ! iface_exists_ns "${ns}" "${iface}"; then
        die "Interface ${iface} is missing in namespace ${ns}. Run cleanup.sh and setup.sh again."
    fi
}

ns_create()
{
    local ns="$1"
    if ! ns_exists "${ns}"; then
        ip netns add "${ns}"
    fi
    ip -n "${ns}" link set lo up
}

move_if_to_ns()
{
    local iface="$1"
    local ns="$2"

    if iface_exists_ns "${ns}" "${iface}"; then
        return 0
    fi

    if ! iface_exists_root "${iface}"; then
        die "Interface not found in root namespace: ${iface}"
    fi

    ip link set dev "${iface}" down
    ip link set dev "${iface}" netns "${ns}"
}

restore_if_from_ns()
{
    local ns="$1"
    local iface="$2"

    if iface_exists_ns "${ns}" "${iface}"; then
        ip -n "${ns}" link set dev "${iface}" down || true
        ip netns exec "${ns}" ip link set dev "${iface}" netns 1 || true
    fi
}

is_pidfile_running()
{
    local pidfile="$1"
    local pid

    if [[ ! -f "${pidfile}" ]]; then
        return 1
    fi

    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -z "${pid}" || "${pid}" =~ [^0-9] ]]; then
        return 1
    fi

    kill -0 "${pid}" 2>/dev/null
}

stop_pidfile()
{
    local pidfile="$1"
    local pid
    local attempt

    if [[ ! -f "${pidfile}" ]]; then
        return 0
    fi

    pid="$(cat "${pidfile}" 2>/dev/null || true)"
    if [[ -n "${pid}" && "${pid}" =~ ^[0-9]+$ ]]; then
        if kill -0 "${pid}" 2>/dev/null; then
            kill -INT "${pid}" 2>/dev/null || kill -TERM "${pid}" 2>/dev/null || true

            for attempt in {1..20}; do
                if ! kill -0 "${pid}" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done

            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
        fi
    fi

    rm -f "${pidfile}"
}

select_dhcp_client()
{
    case "${DHCP_CLIENT}" in
        dhclient)
            require_command dhclient
            printf '%s\n' dhclient
            ;;
        udhcpc)
            require_command udhcpc
            printf '%s\n' udhcpc
            ;;
        auto)
            if command -v udhcpc >/dev/null 2>&1; then
                printf '%s\n' udhcpc
            elif command -v dhclient >/dev/null 2>&1; then
                printf '%s\n' dhclient
            else
                die "Neither udhcpc nor dhclient is available."
            fi
            ;;
        *)
            die "Unsupported DHCP_CLIENT value: ${DHCP_CLIENT}"
            ;;
    esac
}

run_dut_cmd()
{
    local cmd="$1"

    if [[ -z "${DUT_SSH_HOST:-}" || -z "${cmd}" ]]; then
        return 0
    fi

    require_command ssh

    # shellcheck disable=SC2086
    ssh ${DUT_SSH_OPTS} "${DUT_SSH_USER}@${DUT_SSH_HOST}" "${cmd}"
}
