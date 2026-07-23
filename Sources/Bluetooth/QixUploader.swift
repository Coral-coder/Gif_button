import CoreBluetooth
import Foundation

/// Drives the interactive **Qix dial-push** upload for the N88 (service C2E6FD00).
/// Ported byte-for-byte from the ZRun app's `com.qix.library.sdk.UpdateManager`:
/// the dial blob (built by `QixProtocol.buildDialFile`) is streamed over the same
/// OTA "update" channel the watch app uses for firmware/dial pushes.
///
/// Sequence:
///   TX 0xC0 (REQ_UPDATE) + 27-byte fileHeader   → RX 0xC1 {status, allowLen, offset}
///   loop: TX 0xC2 [len|offset|chunk]            → RX 0xC3 {status, nextOffset}
///   TX 0xC4 (REQ_UPDATE_CON){3}                 → RX 0xC5 {status: 0 = success}
///
/// The device flow-controls the whole thing: 0xC1 grants `allowLen` bytes per
/// package and each 0xC3 echoes the next offset. We honour both. Each logical
/// frame is handed to `send` whole — `BluetoothManager` fragments it to the
/// negotiated write length (the device reassembles by concatenation).
///
/// Runs entirely on the CoreBluetooth main queue (callbacks + timeout there too),
/// so it needs no locking. NOT hardware-validated: every step and the device's
/// status byte are logged so the first failing step is visible on-device.
final class QixUploader {
    private let send: (Data) -> Void
    private let dlog: (String) -> Void
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<Void, Error>) -> Void

    private var data: [UInt8] = []   // image body (blob after the 27-byte header)
    private var head: [UInt8] = []   // 27-byte file header
    private var total = 0
    private var allowLen = 0         // bytes the device grants per package
    private var offset = 0
    private var serial: UInt8 = 0    // 0…15, wraps (UpdateManager.serialNumber)
    private var finished = false
    private var timeoutToken = 0

    init(send: @escaping (Data) -> Void, dlog: @escaping (String) -> Void,
         onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.send = send
        self.dlog = dlog
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    /// Begin the upload with a complete dial blob (call on the main queue).
    func start(dialFile: [UInt8]) {
        guard dialFile.count > 27 else {
            fail(BadgeError.encodingFailed); return
        }
        head = Array(dialFile[0..<27])
        data = Array(dialFile[27...])
        total = data.count
        offset = 0
        serial = 0
        dlog("qix: upload start (blob \(dialFile.count)B, data \(total)B)")
        transmit(cmd: QixProtocol.cmdReqUpdate, data: head, label: "reqUpdate")
    }

    /// Feed every C2E6FD01 notification here (main queue).
    func handleNotification(_ notif: Data) {
        guard !finished, let r = QixProtocol.parseUpdate(notif) else { return }
        timeoutToken &+= 1  // invalidate the pending timeout for the frame we just answered
        switch r.cmd {
        case QixProtocol.respReqUpdate:
            dlog("qix RX reqUpdate status=\(r.status) allow=\(r.allowLen) off=\(r.offset)")
            allowLen = r.allowLen
            offset = r.offset
            if r.status == 1 {
                sendNext()
            } else {
                fail(BadgeError.badgeUnsupported("Qix device rejected update (status \(r.status))"))
            }
        case QixProtocol.respData:
            offset = r.offset
            if r.status == 0 {
                onProgress(total == 0 ? 1 : Double(offset) / Double(total))
                sendNext()
            } else {
                fail(BadgeError.badgeUnsupported("Qix device data error (status \(r.status)) @\(offset)"))
            }
        case QixProtocol.respResult:
            if r.status == 0 {
                finished = true
                onProgress(1)
                dlog("qix: upload complete")
                onFinish(.success(()))
            } else {
                fail(BadgeError.badgeUnsupported("Qix device rejected dial (result \(r.status))"))
            }
        default:
            break
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish(.failure(BadgeError.notConnected))
    }

    // MARK: - state machine

    private func sendNext() {
        var n = allowLen
        if offset + n > total { n = total - offset }
        if n <= 0 {
            // Everything's been acked; ask the device to commit (it replies 0xC5).
            transmit(cmd: QixProtocol.cmdReqUpdateCon, data: [3], label: "stop")
            return
        }
        let chunk = Array(data[offset..<offset + n])
        let pkg = QixProtocol.dataPackage(chunk: chunk, offset: offset)
        transmit(cmd: QixProtocol.cmdSendData, data: pkg, label: "data@\(offset)(\(n)B)")
    }

    private func transmit(cmd: UInt8, data param: [UInt8], label: String) {
        let mySerial = serial
        serial = serial >= 15 ? 0 : serial + 1  // UpdateManager wraps at 16
        let frame = QixProtocol.updateFrame(cmd: cmd, data: param, serial: mySerial)
        dlog("qix TX \(label) sn=\(mySerial) (\(frame.count)B)")
        send(Data(frame))

        timeoutToken &+= 1
        let token = timeoutToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
            guard let self, !self.finished, self.timeoutToken == token else { return }
            self.fail(BadgeError.badgeUnsupported("Qix: no response to \(label)"))
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        dlog("qix: FAILED — \(error.localizedDescription)")
        onFinish(.failure(error))
    }
}
