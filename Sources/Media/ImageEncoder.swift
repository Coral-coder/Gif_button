import CoreGraphics
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
