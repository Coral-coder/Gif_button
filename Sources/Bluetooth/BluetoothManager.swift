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
    /// Known badges to auto-reconnect to on sight (so you can move between them).
    private var autoConnectSet: Set<UUID> = []
    private var suppressAutoConnect = false

    private var outgoing: [Data] = []
    private var sentCount = 0
    private var sendContinuation: CheckedContinuation<Void, Error>?

    // Windowed-ack transport state (used when the adapter requests it).
    private var winPackets: [Data] = []
    private var winCursor = 0          // next packet index to send
    private var winBatchStart = 0      // first index of the in-flight batch
    private var winBatchSize = 0
    private var winAcks = 0
    private var winRetry = 0
    private var winWindow = 8
    private var winPacketDelayMs = 10
    private var winBatchDelayMs = 30
    /// Bumped on every send start/finish so stale timers/closures no-op.
    private var winGeneration = 0
    /// Bumped on every batch so a completed batch's timeout can't fire late.
    private var winBatchToken = 0
    private var usingWindowedAck = false

    // Paced-stream transport state (no acks; fixed inter-packet gap).
    private var usingPacedStream = false
    private var pacedWaitingForReady = false
    private var pacedPacketDelayMs = 12
    private var pacedTotal = 0

    // Jieli (AE00: E87/L8/N88) interactive request/response upload session.
    private var jieliUploader: JieliUploader?
    /// True when the connected badge uses the interactive Jieli upload path.
    var usesInteractiveUpload: Bool { adapter is AuraCastAdapter }

    private let lastDeviceKey = "lastDeviceID"
    private let knownDevicesKey = "knownBadgeIDs"

    /// Every badge we've successfully connected to (for multi-badge auto-connect).
    private var knownBadgeIDs: Set<UUID> {
        Set((UserDefaults.standard.stringArray(forKey: knownDevicesKey) ?? [])
            .compactMap(UUID.init(uuidString:)))
    }

    /// Record a badge so we'll auto-reconnect to it whenever it's in range. The
    /// most recent one is also stored as the priority (fast-path) device.
    private func rememberBadge(_ id: UUID) {
        var arr = UserDefaults.standard.stringArray(forKey: knownDevicesKey) ?? []
        if !arr.contains(id.uuidString) {
            arr.append(id.uuidString)
            UserDefaults.standard.set(arr, forKey: knownDevicesKey)
        }
        UserDefaults.standard.set(id.uuidString, forKey: lastDeviceKey)
    }

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
        // Remembering happens on a *successful* connection (see isReady), so we
        // never auto-reconnect to something that wasn't actually a usable badge.
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        autoConnectSet = []
        suppressAutoConnect = true // don't immediately reconnect on an intentional disconnect
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    /// Forget the current badge so we stop auto-reconnecting to it (others stay).
    func forgetDevice() {
        if let id = peripheral?.identifier {
            var arr = UserDefaults.standard.stringArray(forKey: knownDevicesKey) ?? []
            arr.removeAll { $0 == id.uuidString }
            UserDefaults.standard.set(arr, forKey: knownDevicesKey)
        }
        UserDefaults.standard.removeObject(forKey: lastDeviceKey)
        autoConnectSet = []
    }

    /// Auto-connect to ANY badge we've used before, as soon as it's in range —
    /// so moving between badges just works. Prefers the most recently used one.
    private func attemptAutoConnect() {
        guard settings.autoConnect, !isConnected, status != .connecting else { return }
        let known = knownBadgeIDs
        guard !known.isEmpty else { return }

        // Fast path: if the most-recent badge is already known to the system and
        // reachable, connect straight to it without scanning.
        if let idString = UserDefaults.standard.string(forKey: lastDeviceKey),
           let last = UUID(uuidString: idString),
           let peripheral = central.retrievePeripherals(withIdentifiers: [last]).first,
           peripheral.state != .disconnected {
            connect(DiscoveredDevice(peripheral: peripheral, name: peripheral.name ?? "Badge",
                                     rssi: 0, isBadge: true))
            return
        }
        // Otherwise scan and connect to whichever known badge appears first.
        autoConnectSet = known
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
                self.sentCount = 0
                self.uploadProgress = 0
                self.status = .sending
                self.sendContinuation = cont
                self.winGeneration &+= 1
                self.usingWindowedAck = false
                self.usingPacedStream = false
                self.pacedWaitingForReady = false

                switch self.adapter.transport {
                case .pacedStream(let packetDelayMs):
                    self.usingPacedStream = true
                    self.outgoing = packets
                    self.pacedTotal = packets.count
                    self.pacedPacketDelayMs = max(0, packetDelayMs)
                    self.dlog("TX upload \(packets.count) pkt(s) [paced-stream \(packetDelayMs)ms]")
                    self.pacedStep(peripheral, writeChar, generation: self.winGeneration)
                case .windowedAck(let window, let packetDelayMs, let batchDelayMs):
                    self.usingWindowedAck = true
                    self.winPackets = packets
                    self.winCursor = 0
                    self.winRetry = 0
                    self.winWindow = max(1, window)
                    self.winPacketDelayMs = max(0, packetDelayMs)
                    self.winBatchDelayMs = max(0, batchDelayMs)
                    self.dlog("TX upload \(packets.count) pkt(s) [windowed-ack w=\(window)]")
                    self.sendWindow(peripheral, writeChar, generation: self.winGeneration)
                case .fireAndForget:
                    self.usingWindowedAck = false
                    self.outgoing = packets
                    self.dlog("TX upload \(packets.count) pkt(s)")
                    self.pump(peripheral, writeChar)
                }
            }
        }
    }

    // MARK: - Windowed-ack sender

    /// Send the next window of fragments, then wait for the badge to ack all of
    /// them (in `didUpdateValueFor`) before advancing. Mirrors the stock BeamBox
    /// BleManager: `window` packets `packetDelayMs` apart, retry a batch on a
    /// fail/timeout (≤3×) from its start, `batchDelayMs` between batches.
    private func sendWindow(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, generation: Int) {
        guard generation == winGeneration, status == .sending else { return }
        if winCursor >= winPackets.count { finishSend(); return }

        winBatchStart = winCursor
        winBatchSize = Swift.min(winWindow, winPackets.count - winCursor)
        winAcks = 0
        winBatchToken &+= 1
        let token = winBatchToken

        for i in 0..<winBatchSize {
            let packet = winPackets[winBatchStart + i]
            let delay = Double(winPacketDelayMs * i) / 1000.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, token == self.winBatchToken, self.status == .sending else { return }
                peripheral.writeValue(packet, for: characteristic, type: .withoutResponse)
            }
        }
        winCursor = winBatchStart + winBatchSize

        // Batch timeout → treat like a fail and retry the batch. The per-batch
        // token ensures a completed batch's timeout can't fire during a later one.
        let timeout = Double(winPacketDelayMs * winBatchSize) / 1000.0 + 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, token == self.winBatchToken,
                  generation == self.winGeneration, self.status == .sending else { return }
            if self.winAcks < self.winBatchSize {
                self.dlog("batch timeout (\(self.winAcks)/\(self.winBatchSize) acked) — retrying")
                self.retryOrFailBatch(peripheral, characteristic, generation: generation)
            }
        }
    }

    /// Called from the notification handler when the badge acks a packet.
    private func windowedAckReceived(_ result: BadgeAckResult) {
        guard usingWindowedAck, status == .sending,
              let peripheral, let writeChar else { return }
        let generation = winGeneration
        switch result {
        case .success:
            winAcks += 1
            let acked = winBatchStart + min(winAcks, winBatchSize)
            uploadProgress = winPackets.isEmpty ? 0 : Double(acked) / Double(winPackets.count)
            // Advance exactly once per batch (guard against duplicate acks).
            if winAcks == winBatchSize {
                winRetry = 0
                if winCursor >= winPackets.count {
                    finishSend()
                } else {
                    let delay = Double(winBatchDelayMs) / 1000.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.sendWindow(peripheral, writeChar, generation: generation)
                    }
                }
            }
        case .fail:
            dlog("batch nack — retrying from pkt \(winBatchStart)")
            retryOrFailBatch(peripheral, writeChar, generation: generation)
        case .none:
            break
        }
    }

    private func retryOrFailBatch(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, generation: Int) {
        guard generation == winGeneration, status == .sending else { return }
        winRetry += 1
        if winRetry >= 3 {
            failSend(BadgeError.badgeUnsupported("badge stopped acknowledging the upload"))
            return
        }
        // Back off between retries, and resend the same batch from its start.
        winBatchDelayMs = winRetry >= 2 ? 120 : 80
        winCursor = winBatchStart
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.sendWindow(peripheral, characteristic, generation: generation)
        }
    }

    // MARK: - Paced-stream sender (no acks)

    /// Write one fragment, then schedule the next after `pacedPacketDelayMs`,
    /// gated by the BLE write-without-response buffer. When all fragments are
    /// out, wait a "tail-protection" delay (so the badge can commit the last
    /// fragments to flash) before declaring success. Mirrors the BeamBox app's
    /// non-ack streaming path.
    private func pacedStep(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, generation: Int) {
        guard generation == winGeneration, status == .sending else { return }

        if outgoing.isEmpty {
            // Tail-protection wait, scaled by packet count (matches the stock app:
            // ~300ms per 1000 packets + 800ms, capped).
            let tailMs = Swift.min((pacedTotal / 1000) * 300 + 800, 8000)
            dlog("all \(pacedTotal) pkt written — tail wait \(tailMs)ms")
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(tailMs) / 1000.0) { [weak self] in
                guard let self, generation == self.winGeneration, self.status == .sending else { return }
                self.finishSend()
            }
            return
        }

        guard peripheral.canSendWriteWithoutResponse else {
            // Resume from peripheralIsReady(...).
            pacedWaitingForReady = true
            return
        }

        peripheral.writeValue(outgoing.removeFirst(), for: characteristic, type: .withoutResponse)
        sentCount += 1
        let planned = sentCount + outgoing.count
        uploadProgress = planned > 0 ? Double(sentCount) / Double(planned) : 0

        DispatchQueue.main.asyncAfter(deadline: .now() + Double(pacedPacketDelayMs) / 1000.0) { [weak self] in
            guard let self else { return }
            self.pacedStep(peripheral, characteristic, generation: generation)
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
        dlog("upload complete (\(max(winCursor, sentCount)) pkt written)")
        winGeneration &+= 1            // invalidate any pending windowed/paced timers
        usingWindowedAck = false
        usingPacedStream = false
        pacedWaitingForReady = false
        winPackets = []
        let cont = sendContinuation
        sendContinuation = nil
        cont?.resume()
        flushPendingReply()
    }

    /// Encode content into wire packets using the active (auto-detected) adapter.
    func encodePackets(_ payload: BadgePayload) throws -> [Data] {
        try adapter.encode(payload)
    }

    /// Interactive Jieli (AE00) upload: push `bgBytes` as a custom dial background
    /// via the RCSP request/response sequence. Separate from `transmit` so the
    /// one-shot DZBJ/BeamBox paths are untouched.
    @MainActor
    func uploadJieliBytes(_ bgBytes: [UInt8]) async throws {
        guard isConnected, let peripheral, let writeChar else { throw BadgeError.notConnected }
        guard (adapter as? AuraCastAdapter)?.authenticated == true else {
            throw BadgeError.badgeUnsupported("Jieli badge not authenticated yet — reconnect and retry")
        }
        guard jieliUploader == nil, status != .sending else { throw BadgeError.busy }

        let wType = writeType
        let maxWrite = peripheral.maximumWriteValueLength(for: wType)
        let uploader = JieliUploader(
            maxWrite: maxWrite,
            send: { [weak self] data in
                guard let self, let p = self.peripheral, let w = self.writeChar else { return }
                p.writeValue(data, for: w, type: wType)
            },
            dlog: { [weak self] s in self?.dlog(s) })
        jieliUploader = uploader
        status = .sending
        uploadProgress = 0
        defer {
            jieliUploader = nil
            status = isConnected ? .connected : .disconnected
        }
        try await uploader.upload(bgBytes: bgBytes, progress: { [weak self] p in
            self?.uploadProgress = p
        })
        uploadProgress = 1
        lastMessage = "Sent."
    }

    private func failSend(_ error: Error) {
        outgoing.removeAll()
        winGeneration &+= 1            // invalidate any pending windowed/paced timers
        usingWindowedAck = false
        usingPacedStream = false
        pacedWaitingForReady = false
        winPackets = []
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

        // Auto-connect to any known badge as soon as it appears in range.
        if autoConnectSet.contains(peripheral.identifier) {
            autoConnectSet = []
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
        jieliUploader?.cancel()
        jieliUploader = nil
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
        if let writeChar, !isReady {
            // Size fragments to the negotiated MTU so large frames aren't dropped
            // (iOS can't request an MTU; write-without-response silently truncates
            // over-long writes). The badge reassembles fragments by concatenation,
            // so a smaller fragment is protocol-safe.
            let maxWrite = peripheral.maximumWriteValueLength(for: writeType)
            BadgeTransport.maxDataLen = BadgeTransport.dataLen(forMaxWrite: maxWrite)
            dlog("maxWrite=\(maxWrite)B → fragment payload=\(BadgeTransport.maxDataLen)B")
            isReady = true
            // Now that it's a confirmed, usable badge, remember it so we'll
            // auto-reconnect whenever it's in range (multi-badge support).
            rememberBadge(peripheral.identifier)
            lastMessage = adapter.isSupported
                ? "Ready."
                : "\(adapter.displayName) detected — sending isn't supported yet."
            dlog("ready: write=\(writeChar.uuid.uuidString) notify=\(notifyChar?.uuid.uuidString ?? "?") type=\(writeType == .withResponse ? "resp" : "noResp")")
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

        // Jieli interactive upload: feed responses to the running session.
        jieliUploader?.handleNotification(data)

        // Windowed-ack transport: advance the upload when the badge acks packets.
        if usingWindowedAck, status == .sending {
            let ack = adapter.ackResult(data)
            if ack != .none { windowedAckReceived(ack) }
        }

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
        if usingPacedStream {
            if pacedWaitingForReady {
                pacedWaitingForReady = false
                pacedStep(peripheral, writeChar, generation: winGeneration)
            }
            return
        }
        // Windowed-ack delivery drives its own writes; only the fire-and-forget
        // pump resumes here.
        guard !usingWindowedAck else { return }
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
