import Foundation

public enum TranscriptionError: Error {
    case ffmpegFailed(Int32)
    case whisperFailed(Int32)
    case jsonMissing
}

public struct TranscriptResult {
    public var fullText: String
    public var segments: [(startMs: Int, endMs: Int, text: String)]
}

public struct WhisperTranscriber {
    public var modelPath: String
    public var whisperCLIPath: String
    public var ffmpegPath: String
    public var initialPrompt: String?

    public init(
        modelPath: String,
        whisperCLIPath: String = "/opt/homebrew/bin/whisper-cli",
        ffmpegPath: String = "/opt/homebrew/bin/ffmpeg",
        initialPrompt: String? = nil
    ) {
        self.modelPath = modelPath
        self.whisperCLIPath = whisperCLIPath
        self.ffmpegPath = ffmpegPath
        self.initialPrompt = initialPrompt
    }

    public func convertToWav(inputPath: String, outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-y", "-i", inputPath, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", outputPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.ffmpegFailed(process.terminationStatus)
        }
    }

    public func transcribe(wavPath: String, outputBasePath: String) throws -> TranscriptResult {
        var args = ["-m", modelPath, "-f", wavPath, "-oj", "-of", outputBasePath, "--no-prints"]
        if let prompt = initialPrompt {
            args += ["--prompt", prompt]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperCLIPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.whisperFailed(process.terminationStatus)
        }

        let jsonPath = outputBasePath + ".json"
        guard let data = FileManager.default.contents(atPath: jsonPath) else {
            throw TranscriptionError.jsonMissing
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let transcription = obj?["transcription"] as? [[String: Any]] ?? []

        var segments: [(Int, Int, String)] = []
        var fullTextParts: [String] = []
        for seg in transcription {
            guard let offsets = seg["offsets"] as? [String: Any],
                  let from = offsets["from"] as? Int,
                  let to = offsets["to"] as? Int,
                  let text = seg["text"] as? String else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            segments.append((from, to, trimmed))
            fullTextParts.append(trimmed)
        }

        try? FileManager.default.removeItem(atPath: jsonPath)

        return TranscriptResult(fullText: fullTextParts.joined(separator: " "), segments: segments)
    }
}
