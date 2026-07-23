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
    /// Auto-detected badge family (nil until services are discovered).
    @Published private(set) var detectedBadgeName: String?
    /// False when the connected badge is recognized but not yet supported.
    @Published private(set) var badgeSupported = true
    /// True once we're connected AND the write characteristic is discovered.
    @Published private(set) var isReady = false
    @Published var isScanning = false
    @Published var lastMessage: String?
    @Published private(set) var uploadProgress: Double = 0
    /// Rolling debug log (newest last) surfaced on the Badge tab for diagnosing.
    @Published private(set) var debugLog: [String] = []

    private func dlog(_ s: String) {
        debugLog.append(s)
        if debugLog.count > 80 { debugLog.removeFirst(debugLog.count - 80) }
    }

    private static func hexPreview(_ data: Data, _ maxBytes: Int = 20) -> String {
        data.prefix(maxBytes).map { String(format: "%02x", $0) }.joined(separator: " ")
            + (data.count > maxBytes ? " …(\(data.count)B)" : "")
    }

    private let settings: AppSettings
    /// Known badge protocols; the right one is auto-selected on connect.
    private let adapters = BadgeRegistry.makeAdapters()
    private lazy var adapter: BadgeAdapter = adapters[0]
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse
    private var notifyChar: CBCharacteristic?
    private var pendingReply: [Data] = []
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
        adapters.forEach { $0.reset() }
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
                                          name: known.name ?? "Badge",
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
                self.dlog("TX upload \(packets.count) pkt(s)")
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
        dlog("upload complete (\(sentCount) pkt written)")
        let cont = sendContinuation
        sendContinuation = nil
        cont?.resume()
        flushPendingReply()
    }

    /// Encode content into wire packets using the active (auto-detected) adapter.
    func encodePackets(_ payload: BadgePayload) throws -> [Data] {
        try adapter.encode(payload)
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

    private func flushPendingReply() {
        guard !pendingReply.isEmpty else { return }
        let reply = pendingReply
        pendingReply = []
        for packet in reply { sendControl(packet) }
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
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isBadge = adapters.contains { $0.matches(name: name, serviceUUIDs: advServices) }
            || BadgeRegistry.scanNamePrefixes.contains { name.uppercased().hasPrefix($0.uppercased()) }
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
        connectedName = peripheral.name ?? "Badge"
        detectedBadgeName = nil
        badgeSupported = true
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
        detectedBadgeName = nil
        writeChar = nil
        notifyChar = nil
        pendingReply = []
        adapters.forEach { $0.reset() }
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
        // Auto-detect which badge protocol this device speaks.
        let serviceUUIDs = (peripheral.services ?? []).map { $0.uuid }
        adapter = BadgeRegistry.detect(name: peripheral.name, serviceUUIDs: serviceUUIDs, from: adapters)
        detectedBadgeName = adapter.displayName
        badgeSupported = adapter.isSupported
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

        // Prefer the detected adapter's own service for write/notify; but fall
        // back to ANY writable/notify characteristic so we stay robust to
        // devices whose characteristics live under a different service.
        if service.uuid == adapter.serviceUUID {
            let selection = adapter.selectCharacteristics(chars)
            if let w = selection.write { writeChar = w; writeType = selection.writeType }
            if let n = selection.notify { notifyChar = n }
        } else {
            if writeChar == nil,
               let w = chars.first(where: { $0.properties.contains(.write) })
                    ?? chars.first(where: { $0.properties.contains(.writeWithoutResponse) }) {
                writeChar = w
                writeType = w.properties.contains(.write) ? .withResponse : .withoutResponse
            }
            if notifyChar == nil {
                notifyChar = chars.first { $0.properties.contains(.notify) }
                    ?? chars.first { $0.properties.contains(.indicate) }
            }
        }

        if let notifyChar {
            peripheral.setNotifyValue(true, for: notifyChar)
        }
        if writeChar != nil, !isReady {
            isReady = true
            lastMessage = adapter.isSupported
                ? "Ready."
                : "\(adapter.displayName) detected — sending isn't supported yet."
            dlog("ready: write=\(writeChar?.uuid.uuidString ?? "?") notify=\(notifyChar?.uuid.uuidString ?? "?") type=\(writeType == .withResponse ? "resp" : "noResp")")
            // Kick off the adapter's handshake, if any.
            let initPackets = adapter.onConnect()
            if !initPackets.isEmpty { dlog("TX onConnect \(initPackets.count) pkt(s)") }
            for packet in initPackets { sendControl(packet) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        dlog("RX \(Self.hexPreview(data))")
        let result = adapter.handleNotification(data)
        if let space = result.freeSpaceKB { freeSpaceKB = space; dlog("freespace=\(space)KB") }
        guard !result.reply.isEmpty else { return }
        dlog("TX reply \(result.reply.count) pkt(s)")
        // Never inject a control write mid-upload (it would corrupt the stream) —
        // defer any handshake reply until the current transmit finishes.
        if status == .sending {
            pendingReply.append(contentsOf: result.reply)
        } else {
            for packet in result.reply { sendControl(packet) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastMessage = "Write failed: \(error.localizedDescription)"
            dlog("write ERR: \(error.localizedDescription)")
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
