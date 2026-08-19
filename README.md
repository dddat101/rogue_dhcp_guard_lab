# Rogue DHCP Guard Test Lab

## Summary

This project verifies a gateway feature that detects DHCPv4 server traffic entering from an untrusted Ethernet LAN port, blocks that traffic before it reaches other LAN/WLAN clients, suppresses the gateway's local DHCP server, and automatically restores the configured DHCP state after the foreign server disappears.

The preferred topology uses one Ubuntu PC and two dedicated Ethernet adapters connected to two different physical DUT LAN ports. Linux network namespaces isolate the rogue DHCP server and victim client while still forcing packets through the DUT's physical LAN bridge datapath.

## Assumptions / Constraints

- DUT has at least two physical LAN ports in the same LAN bridge.
- The two Linux test interfaces are dedicated USB/Ethernet adapters and do not carry management or the default route.
- DUT management is independent, for example Wi-Fi, a third adapter, or serial console.
- DUT local LAN is expected to use its normal production subnet; the rogue DHCP pool uses `10.10.0.0/24` to make leakage obvious.
- The product's exact detection/recovery timers are configurable in `config.env`; do not treat example values as normative.
- Test does not disable packet acceleration. Verification must be performed with the production acceleration mode enabled.

## Physical Cabling

```text
                         independent management
Ubuntu PC  ------------------------------- DUT mgmt/SSH (optional)

USB/Ethernet A --------------------------- DUT LAN port A
   ns-atk / rogue DHCP server

USB/Ethernet B --------------------------- DUT LAN port B
   ns-lan1 / victim DHCP client
```

This is intentionally not a local Linux bridge between rogue and victim. Their traffic must traverse the DUT LAN bridge.

## Logical Topology

```text
ns-atk                                    ns-lan1
rogue DHCP                               victim
10.10.0.1/24                              DHCP
    |                                       |
USB NIC A                                  USB NIC B
    |                                       |
DUT LAN A -------- DUT LAN bridge -------- DUT LAN B
                       |
                  local DHCP server
```

Expected rogue traffic path:

```text
rogue OFFER/ACK
   -> DUT LAN A ingress
   -> DHCP guard detect/drop
   -X-> DUT LAN B / WLAN client
```

## Interface / IP / Namespace Table

| Role | Namespace | Interface | Address |
|---|---|---|---|
| Rogue DHCP server | `ns-atk` | `$ROGUE_IF` | `10.10.0.1/24` |
| Victim client | `ns-lan1` | `$VICTIM_IF` | DHCP |
| DUT LAN | DUT | physical LAN ports / `br0` | normal DUT LAN address |
| DUT management | independent | not used by test datapath | site-specific |

## Setup

```bash
cp config.env.example config.env
$EDITOR config.env
sudo ./scripts/setup.sh
```

Validate that each test NIC is cabled to a different DUT LAN port.

> [!TIP]
> **Prevent Host NetworkManager from auto-configuring test NICs:**
> By default, Ubuntu's NetworkManager may try to acquire DHCP leases and add default routes on newly plugged USB NICs. To prevent this, set them as unmanaged:
> ```bash
> sudo nmcli device set <ROGUE_IF> managed no
> sudo nmcli device set <VICTIM_IF> managed no
> ```
> 
> **Fixing "Interface carries default route / already has IPv4 address":**
> If the test NICs already obtained an IP/route on the host before running setup, flush them:
> ```bash
> sudo ip addr flush dev <ROGUE_IF>
> sudo ip addr flush dev <VICTIM_IF>
> sudo ip route del default dev <ROGUE_IF> 2>/dev/null || true
> sudo ip route del default dev <VICTIM_IF> 2>/dev/null || true
> ```

## Packet Flow

Baseline with rogue server off:

```text
Victim DISCOVER -> DUT local DHCP -> OFFER/ACK -> Victim
```

Rogue present:

