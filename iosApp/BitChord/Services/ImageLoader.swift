import UIKit
import CoreImage

/// Artwork download with a memory cache on top of URLCache's disk cache.
final class ImageLoader {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private let palettes = NSCache<NSURL, PaletteBox>()
    private let session: URLSession
    private let context = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {
        cache.countLimit = 300
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 512 << 20)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func cachedImage(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let cached = cachedImage(for: url) { return cached }
        guard let (data, _) = try? await session.data(from: url),
              let image = UIImage(data: data)?.preparingForDisplay() ?? UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }

    // MARK: Colours for the Now Playing background

    final class PaletteBox {
        let colors: [UIColor]
        init(_ colors: [UIColor]) { self.colors = colors }
    }

    /// Nine colours sampled on a 3×3 grid of the artwork, slightly darkened,
    /// for the Now Playing mesh gradient (Apple Music animates the same idea).
    func palette(for url: URL) async -> [UIColor] {
        if let cached = palettes.object(forKey: url as NSURL) { return cached.colors }
        guard let image = await image(for: url), let cgImage = image.cgImage else { return [] }
        let colors = await Task.detached(priority: .utility) { [context] in
            ImageLoader.sample(CIImage(cgImage: cgImage), context: context)
        }.value
        palettes.setObject(PaletteBox(colors), forKey: url as NSURL)
        return colors
    }

    private static func sample(_ image: CIImage, context: CIContext) -> [UIColor] {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return [] }
        var colors: [UIColor] = []
        for row in 0..<3 {
            for column in 0..<3 {
                let cell = CGRect(
                    x: extent.minX + extent.width * CGFloat(column) / 3,
                    y: extent.minY + extent.height * CGFloat(2 - row) / 3,
                    width: extent.width / 3,
                    height: extent.height / 3
                )
                guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
                    kCIInputImageKey: image,
                    kCIInputExtentKey: CIVector(cgRect: cell),
                ]), let output = filter.outputImage else { continue }
                var pixel = [UInt8](repeating: 0, count: 4)
                context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
                let color = UIColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                                    blue: CGFloat(pixel[2]) / 255, alpha: 1)
                colors.append(color.adjusted(saturation: 1.15, brightness: 0.78))
            }
        }
        return colors
    }
}

extension UIColor {
    func adjusted(saturation saturationFactor: CGFloat, brightness brightnessFactor: CGFloat) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        return UIColor(hue: hue, saturation: min(saturation * saturationFactor, 1),
                       brightness: min(max(brightness * brightnessFactor, 0.12), 0.85), alpha: alpha)
    }
}
