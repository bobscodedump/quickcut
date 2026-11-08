import Foundation
import ImageIO
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers

/// Shared ImageIO helpers used by the image and PDF converters.
enum ImageCodec {
    static let encodableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func uti(for formatID: String) -> String? {
        switch formatID {
        case "png": return "public.png"
        case "jpeg": return "public.jpeg"
        case "heic": return "public.heic"
        case "tiff": return "public.tiff"
        case "gif": return "com.compuserve.gif"
        case "bmp": return "com.microsoft.bmp"
        case "webp": return "org.webmproject.webp"
        default: return nil
        }
    }

    static func canEncodeNatively(_ formatID: String) -> Bool {
        uti(for: formatID).map(encodableTypes.contains) ?? false
    }

    /// Loads frame 0 with EXIF orientation applied.
    static func loadOriented(from source: CGImageSource) throws -> CGImage {
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let maxDim = max(width, height)
        if maxDim > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxDim,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConversionError.unreadableInput }
        return image
    }

    static func load(url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError.unreadableInput
        }
        return try loadOriented(from: source)
    }

    /// Composites an image with alpha over white (needed for JPEG).
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb { space = cs } else { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func write(_ image: CGImage, formatID: String, quality: Double, to url: URL) throws {
        guard let uti = uti(for: formatID), encodableTypes.contains(uti) else {
            throw ConversionError.unsupported("This Mac can't encode \(formatID.uppercased()) with ImageIO.")
        }
        let source = formatID == "jpeg" ? flattened(image) : image
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.outputFailed("Couldn't create \(url.lastPathComponent).")
        }
        var props: [CFString: Any] = [:]
        if ["jpeg", "heic", "webp"].contains(formatID) { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, source, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.outputFailed("Encoding \(formatID.uppercased()) failed.")
        }
    }

    static func writePDF(_ image: CGImage, to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError.outputFailed("Couldn't create \(url.lastPathComponent).")
        }
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Renders a PDF page onto a white background at `scale` × 72 dpi.
    static func render(page: PDFPage, scale: CGFloat) -> CGImage? {
        guard let pageRef = page.pageRef else { return nil }
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let width = max(1, Int(((rotated ? box.height : box.width) * scale).rounded()))
        let height = max(1, Int(((rotated ? box.width : box.height) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(target)
        ctx.concatenate(pageRef.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(pageRef)
        return ctx.makeImage()
    }
}
