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

/// Owns the CoreBluetooth stack: scanning, (auto)connecting, GATT discovery,
/// the device-id handshake, and streaming encoded packets to the badge via an
/// async `transmit(_:)` the send queue can await one job at a time.
///
/// The central is created with `queue: .main`, so every delegate callback and
/// published mutation happens on the main thread. `transmit(_:)` hops to the
/// main actor so its setup runs there too.
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var connectedName: String?
    @Published private(set) var services: [GATTService] = []
    @Published private(set) var status: ConnectionStatus = .idle
    @Published private(set) var freeSpaceKB: Int?
    /// True once we're connected AND the write characteristic is discovered.
    @Published private(set) var isReady = false
    @Published var isScanning = false
    @Published var lastMessage: String?
    @Published private(set) var uploadProgress: Double = 0

    private let settings: AppSettings
    private let descriptor = BadgeDescriptor.eGoods
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var notifyChar: CBCharacteristic?
    private var didVerify = false
    private var pendingVerify: Any?
    private var autoConnectTarget: UUID?
    private var suppressAutoConnect = false

    private var outgoing: [Data] = []
    private var sentCount = 0
    private var sendContinuation: CheckedContinuation<Void, Error>?

    private let lastDeviceKey = "lastDeviceID"

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isConnected: Bool { isReady && peripheral?.state == .connected }

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
        suppressAutoConnect = false
        peripheral = device.peripheral
        device.peripheral.delegate = self
        UserDefaults.standard.set(device.peripheral.identifier.uuidString, forKey: lastDeviceKey)
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        autoConnectTarget = nil
        suppressAutoConnect = true // don't immediately reconnect on an intentional disconnect
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// Forget the saved device so we stop auto-reconnecting to it.
    func forgetDevice() {
        UserDefaults.standard.removeObject(forKey: lastDeviceKey)
        autoConnectTarget = nil
    }

    private func attemptAutoConnect() {
        guard settings.autoConnect, !isConnected, status != .connecting,
              let idString = UserDefaults.standard.string(forKey: lastDeviceKey),
              let uuid = UUID(uuidString: idString) else { return }

        // Fast path: retrieve the known peripheral and connect directly.
        if let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            let device = DiscoveredDevice(peripheral: known,
                                          name: known.name ?? descriptor.displayName,
                                          rssi: 0, isBadge: true)
            connect(device)
            return
        }
        // Fallback: scan and connect when the saved device appears.
        autoConnectTarget = uuid
        startScan()
    }

    // MARK: - Transmit (async, one job at a time)

    func transmit(_ packets: [Data]) async throws {
        // Run setup on the main actor so `@Published` mutations and the write
        // pump stay on the main thread (where the CB delegate also runs).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task { @MainActor in
                guard self.isConnected, let peripheral = self.peripheral, let writeChar = self.writeChar else {
                    cont.resume(throwing: BadgeError.notConnected); return
                }
                guard self.sendContinuation == nil, self.status != .sending else {
                    cont.resume(throwing: BadgeError.busy); return
                }
                self.outgoing = packets
                self.sentCount = 0
                self.uploadProgress = 0
                self.status = .sending
                self.sendContinuation = cont
                self.pump(peripheral, writeChar)
            }
        }
    }

    /// Drive the queue. Write-with-response waits for each `didWrite`;
    /// write-without-response pumps only while `canSendWriteWithoutResponse`
    /// allows and resumes from `peripheralIsReady(...)`. Without that gate the
    /// controller buffer overflows and fragments are silently dropped.
    private func pump(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        if writeType == .withoutResponse {
            while !outgoing.isEmpty {
                guard peripheral.canSendWriteWithoutResponse else { return }
                peripheral.writeValue(outgoing.removeFirst(), for: characteristic, type: .withoutResponse)
                bumpProgress()
            }
            finishSend()
        } else {
            guard !outgoing.isEmpty else { finishSend(); return }
            peripheral.writeValue(outgoing.removeFirst(), for: characteristic, type: .withResponse)
            // Next write in didWriteValueFor.
        }
    }

    private func bumpProgress() {
        sentCount += 1
        let planned = sentCount + outgoing.count
        uploadProgress = planned > 0 ? Double(sentCount) / Double(planned) : 0
    }

    private func finishSend() {
        status = .connected
        uploadProgress = 1
        lastMessage = "Sent."
        let cont = sendContinuation
        sendContinuation = nil
        cont?.resume()
        flushPendingVerify()
    }

    private func failSend(_ error: Error) {
        outgoing.removeAll()
        status = isConnected ? .connected : .disconnected
        let cont = sendContinuation
        sendContinuation = nil
        cont?.resume(throwing: error)
    }

    private func sendControl(_ data: Data?) {
        guard let data, let peripheral, let writeChar, peripheral.state == .connected else { return }
        peripheral.writeValue(data, for: writeChar, type: writeType)
    }

    private func flushPendingVerify() {
        guard !didVerify, let value = pendingVerify else { return }
        pendingVerify = nil
        sendControl(EGoodsProtocol.deviceIdVerification(ret: value))
        didVerify = true
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        if central.state == .poweredOn {
            attemptAutoConnect()
        } else {
            isScanning = false
            isReady = false
        }
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
        discovered.sort { ($0.isBadge ? 1 : 0, $0.rssi) > ($1.isBadge ? 1 : 0, $1.rssi) }

        // Auto-connect when the saved device shows up.
        if let target = autoConnectTarget, peripheral.identifier == target {
            autoConnectTarget = nil
            connect(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = .connected
        connectedName = peripheral.name ?? descriptor.displayName
        services = []
        writeChar = nil
        notifyChar = nil
        isReady = false
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = .disconnected
        isReady = false
        lastMessage = "Couldn't connect: \(error?.localizedDescription ?? "unknown error")."
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = .disconnected
        connectedName = nil
        writeChar = nil
        notifyChar = nil
        didVerify = false
        pendingVerify = nil
        isReady = false
        services = []
        if sendContinuation != nil { failSend(BadgeError.notConnected) }
        if suppressAutoConnect {
            suppressAutoConnect = false
        } else {
            attemptAutoConnect()
        }
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

        // Choose characteristics by PROPERTY, not UUID — a characteristic's role
        // is defined by its properties. Prefer the badge's own service, then any.
        func pickWrite(_ list: [CBCharacteristic]) -> CBCharacteristic? {
            list.first { $0.properties.contains(.write) }
                ?? list.first { $0.properties.contains(.writeWithoutResponse) }
        }
        func pickNotify(_ list: [CBCharacteristic]) -> CBCharacteristic? {
            list.first { $0.properties.contains(.notify) }
                ?? list.first { $0.properties.contains(.indicate) }
        }

        if service.uuid == descriptor.serviceUUID {
            if let w = pickWrite(chars) { writeChar = w }
            if let n = pickNotify(chars) { notifyChar = n }
        } else {
            if writeChar == nil { writeChar = pickWrite(chars) }
            if notifyChar == nil { notifyChar = pickNotify(chars) }
        }

        if let writeChar {
            writeType = writeChar.properties.contains(.write) ? .withResponse : .withoutResponse
            isReady = true
            lastMessage = "Ready."
        }
        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let json = EGoodsProtocol.extractStatusJSON(data) else { return }

        if let space = json["freespace"] as? Int { freeSpaceKB = space }

        // Device-id handshake: echo the badge's `ADD` challenge back once. Never
        // inject a control write mid-upload (it would corrupt the fragment
        // stream) — defer it until the current transmit finishes.
        if !didVerify, let add = json["ADD"], !(add is NSNull) {
            if let addArray = add as? [Any], addArray.isEmpty { return }
            if status == .sending {
                pendingVerify = add
            } else {
                sendControl(EGoodsProtocol.deviceIdVerification(ret: add))
                didVerify = true
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastMessage = "Write failed: \(error.localizedDescription)"
            failSend(error)
            return
        }
        guard status == .sending, writeType == .withResponse else { return }
        bumpProgress()
        pump(peripheral, characteristic)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard status == .sending, let writeChar else { return }
        pump(peripheral, writeChar)
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
