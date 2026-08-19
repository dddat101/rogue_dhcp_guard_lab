#!/usr/bin/env bash
# Execute the automated end-to-end Rogue DHCP Guard test scenario.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

get_victim_ip()
{
    ip netns exec "${NS_LAN}" ip -4 -o addr show dev "${VICTIM_IF}" 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | head -n 1
}

main()
{
    local auto_yes="${1:-}"
    local p1_ip=""
    local p3_ip=""
    local p5_ip=""
    local p1_status="FAIL"
    local p3_status="FAIL"
    local p5_status="FAIL"

    require_root
    load_config

    validate_namespace_ready "${NS_ATK}" "${ROGUE_IF}"
    validate_namespace_ready "${NS_LAN}" "${VICTIM_IF}"

    cat <<INFO
============================================================
           Rogue DHCP Guard Test Scenario
============================================================
Preconditions:
  - Rogue interface:  ${NS_ATK}/${ROGUE_IF} (Pool: ${ROGUE_POOL_START} - ${ROGUE_POOL_END})
  - Victim interface: ${NS_LAN}/${VICTIM_IF}
  - Detection wait:   ${DETECT_WAIT_SEC}s
  - Recovery wait:    ${CLEAR_WAIT_SEC}s

Verification Invariants:
  1. Baseline: Victim acquires legitimate DUT lease.
  2. Attack: While rogue is active, victim must NOT acquire rogue lease.
  3. Recovery: After rogue is removed, legitimate DHCP service restores.
============================================================
INFO

    if [[ "${auto_yes}" != "-y" && "${auto_yes}" != "--yes" ]]; then
        printf '\nStart automated scenario? [y/N] '
        local answer
        read -r answer
        case "${answer}" in
            y|Y|yes|YES) ;;
            *) log_info "Scenario cancelled."; exit 0 ;;
        esac
    fi

    # Phase 0: Start captures
    log_info "=== Phase 0: Starting packet captures ==="
    "${SCRIPT_DIR}/capture.sh" start
    trap '"${SCRIPT_DIR}/capture.sh" stop >/dev/null 2>&1 || true' EXIT INT TERM

    # Phase 1: Baseline
    log_info "=== Phase 1: Baseline (Rogue server OFF) ==="
    "${SCRIPT_DIR}/rogue.sh" stop >/dev/null 2>&1 || true
    "${SCRIPT_DIR}/client_request.sh" || true
    p1_ip="$(get_victim_ip)"
    if [[ -n "${p1_ip}" && ! "${p1_ip}" =~ ^10\.10\.0\. ]]; then
        p1_status="PASS (${p1_ip})"
    else
        p1_status="FAIL (IP: ${p1_ip:-none})"
    fi
    "${SCRIPT_DIR}/show_state.sh"

    # Phase 2: Enable Rogue DHCP
    log_info "=== Phase 2: Enable Rogue DHCP server ==="
    "${SCRIPT_DIR}/rogue.sh" start
    log_info "Waiting ${DETECT_WAIT_SEC}s for DUT guard detection..."
    sleep "${DETECT_WAIT_SEC}"
    "${SCRIPT_DIR}/show_state.sh"

    # Phase 3: Client request during attack
    log_info "=== Phase 3: Fresh client request with Rogue present ==="
    "${SCRIPT_DIR}/client_request.sh" || true
    p3_ip="$(get_victim_ip)"
    if [[ -n "${p3_ip}" && "${p3_ip}" =~ ^10\.10\.0\. ]]; then
        p3_status="FAIL - LEAKED ROGUE LEASE (${p3_ip})"
    else
        p3_status="PASS - NO ROGUE LEASE (IP: ${p3_ip:-none})"
    fi
    "${SCRIPT_DIR}/show_state.sh"

    # Phase 4: Stop rogue DHCP and wait for automatic recovery
    log_info "=== Phase 4: Stop Rogue server and wait ${CLEAR_WAIT_SEC}s for recovery ==="
    "${SCRIPT_DIR}/rogue.sh" stop
    log_info "Waiting ${CLEAR_WAIT_SEC}s for automatic clear algorithm..."
    sleep "${CLEAR_WAIT_SEC}"
    "${SCRIPT_DIR}/show_state.sh"

    # Phase 5: Request lease after recovery
    log_info "=== Phase 5: Client request after recovery ==="
    "${SCRIPT_DIR}/client_request.sh" || true
    p5_ip="$(get_victim_ip)"
    if [[ -n "${p5_ip}" && ! "${p5_ip}" =~ ^10\.10\.0\. ]]; then
        p5_status="PASS (${p5_ip})"
    else
        p5_status="FAIL (IP: ${p5_ip:-none})"
    fi
    "${SCRIPT_DIR}/show_state.sh"

    # Stop captures
    "${SCRIPT_DIR}/capture.sh" stop
    trap - EXIT INT TERM

    printf '\n============================================================\n'
    printf '                  SCENARIO RESULTS SUMMARY                  \n'
    printf '============================================================\n'
    printf '  Phase 1 (Baseline lease):     %s\n' "${p1_status}"
    printf '  Phase 3 (Isolation under atk):%s\n' "${p3_status}"
    printf '  Phase 5 (Post-recovery lease):%s\n' "${p5_status}"
    printf '============================================================\n'
    printf 'Captures saved under: %s\n' "${CAPTURE_DIR}"
}

main "$@"
