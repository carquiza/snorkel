# Snorkel

**A USB Wi-Fi adapter as an old Mac's Wi-Fi — no kext, SIP stays on.**

Snorkel makes a TP-Link **Archer T3U Plus** (AC1300, Realtek RTL8822BU) the
network connection of a Mac that its vendor driver no longer supports. It was
built for a headless Mac mini (Late 2014) on **macOS 12 Monterey**: TP-Link's
kext will not load there with System Integrity Protection on, and turning SIP
off needs Recovery mode, a keyboard and a screen.

Snorkel needs none of that. It drives the chip from user space over libusb,
joins your network as an ordinary WPA2 client, and hands the traffic to macOS
through a virtual Ethernet interface. To macOS it is just one more network
port.

## What you get

- **802.11n station**: WPA2-PSK (CCMP), 20 MHz, MCS 0–15, Block Ack with
  receive reordering, on 2.4 and 5 GHz (tested on air on 5 GHz).
- **A launchd daemon** that starts at boot, re-joins when the AP goes away,
  gets a DHCP lease and routes internet traffic over the adapter.
- **Three modes**, switched with one command:
  - `auto`: built-in Wi-Fi on, internet over the adapter while it is healthy.
  - `adapter`: built-in Wi-Fi off; everything goes over the adapter.
  - `builtin`: back to the built-in Wi-Fi; the adapter stays joined but idle.
- **Failsafes**: if the adapter link or the internet is down for 30 s, the
  daemon turns the built-in Wi-Fi back on by itself, so a headless Mac never
  ends up unreachable. A power cycle always comes back on the built-in Wi-Fi.
- **Tailscale** works over the adapter; the Mac keeps its tailnet address
  when traffic moves between the adapter and the built-in Wi-Fi.

## Requirements

- An Archer T3U Plus (USB ID `2357:0138`). Other RTL8822BU / RTL8812BU
  adapters should work with `VID` / `PID` set in the config, but only this one
  has been tested on macOS.
- macOS 12 on Intel (tested on a Mac mini, Late 2014). SIP can stay on.
- Homebrew: `brew install libusb openssl@3 cmake ninja just`.
- The network's password saved in the System keychain — joining it once with
  the built-in Wi-Fi does that.

## Quick start

```sh
git clone <this repository> snorkel && cd snorkel
$EDITOR macos/snorkel.conf      # set SSID to your network's name
just test                       # build + headless tests, no adapter needed
just install                    # build, store the password root-only, start the daemon
just status                     # after ~20 s, feth0 should have an address
```

When `just status` shows the adapter with an address, `just wifi-off` moves
everything to it (it checks the router and the internet first). `just wifi-on`
goes back. `just` alone lists every command.

The full guide — every command, the configuration keys, how to read the logs,
troubleshooting and the on-air measurements — is in
**[macos/README.md](macos/README.md)**.

## How it works

```
AP ⇄ Archer T3U Plus ⇄ libusb ⇄ sta_client ⇄ feth5000 ⇄ feth0 ⇄ macOS IP stack
                                scan, join,    BPF read     DHCP, ARP, routes
                                WPA2, CCMP,    NDRV write
                                reorder
```

macOS has no TAP device, so `sta_client` creates a fake-Ethernet pair: macOS
owns `feth0`, and the client reads and writes the peer. The client does the
whole station job in user space — scan, authentication, association, the
WPA2 four-way handshake and CCMP encryption — on top of the devourer driver.
A shell daemon (`macos/snorkel-run.sh`) supervises it and manages routes, the
built-in Wi-Fi and DNS.

## Performance and limits

On a 5 GHz AP at about -70 dBm, the best run measured **18.9 Mbps down and
2.2 Mbps up**, with no drops. Upload is the weak side: the AP hears the
adapter about 5 dB worse than the adapter hears it, and the TX rate is fixed
with only the firmware's fallback. For comparison, the Mac's built-in Wi-Fi
measured 22.1 / 7.1 Mbps in one run from the same spot and stalled to near
zero in another. One location, one AP — your numbers will differ.

Not supported: 802.11ac (VHT) and 40/80 MHz channels, TX aggregation,
roaming, WPA3 and PMF (802.11w). Using a Tailscale exit node on the Mac is
untested and likely conflicts with Snorkel's routes.

## Layout

| Path | What |
|---|---|
| `macos/` | Snorkel: daemon, install scripts, config, guide |
| `justfile` | The commands (`just --list`) |
| `tests/sta_client.cpp` | The station client |
| `src/sta/` | The device-free 802.11 station core |
| `src/`, `hal/` | The devourer driver |

## Credits and license

Snorkel is a fork of [devourer](https://github.com/OpenIPC/devourer), the
OpenIPC project's userspace Realtek Wi-Fi driver. The driver and the station
core are devourer's work; Snorkel adds the macOS interface, the daemon and
the scripts. devourer's own README is kept as [DEVOURER.md](DEVOURER.md).

Licensed under the GNU General Public License v2.0, as devourer — see
[LICENSE](LICENSE).
