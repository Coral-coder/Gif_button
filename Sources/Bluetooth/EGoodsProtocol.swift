import Foundation

/// Byte-level encoder for the "e-Goods" / DZBJ badge, transcribed faithfully
/// from the stock app's JavaScript (`store/bluetooth.js`, `gifAgreement.js`,
/// `imageAgreement.js`). See PROTOCOL.md for the annotated spec.
///
/// Frame layout (little details matter — this is exact):
///   [0]      HEAD           0xC0 app→device, 0xA0 device→app
///   [1]      command type
///   [2..3]   total fragments      (big-endian u16)
///   [4..5]   current fragment idx (big-endian u16, counts DOWN to 0)
///   [6..7]   payload length       (big-endian u16)
///   [8..]    payload
///   [last]   checksum = (256 - (sum of all previous bytes & 0xFF)) & 0xFF
enum EGoodsProtocol {
    static let headAppToDevice: UInt8 = 0xC0   // 192
    static let headDeviceToApp: UInt8 = 0xA0   // 160
    static let fragmentSize = 496

    enum Command: UInt8 {
        case activationQuery = 1
        case ota = 2
        case bootAnimation = 3
        case dialStyle = 4
        case dynamicAtmosphere = 5   // animated GIFs are sent under this opcode
        case album = 6               // still images
        case versionQuery = 7
        case updateTime = 8
        case lyricsBackground = 9
        case marqueeImage = 12
        case deviceInfoSetting = 13
        case deviceIdVerification = 14
    }

    // MARK: - Framing

    static func frame(type: UInt8, payload: [UInt8], total: Int = 0, index: Int = 0) -> Data {
        var s = [UInt8](repeating: 0, count: 8 + payload.count + 1)
        s[0] = headAppToDevice
        s[1] = type
        s[2] = UInt8((total >> 8) & 0xFF)
        s[3] = UInt8(total & 0xFF)
        s[4] = UInt8((index >> 8) & 0xFF)
        s[5] = UInt8(index & 0xFF)
        s[6] = UInt8((payload.count >> 8) & 0xFF)
        s[7] = UInt8(payload.count & 0xFF)
        for (i, b) in payload.enumerated() { s[8 + i] = b }
        var sum = 0
        for i in 0..<(s.count - 1) { sum = (sum &+ Int(s[i])) & 0xFF }
        s[s.count - 1] = UInt8((256 - sum) & 0xFF)
        return Data(s)
    }

