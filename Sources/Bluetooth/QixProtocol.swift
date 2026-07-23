import Foundation

/// Qix wire protocol for the N88 badge (service C2E6FD00). Transcribed from the
/// ZRun app's `com.qix.library` — `BTCommandManager` (command frame),
/// `DialTool` (dial/picture file format + CRC-16) and `ImageCacheUtils`
/// (RGB565). Byte-exact from the decompile; the big-blob streaming orchestration
/// is finalized in QixUploader.
enum QixProtocol {
    static var isImplemented = true

    // MARK: CommandCode (com.qix.library.command.CommandCode)
    static let commandMark: UInt8 = 0x9E          // -98, frame head
    static let cmdGetNotifyType: UInt8 = 0x42     // 66  — image-header[0]
    static let cmdSendNotify: UInt8 = 0x41        // 65
    static let cmdSetNotify: UInt8 = 0x40         // 64
    static let cmdTestGetUserConfig: UInt8 = 0xAF // -81 — file-header[1]
    static let fileHeadMagic: UInt8 = 0xBC        // PSSSigner.TRAILER_IMPLICIT

    // File types (DialTool): dial=5, wechatCard=7, alipay=9, healthy=10,
    // bootAni=11, video=12, map=13.
    static let fileTypeDial: UInt8 = 5

    // MARK: - Command frame  (BTCommandManager.sendCommandData, byte-exact)
    //
    // [0x9E][check = Σ(bArr2)][flag][cmd][len_lo][len_hi][data…]
    // flag = (isConfig<<7) | (serial<<3) | (needSub<<2) | (hasResponse<<1) | d
    // len is 16-bit little-endian; check is a plain byte-sum over bArr2.
    static func commandFrame(cmd: UInt8, data: [UInt8], serial: UInt8,
                             isConfig: Bool = false, hasResponse: Bool = true) -> [UInt8] {
        let needSub = data.count + 6 > 20
        let flag: UInt8 = (isConfig ? 0x80 : 0)
            | UInt8((Int(serial) & 0x0F) << 3)
            | (needSub ? 0x04 : 0)
            | (hasResponse ? 0x02 : 0)
        var bArr2: [UInt8] = [flag, cmd, UInt8(data.count & 0xFF), UInt8((data.count >> 8) & 0xFF)]
        bArr2 += data
        var check = bArr2[0]
        for i in 1..<bArr2.count { check = check &+ bArr2[i] }
        return [commandMark, check] + bArr2
    }

    // MARK: - Dial/picture file blob  (DialTool.fileToBytes, byte-exact)
    //
    // blob = [fileHeader:27][imageHeader:8][rgb565-BE : w*h*2]

