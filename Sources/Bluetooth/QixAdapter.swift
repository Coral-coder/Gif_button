import CoreBluetooth
import Foundation

/// Adapter for **Qix-protocol** badges — service `C2E6FD00-E966-1000-8000-
/// BEF9C223DF6A` (write `C2E6FD02`, notify `C2E6FD01`, control `C2E6FD03`).
///
/// The N88 uses THIS protocol, not the Jieli AE00 RCSP service it also advertises
/// (AE00 doesn't answer image commands on this badge). Ported from the ZRun app's
/// `com.qix.library`. This adapter is ordered before the AE00 adapter so a badge
/// exposing both is driven over Qix.
final class QixAdapter: BadgeAdapter {
    let id = "qix"
    let displayName = "Qix badge (N88)"
    let serviceUUID = CBUUID(string: "C2E6FD00-E966-1000-8000-BEF9C223DF6A")
    private let writeUUID = CBUUID(string: "C2E6FD02-E966-1000-8000-BEF9C223DF6A")
    private let notifyUUID = CBUUID(string: "C2E6FD01-E966-1000-8000-BEF9C223DF6A")

    var isSupported: Bool { QixProtocol.isImplemented }

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
        let type: CBCharacteristicWriteType =
            (write?.properties.contains(.writeWithoutResponse) ?? false) ? .withoutResponse : .withResponse
        return (write, notify, type)
    }

    func onConnect() -> [Data] { QixProtocol.onConnect() }
    func handleNotification(_ data: Data) -> BadgeNotificationResult { QixProtocol.handleNotification(data) }
    func encode(_ payload: BadgePayload) throws -> [Data] { try QixProtocol.encode(payload) }
    func reset() { QixProtocol.reset() }
}
