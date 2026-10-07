import Foundation

// @beacon: ctc-decoder — CTC greedy decoder for PP-OCRv5 recognition output

struct CTCDecoder {
    let dictionary: [String]  // 18383 characters, index 0 = blank

    static func load(from path: String) throws -> CTCDecoder {
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return CTCDecoder(dictionary: lines)
    }

    /// Greedy CTC decode: argmax per timestep, skip blank (0) and consecutive duplicates.
    /// - Parameters:
    ///   - output: Flattened softmax output [seqLen * vocabSize], row-major.
    ///   - seqLen: Number of timesteps (sequence length).
    ///   - vocabSize: Size of vocabulary (dictionary.count + 1, where 0 = blank).
    /// - Returns: Decoded text and mean confidence of kept characters.
    func decode(output: [Float], seqLen: Int, vocabSize: Int) -> (text: String, confidence: Float) {
        var chars: [String] = []
        var scores: [Float] = []
        var prevIndex = -1

        for t in 0..<seqLen {
            let offset = t * vocabSize
            var maxIdx = 0
            var maxVal: Float = output[offset]
            for v in 1..<vocabSize {
                let val = output[offset + v]
                if val > maxVal {
                    maxVal = val
                    maxIdx = v
                }
            }

            // Skip blank (index 0) and consecutive duplicates
            if maxIdx != 0 && maxIdx != prevIndex {
                // Dictionary index: maxIdx - 1 (index 0 is blank, dict starts at index 1)
                let dictIdx = maxIdx - 1
                if dictIdx < dictionary.count {
                    chars.append(dictionary[dictIdx])
                    scores.append(maxVal)
                }
            }
            prevIndex = maxIdx
        }

        let text = chars.joined()
        let confidence: Float = scores.isEmpty ? 0.0 : scores.reduce(0, +) / Float(scores.count)
        return (text, confidence)
    }
}
