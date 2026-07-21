import CoreBluetooth
import Foundation

/// A Bluetooth peripheral we discovered while scanning.
struct DiscoveredDevice: Identifiable {
    let peripheral: CBPeripheral
    let name: String
    let rssi: Int
    let isBadge: Bool
    var id: UUID { peripheral.identifier }
}

/// A read-only snapshot of the connected device's GATT table (handy for RE).
struct GATTService: Identifiable {
    let uuid: String
    var characteristics: [GATTCharacteristic]
    var id: String { uuid }
}

struct GATTCharacteristic: Identifiable {
    let uuid: String
    let properties: [String]
    var id: String { uuid }
}

enum ConnectionStatus: Equatable {
    case idle, connecting, connected, sending, disconnected
}

/// Owns the CoreBluetooth stack: scanning, connecting, GATT discovery, the
/// device-id handshake, and streaming encoded packets to the badge.
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var services: [GATTService] = []
    @Published private(set) var status: ConnectionStatus = .idle
    @Published private(set) var freeSpaceKB: Int?
    @Published var isScanning = false
    @Published var lastMessage: String?
    /// 0…1 while an upload is in progress.
    @Published private(set) var uploadProgress: Double = 0

    private let descriptor = BadgeDescriptor.eGoods
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var didVerify = false

    private var outgoing: [Data] = []
    private var sentCount = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool { peripheral?.state == .connected && writeChar != nil }

    // MARK: - Scanning

    func startScan() {
        guard central.state == .poweredOn else {
            lastMessage = "Turn on Bluetooth to scan."
            return
        }
        discovered.removeAll()
        isScanning = true
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    // MARK: - Connection

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        status = .connecting
        didVerify = false
        peripheral = device.peripheral
        device.peripheral.delegate = self
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Public send API

    func sendStillImage(_ image: EncodedImage) throws {
        try enqueue(EGoodsProtocol.packStillImage(image))
    }

    func sendAnimation(_ animation: EncodedAnimation, name: String = "gif") throws {
        guard !animation.frames.isEmpty else { throw BadgeError.emptyAnimation }
        try enqueue(EGoodsProtocol.packAnimation(animation, name: name))
    }

    func sendMarquee(container: [UInt8], width: Int, height: Int, display: Int, number: Int) throws {
        var packets: [Data] = []
        if let info = EGoodsProtocol.marqueeInfo(width: width, height: height, display: display, number: number) {
            packets.append(info)
        }
        packets.append(contentsOf: EGoodsProtocol.marqueeData(container: container))
        try enqueue(packets)
    }

    private func enqueue(_ packets: [Data]) throws {
        guard let peripheral, let writeChar, peripheral.state == .connected else {
            throw BadgeError.notConnected
        }
        outgoing = packets
        sentCount = 0
        uploadProgress = 0
        status = .sending
        writeNext(peripheral, writeChar)
    }

    private func writeNext(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        guard !outgoing.isEmpty else {
            status = .connected
            uploadProgress = 1
            lastMessage = "Sent."
            return
        }
        let packet = outgoing.removeFirst()
        // iOS negotiates the MTU automatically; write-with-response gives us
        // natural flow control (the next write waits for didWrite).
        peripheral.writeValue(packet, for: characteristic, type: .withResponse)
    }

    private func sendControl(_ data: Data?) {
        guard let data, let peripheral, let writeChar, peripheral.state == .connected else { return }
        peripheral.writeValue(data, for: writeChar, type: .withResponse)
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state != .poweredOn { isScanning = false }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? "Unknown device"
        let isBadge = name.uppercased().hasPrefix(descriptor.namePrefix.uppercased())
        let device = DiscoveredDevice(peripheral: peripheral, name: name, rssi: RSSI.intValue, isBadge: isBadge)
        if let idx = discovered.firstIndex(where: { $0.id == device.id }) {
            discovered[idx] = device
        } else {
            discovered.append(device)
        }
        // Show badges first, then by signal strength.
        discovered.sort { ($0.isBadge ? 1 : 0, $0.rssi) > ($1.isBadge ? 1 : 0, $1.rssi) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = .connected
        connectedName = peripheral.name ?? descriptor.displayName
        services = []
        writeChar = nil
        notifyChar = nil
        peripheral.discoverServices(nil) // discover all (also useful for RE)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = .disconnected
        lastMessage = "Couldn't connect: \(error?.localizedDescription ?? "unknown error")."
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = .disconnected
        connectedName = nil
        writeChar = nil
        notifyChar = nil
        didVerify = false
        services = []
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for service in peripheral.services ?? [] {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []

        // Record for the GATT viewer.
        let infos = chars.map { GATTCharacteristic(uuid: $0.uuid.uuidString,
                                                   properties: Self.describe($0.properties)) }
        let record = GATTService(uuid: service.uuid.uuidString, characteristics: infos)
        if let idx = services.firstIndex(where: { $0.uuid == record.uuid }) {
            services[idx] = record
        } else {
            services.append(record)
        }

        // Prefer the badge's known write/notify characteristics; fall back to
        // the first characteristic advertising the right property.
        for c in chars {
            if c.uuid == descriptor.writeUUID { writeChar = c }
            if c.uuid == descriptor.notifyUUID { notifyChar = c }
        }
        if writeChar == nil {
            writeChar = chars.first { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }
        }
        if notifyChar == nil {
            notifyChar = chars.first { $0.properties.contains(.notify) }
        }
        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
        if writeChar != nil {
            lastMessage = "Ready."
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        guard let json = EGoodsProtocol.extractStatusJSON(data) else { return }

        if let space = json["freespace"] as? Int { freeSpaceKB = space }

        // Device-id handshake: the badge sends an `ADD` challenge; the stock app
        // echoes it back in a type-14 verification. Do the same, once.
        if !didVerify, let add = json["ADD"], !(add is NSNull) {
            if let addArray = add as? [Any], addArray.isEmpty { return }
            sendControl(EGoodsProtocol.deviceIdVerification(ret: add))
            didVerify = true
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastMessage = "Write failed: \(error.localizedDescription)"
            status = .connected
            outgoing.removeAll()
            return
        }
        // Only advance the upload queue for data writes (not control writes).
        guard status == .sending else { return }
        sentCount += 1
        let totalPlanned = sentCount + outgoing.count
        uploadProgress = totalPlanned > 0 ? Double(sentCount) / Double(totalPlanned) : 0
        writeNext(peripheral, characteristic)
    }

    private static func describe(_ p: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if p.contains(.read) { names.append("read") }
        if p.contains(.write) { names.append("write") }
        if p.contains(.writeWithoutResponse) { names.append("writeNoResp") }
        if p.contains(.notify) { names.append("notify") }
        if p.contains(.indicate) { names.append("indicate") }
        return names
    }
}
