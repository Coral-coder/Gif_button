# DZBJ "e-Goods" badge — Bluetooth protocol

Reverse-engineered from the stock Android app (`e-Goods.apk`, package built with
uni-app). The app's logic lives in JavaScript inside the APK
(`assets/apps/__UNI__1F52250/www/app-service.js`), so this is transcribed from
readable source, not guessed from packet captures. Every offset below was taken
from that file (`store/bluetooth.js`, `utils/gifAgreement.js`,
`utils/imageAgreement.js`).

> Status: extracted statically and implemented in `Sources/Bluetooth/`. Not yet
> confirmed against physical hardware. Anything marked **(verify)** is a
> best-effort reading that should be checked on a real badge.

## GATT

| Role | UUID |
|------|------|
| Service | `000001C0-0000-1000-8000-00805F9B34FB` |
| Write characteristic | `000001C1-0000-1000-8000-00805F9B34FB` |
| Notify characteristic | `000001C2-0000-1000-8000-00805F9B34FB` |

- The badge advertises with a name beginning **`DZBJ-`**.
- The stock app also discovers the write/notify characteristics dynamically:
  first characteristic with the `write` property → write; first with `notify` →
  notify. We do both (known UUID first, property fallback).

## Connection sequence

1. `openBluetoothAdapter` / power on.
2. Scan; match name prefix `DZBJ-`.
3. Connect.
4. **Android only:** wait ~3 s, then request MTU 512, wait ~1 s. On iOS the MTU
   is negotiated automatically, so `BluetoothManager` skips this.
5. Discover characteristics; enable notifications on `01C2`.
6. Handshake: the badge pushes a status frame (see below); reply to its `ADD`
   challenge with a type-14 verification.

## Frame format

Every message is `8-byte header + payload + 1 checksum byte`:

| Offset | Size | Meaning |
|-------:|-----:|---------|
| 0 | 1 | HEAD: `0xC0` app→device, `0xA0` device→app |
| 1 | 1 | command type (see table) |
| 2 | 2 | total fragments, **big-endian** |
| 4 | 2 | current fragment index, **big-endian**, counts **down** to 0 |
| 6 | 2 | payload length, **big-endian** |
| 8 | N | payload |
| 8+N | 1 | checksum = `(256 - (sum of all preceding bytes & 0xFF)) & 0xFF` |

Two payload kinds:

- **JSON command** — payload is the UTF-8 of a JSON object (`{"type":…}`). Used
  for queries/settings. `total`/`index` are 0.
- **Binary** — payload is raw bytes. Used for image/animation data.

### Fragmentation

Binary payloads larger than **496 bytes** are split into 496-byte fragments.
For `n` fragments, fragment `a` (0-based) carries `total = n` and
`index = n − a − 1`, so the final fragment has `index = 0`.

## Command types

| Name | id | Payload |
|------|---:|---------|
| ActivationQuery | 1 | `{"type":1}` |
| OTA package | 2 | binary |
| Boot animation | 3 | binary |
| Dial style | 4 | info: `{"type":4,"filename":…}`; data: binary |
| DynamicAtmosphere | 5 | binary — **animated GIFs are sent here** |
| Album | 6 | binary — **still images** |
| VersionQuery | 7 | `{"type":7}` |
| UpdateTime | 8 | `{"type":8,"year":…,"mon":…,"day":…,"hour":…,"min":…,"sec":…}` |
| LyricsBackground | 9 | binary |
| MarqueeImage | 12 | info + binary data |
| DeviceInfoSetting | 13 | `{"type":13,"bglight":…,"breather":…,"devname":…}` |
| DeviceIdVerification | 14 | `{"type":14,"Ret":<ADD echoed back>}` |

## Still image (Album, type 6)

