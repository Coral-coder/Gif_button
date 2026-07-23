import CoreBluetooth
import Foundation

/// Device-agnostic content to send. Encoding to wire packets is the adapter's
/// job, so a job can be queued before we know which badge we'll talk to.
enum BadgePayload {
    case still(EncodedImage)
    case animation(EncodedAnimation)
}

/// What to do in response to a device notification during handshake/transfer.
struct BadgeNotificationResult {
    var reply: [Data] = []
    var freeSpaceKB: Int?
}

/// One badge family's protocol. GifCast auto-detects which adapter matches the
/// connected device (by advertised service UUID / name) and routes through it,
/// so different badges "just work".
protocol BadgeAdapter: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var serviceUUID: CBUUID { get }
    var isSupported: Bool { get } // false = detected but upload not implemented yet

    /// Does this adapter handle a device with these advertised/discovered
    /// services or name?
    func matches(name: String?, serviceUUIDs: [CBUUID]) -> Bool

    /// Pick the write/notify characteristics (and write type) from a service's
    /// characteristics.
    func selectCharacteristics(_ chars: [CBCharacteristic])
        -> (write: CBCharacteristic?, notify: CBCharacteristic?, writeType: CBCharacteristicWriteType)

    /// Packets to send right after the notify channel is enabled (handshake).
    func onConnect() -> [Data]

    /// Handle an incoming notification (handshake replies, acks, status).
    func handleNotification(_ data: Data) -> BadgeNotificationResult

    /// Encode content into write packets.
    func encode(_ payload: BadgePayload) throws -> [Data]

    /// Reset per-connection state.
    func reset()
}

// MARK: - Registry / detection

enum BadgeRegistry {
    /// Order matters: first match wins. e-Goods is the default fallback.
    static func makeAdapters() -> [BadgeAdapter] {
        [EGoodsAdapter(), AuraCastAdapter()]
    }

    /// Any name prefix used to flag "this looks like a badge" while scanning.
    static let scanNamePrefixes = ["DZBJ-"]

    static func detect(name: String?, serviceUUIDs: [CBUUID], from adapters: [BadgeAdapter]) -> BadgeAdapter {
        adapters.first { $0.matches(name: name, serviceUUIDs: serviceUUIDs) } ?? adapters[0]
    }
}

// MARK: - e-Goods (DZBJ) adapter — fully implemented

final class EGoodsAdapter: BadgeAdapter {
    let id = "e-goods"
    let displayName = "DZBJ badge"
    let serviceUUID = BadgeDescriptor.eGoods.serviceUUID
    let isSupported = true

    private let descriptor = BadgeDescriptor.eGoods
    private var didVerify = false

    func matches(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        if serviceUUIDs.contains(serviceUUID) { return true }
        if let name, name.uppercased().hasPrefix(descriptor.namePrefix.uppercased()) { return true }
        return false
    }

    func selectCharacteristics(_ chars: [CBCharacteristic])
        -> (write: CBCharacteristic?, notify: CBCharacteristic?, writeType: CBCharacteristicWriteType) {
        let write = chars.first { $0.uuid == descriptor.writeUUID }
            ?? chars.first { $0.properties.contains(.write) }
            ?? chars.first { $0.properties.contains(.writeWithoutResponse) }
        let notify = chars.first { $0.uuid == descriptor.notifyUUID }
            ?? chars.first { $0.properties.contains(.notify) }
            ?? chars.first { $0.properties.contains(.indicate) }
        let type: CBCharacteristicWriteType =
            (write?.properties.contains(.write) ?? false) ? .withResponse : .withoutResponse
        return (write, notify, type)
    }

    func onConnect() -> [Data] {
        // Prompt the badge so it sends its status frame (freespace + ADD
        // challenge). Some units stay silent until queried.
        [EGoodsProtocol.activationQuery(), EGoodsProtocol.versionQuery()].compactMap { $0 }
    }

    func handleNotification(_ data: Data) -> BadgeNotificationResult {
        var result = BadgeNotificationResult()
        guard let json = EGoodsProtocol.extractStatusJSON(data) else { return result }
        result.freeSpaceKB = json["freespace"] as? Int
        if !didVerify, let add = json["ADD"], !(add is NSNull) {
            if let addArray = add as? [Any], addArray.isEmpty { return result }
            if let pkt = EGoodsProtocol.deviceIdVerification(ret: add) {
                result.reply = [pkt]
                didVerify = true
            }
        }
        return result
    }

    func encode(_ payload: BadgePayload) throws -> [Data] {
        switch payload {
        case .still(let image): return EGoodsProtocol.packStillImage(image)
        case .animation(let animation):
            guard !animation.frames.isEmpty else { throw BadgeError.emptyAnimation }
            return EGoodsProtocol.packAnimation(animation)
        }
    }

    func reset() { didVerify = false }
}
