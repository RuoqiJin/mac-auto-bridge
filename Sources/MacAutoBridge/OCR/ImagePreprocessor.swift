import CoreGraphics
import Accelerate

// @beacon: image-preprocessor — CGImage to CHW Float32 tensor for PP-OCRv5

struct ImagePreprocessor {

    // MARK: - Detection Preprocessing

    /// Resize + normalize for detection model.
    /// - Parameters:
    ///   - image: Source CGImage.
    ///   - maxSideLen: Maximum side length (default 960). Width/height rounded to 32.
    /// - Returns: (CHW Float32 Data, resizedHeight, resizedWidth)
    static func preprocessForDetection(image: CGImage, maxSideLen: Int = 960) -> (Data, Int, Int) {
        let srcW = image.width
        let srcH = image.height

        // Scale so longest side <= maxSideLen
        var ratio: Float = 1.0
        let maxSide = max(srcW, srcH)
        if maxSide > maxSideLen {
            ratio = Float(maxSideLen) / Float(maxSide)
        }
        var resW = Int(Float(srcW) * ratio)
        var resH = Int(Float(srcH) * ratio)

        // Round to multiple of 32
        resW = max(32, (resW + 31) / 32 * 32)
        resH = max(32, (resH + 31) / 32 * 32)

        let pixels = resizeToRGBA(image: image, width: resW, height: resH)
        let data = normalizeImageNet(pixels: pixels, width: resW, height: resH)
        return (data, resH, resW)
    }

    // MARK: - Recognition Preprocessing

    /// Resize + normalize for recognition model. Height=48, width keeps aspect ratio.
    /// - Returns: (CHW Float32 Data, height=48, resizedWidth)
    static func preprocessForRecognition(image: CGImage, targetHeight: Int = 48) -> (Data, Int, Int) {
        let srcW = image.width
        let srcH = image.height
        let resW = max(1, Int(Float(srcW) * Float(targetHeight) / Float(srcH)))
        let resH = targetHeight

        let pixels = resizeToRGBA(image: image, width: resW, height: resH)
        let data = normalizeSymmetric(pixels: pixels, width: resW, height: resH)
        return (data, resH, resW)
    }

    // MARK: - Classification Preprocessing

    /// Resize + normalize for classification model.
    /// PP-OCRv5 server cls model expects 80x160 (height x width).
    /// - Returns: (CHW Float32 Data, height=80, width=160)
    static func preprocessForClassification(image: CGImage) -> (Data, Int, Int) {
        let resW = 160
        let resH = 80
        let pixels = resizeToRGBA(image: image, width: resW, height: resH)
        let data = normalizeSymmetric(pixels: pixels, width: resW, height: resH)
        return (data, resH, resW)
    }

    // MARK: - Internal Helpers

    /// Resize CGImage to target size, return RGBA pixel bytes.
    private static func resizeToRGBA(image: CGImage, width: Int, height: Int) -> [UInt8] {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return pixels
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    /// ImageNet normalization: (pixel/255.0 - mean) / std, output CHW Float32.
    /// mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225]
    private static func normalizeImageNet(pixels: [UInt8], width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let channelCount = 3
        var result = [Float](repeating: 0, count: channelCount * pixelCount)

        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]

        for i in 0..<pixelCount {
            let base = i * 4  // RGBA
            for c in 0..<channelCount {
                let value = Float(pixels[base + c]) / 255.0
                result[c * pixelCount + i] = (value - mean[c]) / std[c]
            }
        }

        return Data(bytes: result, count: result.count * MemoryLayout<Float>.size)
    }

    /// Symmetric normalization: pixel/127.5 - 1.0 (scales to [-1, 1]), output CHW Float32.
    private static func normalizeSymmetric(pixels: [UInt8], width: Int, height: Int) -> Data {
        let pixelCount = width * height
        let channelCount = 3
        var result = [Float](repeating: 0, count: channelCount * pixelCount)

        for i in 0..<pixelCount {
            let base = i * 4  // RGBA
            for c in 0..<channelCount {
                result[c * pixelCount + i] = Float(pixels[base + c]) / 127.5 - 1.0
            }
        }

        return Data(bytes: result, count: result.count * MemoryLayout<Float>.size)
    }
}