1. Resize the picture to the display size (368×368) and JPEG-encode it.
2. Wrap in a **36-byte `IMB\0` container** (little-endian fields):

   | Offset | Size | Value |
   |-------:|-----:|-------|
   | 0 | 4 | `"IMB\0"` = `49 4D 42 00` |
   | 4 | 4 | 0 |
   | 8 | 4 | jpegLen + 32 |
   | 12 | 1 | format flag: `11` = JPEG, `0` = raw |
   | 13 | 1 | `100` (quality marker) |
   | 14 | 2 | 0 |
   | 16 | 2 | width |
   | 18 | 2 | height |
   | 20 | 4 | 32 (data offset) |
   | 24 | 4 | jpegLen |
   | 28 | 4 | 0 |
   | 32 | 4 | 0 |
   | 36 | N | JPEG bytes |

3. Wrap that in the ASCII envelope `{"type":6,"data":` + `<IMB bytes>` + `}`.
4. Fragment (496) and send under command **6**.

## Animation / GIF (DynamicAtmosphere, type 5)

GIFs are **not** sent as `.gif` bytes. Each frame becomes a JPEG, and all frames
are packed into one container (`packImagesToArrayBuffer`), little-endian:

Global header (32 bytes):

| Offset | Size | Value |
|-------:|-----:|-------|
| 0 | 4 | magic `0x12345678` |
| 4 | 4 | `16*n + 24` |
| 8 | 4 | frame count `n` |
| 12 | 4 | frame delay (ms) |
| 16 | 12 | name (zero-padded) |
| 28 | 4 | total container length − 1 |

Index table — `n` × 16 bytes, starting at offset 32:

| Field | Size | Value |
|-------|-----:|-------|
| name | 12 | frame name (e.g. `0.jpg`), zero-padded |
| offset | 4 | absolute offset of the frame's data block |

Per-frame data block (each 4-byte aligned), starting at `32 + 16*n`:

| Offset (rel) | Size | Value |
|-------------:|-----:|-------|
| 0 | 4 | this block's own offset |
| 4 | 4 | next block's offset (last → frame-region start) |
| 8 | 1 | format flag `11` (JPEG) |
| 9 | 1 | 0 |
| 10 | 2 | 0 |
| 12 | 2 | width |
| 14 | 2 | height |
| 16 | 4 | `blockOffset + 32` (JPEG offset) |
| 20 | 4 | jpegLen |
| 24 | 4 | 0 |
| 28 | 4 | 0 |
| 32 | N | JPEG bytes |

Then wrap in `{"type":6,"data":` + `<container>` + `}` and fragment/send under
command **5** (note: envelope says type 6, opcode is 5 — matches the stock app).

## Marquee (type 12) **(verify)**

- Info: `{"type":12,"size":[w>>8, w&255, h>>8, h&255],"display":<d>,"number":<num>}`
  sent under command 12.
- Data: `{"type":12,"data":` + `<image container bytes>` + `}`, fragmented under
  command 12.

The exact meaning of `display` and `number` (scroll direction / count) was not
fully traced; our implementation renders the text to an image and sends it, and
should be checked on hardware.

## Device → app (notifications)

The badge sends JSON status frames on the notify characteristic. Observed keys:

- `type: 13` status with `freespace` (KB), `time_mode`, and `ADD` (a device-id
  challenge).
- The app replies to `ADD` with a **DeviceIdVerification** (type 14) echoing the
  value back. `BluetoothManager` extracts the JSON by slicing between the first
  `{` and last `}`, which is robust to header framing.

## No delete / clear command

The `TYPE` table has **no delete, clear, erase, or format opcode**, and the
stock app's "delete image" (the ✕ on a thumbnail) only edits its *own local
list* (`userAppData` / `delUserImageIndex`) — it never sends anything to the
badge. Each `ALBUM` (6) / `DYNAMIC_ATMOSPHERE` (5) upload sends a complete
container that replaces the current content. So "clear the badge" is
implemented by **uploading a black still frame** before writing new content.
(If your badge turns out to *accumulate* rather than replace, this assumption
needs revisiting on hardware.)

