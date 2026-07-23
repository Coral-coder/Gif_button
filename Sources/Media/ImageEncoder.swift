import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// Turns downloaded GIFs/images and typed text into the JPEG frames the badge
/// expects. All CPU-bound work; call it off the main thread.
enum ImageEncoder {

    /// Max animation frames to upload. GIFs can have hundreds of frames; the
    /// badge has limited storage, so we sample down to this many.
    static let maxFrames = 40

    // MARK: - Still image

    static func encodeStill(_ image: UIImage, side: Int, quality: CGFloat) throws -> EncodedImage {
        guard let jpeg = jpeg(from: image, side: side, quality: quality) else {
            throw BadgeError.encodingFailed
        }
        return EncodedImage(jpeg: jpeg, width: side, height: side)
    }

    // MARK: - Animation

    /// Decode GIF bytes and produce an `EncodedAnimation` sized for the badge.
    static func encodeAnimation(fromGIFData data: Data, side: Int, quality: CGFloat) throws -> EncodedAnimation {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BadgeError.encodingFailed
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw BadgeError.encodingFailed }

        // Even sampling down to maxFrames.
        let indices = sampledIndices(count: count, max: maxFrames)
        var frames: [EncodedFrame] = []
        var totalDelayMs = 0
        for i in indices {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let delay = gifDelayMs(source: source, index: i)
            totalDelayMs += delay
            let image = UIImage(cgImage: cg)
            guard let jpeg = jpeg(from: image, side: side, quality: quality) else { continue }
            frames.append(EncodedFrame(jpeg: jpeg, durationMs: delay))
        }
        guard !frames.isEmpty else { throw BadgeError.encodingFailed }
        let avgDelay = max(20, totalDelayMs / max(1, frames.count))
        return EncodedAnimation(frames: frames, width: side, height: side, frameDelayMs: avgDelay)
    }

    // MARK: - Text → image

    /// Render text centered on a square badge image (single still).
    static func renderText(_ text: String, side: Int, color: UIColor, background: UIColor) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let fontSize = fittingFontSize(for: text, in: size)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: size.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            let rect = CGRect(x: 0, y: (size.height - bounds.height) / 2, width: size.width, height: bounds.height)
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }
    }

    // MARK: - QR code → image

    /// Render a QR code for `text` centered on a square badge image, with a quiet
    /// margin. Returns a solid-background fallback if generation fails.
    static func renderQR(_ text: String, side: Int,
                         color: UIColor = .black, background: UIColor = .white) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            background.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            guard let qr = qrCGImage(text, color: color, background: background) else { return }
            // Draw the QR at ~86% with a quiet-zone margin, pixel-crisp.
            ctx.cgContext.interpolationQuality = .none
            let inset = CGFloat(side) * 0.07
            let rect = CGRect(x: inset, y: inset, width: CGFloat(side) - 2 * inset, height: CGFloat(side) - 2 * inset)
            let ui = UIImage(cgImage: qr)
            ui.draw(in: rect)
        }
    }

    private static func qrCGImage(_ text: String, color: UIColor, background: UIColor) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Recolor with false-color so the QR matches the requested palette.
        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(color: color),
            "inputColor1": CIColor(color: background),
        ])
        let context = CIContext()
        return context.createCGImage(colored, from: colored.extent)
    }

    // MARK: - Gradient → image

    /// A diagonal two-color gradient sized for the badge.
    static func renderGradient(from start: UIColor, to end: UIColor, side: Int) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let colors = [start.cgColor, end.cgColor] as CFArray
            let space = CGColorSpaceCreateDeviceRGB()
            guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) else {
                start.setFill(); ctx.fill(CGRect(origin: .zero, size: size)); return
            }
            cg.drawLinearGradient(gradient,
                                  start: .zero,
                                  end: CGPoint(x: size.width, y: size.height),
                                  options: [])
        }
    }

    /// JPEG-encode an already-badge-sized UIImage (for the Create tab generators).
    static func jpegData(_ image: UIImage, quality: CGFloat = 0.9) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    /// Decode JPEG bytes and convert to a `side`×`side` RGB565 buffer (for the
    /// Jieli custom-dial-bg upload, which needs raw pixels not JPEG).
    static func rgb565(fromJPEG data: Data, side: Int) -> [UInt8] {
        guard let ui = UIImage(data: data) else { return [] }
        return rgb565(ui, side: side)
    }

    /// Aspect-fill an image into a `side`×`side` RGB565 (little-endian) buffer —
    /// a common raw format for Jieli round LCD backgrounds. One candidate for the
    /// N88 custom-dial-bg payload (format confirmed on-device).
    static func rgb565(_ image: UIImage, side: Int) -> [UInt8] {
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            let aspect = max(target.width / image.size.width, target.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * aspect, height: image.size.height * aspect)
            image.draw(in: CGRect(x: (target.width - drawSize.width) / 2,
                                  y: (target.height - drawSize.height) / 2,
                                  width: drawSize.width, height: drawSize.height))
        }
        guard let cg = square.cgImage else { return [] }
        let w = side, h = side
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var out = [UInt8](); out.reserveCapacity(w * h * 2)
        var i = 0
        while i < rgba.count {
            let r = UInt16(rgba[i]), g = UInt16(rgba[i + 1]), b = UInt16(rgba[i + 2])
            let v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) // little-endian
            i += 4
        }
        return out
    }

    // MARK: - Blank / solid frame (used to "clear" the badge)

    static func solidColor(_ color: UIColor, side: Int) -> EncodedImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        let data = image.jpegData(compressionQuality: 0.9) ?? Data()
        return EncodedImage(jpeg: data, width: side, height: side)
    }

    static func black(side: Int) -> EncodedImage { solidColor(.black, side: side) }

    /// A small preview thumbnail (first frame for GIFs), for the queue UI.
    static func thumbnail(from data: Data, maxSide: CGFloat = 240) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cg)
    }

    // MARK: - Helpers

    static func jpeg(from image: UIImage, side: Int, quality: CGFloat) -> Data? {
        let target = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        let resized = renderer.image { _ in
            // Aspect-fill into the square.
            let aspect = max(target.width / image.size.width, target.height / image.size.height)
            let drawSize = CGSize(width: image.size.width * aspect, height: image.size.height * aspect)
            let origin = CGPoint(x: (target.width - drawSize.width) / 2,
                                 y: (target.height - drawSize.height) / 2)
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }

    private static func sampledIndices(count: Int, max: Int) -> [Int] {
        guard count > max else { return Array(0..<count) }
        var result: [Int] = []
        for k in 0..<max {
            result.append(Int((Double(k) * Double(count) / Double(max)).rounded(.down)))
        }
        return result
    }

    private static func gifDelayMs(source: CGImageSource, index: Int) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 100
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return Int(unclamped * 1000)
        }
        if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return Int(delay * 1000)
        }
        return 100
    }

    private static func fittingFontSize(for text: String, in size: CGSize) -> CGFloat {
        var fontSize = size.height * 0.6
        while fontSize > 12 {
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: fontSize)]
            let bounds = (text as NSString).boundingRect(
                with: CGSize(width: size.width * 0.9, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs, context: nil)
            if bounds.height <= size.height * 0.9 && bounds.width <= size.width * 0.95 { break }
            fontSize -= 4
        }
        return fontSize
    }
}
