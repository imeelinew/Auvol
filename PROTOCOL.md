# Auvol LAN Protocol — ALV2

ALV2 carries uncompressed stereo float32 PCM from Windows WASAPI loopback to the
Mac. It is intentionally small, fixed-endian and incompatible with ALV1.

All integers are unsigned little-endian. Every packet starts with the four wire
bytes `41 4c 56 32` (`ALV2`). UDP port is 7777.

## Common header

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 0 | 4 | magic | `ALV2` |
| 4 | 2 | type | `0` config, `1` audio |
| 6 | 2 | header_bytes | 28 for config, 32 for audio |
| 8 | 4 | stream_id | New non-zero ID for every Windows connection |

`stream_id` distinguishes a restarted sender from a repeated config packet. A
receiver resets playback only when the stream or format actually changes.

## Config packet

Exactly 28 bytes. Sent before audio and repeated every 500 ms.

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 12 | 4 | sample_rate | WASAPI mix rate, normally 48000 |
| 16 | 2 | channels | Always 2 |
| 18 | 2 | max_packet_frames | Currently 160 |
| 20 | 4 | capture_period_frames | WASAPI shared-engine buffer/period |
| 24 | 4 | reserved | Zero |

## Audio packet

32-byte header followed by interleaved stereo float32 PCM.

| Offset | Size | Field | Description |
|---:|---:|---|---|
| 12 | 4 | sequence | Increments once per UDP audio packet |
| 16 | 8 | first_frame | WASAPI device-frame position of the first payload frame |
| 24 | 2 | frame_count | 1–160 |
| 26 | 2 | channels | Always 2 |
| 28 | 2 | flags | Bit 0: WASAPI data discontinuity |
| 30 | 2 | reserved | Zero |
| 32 | N | payload | `frame_count * 2 * 4` bytes |

At 160 frames the datagram is 1312 bytes, below a 1500-byte Ethernet MTU after
IP/UDP headers. Packets therefore do not rely on IP fragmentation.

## Timing model

- Windows uses event-driven shared-mode WASAPI loopback and sends each captured
  buffer immediately, split only to stay below MTU.
- The Mac warms the output graph, discards the one-time WASAPI startup backlog,
  then begins playback with a small configurable prime (12 ms by default).
- A preallocated single-producer/single-consumer ring bridges the UDP and Core
  Audio real-time threads.
- Windows capture and Mac output clocks are independent. The receiver keeps the
  ring near its target with a slow PLL and a tightly bounded Apple varispeed
  unit. Normal PCM is never encoded, quantized, or continuously rewritten.
- `first_frame` detects missing, duplicate and stale audio independently of UDP
  sequence wrap. Small losses are replaced with silence; a large discontinuity
  causes a clean re-prime instead of playing stale audio.