    /// JSON control command (payload = UTF-8 of the JSON object).
    static func jsonCommand(_ object: [String: Any], type: Command) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return frame(type: type.rawValue, payload: [UInt8](data))
    }

    /// Split a binary payload into fragments. The last fragment has index 0.
    static func fragment(type: Command, data: [UInt8], size: Int = 496) -> [Data] {
        if data.count <= size {
            return [frame(type: type.rawValue, payload: data)]
        }
        let n = Int(ceil(Double(data.count) / Double(size)))
        var out: [Data] = []
        out.reserveCapacity(n)
        for a in 0..<n {
            let start = a * size
            let end = Swift.min(start + size, data.count)
            out.append(frame(type: type.rawValue,
                             payload: Array(data[start..<end]),
                             total: n,
                             index: n - a - 1))
        }
        return out
    }

    // MARK: - Little-endian helpers

    private static func putU32LE(_ buf: inout [UInt8], _ off: Int, _ v: UInt32) {
        buf[off]     = UInt8(v & 0xFF)
        buf[off + 1] = UInt8((v >> 8) & 0xFF)
        buf[off + 2] = UInt8((v >> 16) & 0xFF)
        buf[off + 3] = UInt8((v >> 24) & 0xFF)
    }

    private static func putU16LE(_ buf: inout [UInt8], _ off: Int, _ v: UInt16) {
        buf[off]     = UInt8(v & 0xFF)
        buf[off + 1] = UInt8((v >> 8) & 0xFF)
    }

    // MARK: - Still image (Album, type 6)

    /// 36-byte "IMB\0" container wrapping a single JPEG (mirrors `jpegBase64ToBin`).
    static func imbImage(jpeg: Data, width: Int, height: Int) -> [UInt8] {
        let n = jpeg.count
        var buf = [UInt8](repeating: 0, count: 36 + n)
        buf[0] = 0x49; buf[1] = 0x4D; buf[2] = 0x42; buf[3] = 0x00 // "IMB\0"
        putU32LE(&buf, 4, 0)
        putU32LE(&buf, 8, UInt32(n + 32))
        buf[12] = 11            // format flag: 11 = JPEG
        buf[13] = 100           // quality marker
        putU16LE(&buf, 14, 0)
        putU16LE(&buf, 16, UInt16(width))
        putU16LE(&buf, 18, UInt16(height))
        putU32LE(&buf, 20, 32)  // data offset within the 32-byte body
        putU32LE(&buf, 24, UInt32(n))
        putU32LE(&buf, 28, 0)
        putU32LE(&buf, 32, 0)
        for (i, b) in jpeg.enumerated() { buf[36 + i] = b }
        return buf
    }

    /// Wrap a binary payload as `{"type":6,"data":<bytes>}` (the app's envelope).
    private static func type6Envelope(_ payload: [UInt8]) -> [UInt8] {
        Array("{\"type\":6,\"data\":".utf8) + payload + Array("}".utf8)
    }

    static func packStillImage(_ image: EncodedImage) -> [Data] {
        let imb = imbImage(jpeg: image.jpeg, width: image.width, height: image.height)
        return fragment(type: .album, data: type6Envelope(imb))
    }

    // MARK: - Animation (DynamicAtmosphere, type 5)

    /// Multi-frame container (mirrors `packImagesToArrayBuffer`).
    /// Global header (32B): magic 0x12345678, indexSize+24, frameCount,
    /// frameDelayMs, 12-byte name, total-1. Then a 16-byte index entry per
    /// frame, then each frame's 32-byte sub-header + JPEG (4-byte aligned).
    static func animationContainer(frames: [Data],
                                   name: String,
                                   frameDelayMs: Int,
                                   width: Int,
                                   height: Int) -> [UInt8] {
        let n = frames.count
        let frameRegionStart = 32 + 16 * n

        // Pre-compute each frame's absolute offset (32B sub-header + JPEG, aligned).
        var offsets = [Int]()
        offsets.reserveCapacity(n)
        var cursor = frameRegionStart
        for f in frames {
            offsets.append(cursor)
            let block = 32 + f.count
            cursor += block + ((4 - (block % 4)) % 4)
        }
        let total = cursor
        var out = [UInt8](repeating: 0, count: total)

        // Global header.
        putU32LE(&out, 0, 0x1234_5678)
        putU32LE(&out, 4, UInt32(16 * n + 24))
        putU32LE(&out, 8, UInt32(n))
        putU32LE(&out, 12, UInt32(frameDelayMs))
        let nameBytes = Array(name.utf8)
        for b in 0..<12 { out[16 + b] = b < nameBytes.count ? nameBytes[b] : 0 }
        putU32LE(&out, 28, UInt32(total - 1))

        // Index table.
        let p = 32
        for (b, _) in frames.enumerated() {
            let fname = Array("\(b).jpg".utf8)
            for e in 0..<12 { out[p + 16 * b + e] = e < fname.count ? fname[e] : 0 }
            putU32LE(&out, p + 16 * b + 12, UInt32(offsets[b]))
        }

        // Frame blocks.
        for (b, f) in frames.enumerated() {
            let a = offsets[b]
            var g = a
            putU32LE(&out, g, UInt32(a)); g += 4
            let next = b < n - 1 ? offsets[b + 1] : frameRegionStart
            putU32LE(&out, g, UInt32(next)); g += 4
            out[g] = 11; g += 1        // JPEG
            out[g] = 0; g += 1
            putU16LE(&out, g, 0); g += 2
            putU16LE(&out, g, UInt16(width)); g += 2
            putU16LE(&out, g, UInt16(height)); g += 2
            putU32LE(&out, g, UInt32(a + 32)); g += 4
            putU32LE(&out, g, UInt32(f.count)); g += 4
            putU32LE(&out, g, 0); g += 4
            putU32LE(&out, g, 0); g += 4
            for (i, byte) in f.enumerated() { out[g + i] = byte }
        }
        return out
    }

    static func packAnimation(_ animation: EncodedAnimation, name: String = "gif") -> [Data] {
        let container = animationContainer(frames: animation.frames.map(\.jpeg),
                                           name: name,
                                           frameDelayMs: animation.frameDelayMs,
                                           width: animation.width,
                                           height: animation.height)
        // GIFs use a `{"type":6,...}` envelope but are sent under opcode 5.
        return fragment(type: .dynamicAtmosphere, data: type6Envelope(container))
    }

    // MARK: - Marquee (type 12)

    static func marqueeInfo(width: Int, height: Int, display: Int, number: Int) -> Data? {
        jsonCommand([
            "type": Command.marqueeImage.rawValue,
            "size": [width >> 8, width & 0xFF, height >> 8, height & 0xFF],
            "display": display,
            "number": number,
        ], type: .marqueeImage)
    }

    static func marqueeData(container: [UInt8]) -> [Data] {
        let envelope = Array("{\"type\":12,\"data\":".utf8) + container + Array("}".utf8)
        return fragment(type: .marqueeImage, data: envelope)
    }

    // MARK: - Control commands

    static func activationQuery() -> Data? { jsonCommand(["type": Command.activationQuery.rawValue], type: .activationQuery) }
    static func versionQuery() -> Data? { jsonCommand(["type": Command.versionQuery.rawValue], type: .versionQuery) }

    static func deviceIdVerification(ret: Any) -> Data? {
        jsonCommand(["type": Command.deviceIdVerification.rawValue, "Ret": ret], type: .deviceIdVerification)
    }

    static func deviceInfoSetting(backlight: Int, breather: Int, name: String) -> Data? {
        jsonCommand([
            "type": Command.deviceInfoSetting.rawValue,
            "bglight": backlight,
            "breather": breather,
            "devname": name,
        ], type: .deviceInfoSetting)
    }

    // MARK: - Parsing device → app

    /// The badge replies with JSON status frames (free space, time mode, and an
    /// `ADD` challenge). We extract the JSON object leniently by slicing between
    /// the first `{` and last `}`, which is robust to header framing details.
    static func extractStatusJSON(_ data: Data) -> [String: Any]? {
        guard let start = data.firstIndex(of: 0x7B),      // {
              let end = data.lastIndex(of: 0x7D),          // }
              start <= end else { return nil }
        let slice = data[start...end]
        return (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any]
    }
}
