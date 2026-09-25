# Millstone Solutions HX Bridge

A macOS app for Apple Silicon that takes **High Bandwidth NDI®** from an app on the same Mac
(built for ProPresenter) and re-sends it as **NDI HX2 / HX3** using the Mac's hardware H.264/HEVC encoder.

The full-bandwidth stream never leaves the Mac. Only the compressed HX stream goes out on the network,
which typically cuts a 1080p feed from 100+ Mbps to roughly 3–15 Mbps.

> **Status: early testing.** Tested with ProPresenter → NDI Video Monitor (same Mac) and
> NDI Studio Monitor 6.0 (Windows PC on the LAN). Please report what works and what doesn't (see [Testing checklist](#testing-checklist)).

---

## Contents
- [Why](#why)
- [Features](#features)
- [Requirements](#requirements)
- [Install and build](#install-and-build)
- [Quick start](#quick-start)
- [Using the app](#using-the-app)
- [Keeping the full-bandwidth feed off the network](#keeping-the-full-bandwidth-feed-off-the-network)
- [Audio](#audio)
- [Receivers and compatibility](#receivers-and-compatibility)
- [Bandwidth](#bandwidth)
- [Troubleshooting](#troubleshooting)
- [NDI licensing and the trial SDK](#ndi-licensing-and-the-trial-sdk)
- [How it works](#how-it-works)
- [Files and settings](#files-and-settings)
- [Development](#development)
- [Testing checklist](#testing-checklist)
- [Known limitations and ideas](#known-limitations-and-ideas)
- [Credits and legal](#credits-and-legal)

---

## Why
ProPresenter (and many other Mac apps) only send **High Bandwidth** NDI, and NDI's own "NDI Bridge"
converter is Windows-only. When ProPresenter renders to virtual displays there's no HDMI/SDI output to feed a
hardware HX encoder either. HX Bridge does the conversion on the same Mac, in software, using the
Apple Silicon media engine.

## Features
- **Multiple bridges**, one per NDI source, each with its own output name and NDI groups
- **H.264 or HEVC**, **HX2 / HX3 / Custom** bit-rate presets, adjustable keyframe interval
- **Hardware encoding** (VideoToolbox, low-latency rate control, no B-frames); GPU colour conversion and scaling
- **640-wide preview stream** for multiviewers (NDI's "lowest bandwidth" stream)
- **Steady output from static sources**: ProPresenter and NDI Test Patterns only send a frame when the picture
  changes; the bridge repeats the last frame so receivers always have a live stream
- **Audio**: multichannel **Opus** (every channel kept separate), **AAC** stereo, or **uncompressed**
- **Keyframes on demand**: when a receiver connects or loses data, NDI asks for a keyframe and the bridge sends one
- **Tally forwarding** from HX receivers back to the source
- **Pause encoding** while nobody is watching
- **Auto-start and auto-retry**, open at login, menu bar status, log window (including NDI library messages)
- **Group helper** to hide this Mac's own full-bandwidth NDI senders from the rest of the network
- **Trial awareness**: running timer, trial notice, and a warning if the NDI library reports a licensing problem

## Requirements
| | |
|---|---|
| Mac | Apple Silicon (M1 or newer) |
| macOS | 13 Ventura or newer |
| Build tools | Xcode **Command Line Tools** (`xcode-select --install`). Full Xcode is not needed. |
| NDI SDK | **NDI Advanced SDK for Apple**, installed at `/Library/NDI Advanced SDK for Apple` (not included, see below) |
| Receivers | Anything that decodes NDI HX: NDI 5+ for Opus audio, NDI 4+ for AAC audio |

### Why the NDI SDK isn't in this repo
Sending HX (compressed) video requires NDI's **Advanced** SDK, and its license does not allow the SDK to be
redistributed. Each developer or tester gets their own copy from NDI:

1. Request the Advanced SDK trial: https://ndi.video/for-developers/ndi-advanced/
2. Run NDI's installer. It installs to `/Library/NDI Advanced SDK for Apple`, which is where this project looks for it.
3. For anything beyond testing, NDI requires a **License ID** (formerly "Vendor ID"). Enter it in the app's Settings.

## Install and build
```bash
git clone https://github.com/millstonesolutions/Millstone-HX-Bridge.git
cd Millstone-HX-Bridge
./build.sh --install --run
```

`build.sh` options (combine as needed):

| Option | What it does |
|---|---|
| *(none)* | Builds `build/Millstone Solutions HX Bridge.app` |
| `--install` | Copies the app to `/Applications` (replaces any older copy) |
| `--run` | Quits a running copy and launches the app |
| `--clean` | Deletes build caches first (use after moving the folder or updating the SDK) |
| `--selftest` | Runs the Opus channel-mapping round-trip test (see [Audio](#audio)) |

The build is ad-hoc signed, which is fine for your own Mac. It is **not** notarized; if you send the built app to
someone else, macOS will block it until they allow it in System Settings → Privacy & Security.
Sharing the source and building locally avoids that.

**First launch:** macOS asks whether *HX Bridge* may find devices on your local network. Click **Allow**,
or source discovery won't work. You can change this later in System Settings → Privacy & Security → Local Network.

## Quick start
1. In ProPresenter, turn on an **NDI output** (Screens configuration).
2. Open **Millstone Solutions HX Bridge**. A bridge named **HX Bridge** is created for you.
3. Pick ProPresenter's output under **Source**, leave **HX3** and **H.264**, and click **Start**.
4. On any computer on the network, open an NDI receiver (e.g. NDI Studio Monitor) and choose
   **`YOUR-MAC (HX Bridge)`**.

That's it. The status panel shows the input format, the encoder, the output bit-rate and how many receivers are connected.

## Using the app

The main window lists your bridges on the left. Select one to see its status and settings on the right.
**Add Bridge** creates another; **Start All / Stop All** control every bridge.

Changes to a running bridge take effect when you click **Apply Changes** (the bridge restarts in about a second).

### Bridge settings

**Input (High Bandwidth NDI)**
- **Source**: the NDI source to convert. The list shows sources in the groups set under Settings → Input group(s).
  The bridge's own outputs are hidden to prevent loops.

**Output (NDI HX)**
- **Output name**: the NDI source name receivers see, shown as `YOUR-MAC (Output name)`.
- **Output group(s)**: NDI groups to publish in (comma-separated). Default `public`.
- **Codec**: **H.264** (widest compatibility) or **H.265 / HEVC** (smaller at the same quality; receiver must support HEVC HX).
- **Preset**:
  - **HX2**: 1.0× the bit-rate NDI's SDK recommends for the input format, keyframe every 2 s.
  - **HX3**: 2.0× the recommended rate, keyframe every 1 s. Better for text and motion.
  - **Custom**: set the bit-rate yourself (2–100 Mbps).

  For reference, the SDK recommends 10.6 Mbps for 1080p30 and 16 Mbps for 1080p60, so HX3 caps those at 21.2 and
  32 Mbps. These are caps: static slides use far less. NDI doesn't publish exact HX2/HX3 encoder settings,
  so these presets are this project's interpretation.
- **Keyframe interval**: 0.5–4 s. Changing the preset resets it to that preset's default.
- **Send 640-wide preview stream**: a second, small stream for multiviewers and thumbnails (about 0.5–1 Mbps).
- **Pause encoding when nobody is receiving**: saves power; encoding resumes, starting with a keyframe, the moment someone connects.

**Audio**: see [Audio](#audio).

**Compatibility**
- **Low-latency encoder mode**: Apple's low-latency rate control (recommended). Turn off only to test a
  receiver that misbehaves.
- **Repeat SPS/PPS inside every keyframe**: also places the codec setup data inside each keyframe, not only in NDI's
  separate field. On by default; harmless, and some decoders expect it.

**Options**
- **Forward tally**: when a receiver puts the HX output on program/preview, pass that tally back to the source.
- **Start this bridge when the app launches**
- **Delete Bridge…**

### Status panel
| Field | Meaning |
|---|---|
| Running for | Time since the bridge (re)started |
| Input | Source resolution and frame rate, plus the rate frames are actually arriving. Static sources may show ~0 fps; that's normal, the last frame is repeated. |
| Encoder | Codec, hardware/software, rate control, bit-rate cap, keyframe interval, preview size |
| Output | Current bit-rate of the main stream (+ preview) |
| Receivers | Number of NDI connections to this output (one receiver can open more than one) |
| Frames / keyframes | Encoded frame and keyframe counts |
| Dropped input frames | Frames the NDI receiver dropped before the bridge got them |
| Audio | Audio codec, channels, bit-rate |
| Tally | Program / Preview state from receivers |

Status colours: **green** running, **mint** running with no receivers, **orange** waiting for the source or its video,
**red** error (the bridge retries automatically every 5 s), **grey** stopped.

### Settings window
Open with the gear icon, **⌘,**, or the app menu → Settings.

- **Source discovery → Input group(s)**: which NDI groups to search for sources, e.g. `public`,
  `propres-local`, or `public,propres-local`. Click **Apply & Rescan** after changing.
- **Keep ProPresenter's High Bandwidth feed off the network**: see the [next section](#keeping-the-full-bandwidth-feed-off-the-network).
- **NDI Advanced SDK license**: company name and **License ID**. Restart bridges after changing.
- **Startup**: start bridges when the app launches; open at login (works best when the app is in /Applications).
- **About**: NDI runtime version, buttons to reveal the settings and log files.

### Menu bar and log
- The **menu bar icon** shows whether any bridge is running and lists each bridge's state. It also has Start All,
  Stop All, open the main window, show the log, and Quit. Closing the main window keeps the bridges running.
- The **log window** (toolbar **Log**, or ⇧⌘L) shows app events and anything the NDI library prints (tagged `SDK`),
  with filter, copy, clear and reveal-file buttons.

## Keeping the full-bandwidth feed off the network
ProPresenter's NDI output is still visible to every computer on the network. Nothing is sent unless something
connects to it, but someone could select it by mistake and pull 100+ Mbps. NDI **groups** prevent that:

1. In HX Bridge, open **Settings → Keep ProPresenter's High Bandwidth feed off the network**,
   enter a group name (default `propres-local`) and click **Apply**.
   This writes `~/.ndi/ndi-config.v1.json` (a backup is kept) and sets the **default send group for every NDI
   sender on this Mac** that doesn't choose its own group (ProPresenter, NDI Scan Converter, Test Patterns…).
   HX Bridge's outputs are unaffected because they set their own groups. NDI Access Manager edits the same file.
2. **Restart ProPresenter** so it picks up the new group.
3. In **Settings → Input group(s)**, add the same group (e.g. `propres-local`) and click **Apply & Rescan**.
4. Re-select the source in each bridge if needed.

To undo: **Reset to public**, then restart ProPresenter.

## Audio
| Mode | Channels | Bandwidth | Receivers |
|---|---|---|---|
| **Opus, all channels** (default) | All, up to 16, kept separate | 48–160 kbps per channel (8 ch at 96 kbps ≈ 0.8 Mbps) | NDI 5+ |
| **AAC stereo** | Channels 1–2 only | 128–320 kbps | NDI 4+ |
| **Uncompressed** | All | Several Mbps for 8 channels | Any |
| **No audio** | – | – | – |

ProPresenter sends 8 audio channels over NDI. Opus mode keeps all of them as separate channels.
Opus requires 48 kHz audio (ProPresenter's default).

**How the Opus layout was verified:** NDI doesn't document how it expects multichannel Opus to be laid out, so
`./build.sh --selftest` sends a different test tone on every channel through NDI, receives it back with the NDI
library's own decoder on the same Mac, and reports which tone came out of which channel. The layout NDI accepts
(original channel order, coded as stereo pairs 1–2, 3–4, … plus a mono stream for an odd last channel) passes for
1, 2, 3, 6, 8 and 16 channels, with at least 61 dB of separation between channels at 8 channels.

## Receivers and compatibility
| Receiver | Result |
|---|---|
| NDI Video Monitor (macOS, same Mac) | ✅ H.264 HX2/HX3 video, 30 and 60 fps |
| NDI Studio Monitor 6.0 (Windows, LAN) | ✅ H.264 HX2/HX3 video, 1080p60 |
| Others (OBS + DistroAV, vMix, TriCaster, hardware decoders…) | Not tested yet. Please report. |

## Bandwidth
Measured on the test system (H.264, HX3):

| Content | Output |
|---|---|
| 1080p30 ProPresenter slides (static) | ≈ 3.3 Mbps + 0.8 Mbps preview |
| 1080p60 ProPresenter with moving background video | ≈ 10–15 Mbps + ≈ 1 Mbps preview |

Plus audio (≈ 0.8 Mbps for 8-channel Opus). The same content as High Bandwidth NDI is typically well over 100 Mbps.

## Troubleshooting
**No sources in the Source list**
- Check ProPresenter's NDI output is on.
- Check macOS allowed Local Network access for HX Bridge (System Settings → Privacy & Security → Local Network).
- If you moved ProPresenter to a private group, that group must be in Settings → Input group(s).

**Receiver sees "HX Bridge" but shows black**
- Confirm the receiver supports NDI HX (and HEVC, if you chose it).
- Make sure the source is sending: the status should be green/mint, not orange.
- Reconnect the receiver (choose another source, then HX Bridge again).
- Try toggling the two **Compatibility** switches, then Apply Changes.
- Check the log for `SDK` lines: NDI prints stream-validation errors there.

**Picture isn't changing on the receiver**
- If the source is a static slide, that's expected. Trigger a slide change or a motion background to confirm.

**Audio missing or only 2 channels**
- Opus needs an NDI 5+ receiver and 48 kHz audio. AAC carries channels 1–2 only.

**Red "NDI reported a licensing problem" box**
- See the next section. The message shown is exactly what the NDI library printed.

**After moving the project folder or updating the SDK, the build fails**
- Run `./build.sh --clean`.

## NDI licensing and the trial SDK
- HX output needs the **NDI Advanced SDK**. The free NDI SDK can only send High Bandwidth, so there is no free HX setting.
- The only trial limit NDI documents is that **HDR** streams stop after 30 minutes. HX Bridge sends SDR.
  No time limit for HX or High Bandwidth sending is documented.
- If the NDI library ever prints a message about licensing, trials or expiry, the bridge shows a red warning with the
  message and how long it had been running.
- Using the Advanced SDK beyond evaluation requires a License ID from NDI (licensing@ndi.video).
- Distributing a **built** app with the NDI library inside requires NDI's permission and a license agreement that
  passes on NDI's terms. This repository shares **source only**, and each tester installs the SDK themselves.

## How it works
```
NDI receive (UYVY / BGRA, High Bandwidth)
  → IOSurface-backed CVPixelBuffer
  → VTPixelTransferSession → NV12 (GPU)            ─→ 640-wide preview (GPU scale) → encoder
  → VTCompressionSession (hardware, low-latency RC, no B-frames)
  → length-prefixed NALs rewritten to Annex B, SPS/PPS(/VPS) added on keyframes
  → NDIlib_compressed_packet_t → NDIlib_send_send_video_v2 (H264/HEVC highest-bandwidth FourCC)
Audio: NDI float planar → Opus (libopus multistream) / AAC (AudioToolbox) / pass-through
```
- Keyframes are forced whenever `NDIlib_send_is_keyframe_required` says a receiver needs one.
- When the source stops sending (static picture), the last frame is re-encoded at the source frame rate.
- Bit-rate caps use `NDIlib_send_get_target_bit_rate`; burst size is limited to smooth out big keyframes.

## Files and settings
| What | Where |
|---|---|
| App | `/Applications/Millstone Solutions HX Bridge.app` |
| Settings | `~/Library/Application Support/MillstoneHXBridge/config.json` |
| Log | `~/Library/Logs/MillstoneHXBridge.log` (reset when it passes 5 MB) |
| NDI machine config (groups) | `~/.ndi/ndi-config.v1.json` |

`config.json` is plain JSON and can be copied between Macs. Fields per bridge: `sourceName`, `outputName`,
`outputGroups`, `codec` (`h264`/`hevc`), `preset` (`hx2`/`hx3`/`custom`), `customBitrateMbps`,
`keyframeIntervalSec`, `sendPreviewStream`, `skipEncodeWithoutReceivers`, `audioMode` (`opus`/`aac`/`pcm`/`off`),
`aacBitrateKbps`, `opusKbpsPerChannel`, `forwardTally`, `autoStart`, `lowLatencyEncoder`, `inlineParameterSets`.
Global: `inputGroups`, `vendorName`, `vendorID` (License ID), `startBridgesOnLaunch`.
Quit the app before editing it by hand.

## Development
```
Package.swift                 Swift package (targets: HXBridge app, CNDI, COpus)
Sources/HXBridge/             the app
  App.swift                   app, windows, menu bar
  AppController.swift         bridges, settings, NDI config-file helper
  BridgeEngine.swift          receive → encode → send pipeline (one thread per bridge)
  HXVideoEncoder.swift        VideoToolbox encoder, Annex B packaging, GPU scaler
  OpusEncoder.swift           multichannel Opus in NDI's layout
  AACEncoder.swift            AAC-LC via AVAudioConverter
  SourceFinder.swift          NDI discovery
  Config.swift                settings model and persistence
  Log.swift, LogView.swift    log (captures NDI library stdout)
  ContentView.swift, BridgeDetailView.swift, SettingsView.swift   UI
  OpusSelfTest.swift          --opus-selftest round trip
Sources/CNDI/                 module map → /Library/NDI Advanced SDK for Apple/include
Sources/COpus/                libopus 1.5.2 source (BSD), compiled in
Resources/Info.plist
build.sh                      build / install / run / selftest
tools/dev-git.sh              git helper used by the build watcher (./build.sh --git fetch|merge|commit|push|status)
Dev Build Watcher.command     optional: rebuilds when build/.request changes (for remote or AI-assisted work)
```
Notes:
- Builds with the Command Line Tools only; there's no Xcode project. Because the CLT's SwiftUI lacks the macro plugin
  behind `@State`, views use a small `Box` observable instead.
- Swift 5 language mode; the NDI C API is used directly from Swift.
- Please keep NDI SDK files out of commits (`.gitignore` blocks the usual ones).

## Testing checklist
When you try it, please note your Mac model, macOS version, NDI SDK version and receiver, and check:
- [ ] Builds with `./build.sh --install --run`
- [ ] Sources appear; bridge starts; status turns green when a receiver connects
- [ ] Video on a receiver on **another computer** (H.264 HX3, then HX2, then HEVC)
- [ ] Static slide and moving video both look right; switching slides is immediate
- [ ] Audio: Opus with all channels in the right order; AAC; uncompressed
- [ ] Runs for 2+ hours without a licensing warning or dropouts (note the time if anything happens)
- [ ] Private-group setup hides the full-bandwidth feed from other computers
- [ ] `./build.sh --selftest` reports ALL CORRECT

## Known limitations and ideas
- Apple Silicon only; not notarized; built app not yet distributable (see licensing).
- No HDR / 10-bit output yet (and HDR would hit the 30-minute trial limit).
- Opus over 16 channels is untested; AAC is stereo only.
- Ideas: HX → High Bandwidth direction, HEVC with alpha, per-bridge input groups, a web control page, notarized builds.

## Credits and legal
© 2026 Millstone Solutions LLC. No open-source license has been chosen yet; until one is added, all rights are reserved
and the code is shared with invited testers only.

NDI® is a registered trademark of Vizrt NDI AB. This project is not affiliated with, sponsored by or endorsed by
Vizrt NDI AB. ProPresenter is a trademark of Renewed Vision. Opus is © Xiph.Org Foundation and contributors (BSD).
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
