import CoreBluetooth
import Foundation

/// Adapter for BeamBox badges (`com.guangshen.beambox`) — service 000001F0,
/// write 000001F1 (writeNoResponse), notify 000001F2.
///
/// The protocol (framing / handshake / image format) is ported from the BeamBox
/// app decompile — see `encode`. Until that lands, detection is exact so the app
/// labels the badge correctly instead of feeding it the wrong protocol.
final class BeamBoxAdapter: BadgeAdapter {
    let id = "beambox"
    let displayName = "BeamBox badge"
    let serviceUUID = CBUUID(string: "000001F0-0000-1000-8000-00805F9B34FB")
    private let writeUUID = CBUUID(string: "000001F1-0000-1000-8000-00805F9B34FB")
    private let notifyUUID = CBUUID(string: "000001F2-0000-1000-8000-00805F9B34FB")

    // Flip to true once encode() is filled in from the decompile.
    var isSupported: Bool { BeamBoxProtocol.isImplemented }

    func matches(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        serviceUUIDs.contains(serviceUUID)
    }

    func selectCharacteristics(_ chars: [CBCharacteristic])
        -> (write: CBCharacteristic?, notify: CBCharacteristic?, writeType: CBCharacteristicWriteType) {
        let write = chars.first { $0.uuid == writeUUID }
            ?? chars.first { $0.properties.contains(.writeWithoutResponse) }
            ?? chars.first { $0.properties.contains(.write) }
        let notify = chars.first { $0.uuid == notifyUUID }
            ?? chars.first { $0.properties.contains(.notify) }
            ?? chars.first { $0.properties.contains(.indicate) }
        let type: CBCharacteristicWriteType =
            (write?.properties.contains(.write) ?? false) ? .withResponse : .withoutResponse
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

/// BeamBox wire protocol. Filled in from the app decompile (`beambox-findings`).
enum BeamBoxProtocol {
    /// Set true once the encode path is implemented + validated.
    static var isImplemented = false

    static func onConnect() -> [Data] { [] }
    static func handleNotification(_ data: Data) -> BadgeNotificationResult { BadgeNotificationResult() }
    static func reset() {}

    static func encode(_ payload: BadgePayload) throws -> [Data] {
        throw BadgeError.badgeUnsupported("BeamBox badge")
    }
}
