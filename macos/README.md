# Snorkel — a USB Wi-Fi adapter as an old Mac's Wi-Fi, with no kext

Snorkel makes a TP-Link **Archer T3U Plus** (AC1300, RTL8822BU, USB `2357:0138`) the Wi-Fi
of a Mac mini 2014 on **macOS 12 with SIP on**. TP-Link's Realtek kext cannot
load on Monterey without SIP off, and SIP can only be changed from Recovery,
which needs a keyboard and screen this headless Mac does not have. Snorkel
drives the chip from user space over libusb instead: no kext, no SIP change.

Snorkel is a fork of [devourer](https://github.com/OpenIPC/devourer), the
OpenIPC userspace Realtek driver. The radio driver and the station core are
devourer's; Snorkel adds the macOS interface, the daemon and the scripts in
this directory. Licence: GPL-2.0, as devourer.

The station client (`tests/sta_client.cpp`) scans, joins with WPA2-PSK, runs
CCMP in software, and hands Ethernet frames to macOS through a fake-Ethernet
interface, `feth0`. A launchd daemon keeps it running and routes internet
traffic over it. The built-in Wi-Fi (`en1`) stays as the fallback, or can be
switched off.

## Quick start

Needs: Homebrew `libusb`, `openssl@3`, `cmake`, `ninja`, `just`; the AP's
password saved in the System keychain (the Mac joined it once before).

```
git clone <this repo> snorkel && cd snorkel
$EDITOR macos/snorkel.conf   # set SSID to your network's name
just test             # build + headless tests, no adapter needed
just install          # build, store the password root-only, start the daemon
just status           # wait ~20 s: feth0 should have an address
```

Then, to run on the adapter alone, see [Switching over](#switching-over).

## Commands

All from the repo root. The ones that change the system ask for your password.

| Command | What it does |
|---|---|
| `just` | List the commands |
| `just build` | Build `build/sta_client` |
| `just test` | Build and run the 8 headless station test suites |
| `just datapath-test` | One-shot on-air test (~3 min): join, DHCP, ping, speed vs `en1`, default-route switch; writes `logs/datapath-*`. Needs the daemon stopped. |
| `just install` | Build, install and start the daemon. Re-run after any code change. Keeps an edited config. |
| `just uninstall` | Remove the daemon, its files and the stored password; turns `en1` on |
| `just start` / `just stop` / `just restart` | Control the installed daemon. Stopping turns `en1` on. |
| `just status` | Daemon, mode, both interfaces, routes, DNS, last link line, last daemon lines |
| `just logs` | Follow both logs |
| `just link` | Follow only state changes, Block Ack events and the 2 s link lines |
| `just wifi-off` | Mode `adapter`: built-in Wi-Fi off, everything on the adapter (checked first) |
| `just wifi-on` | Mode `auto`: built-in Wi-Fi on, internet on the adapter while healthy |
| `just use-builtin` | Mode `builtin`: built-in Wi-Fi carries everything; adapter idle |
| `just config` | Edit the installed config, then restart the daemon |

## Switching over

The intended routine: log in over the built-in Wi-Fi, then move to the adapter.

1. Connect (Screen Sharing or SSH) to the Mac's built-in Wi-Fi address.
2. `just status` — check `daemon: running` and that `adapter feth0` has an
   address. Note that address: you reconnect to it in step 4.
3. `just wifi-off`. It refuses unless the adapter reaches the router (2 of 3
   pings) and the internet (1.1.1.1) right now. Then it prints the address to
   reconnect to and sets mode `adapter`.
4. Within about 10 s the built-in Wi-Fi turns off and your session drops.
   Reconnect to the adapter's address (or `<LocalHostName>.local`).

**Failsafes in mode `adapter`** (the daemon checks every 5 s):

| Condition | What the daemon does |
|---|---|
| Adapter link down (router silent on `feth0`) for 30 s | Built-in Wi-Fi on. When the link recovers, off again. |
| Link up but no internet (ping 1.1.1.1 + DNS) for 30 s | Built-in Wi-Fi on, mode set back to `auto` |
| `sta_client` exits or restarts | Built-in Wi-Fi on until it is healthy again |
| Daemon stops (`just stop`, `uninstall`, crash) | Built-in Wi-Fi on |

The mode survives a reboot: in `adapter` mode the built-in Wi-Fi comes up at
boot and is switched off once the adapter is healthy. If you lose the Mac
entirely, power-cycle it: the built-in Wi-Fi is on at every boot.

`just wifi-on` returns to `auto`. In `auto` LAN traffic (including Screen
Sharing to the built-in address) stays on the built-in Wi-Fi and internet
traffic uses the adapter.

## Modes

| Mode | Built-in Wi-Fi | Internet traffic | LAN traffic |
|---|---|---|---|
| `auto` (default) | on | adapter while it answers, else built-in | built-in |
| `adapter` | off while the adapter is healthy | adapter | adapter |
| `builtin` | on | built-in | built-in |

Stored in `/usr/local/etc/snorkel/mode`; `just wifi-off` / `wifi-on` /
`use-builtin` write it.

## Configuration

`macos/snorkel.conf` is the default; the installed copy is
`/usr/local/etc/snorkel/snorkel.conf` (`just config`).

| Key | Default | Meaning |
|---|---|---|
| `SSID` | (empty) | Network to join; required. Its password is read from the System keychain at install. |
| `CHANNEL` | `48` | Channel to start on. Start in the AP's band: a 2.4 ↔ 5 GHz start costs a scan. |
| `SCAN_CHANNELS` | `36,40,44,48` | Where to look for the AP after losing it |
| `HT` | `1` | 802.11n association (HT Capabilities + WMM). `0` = legacy 802.11a/g. |
| `BA` | `1` | Accept Block Ack (A-MPDU) agreements. `0` declines them. Needs `HT=1`. |
| `TX_RATE` | `MCS3` | Rate for our data frames (`6M`..`54M`, `MCS0`..`MCS15`); the firmware steps down on retries |
| `BASE_RATE` | `6M` | Rate for management, WPA2 handshake and broadcast frames |
| `ACK_RATES` | `0x10` | Rates the chip may ACK with (RRSR bits; `0x10` = 6M only) |
| `IGI_MAX` | `50` | Ceiling of the receiver's gain control (DIG) |
| `IFACE` | `feth0` | Host-side interface; its peer is `feth<N+5000>` |
| `VID` / `PID` | `0x2357` / `0x0138` | The adapter's USB ID |

A new SSID needs its password stored again: `just uninstall`, edit
`macos/snorkel.conf`, `just install`.

## Reading the logs

`/var/log/snorkel.log` is the client; `/var/log/snorkel-daemon.log`
is the daemon (routes, Wi-Fi power, DNS, restarts). The client log restarts
at 20 MB (the old one is kept as `.1`).

- `station state: Connected t=12.345` — every state change. A failure names
  its reason: `beacon-lost`, `deauthenticated` (with the AP's `status`),
  `auth-timeout`, `assoc-refused`, `handshake-timeout`, ...
- `block ack: TID 0 started t=... ssn=... win=64` / `ended` — the AP opened or
  closed an aggregation agreement.
- `link:` every 2 s:

  | Field | Meaning |
  |---|---|
  | `igi` | receiver gain index (0x1c = most sensitive) |
  | `fa` | false alarms in the last DIG window |
  | `ap_rssi` | AP signal, dBm (approximate) |
  | `rx` / `dup` / `tx` | encrypted frames from the AP, duplicates dropped, frames we queued |
  | `ht` / `legacy` / `mcs_max` | data frames to us by PHY, and the highest MCS seen |

- The ledger at exit: joins, the four-way, CCMP counters, `ht:` (ADDBA
  declined, A-MSDUs), `block ack:` (agreements, DELBAs, reorder holes), TAP
  and TX counters.

## How it works

```
AP ⇄ T3U Plus ⇄ libusb ⇄ sta_client ⇄ feth5000 ⇄ feth0 ⇄ macOS IP stack
                         scan, join,    BPF read     DHCP, ARP, routes
                         WPA2, CCMP,    NDRV write
                         reorder
```

- **Interface.** macOS has no TAP device. `sta_client` creates a fake-Ethernet
  pair: the host stack owns `feth0`, which carries the radio's MAC; the
  client owns the peer, reading what the host sends with BPF and writing what
  it receives with an NDRV socket (the method ZeroTier uses). Needs root.
- **Station.** The device-free core in `src/sta/` (`StationSm`, `Supplicant`,
  `Ccmp`, `BssTable`, `Reorder`). The chip ACKs and BlockAcks frames for our
  address once the client arms the station identity.
- **802.11n.** The association request carries HT Capabilities (20 MHz,
  MCS 0–15, short GI, RX STBC) and WMM. A-MSDUs are unpacked, with the
  A-MSDU-flip guard (CVE-2020-24588). No VHT: the radio is tuned at 20 MHz.
- **Block Ack.** Immediate-policy agreements for TID 0–7 are accepted with a
  window of up to 64. `src/sta/Reorder.h` puts A-MPDU frames back in sequence
  order before CCMP and gives up on a hole on a BlockAckReq, a window slide or
  after 100 ms. Our own transmissions are not aggregated.
- **Rates.** Management, EAPOL and broadcast go at `BASE_RATE`; our data at
  `TX_RATE` with the firmware's MCS3 → 2 → 1 → 0 fallback. The chip ACKs at
  6M (`ACK_RATES`) because the AP hears us about 5 dB weaker than we hear it.
- **Routing.** DHCP on `feth0` through `ipconfig`. Internet goes over two
  half-default routes (0/1, 128/1) via `-ifp feth0`, which override the
  default route without touching it: macOS ignored `PrimaryRank` for this
  interface. When the built-in Wi-Fi is off and macOS has no DNS left, the
  daemon publishes `feth0`'s DHCP answers as its own network service in the
  dynamic store, the way VPN up-scripts do.

**Installed files:** `/usr/local/libexec/snorkel/` (binary, daemon,
helpers; root-owned), `/usr/local/etc/snorkel/` (config, mode, and `psk`
with mode 600), `/Library/LaunchDaemons/local.snorkel.plist`,
`/var/log/snorkel*.log`.

## Troubleshooting

| Symptom | Check / fix |
|---|---|
| `just status` shows no `feth0` address | `just link`: is there a `Connected` line? If not, the `Failed` line names the reason. Wrong password: `just uninstall`, then `just install`. |
| `wifi-off` refused | It says why. Usually the link is still joining: wait 20 s, then `just status`. |
| Lost the Mac after `wifi-off` | Wait 30–60 s for the failsafe, then reconnect to the built-in address. Last resort: power-cycle. |
| `datapath-test` says the daemon holds the adapter | `just stop`, run the test, `just start` |
| Slow upload | Expected (see Known limits). Moving the adapter into the open helps more than any setting. |
| After a macOS update | `just install` again (rebuilds against the current SDK) |

## Development

- `just build` turns off the Jaguar1 and RTL8733B backends: AppleClang 14
  (Xcode 14, macOS 12) has no `std::jthread`. The 8822B is Jaguar2.
- `just test` runs `sta_client_headless`, `station_sm`, `supplicant`,
  `ccmp_framing`, `dot11_frames`, `bss_table`, `sta_reorder`, `station_arm`.
  The full `ctest` passes except `noise_floor_math`, which AppleClang 14
  cannot compile (unrelated).
- Client switches added for macOS: `DEVOURER_STA_TAP=feth<N>`,
  `DEVOURER_STA_BASE_RATE`, `DEVOURER_STA_ACK_RATES`, `DEVOURER_STA_HT`,
  `DEVOURER_STA_BA`, `DEVOURER_STA_LINK_LOG`, `DEVOURER_STA_SCAN_LOG`, and
  `DEVOURER_IGI_MAX` (library). By hand:
  `sudo DEVOURER_STA_PSK=... DEVOURER_VID=0x2357 DEVOURER_PID=0x0138 DEVOURER_CHANNEL=48 DEVOURER_STA_SSID=<ssid> DEVOURER_STA_TAP=feth0 build/sta_client 60`

## Measurements (on air, 2026-10-05 / 06)

The home AP on channel 48 at about -70 dBm to the adapter; the built-in Wi-Fi
saw it at -77 dBm.

| Run | Result |
|---|---|
| Legacy, 54M for everything | 23 joins failed in 45 s → management/EAPOL now at `BASE_RATE` 6M |
| Legacy, 24M data | join 3 s, DHCP 3–6 s, ping router 0% loss 4–7 ms; down 5 / up 1.7 Mbps; 13 drops in 2 min |
| The drops | all `beacon-lost` while thousands of AP frames arrived: `StationSm::tick` got a clock older than the RX thread's last stamp and the unsigned difference wrapped. Fixed (`StationSm::elapsed`). After: 0 drops. |
| DIG | IGI at the 0x1c floor throughout: not a cause. `IGI_MAX` kept as a guard. |
| Duplicates ~20% | the AP missed our ACKs → `ACK_RATES=0x10`; then fixed outright by HT |
| HT on, ADDBA declined | down 15.6 / up 4.6 Mbps (en1 22.1 / 7.1); duplicates 47 of 55,922 |
| HT + Block Ack | down 18.9 (16.4 as default route) / up 2.2 Mbps; 54,510 HT frames to 8 legacy, MCS up to 12; ~2,700 frames/s at peak; 0 duplicates, 0 MIC failures. en1 stalled to 0.2 / 0.0 in the same run. |
| Default route | `PrimaryRank Last` on en1 did not move it; 0/1 + 128/1 via `-ifp feth0` did |
| TX power | Local limit: 200 mW EIRP in 5150–5350 MHz, the ETSI figure. This board's table allows index 32 (ETSI) vs the 30 (MKK) world-wide minimum in use: +1 dB, not worth it. |

## Known limits

- Upload (2–5 Mbps) is limited by how well the AP hears us: TX power is at
  the legal limit, and `TX_RATE` is fixed with only the firmware's fallback —
  no rate control from TX reports yet.
- No VHT (802.11ac): the radio tunes 20 MHz only. No TX aggregation.
- One BSS by SSID, no roaming. PMF (802.11w) and WPA3 are not supported.
- The DNS fallback is written but not yet triggered on air: in the first
  adapter-mode run (2026-10-06) macOS kept its DNS after `en1` went off.
- The firmware logs `LCK TIMEOUT (LO not locked!)` at bring-up; RX and TX work.
