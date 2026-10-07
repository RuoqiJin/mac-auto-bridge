import CoreGraphics
import CoreImage

// @beacon: text-box-cropper — Crop text line regions from source image using perspective correction

struct TextBoxCropper {

    /// Crop a TextBox region from the source image, producing an axis-aligned text line image.
    /// Uses CIPerspectiveCorrection for proper deskewing.
    /// If the result is taller than 1.5x its width, rotates 90 degrees (vertical text).
    static func crop(image: CGImage, box: TextBox) -> CGImage? {
        let points = box.points
        guard points.count == 4 else { return nil }

        let imageHeight = CGFloat(image.height)

        // CIImage uses bottom-left origin; CGImage uses top-left origin.
        // Convert points from top-left origin to bottom-left origin for CoreImage.
        let ciPoints = points.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }

        let ciImage = CIImage(cgImage: image)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        // Order: topLeft, topRight, bottomRight, bottomLeft (in original top-left coords)
        // In CI bottom-left coords: these become bottomLeft, bottomRight, topRight, topLeft
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else {
            return cropBoundingRect(image: image, box: box)
        }

        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciPoints[0]), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciPoints[1]), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciPoints[2]), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciPoints[3]), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage,
              let cgResult = context.createCGImage(outputImage, from: outputImage.extent)
        else {
            return cropBoundingRect(image: image, box: box)
        }

        // If height > 1.5 * width, this is vertical text — rotate 90 degrees
        if cgResult.height > Int(1.5 * Double(cgResult.width)) {
            return rotateImage90(cgResult)
        }

        return cgResult
    }

    /// Fallback: simple bounding-rect crop when perspective correction fails.
    private static func cropBoundingRect(image: CGImage, box: TextBox) -> CGImage? {
        let points = box.points
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }

        let rect = CGRect(
            x: max(0, minX),
            y: max(0, minY),
            width: min(CGFloat(image.width) - max(0, minX), maxX - minX),
            height: min(CGFloat(image.height) - max(0, minY), maxY - minY)
        )

        guard rect.width > 0 && rect.height > 0 else { return nil }
        return image.cropping(to: rect)
    }

    /// Rotate a CGImage 90 degrees counterclockwise (vertical text -> horizontal).
    private static func rotateImage90(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        // Rotated dimensions: width becomes height, height becomes width
        let newW = h
        let newH = w

        guard let context = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        // Rotate 90 CCW: translate then rotate
        context.translateBy(x: 0, y: CGFloat(newH))
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
