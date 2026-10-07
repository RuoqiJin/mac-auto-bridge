import CoreGraphics
import Foundation
import OnnxRuntimeBindings

// @beacon: paddle-ocr-engine — PP-OCRv5 ONNX inference pipeline (det + cls + rec)

final class PaddleOCREngine: @unchecked Sendable {

    private let env: ORTEnv
    private let detSession: ORTSession
    private let clsSession: ORTSession
    private let recSession: ORTSession
    private let decoder: CTCDecoder

    // Dynamic input/output names read from model metadata
    private let detInputName: String
    private let detOutputName: String
    private let clsInputName: String
    private let clsOutputName: String
    private let recInputName: String
    private let recOutputName: String

    // MARK: - Initialization

    init() throws {
        // Sweep CoreML temp models leaked by previously-crashed/killed instances.
        // ORT's CoreML EP compiles each model into $TMPDIR/onnxruntime-*.mlmodelc and
        // does NOT remove them on abnormal exit; left unchecked this fills the disk
        // (observed 146 GB / 325k files). A compile finishes in seconds, so anything
        // older than the threshold is dead and safe to delete.
        PaddleOCREngine.cleanStaleCoreMLTempArtifacts()

        let env = try ORTEnv(loggingLevel: .warning)
        self.env = env

        let modelsDir = PaddleOCREngine.modelsDirectory()
        let detPath = (modelsDir as NSString).appendingPathComponent("pp_ocrv5_det.onnx")
        let clsPath = (modelsDir as NSString).appendingPathComponent("pp_ocrv5_cls.onnx")
        let recPath = (modelsDir as NSString).appendingPathComponent("pp_ocrv5_rec.onnx")
        let dictPath = (modelsDir as NSString).appendingPathComponent("ppocrv5_dict.txt")

        let sessionOptions = try PaddleOCREngine.makeSessionOptions()

        self.detSession = try ORTSession(env: env, modelPath: detPath, sessionOptions: sessionOptions)
        self.clsSession = try ORTSession(env: env, modelPath: clsPath, sessionOptions: sessionOptions)
        self.recSession = try ORTSession(env: env, modelPath: recPath, sessionOptions: sessionOptions)
        self.decoder = try CTCDecoder.load(from: dictPath)

        // Read input/output names dynamically
        let detInputs = try detSession.inputNames()
        let detOutputs = try detSession.outputNames()
        self.detInputName = detInputs.first ?? "x"
        self.detOutputName = detOutputs.first ?? "sigmoid_0.tmp_0"

        let clsInputs = try clsSession.inputNames()
        let clsOutputs = try clsSession.outputNames()
        self.clsInputName = clsInputs.first ?? "x"
        self.clsOutputName = clsOutputs.first ?? "softmax_0.tmp_0"

        let recInputs = try recSession.inputNames()
        let recOutputs = try recSession.outputNames()
        self.recInputName = recInputs.first ?? "x"
        self.recOutputName = recOutputs.first ?? "softmax_0.tmp_0"
    }

    // MARK: - Public API

    /// Full OCR pipeline: detect text boxes, classify orientation, recognize text.
    /// Returns entries in pixel coordinates of the source image.
    func recognize(image: CGImage) throws -> [OCRTextEntry] {
        // Stage 1: Detection
        let boxes = try detect(image: image)
        guard !boxes.isEmpty else { return [] }

        // Stage 2 & 3: For each box, crop -> classify -> recognize
        var results: [OCRTextEntry] = []

        for box in boxes {
            guard let cropped = TextBoxCropper.crop(image: image, box: box) else { continue }

            // Stage 2: Classification (0 or 180 degrees)
            let corrected = try classifyAndCorrect(image: cropped)

            // Stage 3: Recognition
            let (text, confidence) = try recognizeText(image: corrected)
            guard !text.isEmpty && confidence > 0.1 else { continue }

            // Compute bounding rect from box points for the OCRTextEntry frame
            let xs = box.points.map { $0.x }
            let ys = box.points.map { $0.y }
            let minX = xs.min() ?? 0
            let minY = ys.min() ?? 0
            let maxX = xs.max() ?? 0
            let maxY = ys.max() ?? 0

            let frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            results.append(OCRTextEntry(text: text, frame: frame, confidence: confidence))
        }

        return results
    }

    // MARK: - Stage 1: Detection

    private func detect(image: CGImage) throws -> [TextBox] {
        let (inputData, resH, resW) = ImagePreprocessor.preprocessForDetection(image: image)

        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: [1, 3, NSNumber(value: resH), NSNumber(value: resW)]
        )

        let outputs = try detSession.run(
            withInputs: [detInputName: inputTensor],
            outputNames: Set([detOutputName]),
            runOptions: nil
        )

        guard let outputTensor = outputs[detOutputName] else {
            throw PaddleOCRError.missingOutput("Detection output '\(detOutputName)' not found")
        }

