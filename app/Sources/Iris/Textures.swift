import AppKit
import SpriteKit

/// Textures shrunk once, with high-quality filtering, to the size they are
/// drawn at (×2 for sharpness). SpriteKit samples without mipmaps, so a big
/// picture drawn small every frame comes out jagged.
enum Textures {
    static func load(_ url: URL, drawnAt size: CGSize) -> SKTexture? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 1)
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard w < img.width || h < img.height,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return SKTexture(cgImage: img)
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage() else { return SKTexture(cgImage: img) }
        let t = SKTexture(cgImage: small)
        t.filteringMode = .linear
        return t
    }
}