    /// 8-byte image header: [0x42,'M',w_lo,w_hi,h_lo,h_hi,0x10,0x80] (0x10 = 16bpp).
    static func imageHeader(w: Int, h: Int) -> [UInt8] {
        [cmdGetNotifyType, 0x4D,
         UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF),
         UInt8(h & 0xFF), UInt8((h >> 8) & 0xFF),
         0x10, 0x80]
    }

    /// 27-byte file header: magic 0xBC, cmd 0xAF, type, 16-bit index, 32-bit data
    /// length @13, CRC-16 @25 (little-endian). `data` = the image block.
    static func fileHeader(dataLen: Int, crc: UInt16, type: UInt8, index: Int) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 27)
        h[0] = fileHeadMagic
        h[1] = cmdTestGetUserConfig
        h[2] = type
        h[3] = UInt8(index & 0xFF)
        h[4] = UInt8((index >> 8) & 0xFF)
        // data length at [13..16] — LITTLE-endian (TypeConversion.intToBytes).
        h[13] = UInt8(dataLen & 0xFF)
        h[14] = UInt8((dataLen >> 8) & 0xFF)
        h[15] = UInt8((dataLen >> 16) & 0xFF)
        h[16] = UInt8((dataLen >> 24) & 0xFF)
        h[25] = UInt8(crc & 0xFF)
        h[26] = UInt8((crc >> 8) & 0xFF)
        return h
    }

    /// Build the complete dial file for a `w`×`h` RGB565 (big-endian) image.
    static func buildDialFile(rgb565BE: [UInt8], w: Int, h: Int,
                              type: UInt8 = fileTypeDial, index: Int = 0) -> [UInt8] {
        let imageBlock = imageHeader(w: w, h: h) + rgb565BE
        let crc = crc16(imageBlock)
        return fileHeader(dataLen: imageBlock.count, crc: crc, type: type, index: index) + imageBlock
    }

    // MARK: - CRC-16  (DialTool.getCRC16, byte-exact — CCITT byte-swap variant)
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc = 0xFFFF
        for b in bytes {
            let x = ((((crc << 8) & 0xFFFF) | ((crc >> 8) & 0xFFFF)) & 0xFFFF) ^ Int(b)
            let y = x ^ (((x & 0xFF) >> 4) & 0xFFFF)
            let z = y ^ ((y << 12) & 0xFFFF)
            crc = z ^ (((z & 0xFF) << 5) & 0xFFFF)
        }
        return UInt16(crc & 0xFFFF)
    }

    // MARK: - Dial-push transfer (UpdateManager, byte-exact)
    //
    // The ~N-byte dial blob is streamed via the same OTA "update" channel the
    // watch app uses. We split the blob into its 27-byte fileHeader and the image
    // body, then:
    //   TX 0xC0 (REQ_UPDATE) + fileHeader        → RX 0xC1 {status, allowLen, offset}
    //   loop: TX 0xC2 (SEND_DATA) [len|offset|chunk] → RX 0xC3 {status, nextOffset}
    //   TX 0xC4 (REQ_UPDATE_CON) {3} at the end   → RX 0xC5 {status: 0 = done}
    // The device flow-controls: 0xC1 grants `allowLen` bytes per package and each
    // 0xC3 echoes the next offset to send from.
    static let cmdReqUpdate: UInt8 = 0xC0      // -64  send file header / request update
    static let cmdSendData: UInt8 = 0xC2       // -62  send a data package
    static let cmdReqUpdateCon: UInt8 = 0xC4   // -60  control (stop = {3})
    static let respReqUpdate: UInt8 = 0xC1     // -63  request granted (allowLen, offset)
    static let respData: UInt8 = 0xC3          // -61  data acked (next offset)
    static let respResult: UInt8 = 0xC5        // -59  final result (0 = success)

    /// Update-channel command frame (UpdateManager.sendCommandData + getFlagStatus):
    /// flag = (serial<<3) | (needSub<<2) | 1 — note isConfig=0, hasResponse=0, d=1,
    /// which differs from the config/command channel's flag byte.
    static func updateFrame(cmd: UInt8, data: [UInt8], serial: UInt8) -> [UInt8] {
        let needSub = data.count + 6 > 20
        let flag: UInt8 = UInt8((Int(serial) & 0x0F) << 3) | (needSub ? 0x04 : 0) | 0x01
        var bArr2: [UInt8] = [flag, cmd, UInt8(data.count & 0xFF), UInt8((data.count >> 8) & 0xFF)]
        bArr2 += data
        var check = bArr2[0]
        for i in 1..<bArr2.count { check = check &+ bArr2[i] }
        return [commandMark, check] + bArr2
    }

    /// A 0xC2 data package: [len:LE32][offset:LE32][chunk] (UpdateManager.sendNextPackageData).
    static func dataPackage(chunk: [UInt8], offset: Int) -> [UInt8] {
        let n = chunk.count
        var b = [UInt8](repeating: 0, count: n + 8)
        b[0] = UInt8(n & 0xFF); b[1] = UInt8((n >> 8) & 0xFF)
        b[2] = UInt8((n >> 16) & 0xFF); b[3] = UInt8((n >> 24) & 0xFF)
        b[4] = UInt8(offset & 0xFF); b[5] = UInt8((offset >> 8) & 0xFF)
        b[6] = UInt8((offset >> 16) & 0xFF); b[7] = UInt8((offset >> 24) & 0xFF)
        for i in 0..<n { b[8 + i] = chunk[i] }
        return b
    }

    /// Parsed update-channel response (UpdateManager.responseDisposal): the notify
    /// frame is [0x9E, check, flag, cmd, len_lo, len_hi, payload…]; cmd is at [3]
    /// and the payload (little-endian ints) starts at [6].
    struct UpdateResponse { let cmd: UInt8; let status: UInt8; let allowLen: Int; let offset: Int }

    static func parseUpdate(_ data: Data) -> UpdateResponse? {
        let b = [UInt8](data)
        guard b.count > 6 else { return nil }
        let cmd = b[3]
        let payload = Array(b[6...])
        func le32(_ s: Int) -> Int {
            Int(payload[s]) | (Int(payload[s + 1]) << 8) | (Int(payload[s + 2]) << 16) | (Int(payload[s + 3]) << 24)
        }
        switch cmd {
        case respReqUpdate:
            guard payload.count >= 9 else { return nil }
            return UpdateResponse(cmd: cmd, status: payload[0], allowLen: le32(1), offset: le32(5))
        case respData:
            guard payload.count >= 5 else { return nil }
            return UpdateResponse(cmd: cmd, status: payload[0], allowLen: 0, offset: le32(1))
        case respResult:
            guard payload.count >= 1 else { return nil }
            return UpdateResponse(cmd: cmd, status: payload[0], allowLen: 0, offset: 0)
        default:
            return nil
        }
    }

    // MARK: - Adapter entry points (transmission handled by QixUploader)
    static func onConnect() -> [Data] { [] }
    static func handleNotification(_ data: Data) -> BadgeNotificationResult { BadgeNotificationResult() }
    static func reset() {}
    static func encode(_ payload: BadgePayload) throws -> [Data] {
        throw BadgeError.badgeUnsupported("Qix badge (N88) — uses interactive upload")
    }
}
