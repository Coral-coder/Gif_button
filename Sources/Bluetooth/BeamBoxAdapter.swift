import CoreBluetooth
import Foundation

/// Adapter for BeamBox badges (`com.guangshen.beambox`) — service 000001F0,
/// write 000001F1 (write-without-response), notify 000001F2.
///
/// The wire protocol was reverse-engineered from the stock BeamBox app
/// (`com.example.nn20.bleutils` / `manager`). It is the same family as the DZBJ
/// "e-Goods" badge — 496-byte fragments, big-endian subpage counters, and a
/// `(0 - Σbytes)` checksum — but with three concrete differences, all captured
/// in `BeamBoxProtocol`:
///   1. Frame head byte is 0xF1 (e-Goods uses 0xC0).
///   2. The JSON envelope's `"type"` digit matches the frame type (album→6,
///      gif→5), not a fixed 6.
///   3. The "IMB" still-image header uses slightly different constant fields
///      (offset[4]=4, byte[13]=0, data offset=36).
final class BeamBoxAdapter: BadgeAdapter {
    let id = "beambox"
    let displayName = "BeamBox badge"
    let serviceUUID = CBUUID(string: "000001F0-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "000001F1-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "000001F2-0000-1000-8000-00805F9B34FB")

    var isSupported: Bool { BeamBoxProtocol.isImplemented }

    func matches(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        serviceUUIDs.contains(serviceUUID)
    }

    func selectCharacteristics(_ chars: [CBCharacteristic])
        -> (write: CBCharacteristic?, notify: CBCharacteristic?, writeType: CBCharacteristicWriteType) {
        // 01F1 is write-without-response on this badge; prefer it explicitly.
        let write = chars.first { $0.uuid == writeUUID }
            ?? chars.first { $0.properties.contains(.writeWithoutResponse) }
            ?? chars.first { $0.properties.contains(.write) }
        let notify = chars.first { $0.uuid == notifyUUID }
            ?? chars.first { $0.properties.contains(.notify) }
            ?? chars.first { $0.properties.contains(.indicate) }
        // The badge's write characteristic is write-without-response.
        let type: CBCharacteristicWriteType =
            (write?.properties.contains(.writeWithoutResponse) ?? false) ? .withoutResponse
            : ((write?.properties.contains(.write) ?? false) ? .withResponse : .withoutResponse)
        return (write, notify, type)
    }

    func onConnect() -> [Data] { BeamBoxProtocol.onConnect() }

    func handleNotification(_ data: Data) -> BadgeNotificationResult {
        BeamBoxProtocol.handleNotification(data)
    }

    func encode(_ payload: BadgePayload) throws -> [Data] {
        try BeamBoxProtocol.encode(payload)
    }

    func reset() { BeamBoxProtocol.reset() }
}

/// BeamBox wire protocol, transcribed byte-for-byte from the app decompile
/// (`BleProtocolConstant`, `BleProtocolUtils`, `manager/j.java` split builder
/// `t()`, and `utils/BinConverter`).
///
/// NOTE: correctness is verified against the decompiled source but has NOT been
/// validated on a physical badge. The transport uses write-without-response with
/// the manager's flow-control pump rather than the app's windowed per-packet ACK
/// scheme; if a device proves to need explicit ACK pacing, add it in
/// `handleNotification` (the badge acks with JSON containing "GetPacketSuccess").
enum BeamBoxProtocol {
    static var isImplemented = true

    // MARK: Constants (BleProtocolConstant)

    static let headAppToDevice: UInt8 = 0xF1   // -15
    static let headDeviceToApp: UInt8 = 0xA0   // -96
    static let maxDataLenPerPacket = 496

    enum Command: UInt8 {
        case activateQuery = 1
        case gifAnimation = 5
        case album = 6
        case getVersion = 7
        case setBrightness = 13
    }

    // Native panel resolution. The app only ever writes 360 or 368 into headers.
    static let side = 368

