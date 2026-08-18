# KVMBar

A tiny macOS menu bar app that makes a Dell U2725QE (or any DDC-capable
monitor) behave like a proper KVM between two Macs.

```bash
git clone https://github.com/wishval/KVMBar.git
cd KVMBar && make install
```

## The problem

The U2725QE's built-in KVM moves the USB hub (keyboard/mouse) when you switch
inputs, but on the Mac side two things go wrong:

1. **Phantom display** — when the monitor switches to the other Mac's input,
   the Thunderbolt/HDMI link often does *not* drop, so macOS keeps treating the
   display as connected: windows and the cursor drift onto an invisible screen.
2. **Black screen on return** — when the monitor switches back, macOS
   sometimes doesn't re-issue the video stream.

KVMBar fixes both by soft-disconnecting/reconnecting the display at the
WindowServer level, and can drive the monitor's input switch itself over DDC.

## Features

- **DDC input switching** on Apple Silicon (native `IOAVService` I2C writes,
  ported from the MIT-licensed [m1ddc](https://github.com/waydabber/m1ddc) —
  no external binaries).
- **Soft disconnect / reconnect** of the external display via the private
  SkyLight API (`SLSMainConnectionID` + `SLSConfigureDisplayEnabled`), the same
  mechanism BetterDisplay and Lunar use. The last display ID is persisted so
  reconnect works while the display is offline.
- **Give away**: DDC-switch the monitor to the other input, wait ~1 s, then
  soft-disconnect the phantom display (DDC first — I2C dies after disconnect).
- **Auto mode driven by USB-KVM presence (the key mechanism)**: the monitor's
  KVM moves your wireless receiver / peripherals between computers together
  with the video, so the receiver's appearance in the USB tree is a perfect
  hardware "who owns the monitor" signal. KVMBar watches it via IOKit
  notifications (vendor/product ID configurable):
  - receiver disappears → the monitor left (button press or another computer
    pulled it): the phantom display is disconnected automatically, then
    **parked** — re-enabled as a *mirror* of the built-in screen, which is a
    harmless phantom (no window/cursor drift) that keeps a live signal on our
    input so the monitor can switch back instantly;
  - receiver appears → the monitor is back: the mirror unparks back to an
    extended desktop. Measured round-trip: ~2 s, fully automatic.

  Backup signals: display reconfiguration events (debounced) and IORegistry
  lifecycle of the external `DCPAVServiceProxy`. Optional extras (off by
  default, see Settings): DDC input probe, phantom watch, blind return probe.
- Menu bar icon reflects state (`display` / `display.slash` /
  `arrow.triangle.2.circlepath`), optional notifications on auto actions,
  launch at login via `SMAppService`, and a CLI mode for Raycast hotkeys.

## Build

Requires Xcode command line tools (Swift 5.9+), macOS 13+. No dependencies,
no sandbox, no notarization — it's a personal tool built from source:

```bash
make build      # -> dist/KVMBar.app (ad-hoc signed)
make install    # -> /Applications/KVMBar.app
make run
```

Build it **on each Mac** (copying the app between machines adds a quarantine
flag and the ad-hoc signature is machine-local anyway).

On the second Mac, open Settings from the menu and swap the inputs
(e.g. *my input = HDMI / 17*, *other = Thunderbolt / 27*).

## CLI (Raycast / scripts)

The same binary is the CLI. If the menu bar app is running, commands are
forwarded to it (via `DistributedNotificationCenter`) so the icon stays in
sync; otherwise they execute directly.

```bash
KVMBAR=/Applications/KVMBar.app/Contents/MacOS/KVMBar
"$KVMBAR" --status              # read-only diagnostics
"$KVMBAR" --give-away           # switch input + disconnect
"$KVMBAR" --reconnect           # fix a black screen / re-enable
"$KVMBAR" --disconnect          # soft-disconnect only
"$KVMBAR" --switch-input 17     # code, configured name, "mine" or "other"
```

Raycast script command example:

```bash
#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title Give monitor away
# @raycast.mode silent
/Applications/KVMBar.app/Contents/MacOS/KVMBar --give-away
```

## How it works

### Soft disconnect (SkyLight)

`/System/Library/PrivateFrameworks/SkyLight.framework` exports
`SLSMainConnectionID()` and `SLSConfigureDisplayEnabled(cid, displayID, enabled)`.
Disabling a display removes it from the desktop even though the physical link
stays up (kills the phantom); enabling it forces a fresh modeset, which also
cures the black-screen-on-return case. Both symbols are loaded with
`dlopen`/`dlsym` — if a macOS update removes them, KVMBar shows a warning in
the menu instead of crashing.

### DDC on Apple Silicon (IOAVService)

There is no documented DDC path on Apple Silicon. KVMBar finds the
`DCPAVServiceProxy` IORegistry entry with `Location = External`, wraps it in an
`IOAVService` (`IOAVServiceCreateWithService`, exported by the CoreDisplay
framework), and writes DDC/CI packets to I2C chip address `0x37` / data
address `0x51` — exactly what m1ddc does. Input select is VCP code `0x60`.

### Give-away and return on the U2725QE (measured behavior)

The U2725QE turned out to need **no DDC control at all** — and that's lucky,
because it ignores it: input select (VCP `0x60`) and the vendor KVM codes
(`E5/E7/E8/EA`) are ACKed, echoed back on reads, but switch nothing. The
read reply's high byte is a static per-port identity (always `0x19` on the
TB port), so it can't be used as a "current input" probe either. DDC works
over TB/USB-C for *reads* of ordinary VCPs and is entirely dead through the
MacBook's built-in HDMI port (its internal DP→HDMI converter drops DDC).

