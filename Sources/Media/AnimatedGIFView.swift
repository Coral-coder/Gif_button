import ImageIO
import SwiftUI
import UIKit

/// Plays an animated GIF from raw bytes. AsyncImage/Image only show the first
/// frame; this decodes every frame and animates it. Non-GIF data shows as a
/// still image.
struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> GIFPlayerView {
        let view = GIFPlayerView()
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        return view
    }

    func updateUIView(_ uiView: GIFPlayerView, context: Context) {
        uiView.setData(data)
    }
}

/// UIImageView that renders an animated GIF using the platform's own animated
/// `UIImage` (auto-plays, respects total duration, no timers to leak).
final class GIFPlayerView: UIImageView {
    private var loadedHash: Int?

    func setData(_ data: Data) {
        let hash = data.hashValue
        guard hash != loadedHash else { return }
        loadedHash = hash

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 1 else {
            image = UIImage(data: data)   // still image / single frame
            return
        }

        let count = CGImageSourceGetCount(source)
        var frames: [UIImage] = []
        frames.reserveCapacity(count)
        var duration = 0.0
        for i in 0..<count {
            guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cg))
            duration += Self.frameDelay(source, i)
        }
        guard !frames.isEmpty else { image = UIImage(data: data); return }
        image = UIImage.animatedImage(with: frames, duration: duration > 0 ? duration : Double(frames.count) / 20.0)
        startAnimating()
    }

    private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }
}
