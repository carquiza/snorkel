# STATUS

**Updated:** 2026-10-06 · **Phase:** Snorkel daemon in daily use on the Mac mini (adapter mode) · **Health:** link proven on air — 0 drops, down 18.9 / up 2.2 Mbps with 802.11n + Block Ack; upload is the weak side

## Now / Next

- `just install` once more: the daemon label is now `local.snorkel`, and
  install.sh removes the earlier label's daemon.
- The typed-password path of `store_psk` (network not in the Keychain) is
  untested on a terminal.
- Upload: rate control from TX reports instead of a fixed `TX_RATE`.
- DNS fallback (`ensure_dns`) still to be seen on air.
- Tailscale exit node on this Mac: untested; its 0/1 + 128/1 routes collide
  with Snorkel's.

## Recently done

- 2026-10-06 — `just install "<ssid>" [channel]` and `just ssid`: set or
  change the network without editing a tracked file; password from the
  Keychain or typed. NOTICE file (GPL-2.0 §2(a)).
- 2026-10-06 — Project README (`README.md`); devourer's README moved to
  `DEVOURER.md`.
- 2026-10-06 — Tailscale checked over the adapter: direct path, MagicDNS OK.
- 2026-10-06 — Renamed the macOS layer to Snorkel (scripts, launchd label
  `local.snorkel`, paths, logs); SSID out of the repo config.
- 2026-10-06 — Adapter mode on air: built-in Wi-Fi off, internet and DNS on
  the adapter.
- 2026-10-06 — Mode switching (`auto` / `adapter` / `builtin`), failsafes,
  `just status`, justfile.
- 2026-10-05 — 802.11n association, Block Ack + reorder; beacon-lost clock
  wrap fixed.

## Blockers

None.

## Pointers

- `macos/README.md` — setup, commands, modes, measurements, limits.
- `docs/station-client.md`, `src/sta/CLAUDE.md` — the station client and core.
- Upstream: https://github.com/OpenIPC/devourer (remote `upstream`).