What actually works, and what KVMBar does:

1. **Give away** = soft-disconnect our display. Our signal dies, the
   monitor's *Auto Select* switches to the other computer's live input, and
   the KVM moves the USB peripherals along with it.
2. ~8 s later the display is **parked**: re-enabled as a mirror of the
   built-in screen. A mirror is a harmless phantom — windows can't drift
   there — but it keeps a live signal on our input, so switching back never
   bounces (Auto Select would flee from a dead input immediately).
3. **Return** is detected by the KVM USB device (wireless receiver)
   reappearing → unpark to extended desktop. Works for returns initiated by
   the monitor's joystick or by the other Mac's give-away alike.

Requires *Auto Select = On* in the monitor's OSD (factory default).

Two experimental toggles in Settings:

- **Auto-disconnect when monitor switches away** — while active, poll the
  input; if the monitor reports the other input twice in a row, the phantom is
  disconnected automatically (no hotkey needed at all).
- **Blind return probe** — if DDC becomes unreachable after disconnect (the
  AVService can die with the link), periodically enable the display for ~1 s,
  probe DDC, and disable again if the monitor is still away. Causes a brief
  phantom window, hence opt-in.

Whether DDC stays reachable after a soft disconnect is monitor/OS-specific —
check the logs on real hardware and pick the toggles accordingly.

## Settings

Everything lives in `UserDefaults` suite `dev.valerii.kvmbar.shared` (shared
between the app and CLI): input names/DDC codes, delays, and the KVM
detection block — **KVM device vendor/product ID** (find yours in System
Information → USB while the receiver is plugged into the monitor; defaults to
a Nordic 2.4G receiver, `0x25A7:0xFA11`), mirror-parking toggle and delay.
Legacy/experimental toggles (DDC probe, phantom watch, blind probe) are off
by default and only useful on monitors that honor DDC properly.

On the second Mac, swap the inputs in Settings (my = HDMI/17,
other = Thunderbolt/25 for a U2725QE) — the USB device IDs stay the same,
it's the same receiver moving between the two.

## Finding DDC input codes for other monitors

Common values (Dell): DisplayPort = 15, HDMI 1 = 17, HDMI 2 = 18,
USB-C/Thunderbolt = 27. To discover yours: put the monitor on a given input
and run `KVMBar --status` — it prints the current VCP `0x60` value. Or probe
with `--switch-input <n>` / [m1ddc](https://github.com/waydabber/m1ddc) /
`ddcutil capabilities` on Linux.

## Known risks & limitations

- **Private APIs.** `SLS*` and `IOAVService*` are undocumented and can change
  in any macOS update. KVMBar resolves them at runtime and degrades to a
  menu warning; symbol locations were verified on macOS 26.5.
- **Ad-hoc signing.** After every rebuild the code signature changes; if
  Launch at Login stops working after an update, toggle it off/on once.
- **Clamshell.** KVMBar refuses to disable the display if it's the only active
  one (you'd end up with a headless Mac). Keep the lid open when giving away.
- **Multiple externals.** The first non-builtin display is used; a warning is
  logged.
- Notifications and Launch at Login only work when running from the `.app`
  bundle (not the bare `swift build` binary). macOS may refuse notification
  authorization for ad-hoc-signed apps ("Notifications are not allowed for
  this application" in the log) — if you want them, install to `/Applications`
  and enable KVMBar under System Settings → Notifications; otherwise ignore,
  everything else works without them.

## Debugging

```bash
log stream --predicate 'subsystem == "dev.valerii.kvmbar"' --level debug
```

Categories: `app`, `menu`, `display`, `watcher`, `ddc`, `skylight`, `cli`,
`notify`, `login`.

## License & author

MIT — see [LICENSE](LICENSE).

Made by Valerii Bakalenko —
[valeriy.bakalenko@gmail.com](mailto:valeriy.bakalenko@gmail.com) ·
[linkedin.com/in/valerii-bakalenko](https://www.linkedin.com/in/valerii-bakalenko/) ·
[github.com/wishval](https://github.com/wishval)
