import CoreBluetooth
import Foundation

/// Drives the interactive Jieli RCSP custom-dial-background upload for AE00
/// badges (E87 / L8 / N88). Unlike the DZBJ/BeamBox one-shot protocols, Jieli is
/// a request/response sequence: each command is a framed RCSP packet on AE01 and
/// we wait for the badge's response on AE02 before the next step.
///
/// Sequence (from the ZRun decompile):
///   getFreeSpace → enableCustomDialBg(dialPath) → createFileStart(size,file)
///   → loop[ writeData(offset,chunk) → queryWriteResult(crc) ] → createFileStop
///   → setUsingDial(dialPath)
///
/// Implemented as a synchronous state machine driven entirely on the CoreBluetooth
/// main queue (all callbacks + the timeout run there), so no actor isolation or
/// locking is needed. NOT hardware-validated: every step and the badge's status
/// byte are logged, so the first failing step is visible on-device — the unknowns
/// to confirm there are the CRC-16 variant and the exact bg byte format/paths.
final class JieliUploader {
    private let send: (Data) -> Void
    private let dlog: (String) -> Void
    private let onProgress: (Double) -> Void
    private let onFinish: (Result<Void, Error>) -> Void
    private let maxChunk: Int
    private let dialPath: String
    private let fileName = "/BGP/CUSTOM.BGP"   // custom-bg file (path confirmed on-device)

    private var bgBytes: [UInt8] = []
    private var offset = 0
    private var sn: UInt8 = 0
    private var awaitingSn: UInt8?
    private var timeoutToken = 0
    private var finished = false

    private enum Step { case freeSpace, enableBg, createStart, write, query, createStop, setDial }
    private var step: Step = .freeSpace

    init(maxWrite: Int, dialPath: String = JieliRCSP.defaultCustomBgPath,
         send: @escaping (Data) -> Void, dlog: @escaping (String) -> Void,
         onProgress: @escaping (Double) -> Void, onFinish: @escaping (Result<Void, Error>) -> Void) {
        // frame overhead 9 + flash-param [op,flag,offset(4)] = 15; keep margin.
        self.maxChunk = max(64, min(maxWrite, 512) - 16)
        self.dialPath = dialPath
        self.send = send
        self.dlog = dlog
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    /// Begin the upload (call on the main queue).
    func start(bgBytes: [UInt8]) {
        self.bgBytes = bgBytes
        dlog("jieli: upload start (\(bgBytes.count)B, chunk \(maxChunk))")
        step = .freeSpace
        sendStep()
    }

    /// Feed every AE02 notification here (main queue).
    func handleNotification(_ data: Data) {
        guard !finished, let want = awaitingSn, let resp = JieliRCSP.parse(data) else { return }
        guard resp.sn == want || resp.sn == 0 else { return }
        awaitingSn = nil
        timeoutToken &+= 1  // invalidate the pending timeout
        dlog("jieli RX \(stepLabel) status=\(resp.status)")
        if resp.status != 0 {
            // getFreeSpace / queryWriteResult failures are non-fatal (best-effort).
            if step == .freeSpace || step == .query {
                advance()
                return
            }
            fail(BadgeError.badgeUnsupported("Jieli \(stepLabel) rejected (status \(resp.status))"))
            return
        }
        advance()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish(.failure(BadgeError.notConnected))
    }

    // MARK: - state machine

    private func advance() {
        switch step {
        case .freeSpace:   step = .enableBg
        case .enableBg:    step = .createStart
        case .createStart: step = .write
        case .write:       step = .query
        case .query:
            offset = min(offset + maxChunk, bgBytes.count)
            onProgress(bgBytes.isEmpty ? 1 : Double(offset) / Double(bgBytes.count))
            step = offset >= bgBytes.count ? .createStop : .write
        case .createStop:  step = .setDial
        case .setDial:
            finished = true
            dlog("jieli: upload complete")
            onFinish(.success(()))
            return
        }
        sendStep()
    }

    private func sendStep() {
        let param: [UInt8]
        switch step {
        case .freeSpace:   param = JieliRCSP.getFreeSpace()
        case .enableBg:    param = JieliRCSP.enableCustomDialBg(path: dialPath)
        case .createStart: param = JieliRCSP.createFileStart(size: bgBytes.count, path: fileName)
        case .write:
            let end = min(offset + maxChunk, bgBytes.count)
            let chunk = Array(bgBytes[offset..<end])
            param = JieliRCSP.writeData(offset: offset, data: chunk, isFinal: end >= bgBytes.count)
        case .query:
            let end = min(offset + maxChunk, bgBytes.count)
            let chunk = Array(bgBytes[offset..<end])
            param = JieliRCSP.queryWriteResult(crc: JieliRCSP.crc16(chunk), isFinal: end >= bgBytes.count)
        case .createStop:  param = JieliRCSP.createFileStop()
        case .setDial:     param = JieliRCSP.setUsingDial(path: dialPath)
        }
        transmit(param)
    }

    private func transmit(_ param: [UInt8]) {
        sn = sn &+ 1
        let mySn = sn
        awaitingSn = mySn
        let frame = JieliRCSP.frame(opcode: JieliRCSP.opExternalFlashIOCtrl, sn: mySn, param: param)
        dlog("jieli TX \(stepLabel) sn=\(mySn) (\(frame.count)B)")
        send(frame)

        timeoutToken &+= 1
        let token = timeoutToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, !self.finished, self.timeoutToken == token, self.awaitingSn == mySn else { return }
            self.fail(BadgeError.badgeUnsupported("Jieli: no response to \(self.stepLabel)"))
        }
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        dlog("jieli: FAILED at \(stepLabel) — \(error.localizedDescription)")
        onFinish(.failure(error))
    }

    private var stepLabel: String {
        switch step {
        case .freeSpace: return "getFreeSpace"
        case .enableBg: return "enableCustomDialBg"
        case .createStart: return "createFileStart"
        case .write: return "writeData@\(offset)"
        case .query: return "queryWriteResult@\(offset)"
        case .createStop: return "createFileStop"
        case .setDial: return "setUsingDial"
        }
    }
}
