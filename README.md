# Auvol

Mac or Windows system audio → gigabit LAN → the other device's default output,
with low latency and uncompressed PCM quality.

Auvol is a half-duplex, two-clock real-time audio transport. Select exactly one
direction at a time: Windows → Mac or Mac → Windows.

## Architecture

- **Windows send**: event-driven shared-mode WASAPI loopback with MMCSS
  `Pro Audio` scheduling.
- **Mac send**: Core Audio system-audio tap, feeding raw PCM directly to UDP.
- **Windows receive**: high-priority UDP receiver, atomic jitter ring and
  event-driven WASAPI render output.
- **Windows UI**: native C++/WinRT with WinUI 3 and Windows App SDK 2.2;
  transport code remains in the same native process.
- **Mac receive**: high-priority UDP receive queue, preallocated C11 atomic
  SPSC ring and allocation-free Core Audio render callback.
- **Protocol** (`PROTOCOL.md`): ALV2 raw stereo float32 PCM with stream identity,
  packet sequence and sender frame positions.

There is no codec in the path. The only sample-rate operation during a stable
48 kHz stream is the tiny clock correction required because two physical audio
devices never run at exactly the same rate.

## Select a direction

On Windows, choose one of these roles then press **Start** once. While Auvol is
running, changing the direction switches roles immediately; there is no need to
press Stop first.

- **Send Windows audio to Mac**: captures the current Windows default output.
- **Receive Mac audio on Windows**: plays to the current Windows default output;
  choose the Bluetooth headset in Windows sound settings first.

On Mac, select **Receive from Windows** or **Send to Windows** in the menu bar.
Mac send requires the one-time system-audio capture permission.

For unattended Windows launch, use `Auvol.exe --send <mac-ip>` or
`Auvol.exe --receive <mac-ip>`.

Windows remembers the peer IP, selected direction and whether transport was
running. After the app has been launched once, it starts automatically at the
next Windows sign-in and resumes an active transport session. Pressing Stop or
closing the window records a paused state, so the next sign-in opens Auvol idle.

## Build and deploy

`deploy.sh` regenerates the Xcode project, builds both apps, installs the WinUI
app under `%LOCALAPPDATA%\Auvol`, and restarts both sides. The Windows source
workspace is synchronized to `C:\dev\Auvol\windows` and built with Visual
Studio's x64 C++ toolchain.

```sh
# Same LAN: preferred
WIN_HOST=eli-lan ./deploy.sh

# Remote through Surge Tailscale
./deploy.sh
```

After deployment, the new Windows app launches automatically. During normal use, default
audio-device changes, Bluetooth disconnects, transient WASAPI/Core Audio
failures, and direction changes are recovered automatically. Start/Stop is a
global pause control, not a recovery procedure.
ALV1 and ALV2 are intentionally incompatible.

## Status and tuning

The Mac menu shows the timing of every important queue:

- **Queued**: current Mac jitter-buffer depth.
- **Source period**: source capture callback/engine period.
- **Output quantum**: frames requested by the local output callback.
- **Clock correction**: learned Windows/Mac clock difference in ppm.
- **Lost / late**, **Starved**, **Overflow**: these should stay at zero on wired
  Ethernet.
- **Signal**: the actual PCM peak in dBFS. `Silence` means transport packets are
  arriving but the sender is currently producing zero-valued audio.
- **Playing on / Capturing from**: the audio endpoint currently bound to the
  live graph. It changes after automatic device recovery.

The default jitter target is **12 ms**. Start there. If `Starved` remains zero,
lower it one millisecond at a time; if it rises, increase the target slightly.
Changing the target is gradual—the PLL moves the queue without inserting a
block of held samples or deleting a block of live audio.

On Windows → Mac connect, the Mac intentionally warms the output graph for
200 ms before it opens the audio gate. This one-time startup delay discards the
source startup backlog and does not affect steady-state latency.

## Latency boundary

Auvol controls capture, network, jitter and output-buffer latency. Bluetooth
headphones add their own codec/radio delay after the Windows output engine; that
delay is external to the LAN transport and is also present for other Windows
applications using the same headphones.