    // MARK: - Framing (BleProtocolUtils + j.java)

    /// One wire frame: [head, type, subpageTotal(BE u16), curSubpage(BE u16),
    /// dataLen(BE u16), payload…, checksum]. checksum = (0 - Σ(prev bytes)) & 0xFF.
    static func frame(type: UInt8, payload: [UInt8], total: Int = 0, index: Int = 0) -> Data {
        var s = [UInt8](repeating: 0, count: 8 + payload.count + 1)
        s[0] = headAppToDevice
        s[1] = type
        s[2] = UInt8((total >> 8) & 0xFF)   // big-endian
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

    /// JSON control frame, e.g. `{"type":1}` for the activate query. Sent as a
    /// single no-split frame (total = index = 0), mirroring `j.s()`.
    static func jsonCommand(_ object: [String: Any], type: Command) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return frame(type: type.rawValue, payload: [UInt8](data))
    }

    /// `{"type":<n>,"data":` + bytes + `}`, where the digit matches the frame
    /// type (album→"6", gif→"5"). Transcribed from `t()`'s bArr4/bArr5.
    private static func envelope(type: Command, _ payload: [UInt8]) -> [UInt8] {
        Array("{\"type\":\(type.rawValue),\"data\":".utf8) + payload + Array("}".utf8)
    }

