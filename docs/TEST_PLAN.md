# Test Plan

## Objective

Verify detection, isolation, local DHCP suppression, failure safety, and automatic recovery for unauthorized DHCPv4 server traffic received from a DUT Ethernet LAN port.

## Core Test Cases

| ID | Test | Expected result |
|---|---|---|
| T01 | Baseline local DHCP | Victim obtains legitimate DUT lease |
| T02 | Rogue DHCP server emits OFFER/ACK | Rogue-side capture proves server responses are generated |
| T03 | Isolation | Victim does not receive rogue `67 -> 68` responses |
| T04 | Detection | DUT ingress detection counter increases |
| T05 | Suppression | DUT local DHCP server stops/suppresses after detection |
| T06 | No rogue lease during suppression | Fresh victim request never receives `10.10.0.x` |
| T07 | Automatic recovery | After rogue removal and approved clear checks, configured DHCP state is restored |
| T08 | Recovery race | Reintroduce rogue during recovery; isolation remains and recovery aborts/re-suppresses |
| T09 | Rule self-repair | Remove owned guard rule/table; implementation repairs it and reports degraded/error state as designed |
| T10 | Firewall daemon restart | Isolation and suppression checkpoint behavior matches design |
| T11 | Port inventory change | Move cable to another LAN port; protected inventory updates without leaking rogue DHCP |
| T12 | Repeated cycles | Repeat detect/clear cycle >=100 times without stale state or lease leakage |

## Measurements

For every run record:

- Packet direction and interface.
- Ethernet frame/MTU.
- Duration.
- Link speed/duplex.
- Offload/acceleration state.
- nftables or hardware counters.
- Packet drops.
- DUT CPU and softirq load for repeated/stress tests.
- Detection latency.
- DHCP stop latency.
- Clear/recovery latency.

## Pass Criteria

The minimum security invariant is:

```text
Unauthorized DHCP server responses received from a protected LAN ingress
must never reach wired or wireless clients.
```

The control-plane invariant is:

```text
After detection the local DHCP server enters the required suppressed state,
and after the foreign server is considered cleared the original configured
DHCP state is restored, not blindly forced on.
```
