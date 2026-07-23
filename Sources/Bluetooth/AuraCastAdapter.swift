import CoreBluetooth
import Foundation

/// Adapter for AuraCast-style badges (E87 / L8, Jieli BR23). Reverse-engineering
/// credit: AuraCast (github.com/Manaiakalani/auracast, MIT © Felix Herbst).
///
/// Confirmed via the ZRun app decompile: these badges use the **Jieli RCSP SDK**
/// (com.jieli.jl_rcsp / jl_bt_ota) over service 0000AE00 (write AE01, notify
/// AE02). Full support means porting the Jieli RCSP subset — auth handshake +
/// windowed file transfer — which is a sizable effort and needs on-device
/// testing. (ZRun also drives a second "Qix" badge family on service
/// C2E6FD00 — a future third adapter.)
///
/// This is a **detection + framing scaffold**. The building blocks below
/// (service/characteristics, FE framing, CRC-16/XMODEM, opcodes) are transcribed
/// from AuraCast's PROTOCOL.md, but two pieces still need porting from their
/// source and verifying on a real E87/L8:
///   1. The crypto handshake (Jieli block cipher, static key) that must run on
///      AE01/AE02 before any FE-framed command.
///   2. The windowed upload transfer (8-frame windows gated by 0x1D acks).
/// Until then `isSupported` is false: the app will *recognize* the badge and say
/// so, rather than sending packets that won't work.
final class AuraCastAdapter: BadgeAdapter {
    let id = "jieli-ae00"
    let displayName = "Jieli badge (E87/L8/N88)"
    let serviceUUID = CBUUID(string: "0000AE00-0000-1000-8000-00805F9B34FB")
    // Auth is ported; the custom-dial-bg upload (Jieli RCSP external-flash file
    // transfer) is mapped in docs/PROTOCOL.md but not yet implemented/verified.
    let isSupported = false

    private let writeUUID = CBUUID(string: "0000AE01-0000-1000-8000-00805F9B34FB")   // WriteNoResponse
    private let notifyUUID = CBUUID(string: "0000AE02-0000-1000-8000-00805F9B34FB")

    /// Static 16-byte Jieli key from AuraCast's PROTOCOL.md (for the handshake, TODO).
    static let jieliKey: [UInt8] = [
        0x6B, 0xE9, 0xB2, 0xC0, 0x83, 0xD9, 0x4A, 0x1E,
        0x5A, 0xF8, 0x9C, 0x4E, 0x7B, 0x6D, 0x3F, 0x20,
    ]

    enum Opcode: UInt8 {
        case resetAuth = 0x06
        case deviceInfo = 0x03
        case beginUpload = 0x21
        case metadata = 0x1B
        case dataFrame = 0x01
        case windowAck = 0x1D
        case uploadComplete = 0x20
        case finalize = 0x1C
    }
    static let flagCommand: UInt8 = 0xC0
    static let flagResponse: UInt8 = 0x00
    static let flagData: UInt8 = 0x80

    func matches(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        serviceUUIDs.contains(serviceUUID)
    }

    func selectCharacteristics(_ chars: [CBCharacteristic])
        -> (write: CBCharacteristic?, notify: CBCharacteristic?, writeType: CBCharacteristicWriteType) {
        let write = chars.first { $0.uuid == writeUUID }
            ?? chars.first { $0.properties.contains(.writeWithoutResponse) }
        let notify = chars.first { $0.uuid == notifyUUID }
            ?? chars.first { $0.properties.contains(.notify) }
        return (write, notify, .withoutResponse)
    }

    // MARK: - Jieli RCSP auth handshake (ported + verified; see JieliAuth)

    private enum AuthStep { case idle, awaitingResponse, awaitingChallenge, awaitingConfirm, authed }
    private var authStep: AuthStep = .idle
    private(set) var authenticated = false

    func onConnect() -> [Data] {
        authenticated = false
        authStep = .awaitingResponse
        // Kick off the handshake: TX [0x00, rand×16] (raw on AE01).
        return [Data(JieliAuth.randomAuthData())]
    }

    func handleNotification(_ data: Data) -> BadgeNotificationResult {
        var result = BadgeNotificationResult()
        let b = [UInt8](data)
        switch authStep {
        case .awaitingResponse:
            // Device replies [0x01, enc×16]; we answer [0x02,"pass"].
            if b.count == 17, b[0] == 0x01 {
                result.reply = [Data([0x02, 0x70, 0x61, 0x73, 0x73])]
                authStep = .awaitingChallenge
            }
        case .awaitingChallenge:
            // Device sends [0x00, challenge×16]; we return the encrypted response.
            if b.count == 17, b[0] == 0x00 {
                result.reply = [Data(JieliAuth.encryptedAuthData(b))]
                authStep = .awaitingConfirm
            }
        case .awaitingConfirm:
            // Device confirms [0x02,"pass"].
            if b.count >= 5, b[0] == 0x02, b[1] == 0x70, b[2] == 0x61, b[3] == 0x73, b[4] == 0x73 {
                authenticated = true
                authStep = .authed
            }
        case .idle, .authed:
            break
        }
        return result
    }

    func encode(_ payload: BadgePayload) throws -> [Data] {
        // Auth is implemented + verified. The remaining piece is the interactive
        // windowed file transfer (MJPG AVI over FE frames, gated by 0x1D acks),
        // which needs the manager's interactive-session support and on-device
        // validation. See PROTOCOL notes.
        throw BadgeError.badgeUnsupported(displayName)
    }

    func reset() {
        authenticated = false
        authStep = .idle
    }

    // MARK: - Framing building blocks (verified layout, ready for the transfer impl)

    /// `FE DC BA [flag] [cmd] [len_BE16] [body] EF`
    static func frame(flag: UInt8, cmd: Opcode, body: [UInt8]) -> [UInt8] {
        var f: [UInt8] = [0xFE, 0xDC, 0xBA, flag, cmd.rawValue,
                          UInt8((body.count >> 8) & 0xFF), UInt8(body.count & 0xFF)]
        f.append(contentsOf: body)
        f.append(0xEF)
        return f
    }

    /// CRC-16/XMODEM (poly 0x1021, init 0x0000), big-endian in the frame.
    static func crc16xmodem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x0000
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : (crc << 1)
            }
        }
        return crc
    }
}
