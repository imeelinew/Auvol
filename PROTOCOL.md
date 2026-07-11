# Auvol LAN Protocol — ALV2

ALV2 carries uncompressed stereo float32 PCM between a Mac and a Windows PC.
Either device may be the sender, but Auvol runs one direction at a time.

All integers are unsigned little-endian. Every packet starts with the four wire
bytes `41 4c 56 32` (`ALV2`). UDP port is 7777.

## Common header

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 0 | 4 | magic | `ALV2` |
| 4 | 2 | type | `0` config, `1` audio |
| 6 | 2 | header_bytes | 28 for config, 32 for audio |
| 8 | 4 | stream_id | New non-zero ID for every sender start |

`stream_id` distinguishes a restarted sender from a repeated config packet. A
receiver resets playback only when the stream or format actually changes.

## Config packet

Exactly 28 bytes. Sent before audio and repeated every 500 ms.

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 12 | 4 | sample_rate | Sender PCM rate, normally 48000 |
| 16 | 2 | channels | Always 2 |
| 18 | 2 | max_packet_frames | Currently 160 |
| 20 | 4 | source_period_frames | Sender capture callback/engine period |
| 24 | 4 | reserved | Zero |

## Audio packet

32-byte header followed by interleaved stereo float32 PCM.

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 12 | 4 | sequence | Increments once per UDP audio packet |
| 16 | 8 | first_frame | Sender source-frame position of the first payload frame |
| 24 | 2 | frame_count | 1–160 |
| 26 | 2 | channels | Always 2 |
| 28 | 2 | flags | Bit 0: source data discontinuity |
| 30 | 2 | reserved | Zero |
| 32 | N | payload | `frame_count * 2 * 4` bytes |

At 160 frames the datagram is 1312 bytes, below a 1500-byte Ethernet MTU after
IP/UDP headers. Packets therefore do not rely on IP fragmentation.

## Timing model

- Windows uses event-driven shared-mode WASAPI loopback when it sends. The Mac
  uses a Core Audio system-audio tap when it sends. Both packetize immediately,
  splitting only to stay below MTU.
- A receiver starts playback with a small configurable prime (12 ms by default).
- A preallocated single-producer/single-consumer ring bridges UDP and the
  platform real-time output callback.
- Sender and receiver clocks are independent. Each receiver keeps the ring near
  its target with slow, bounded rate correction. Normal PCM is never encoded or
  quantized.
- `first_frame` detects missing, duplicate and stale audio independently of UDP
  sequence wrap. Small losses are replaced with silence; a large discontinuity
  causes a clean re-prime instead of playing stale audio.