        let outputData = try outputTensor.tensorData() as Data
        let pixelCount = resH * resW
        var probMap = [Float](repeating: 0, count: pixelCount)
        outputData.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            // Output shape: [1, 1, H, W] — copy from offset 0
            for i in 0..<pixelCount {
                probMap[i] = floatPtr[i]
            }
        }

        return DBPostProcessor.process(
            probMap: probMap,
            width: resW,
            height: resH,
            srcWidth: image.width,
            srcHeight: image.height
        )
    }

    // MARK: - Stage 2: Classification

    /// Classify text orientation (0 or 180 degrees). If 180, flip the image.
    private func classifyAndCorrect(image: CGImage) throws -> CGImage {
        let (inputData, resH, resW) = ImagePreprocessor.preprocessForClassification(image: image)

        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: [1, 3, NSNumber(value: resH), NSNumber(value: resW)]
        )

        let outputs = try clsSession.run(
            withInputs: [clsInputName: inputTensor],
            outputNames: Set([clsOutputName]),
            runOptions: nil
        )

        guard let outputTensor = outputs[clsOutputName] else {
            return image  // If classification fails, return original
        }

        let outputData = try outputTensor.tensorData() as Data
        // Output shape: [1, 2] — class 0 = 0 degrees, class 1 = 180 degrees
        var scores = [Float](repeating: 0, count: 2)
        outputData.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            scores[0] = floatPtr[0]
            scores[1] = floatPtr[1]
        }

        // If 180 degrees with high confidence, rotate the image
        if scores[1] > scores[0] && scores[1] > 0.9 {
            return rotate180(image) ?? image
        }

        return image
    }

    // MARK: - Stage 3: Recognition

    /// Recognize text from a single cropped text line image.
    private func recognizeText(image: CGImage) throws -> (String, Float) {
        let (inputData, resH, resW) = ImagePreprocessor.preprocessForRecognition(image: image)

        let inputTensor = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: [1, 3, NSNumber(value: resH), NSNumber(value: resW)]
        )

        let outputs = try recSession.run(
            withInputs: [recInputName: inputTensor],
            outputNames: Set([recOutputName]),
            runOptions: nil
        )

        guard let outputTensor = outputs[recOutputName] else {
            throw PaddleOCRError.missingOutput("Recognition output '\(recOutputName)' not found")
        }

        // Get output shape to determine seqLen and vocabSize
        let shapeInfo = try outputTensor.tensorTypeAndShapeInfo()
        let shape = shapeInfo.shape  // [1, seqLen, vocabSize]
        guard shape.count == 3 else {
            throw PaddleOCRError.unexpectedShape("Expected 3D output, got \(shape.count)D")
        }
        let seqLen = shape[1].intValue
        let vocabSize = shape[2].intValue

        let outputData = try outputTensor.tensorData() as Data
        let totalElements = seqLen * vocabSize
        var output = [Float](repeating: 0, count: totalElements)
        outputData.withUnsafeBytes { rawBuffer in
            guard let floatPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<totalElements {
                output[i] = floatPtr[i]
            }
        }

        return decoder.decode(output: output, seqLen: seqLen, vocabSize: vocabSize)
    }

    // MARK: - Helpers

    /// Rotate image 180 degrees.
    private func rotate180(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let context = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.translateBy(x: CGFloat(w), y: CGFloat(h))
        context.rotate(by: .pi)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    /// Locate models directory. Prefers Bundle.module, falls back to source-relative path.
    private static func modelsDirectory() -> String {
        // SPM Bundle.module resource path
        if let resourceURL = Bundle.module.resourceURL {
            let modelsURL = resourceURL.appendingPathComponent("Resources/models")
            if FileManager.default.fileExists(atPath: modelsURL.path) {
                return modelsURL.path
            }
            // Also try without Resources/ prefix (depends on SPM copy behavior)
            let altURL = resourceURL.appendingPathComponent("models")
            if FileManager.default.fileExists(atPath: altURL.path) {
                return altURL.path
            }
        }

        // Fallback: relative to executable
        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let relative = (execDir as NSString).appendingPathComponent(
            "MacAutoBridge_MacAutoBridge.bundle/Contents/Resources/Resources/models"
        )
        if FileManager.default.fileExists(atPath: relative) {
            return relative
        }

        // Last resort: resolve a development checkout from its working directory.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/MacAutoBridge/Resources/models").path
    }

    /// Create session options with CoreML EP enabled.
    private static func makeSessionOptions() throws -> ORTSessionOptions {
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(4)

        // Enable CoreML EP if available
        if ORTIsCoreMLExecutionProviderAvailable() {
            let coremlOptions = ORTCoreMLExecutionProviderOptions()
            coremlOptions.useCPUAndGPU = false  // Allow ANE
            try options.appendCoreMLExecutionProvider(with: coremlOptions)
        }

        return options
    }

    /// Best-effort sweep of stale ONNX Runtime CoreML temp artifacts in $TMPDIR.
    /// Runs at engine init so every process launch clears the backlog left by
    /// predecessors that exited without cleaning up (including crashes / kill -9).
    /// Conservative age threshold avoids racing a sibling instance mid-compile.
    static func cleanStaleCoreMLTempArtifacts(olderThan maxAge: TimeInterval = 1800) {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date(timeIntervalSinceNow: -maxAge)
        var removed = 0
        for url in entries where url.lastPathComponent.hasPrefix("onnxruntime-") {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            guard let mtime, mtime < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            FileHandle.standardError.write(Data(
                "[PaddleOCREngine] swept \(removed) stale onnxruntime-* temp entries from \(tmp.path)\n".utf8))
        }
    }
}

// MARK: - Errors

enum PaddleOCRError: Error, LocalizedError {
    case missingOutput(String)
    case unexpectedShape(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingOutput(let detail): "PaddleOCR: \(detail)"
        case .unexpectedShape(let detail): "PaddleOCR: \(detail)"
        case .modelNotFound(let detail): "PaddleOCR: model not found — \(detail)"
        }
    }
}
