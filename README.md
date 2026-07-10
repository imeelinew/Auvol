# Auvol

Windows system audio → gigabit LAN → Mac default output, with low latency and
uncompressed PCM quality.

Auvol is a two-clock real-time audio transport. Windows captures its default
render endpoint with WASAPI loopback; the Mac receives raw float32 stereo PCM,
mixes it with local audio and plays it through the current macOS output device.

## Architecture

- **Windows sender** (`windows/`): event-driven shared-mode WASAPI loopback,
  MMCSS `Pro Audio` scheduling, MTU-safe UDP packets.
- **Protocol** (`PROTOCOL.md`): ALV2, raw stereo float32 PCM with stream identity,
  packet sequence and WASAPI device-frame positions.
- **Mac receiver** (`mac/`): high-priority UDP receive queue, preallocated C11
  atomic SPSC ring, allocation-free Core Audio render callback.
- **Clock control**: a slow PLL keeps the jitter ring near its target through a
  tightly bounded `AVAudioUnitVarispeed`; this absorbs hardware-clock drift
  without the old hard buffer drops or coarse resampling steps.

There is no codec in the path. The only sample-rate operation during a stable
48 kHz stream is the tiny clock correction required because two physical audio
devices never run at exactly the same rate.

## Windows audio device

Use **VB-Cable** as the Windows default output. The default endpoint must expose
stereo float32 PCM.

1. Install VB-Cable and restart Windows.
2. Set Windows output to **CABLE Input (VB-Audio Virtual Cable)**.
3. Start `Auvol.exe`, enter the Mac's current LAN IP and select **Connect**.

For unattended launch, `Auvol.exe --connect 192.168.x.x` starts streaming
immediately.

## Build and deploy

`deploy.sh` regenerates the Xcode project, builds both apps, copies the Windows
binary to the desktop and restarts the Mac receiver.

```sh
# Same LAN: preferred
WIN_HOST=eli-lan ./deploy.sh

# Remote through Surge Tailscale
./deploy.sh
```

After deployment, restart the Windows sender or select Disconnect → Connect.
ALV1 and ALV2 are intentionally incompatible.

## Status and tuning

The Mac menu shows the timing of every important queue:

- **Queued**: current Mac jitter-buffer depth.
- **Windows period**: WASAPI capture event period.
- **Mac quantum**: frames requested by the output render callback.
- **Clock correction**: learned Windows/Mac clock difference in ppm.
- **Lost / late**, **Starved**, **Overflow**: these should stay at zero on wired
  Ethernet.

The default jitter target is **12 ms**. Start there. If `Starved` remains zero,
lower it one millisecond at a time; if it rises, increase the target slightly.
Changing the target is gradual—the PLL moves the queue without inserting a
block of held samples or deleting a block of live audio.

On connect, the Mac intentionally warms the output graph for 200 ms before it
opens the audio gate. This one-time startup delay discards WASAPI's initial
backlog and does not affect steady-state latency.

## Latency boundary

Auvol controls capture, network, jitter and output-buffer latency. Bluetooth
headphones add their own codec/radio delay after macOS; that delay is external
to the LAN transport and is also present for other Mac applications using the
same headphones.
