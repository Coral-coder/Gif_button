# GifCast

A private, trustworthy iOS replacement for the stock app that drives the DZBJ
"e-Goods" Bluetooth LED badge. Search GIFs on Giphy and Tenor (or use your own
photos / a pasted link / typed text), preview them, and push them straight to
the badge over Bluetooth — with **no analytics, no ad SDKs, and no third-party
data collection**.

It exists because the original app (`baji.gdwlong.com`) is a uni-app bundle that
ships a pile of trackers and phones home. GifCast talks to exactly two kinds of
host: the GIF service you search, and the CDN that hosts a GIF you choose to
send. Nothing about your badge leaves your phone.

## Status

| Piece | State |
|-------|-------|
| Giphy / Tenor search | ✅ implemented |
| GIF → badge pipeline (resize, JPEG, animation container) | ✅ implemented |
| Bluetooth stack (scan, connect, GATT, notify, handshake) | ✅ implemented |
| Badge protocol (framing, still, animation) | ✅ transcribed from the stock app — **needs on-device confirmation** |
| Text → badge (still) | ✅ implemented |
| Text marquee (scrolling mode) | ⚠️ wired, `display`/`number` params need hardware verification |
| Photo-library picker | ✅ implemented |
| Paste-a-URL | ✅ implemented |

The badge protocol was reverse-engineered from the stock APK. The full spec is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md); it lives behind one file
(`Sources/Bluetooth/EGoodsProtocol.swift`) so it's easy to audit and adjust.

## Build

This repo does **not** commit the Xcode project (it's generated). On a Mac:

```sh
brew install xcodegen      # one time
xcodegen generate          # creates GifCast.xcodeproj from project.yml
open GifCast.xcodeproj
```

Then in Xcode: select your team under **Signing & Capabilities**, plug in an
iPhone (Bluetooth LE needs a real device — the simulator has no BLE), and Run.

- iOS 16+, SwiftUI, zero third-party Swift dependencies.
- Add your **Giphy** and **Tenor** API keys in the app's Settings tab (both are
  free; links are in-app).

## How it works

1. **Search** GIFs (Giphy/Tenor) → pick one.
2. GifCast downloads the full GIF, decodes its frames, resizes each to the
   badge's 368×368, and JPEG-encodes them.
3. Frames are packed into the badge's container format and fragmented into
   ≤496-byte BLE writes.
4. Connect to the badge (name starts `DZBJ-`) on the **Badge** tab, then send.

## Layout

```
project.yml                 XcodeGen project definition
App/Info.plist              Bundle + Bluetooth/Photos usage strings
Sources/
  App/                      App entry, root tabs, settings store
  Models/                   GifItem, sources
  Networking/               Tiny async HTTP client
  GifProviders/             Giphy + Tenor
  Bluetooth/                Device descriptor, protocol encoder, CB manager
  Media/                    GIF/image/text → JPEG frames
  Features/                 Search, Send, Devices, Marquee, Settings screens
docs/PROTOCOL.md            The reverse-engineered badge protocol
PRIVACY.md                  What the app does and does not do with data
```

## Privacy

See [`PRIVACY.md`](PRIVACY.md). Short version: no tracking, no third parties
beyond the GIF search service you explicitly use.
