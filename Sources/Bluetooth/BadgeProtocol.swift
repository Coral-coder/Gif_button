import CoreBluetooth
import Foundation

/// Identity + GATT layout of a supported badge, reverse-engineered from the
/// stock "e-Goods" app (see PROTOCOL.md).
struct BadgeDescriptor {
    let displayName: String
    /// Advertised-name prefix used to recognize the badge while scanning.
    let namePrefix: String
    let serviceUUID: CBUUID
    let writeUUID: CBUUID
    let notifyUUID: CBUUID

    static let eGoods = BadgeDescriptor(
        displayName: "DZBJ e-badge",
        namePrefix: "DZBJ-",
        serviceUUID: CBUUID(string: "000001C0-0000-1000-8000-00805F9B34FB"),
        writeUUID: CBUUID(string: "000001C1-0000-1000-8000-00805F9B34FB"),
        notifyUUID: CBUUID(string: "000001C2-0000-1000-8000-00805F9B34FB")
    )
}

/// A still image already encoded as JPEG at the badge's native resolution.
struct EncodedImage {
    let jpeg: Data
    let width: Int
    let height: Int
}

/// One frame of an animation (JPEG) plus how long to show it.
struct EncodedFrame {
    let jpeg: Data
    let durationMs: Int
}

/// A processed animation ready to be packed for the badge.
struct EncodedAnimation {
    let frames: [EncodedFrame]
    let width: Int
    let height: Int
    /// Per-frame delay written into the container header (ms).
    var frameDelayMs: Int
}

enum BadgeError: LocalizedError {
    case notConnected
    case notEnoughSpace
    case encodingFailed
    case emptyAnimation

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect to your badge first."
        case .notEnoughSpace: return "This is too large for the badge's free space."
        case .encodingFailed: return "Couldn't encode the image for the badge."
        case .emptyAnimation: return "There were no frames to send."
        }
    }
}
