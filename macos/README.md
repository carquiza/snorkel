# devourer station on macOS — Archer T3U Plus on a Mac mini 2014

**Updated:** 2026-10-06 · **Phase:** 802.11n on air · **Health:** 0 drops; down 15.6 / up 4.6 Mbps vs en1 22.1 / 7.1; duplicates 47 (was ~11,000)

Goal: use the TP-Link Archer T3U Plus (RTL8822BU, `2357:0138`) as this Mac's
Wi-Fi on macOS 12 with SIP **on**. The Realtek kext cannot load on Monterey
without SIP off, and SIP can only be changed from Recovery, which needs a
keyboard and screen this machine does not have. devourer runs the chip from
user space over libusb instead, so no kext and no SIP change.

## Shape

```
router ⇄ T3U Plus ⇄ libusb ⇄ sta_client ⇄ feth5000 ⇄ feth0 ⇄ macOS IP stack
                              (scan, join,   BPF read      DHCP, ARP, routes
                               WPA2, CCMP)   NDRV write
```

- `feth0`/`feth5000` is a macOS fake-Ethernet pair (as ZeroTier uses). The host
  side, `feth0`, carries the radio's MAC, so the AP sees the frames the host
  sends as coming from the associated station.
- `sta_client` creates the pair on start and destroys it on exit. Needs root.
- The built-in Wi-Fi (`en1`) stays associated as the fallback.

## Plan

1. **Band switch bug** — Jaguar2 `set_channel_bw` keeps RF18 band bits 16/8
   from the previous register value on 5 GHz, but clears them on 2.4 GHz, so a
   2.4 → 5 GHz retune leaves the synth in 2.4 GHz mode. Set them explicitly.
2. **macOS data plane** — `tap_open` on macOS: create the feth pair, BPF on the
   peer for host → radio, NDRV for radio → host.
3. **Transmit rate** — start unicast at 54M and let the firmware's retry ladder
   step down (`DEVOURER_TX_RETRY_FALLBACK` default). Association stays legacy
   (no HT/VHT IEs), so the AP's downlink is capped at 54 Mbps as well.
4. **Routing** — DHCP on `feth0` via `ipconfig set feth0 DHCP`; when the link
   is healthy make it primary over `en1`, and drop back when it is not.
5. **Start at boot** — a launchd daemon runs `devourer-sta-run.sh`, which loops
   the client, runs DHCP, and watches the link.

## Files

| File | Role |
|---|---|
| `macos/sta-datapath-test.sh` | one-shot root test: client + feth + DHCP + ping/speed, auto teardown |
| `macos/devourer-sta-run.sh` | the daemon body (loop, DHCP, primary-route watchdog) |
| `macos/install.sh` / `uninstall.sh` | copy binary + scripts, store the PSK root-only, load the daemon |
| `macos/com.openipc.devourer-sta.plist` | launchd job |

## Findings (on air, 2026-10-06)

| Run | Result |
|---|---|
| 54M for everything | 23 joins failed in 45 s → management/EAPOL now at `BASE_RATE` 6M |
| 24M data, 6M base | join 3 s, DHCP 3–6 s, ping router 0% loss 4–7 ms; down 5 / up 1.7 Mbps (en1: 17 / 6.6) |
| drops | 13 in 2 min, all `beacon-lost` while thousands of AP frames arrived: `StationSm::tick` got a clock older than the RX thread's last stamp and the unsigned diff wrapped. Fixed (`StationSm::elapsed`, cell `test_tick_behind_the_last_frame`). |
| DIG | IGI sat at the 0x1c floor throughout: not the cause. `IGI_MAX` kept as a guard. |
| duplicates | 15–100% of AP frames arrived twice (Retry bit): AP misses our ACKs. TX power is the world-wide-min limit (index 30 ≈ 15 dBm at ch48). `ACK_RATES=0x10` makes the chip ACK at 6M. |
| default route | `PrimaryRank Last` on en1 did not move it; 0/1 + 128/1 via `-ifp feth0` did. |
| after the tick fix | 0 drops in 2 min, 1 join; down 9.4 / up 1.8 Mbps; still ~20% duplicates |
| HT on (MCS3 up, ADDBA declined) | down 15.6 / up 4.6 Mbps (from 9.4 / 1.8); duplicates 47 of 55,922 (from 11,190); 9 ADDBA declined, 0 A-MSDU. The run's rate counter read DESC_RATE as an AX code and called every frame legacy - fixed after the run. |
| TX power | Local limit: 200 mW EIRP in 5150–5350 MHz, the ETSI figure. The rfe_type 3 table allows 32 (ETSI) vs the 30 (MKK) world-wide min in use: +1 dB, not worth it. |

## Known limits

- 802.11n (`HT=1`): HT Capabilities (20 MHz, MCS 0-15, SGI20, RX STBC) + WMM in
  the association request; every ADDBA is declined, so no A-MPDU; A-MSDUs are
  unpacked (with the A-MSDU-flip guard). No VHT (80 MHz is not tuned).
- One BSS by SSID, no roaming; 2.4 GHz + 5 GHz scan works after fix 1.
- Firmware logs `LCK TIMEOUT (LO not locked!)` at bring-up; RX/TX still work.
- TX power stays at the world-wide-minimum regulatory limit; raising it
  (`DEVOURER_TX_PWR`) is the owner's regulatory call, not a default.