```text
Victim DISCOVER -> DUT bridge -> Rogue server
Rogue OFFER/ACK -> DUT LAN ingress -> guard DROP
Detection -> DUT local DHCP suppression
```

After rogue removal:

```text
controlled clear verification -> suppression cleared -> configured local DHCP state restored
```

## Test Commands

Start packet captures:

```bash
sudo ./scripts/capture.sh start
```

Baseline request (rogue server OFF):

```bash
sudo ./scripts/rogue.sh stop
sudo ./scripts/client_request.sh
```

Start rogue server:

```bash
sudo ./scripts/rogue.sh start
```

Inspect state & diagnostics:

```bash
sudo ./scripts/show_state.sh
./scripts/diagnose.sh
```

Request a fresh lease while rogue is present:

```bash
sudo ./scripts/client_request.sh
```

Remove rogue and wait for automatic recovery:

```bash
sudo ./scripts/rogue.sh stop
sleep 60
sudo ./scripts/client_request.sh
```

Or run the bounded end-to-end automated scenario:

```bash
sudo ./scripts/scenario.sh
```

## Verification / Expected Result

1. Baseline: victim obtains a legitimate DUT LAN lease.
2. Rogue enabled: capture on `ns-atk` proves the rogue server emits DHCP server responses.
3. Capture on victim must not show rogue `UDP 67 -> 68` responses crossing the DUT.
4. DUT detection/drop counters increase on the ingress LAN port.
5. DUT local DHCP server transitions to the suppressed/stopped state after detection.
6. While suppressed, a fresh victim request must not obtain a rogue `10.10.0.x` lease.
7. After rogue removal and the approved clear algorithm completes, the DUT restores the configured DHCP state.
8. Victim again obtains a legitimate DUT LAN lease.

## Capture / Diagnostics

Ubuntu captures are saved in `captures/`:

```text
rogue_<timestamp>.pcapng
victim_<timestamp>.pcapng
```

Useful offline filters:

```bash
tshark -r captures/<file>.pcapng -Y 'bootp || dhcp'
tshark -r captures/<file>.pcapng -Y 'udp.srcport == 67 && udp.dstport == 68'
```

On the DUT, prefer:

```bash
tcpdump -ni br0 -s 0 'udp port 67 or udp port 68'
```

If the implementation exposes feature state/counters through platform-specific commands, put those commands in `config.env` rather than hard-coding them into the scripts.

Record for each run:

- DUT firmware/build.
- LAN link speed/duplex.
- Packet acceleration state.
- Detection/drop counters.
- DHCP process state.
- Detection time and recovery time.
- Captures on rogue, victim, and DUT.
- CPU/softirq if stress testing.

## Cleanup

```bash
sudo ./scripts/cleanup.sh
```

The script stops captures and dnsmasq, moves the physical NICs back to the root namespace, deletes namespaces, and leaves the dedicated test NICs down.

> [!TIP]
> **Viewing and bringing interfaces UP after cleanup:**
> * `cleanup.sh` leaves test interfaces in `DOWN` state so `ifconfig` (without `-a`) hides them. Use `ip -br link` or `ifconfig -a` to view all interfaces.
> * To bring an interface UP on the host manually:
>   ```bash
>   sudo ip link set dev <interface_name> up
>   ```

## Limitations

- The lab verifies rogue DHCP arriving through a physical Ethernet LAN port. WLAN-ingress rogue-server testing requires a separate Wi-Fi topology.
- Absence of a response to an active probe is heuristic evidence that the rogue server is gone; use the product-approved clear algorithm.
- A Linux-side capture alone does not prove enforcement when the platform has hardware acceleration. The decisive evidence is absence of rogue DHCP at the victim plus DUT hardware/software counters as available.
- If the DUT has only one LAN port, use two physical Ubuntu PCs with a managed L2 setup that still forces rogue-to-victim traffic through the DUT datapath; do not locally bridge the two namespaces on the same PC.