    /// Split a full envelope into 496-byte data fields, subpage counting DOWN so
    /// the last fragment has index 0 (matches `t()`: `s10 = (total-1) - i`).
    static func fragment(type: Command, data: [UInt8], size: Int = BadgeTransport.maxDataLen) -> [Data] {
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

    /// The app only writes 368 (exact match) or 360 into header dimension fields.
    private static func headerDim(_ d: Int) -> UInt16 { d == 368 ? 368 : 360 }

    // MARK: - Still image "IMB" container (BinConverter.b)

    /// 36-byte "IMB\0" header + JPEG. Distinct from e-Goods at offsets 4, 13, 20.
    static func imbImage(jpeg: Data, width: Int, height: Int) -> [UInt8] {
        let n = jpeg.count
        var buf = [UInt8](repeating: 0, count: 36 + n)
        buf[0] = 0x49; buf[1] = 0x4D; buf[2] = 0x42; buf[3] = 0x00  // "IMB\0"
        putU32LE(&buf, 4, 4)                    // FIXED_VALUE = 4
        putU32LE(&buf, 8, UInt32(n + 32))
        buf[12] = 0x0B                          // FORMAT = 11 (JPEG)
        buf[13] = 0                             // COMPRESS = 0
        putU16LE(&buf, 14, 0)                   // DATA_CRC = 0
        putU16LE(&buf, 16, headerDim(width))
        putU16LE(&buf, 18, headerDim(height))
        putU32LE(&buf, 20, 36)                  // data offset = 36 (HEADER_SIZE)
        putU32LE(&buf, 24, UInt32(n))
        putU32LE(&buf, 28, 0)
        putU32LE(&buf, 32, 0)
        for (i, b) in jpeg.enumerated() { buf[36 + i] = b }
        return buf
    }

    static func packStillImage(_ image: EncodedImage) -> [Data] {
        let imb = imbImage(jpeg: image.jpeg, width: image.width, height: image.height)
        return fragment(type: .album, data: envelope(type: .album, imb))
    }

    // MARK: - Animation container (BinConverter.c)

    /// Multi-frame GIF container. Global header (32B): magic 0x12345678,
    /// 16·n+24, frameCount, 100ms delay, 12-byte name "output/100ms", total-1.
    /// Then a 16-byte index entry per frame ("frame_%05d." + offset), then each
    /// frame's 32-byte sub-header + JPEG, packed contiguously (no padding).
    static func animationContainer(frames: [Data], width: Int, height: Int) -> [UInt8] {
        let n = frames.count
        let frameRegionStart = 32 + 16 * n

        // Frames are packed with NO alignment padding (unlike e-Goods).
        var offsets = [Int]()
        offsets.reserveCapacity(n)
        var cursor = frameRegionStart
        for f in frames {
            offsets.append(cursor)
            cursor += 32 + f.count
        }
        let total = cursor
        var out = [UInt8](repeating: 0, count: total)

        // Global header.
        putU32LE(&out, 0, 0x1234_5678)
        putU32LE(&out, 4, UInt32(16 * n + 24))
        putU32LE(&out, 8, UInt32(n))
        putU32LE(&out, 12, 100)                 // fixed 100ms/frame (BinConverter)
        let nameBytes = Array("output/100ms".utf8)   // exactly 12 bytes
        for b in 0..<12 { out[16 + b] = b < nameBytes.count ? nameBytes[b] : 0 }
        putU32LE(&out, 28, UInt32(total - 1))

        // Index table: 12-byte "frame_%05d." (1-based) name + 4-byte offset.
        let p = 32
        for b in 0..<n {
            let fname = Array(String(format: "frame_%05d.", b + 1).utf8)
            for e in 0..<12 { out[p + 16 * b + e] = e < fname.count ? fname[e] : 0 }
            putU32LE(&out, p + 16 * b + 12, UInt32(offsets[b]))
        }

        // Frame blocks: [selfOff, nextOff, 0x0B, 0, u16 0, w, h, selfOff+32,
        // jpegLen, 0, 0, jpeg…].
        let dim = headerDim(width)
        for (b, f) in frames.enumerated() {
            let a = offsets[b]
            var g = a
            putU32LE(&out, g, UInt32(a)); g += 4
            let next = b < n - 1 ? offsets[b + 1] : offsets[0]  // last loops to first
            putU32LE(&out, g, UInt32(next)); g += 4
            out[g] = 0x0B; g += 1
            out[g] = 0; g += 1
            putU16LE(&out, g, 0); g += 2
            putU16LE(&out, g, dim); g += 2
            putU16LE(&out, g, dim); g += 2
            putU32LE(&out, g, UInt32(a + 32)); g += 4
            putU32LE(&out, g, UInt32(f.count)); g += 4
            putU32LE(&out, g, 0); g += 4
            putU32LE(&out, g, 0); g += 4
            for (i, byte) in f.enumerated() { out[g + i] = byte }
        }
        return out
    }

    static func packAnimation(_ animation: EncodedAnimation) -> [Data] {
        let container = animationContainer(frames: animation.frames.map(\.jpeg),
                                           width: animation.width,
                                           height: animation.height)
        return fragment(type: .gifAnimation, data: envelope(type: .gifAnimation, container))
    }

    // MARK: - Adapter entry points

    static func onConnect() -> [Data] {
        // Prompt the badge for its status (freespace / device info).
        [jsonCommand(["type": Command.activateQuery.rawValue], type: .activateQuery)].compactMap { $0 }
    }

    static func handleNotification(_ data: Data) -> BadgeNotificationResult {
        var result = BadgeNotificationResult()
        guard let json = extractStatusJSON(data) else { return result }
        result.freeSpaceKB = json["freespace"] as? Int
        return result
    }

    static func encode(_ payload: BadgePayload) throws -> [Data] {
        switch payload {
        case .still(let image): return packStillImage(image)
        case .animation(let animation):
            guard !animation.frames.isEmpty else { throw BadgeError.emptyAnimation }
            return packAnimation(animation)
        }
    }

    static func reset() {}

    /// The badge replies with JSON status frames; slice between the first `{`
    /// and last `}` to be robust to framing.
    static func extractStatusJSON(_ data: Data) -> [String: Any]? {
        guard let start = data.firstIndex(of: 0x7B),
              let end = data.lastIndex(of: 0x7D),
              start <= end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(data[start...end]))) as? [String: Any]
    }
}
