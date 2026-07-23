import CoreBluetooth
import Foundation

/// Drives the interactive Jieli RCSP custom-dial-background upload for AE00
/// badges (E87 / L8 / N88). Unlike the DZBJ/BeamBox one-shot protocols, Jieli is
/// a request/response sequence: each command is a framed RCSP packet on AE01 and
/// we wait for the badge's response on AE02 before the next step.
///
/// Sequence (from the ZRun decompile):
///   getFreeSpace → enableCustomDialBg(dialPath) → createFileStart(size,file)
///   → loop[ writeData(offset,chunk) → (queryWriteResult) ] → createFileStop
///   → setUsingDial(dialPath)
///
/// NOT hardware-validated. Every step is logged to the debug log so the first
/// failing step (and the badge's status byte) is visible on-device — the two
/// unknowns to confirm there are the CRC-16 variant and the exact bg byte format.
@MainActor
final class JieliUploader {
    private let send: (Data) -> Void
    private let dlog: (String) -> Void
    private let maxChunk: Int

    private var sn: UInt8 = 0
    private var pending: (sn: UInt8, cont: CheckedContinuation<JieliRCSP.Response, Error>)?
    private var timeoutTask: Task<Void, Never>?

    init(maxWrite: Int, send: @escaping (Data) -> Void, dlog: @escaping (String) -> Void) {
        self.send = send
        self.dlog = dlog
        // frame overhead 9 + flash-param [op,flag,offset(4)] = 15; keep margin.
        self.maxChunk = max(64, min(maxWrite, 512) - 16)
    }

    /// Feed every AE02 notification here while an upload is running.
    func handleNotification(_ data: Data) {
        guard let resp = JieliRCSP.parse(data), let p = pending else { return }
        // Match by opcode-sn echo (fall back to opcode when the badge zeroes sn).
        guard resp.sn == p.sn || resp.sn == 0 else { return }
        pending = nil
        timeoutTask?.cancel(); timeoutTask = nil
        p.cont.resume(returning: resp)
    }

    func cancel() {
        timeoutTask?.cancel(); timeoutTask = nil
        pending?.cont.resume(throwing: BadgeError.notConnected)
        pending = nil
    }

    /// Run the whole upload. `bgBytes` is the raw background payload; `dialPath`
    /// is the target dial (defaults to the custom-bg constant).
    func upload(bgBytes: [UInt8], dialPath: String = JieliRCSP.defaultCustomBgPath,
                progress: @escaping (Double) -> Void) async throws {
        dlog("jieli: upload start (\(bgBytes.count)B, chunk \(maxChunk))")

        _ = try? await step(op: JieliRCSP.opExternalFlashIOCtrl, param: JieliRCSP.getFreeSpace(), label: "getFreeSpace")
        _ = try await step(op: JieliRCSP.opExternalFlashIOCtrl,
                           param: JieliRCSP.enableCustomDialBg(path: dialPath), label: "enableCustomDialBg")

        let fileName = "/BGP/CUSTOM.BGP"   // custom background file (path confirmed on-device)
        _ = try await step(op: JieliRCSP.opExternalFlashIOCtrl,
                           param: JieliRCSP.createFileStart(size: bgBytes.count, path: fileName),
                           label: "createFileStart")

        var offset = 0
        while offset < bgBytes.count {
            let end = min(offset + maxChunk, bgBytes.count)
            let chunk = Array(bgBytes[offset..<end])
            let isFinal = end >= bgBytes.count
            _ = try await step(op: JieliRCSP.opExternalFlashIOCtrl,
                               param: JieliRCSP.writeData(offset: offset, data: chunk, isFinal: isFinal),
                               label: "writeData@\(offset)")
            // Verify the block (badge compares its CRC against ours).
            let crc = JieliRCSP.crc16(chunk)
            _ = try? await step(op: JieliRCSP.opExternalFlashIOCtrl,
                                param: JieliRCSP.queryWriteResult(crc: crc, isFinal: isFinal),
                                label: "queryWriteResult@\(offset)")
            offset = end
            progress(Double(offset) / Double(bgBytes.count))
        }

        _ = try await step(op: JieliRCSP.opExternalFlashIOCtrl, param: JieliRCSP.createFileStop(), label: "createFileStop")
        _ = try await step(op: JieliRCSP.opExternalFlashIOCtrl,
                           param: JieliRCSP.setUsingDial(path: dialPath), label: "setUsingDial")
        dlog("jieli: upload complete")
    }

    /// Send one framed command and await the badge's response (2.5s timeout).
    @discardableResult
    private func step(op: UInt8, param: [UInt8], label: String) async throws -> JieliRCSP.Response {
        sn = sn &+ 1
        let mySn = sn
        let frame = JieliRCSP.frame(opcode: op, sn: mySn, param: param)
        dlog("jieli TX \(label) sn=\(mySn) (\(frame.count)B)")
        let resp: JieliRCSP.Response = try await withCheckedThrowingContinuation { cont in
            pending = (mySn, cont)
            send(frame)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard let self, let p = self.pending, p.sn == mySn else { return }
                self.pending = nil
                p.cont.resume(throwing: BadgeError.badgeUnsupported("Jieli: no response to \(label)"))
            }
        }
        dlog("jieli RX \(label) status=\(resp.status)")
        if resp.status != 0 {
            throw BadgeError.badgeUnsupported("Jieli \(label) rejected (status \(resp.status))")
        }
        return resp
    }
}
