import Foundation

/// Jieli RCSP protocol for AE00 badges (E87 / L8 / N88), used to push a custom
/// watch-face background image into the badge's external flash.
///
/// Transcribed from the ZRun app decompile:
///  - wire frame: `ParseHelper.packSendBasePacket` (byte-exact, below),
///  - command param bodies: `com.jieli.jl_rcsp.model.parameter.*` (byte-exact),
///  - CRC-16 (flash-write verification only): `CryptoUtil` native `jl_crc`.
///
/// Byte-exact pieces are marked. The two on-device-confirm points are the CRC-16
/// variant used by QueryWriteResult and the custom-bg image *format* (the bytes
/// written to flash) — everything else is transcribed verbatim.
enum JieliRCSP {

    // MARK: RCSP opcodes (CommandBase ids)
    static let opGetTargetInfo: UInt8 = 0x03       // GetTargetInfoCmd
    static let opExternalFlashIOCtrl: UInt8 = 0x1A // 26 — ExternalFlashIOCtrlCmd

    // Frame flag bits (ParseHelper.packSendBasePacket).
    static let flagIsCommand: UInt8 = 0x80
    static let flagNeedResponse: UInt8 = 0x40      // CommandCode.COMMAND_SET_NOTIFY

    // MARK: ExternalFlashIOCtrl sub-ops (first param byte)
    enum FlashOp: UInt8 {
        case writeData = 0, readData = 1, createFile = 2, dialAction = 3
        case eraseData = 4, queryWriteResult = 8, getFreeSpace = 12, getResourceSpace = 13
    }
    // Dial actions (DialActionParam, op 3, second byte)
    static let dialGetUsing: UInt8 = 0, dialSetUsing: UInt8 = 1
    static let dialEnableCustomBg: UInt8 = 4, dialGetBg: UInt8 = 5

    static let defaultCustomBgPath = "/null"

    // MARK: - Wire frame  (byte-exact from ParseHelper.packSendBasePacket)
    //
    // [0xFE 0xDC 0xBA][flags][opCode][paramLen: u16 BE][opCodeSn][paramData…][0xEF]
    // flags = 0x80 (command) | 0x40 (needs response); paramLen counts the
    // opCodeSn byte + paramData. No frame-level CRC.
    static func frame(opcode: UInt8, sn: UInt8, param: [UInt8], needsResponse: Bool = true) -> Data {
        let body = [sn] + param                    // [opCodeSn][paramData…]
        let paramLen = body.count
        var flags: UInt8 = flagIsCommand
        if needsResponse { flags |= flagNeedResponse }
        var f: [UInt8] = [0xFE, 0xDC, 0xBA, flags, opcode,
                          UInt8((paramLen >> 8) & 0xFF), UInt8(paramLen & 0xFF)]
        f += body
        f.append(0xEF)
        return Data(f)
    }

    /// A parsed RCSP response frame from the badge.
    struct Response {
        let opcode: UInt8
        let sn: UInt8
        let status: UInt8
        let param: [UInt8]   // paramData after the sn byte
    }

    /// Parse a received frame `[FE DC BA][flags][opcode][len:2][sn][status?][param…][EF]`.
    /// Responses carry a status byte; we surface it plus the remaining param.
    static func parse(_ data: Data) -> Response? {
        let b = [UInt8](data)
        guard b.count >= 9, b[0] == 0xFE, b[1] == 0xDC, b[2] == 0xBA, b.last == 0xEF else { return nil }
        let opcode = b[4]
        let paramLen = (Int(b[5]) << 8) | Int(b[6])
        guard b.count >= 7 + paramLen + 1 else { return nil }
        let bodyStart = 7
        let body = Array(b[bodyStart..<(bodyStart + paramLen)])
        guard let sn = body.first else { return nil }
        // Response body: [opCodeSn][status][param…]
        let status = body.count > 1 ? body[1] : 0
        let param = body.count > 2 ? Array(body[2...]) : []
        return Response(opcode: opcode, sn: sn, status: status, param: param)
    }

    // MARK: - Command param bodies  (layout: [op][flag][payload…], byte-exact)

    private static func flash(_ op: FlashOp, _ flag: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
        [op.rawValue, flag] + payload
    }
    static func createFileStart(size: Int, path: String) -> [UInt8] {
        flash(.createFile, 1, u32be(size) + Array(path.utf8))     // [02][01][size4][path]
    }
    static func createFileStop() -> [UInt8] { flash(.createFile, 0) } // [02][00]
    static func writeData(offset: Int, data: [UInt8], isFinal: Bool) -> [UInt8] {
        flash(.writeData, isFinal ? 0 : 1, u32be(offset) + data)  // [00][flag][off4][data]
    }
    static func queryWriteResult(crc: UInt16, isFinal: Bool) -> [UInt8] {
        flash(.queryWriteResult, isFinal ? 0 : 1, u16be(crc))     // [08][flag][crc2]
    }
    static func getFreeSpace() -> [UInt8] { flash(.getFreeSpace, 0) }      // [0C][00]
    static func dialAction(_ action: UInt8, path: String) -> [UInt8] {
        flash(.dialAction, action, Array(path.utf8))              // [03][action][path]
    }
    static func enableCustomDialBg(path: String) -> [UInt8] { dialAction(dialEnableCustomBg, path: path) }
    static func setUsingDial(path: String) -> [UInt8] { dialAction(dialSetUsing, path: path) }

    // MARK: - CRC-16 for flash-write verification (QueryWriteResult)
    // The SDK's `jl_crc` is native; the Jieli stack uses CRC-16/CCITT-FALSE
    // (poly 0x1021, init 0xFFFF, no reflection). Confirm on-device.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }

    // MARK: helpers
    static func u32be(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    static func u16be(_ v: UInt16) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
}