## Free-space guard

Before uploading, the stock app compares `ceil(totalBytes / 1024)` against the
badge's reported `freespace` and aborts if it won't fit. Worth replicating once
`freespace` is confirmed live.

---

# BeamBox badge — Bluetooth protocol

Reverse-engineered from the stock **BeamBox** Android app
(`com.guangshen.beambox`), a native app whose BLE logic lives in the
`com.example.nn20.bleutils` / `com.example.nn20.manager` package. Transcribed
from the decompiled classes `BleProtocolConstant`, `BleProtocolUtils`, the split
builder `manager/j.java#t()`, and the image packer `utils/BinConverter`.
Implemented in `Sources/Bluetooth/BeamBoxAdapter.swift`.

> Status: extracted statically, byte-cross-checked against the decompile, **not
> yet confirmed on hardware.**

BeamBox is the **same protocol family** as DZBJ/e-Goods. Only three things
differ; everything else (496-byte fragments, big-endian subpage counters
counting **down** to 0, checksum `(0 − Σbytes) & 0xFF`, `IMB\0` still container,
0x12345678 multi-frame GIF container, `{"type":N,"data":…}` envelope) is
identical.

## GATT

- Service `000001F0-0000-1000-8000-00805F9B34FB`
- Write `000001F1-…` (**write-without-response**)
- Notify `000001F2-…`
- (secondary service `000003C4/5/6` exists but is unused for image upload)

## The three differences vs e-Goods

1. **Frame head byte** is `0xF1` (`HEAD_APP_TO_DEVICE = -15`), not `0xC0`.
   Device→app head is `0xA0`. Frame = `[0xF1, type, subTotal(BE u16),
   curSub(BE u16), dataLen(BE u16), payload…, checksum]`.
2. **JSON envelope digit matches the frame type**: album (6) →
   `{"type":6,"data":…}`, gif (5) → `{"type":5,"data":…}`. (e-Goods always used
   `type:6`.) The digit is literally `(byte)(type + 48)` in `t()`.
3. **`IMB` still-image header constants** differ at three offsets — `[4]=4`
   (e-Goods `0`), `[13]=0` (e-Goods `100`), data-offset field `[20]=36`
   (e-Goods `32`). Header is 36 bytes, format `0x0B` (JPEG), dimensions `368`
   (or `360`).

## Animation container (`BinConverter.c`)

32-byte global header (`0x12345678`, `16·n+24`, frameCount, **fixed 100ms**
delay, 12-byte name `"output/100ms"`, total−1), then a 16-byte index entry per
frame (`"frame_%05d."` 1-based name + offset), then each frame's 32-byte
sub-header + JPEG packed **contiguously with no padding** (e-Goods 4-byte-aligns
each frame). Last frame's "next" offset loops back to the first.

## Transport (implemented)

BeamBox needs a **windowed, per-packet-acked** upload — a free-running
write-without-response stream overruns its receive buffer and the whole transfer
is silently dropped (the "it writes but nothing arrives" symptom). Replicated
from the stock BleManager (`manager/j.java`) in
`BluetoothManager`'s windowed sender via `BadgeTransportMode.windowedAck`:

- Send a window of **8** fragments, **10 ms** apart.
- The badge acks **each** received packet with a notification whose JSON
  contains `"GetPacketSuccess"` (or `"GetPacketFail"` to reject the batch).
- Wait for all 8 acks, then send the next window after **30 ms**.
- On a `GetPacketFail` or a `(10·N)+2500 ms` timeout, resend the batch from its
  start, up to **3×**, backing the inter-batch gap off to 80 then 120 ms.

No `ADD` challenge is used (BeamBox's status JSON has `freespace`/`allspace` but
no challenge field). Fragments are also MTU-sized (see BadgeTransport) so no
single frame exceeds the negotiated write length.
