import Foundation

public struct DecodedVoice: Equatable, Sendable {
    public let pcmData: Data
    public let sampleRate: Int
    public let channels: Int

    public init(pcmData: Data, sampleRate: Int, channels: Int) {
        self.pcmData = pcmData
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public var duration: Double {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return Double(pcmData.count) / Double(sampleRate * channels * 2)
    }
}

public protocol VoiceDecoder: Sendable {
    func decode(_ data: Data) throws -> DecodedVoice
    func decode(_ data: Data, shouldCancel: @escaping @Sendable () -> Bool) throws -> DecodedVoice
}

public extension VoiceDecoder {
    func decode(_ data: Data, shouldCancel: @escaping @Sendable () -> Bool) throws -> DecodedVoice {
        guard !shouldCancel() else { throw VoiceDecoderError.cancelled }
        let decoded = try decode(data)
        guard !shouldCancel() else { throw VoiceDecoderError.cancelled }
        return decoded
    }
}

public enum VoiceDecoderError: Error, Equatable, Sendable {
    case unsupportedFormat
    case decoderUnavailable
    case processFailed
    case invalidPCM
    case ioFailure
    case timeout
    case cancelled
}

/// Writes standards-compliant little-endian 16-bit PCM WAV. It deliberately
/// has no Silk knowledge, so format decoding remains isolated behind
/// `VoiceDecoder`.
public struct WAVWriter: Sendable {
    public init() {}

    public func write(_ decoded: DecodedVoice) throws -> Data {
        guard decoded.sampleRate > 0, decoded.channels > 0,
              decoded.pcmData.count <= Int(UInt32.max) - 36,
              decoded.pcmData.count.isMultiple(of: 2) else { throw VoiceDecoderError.invalidPCM }
        let byteRate = decoded.sampleRate * decoded.channels * 2
        let blockAlign = decoded.channels * 2
        guard byteRate > 0, byteRate <= Int(UInt32.max), blockAlign <= Int(UInt16.max) else { throw VoiceDecoderError.invalidPCM }
        var wav = Data()
        wav.append(Data("RIFF".utf8))
        wav.append(UInt32(decoded.pcmData.count + 36).littleEndianData)
        wav.append(Data("WAVEfmt ".utf8))
        wav.append(UInt32(16).littleEndianData)
        wav.append(UInt16(1).littleEndianData)
        wav.append(UInt16(decoded.channels).littleEndianData)
        wav.append(UInt32(decoded.sampleRate).littleEndianData)
        wav.append(UInt32(byteRate).littleEndianData)
        wav.append(UInt16(blockAlign).littleEndianData)
        wav.append(UInt16(16).littleEndianData)
        wav.append(Data("data".utf8))
        wav.append(UInt32(decoded.pcmData.count).littleEndianData)
        wav.append(decoded.pcmData)
        return wav
    }
}

/// Bridges a separately installed Silk SDK decoder without putting it on a
/// shell command line. The executable receives only protected temporary files
/// containing archived voice bytes, and no output is logged.
public struct SilkProcessVoiceDecoder: VoiceDecoder {
    private let executableURL: URL?
    private let outputSampleRate: Int
    private let maximumPCMBytes: Int
    private let timeout: TimeInterval

    public init(
        executableURL: URL? = nil,
        outputSampleRate: Int = 24_000,
        maximumPCMBytes: Int = 128 * 1_024 * 1_024,
        timeout: TimeInterval = 30
    ) {
        self.executableURL = executableURL ?? Self.defaultExecutableURL()
        self.outputSampleRate = outputSampleRate
        self.maximumPCMBytes = maximumPCMBytes
        self.timeout = min(max(timeout, 0.01), 300)
    }

    /// Allows the export UI to warn before a long export starts. This probes
    /// only a local executable path and never invokes the decoder.
    public static var isAvailable: Bool { defaultExecutableURL() != nil }

    public func decode(_ data: Data) throws -> DecodedVoice {
        try decode(data, shouldCancel: { false })
    }

    public func decode(_ data: Data, shouldCancel: @escaping @Sendable () -> Bool) throws -> DecodedVoice {
        guard VoiceFormatDetector().detect(data) == .silk else { throw VoiceDecoderError.unsupportedFormat }
        guard let executableURL, isSafeExecutable(executableURL) else { throw VoiceDecoderError.decoderUnavailable }
        guard !shouldCancel() else { throw VoiceDecoderError.cancelled }
        // The supported SDK decoder resamples every accepted Silk stream to
        // the explicitly requested API rate, so this is output metadata, not
        // an assumption about the stream's original sampling rate.
        guard [8_000, 12_000, 16_000, 24_000].contains(outputSampleRate) else { throw VoiceDecoderError.invalidPCM }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WeChatArchive-Silk-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let inputURL = directory.appending(path: "voice.silk")
            let outputURL = directory.appending(path: "voice.pcm")
            guard FileManager.default.createFile(atPath: inputURL.path(), contents: nil, attributes: [.posixPermissions: 0o600]) else { throw VoiceDecoderError.ioFailure }
            let input = try FileHandle(forWritingTo: inputURL)
            do {
                try input.write(contentsOf: data)
                try input.synchronize()
                try input.close()
            } catch {
                try? input.close()
                throw error
            }
            let process = Process()
            process.executableURL = executableURL
            process.arguments = [inputURL.path, outputURL.path, "-Fs_API", String(outputSampleRate), "-quiet"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if shouldCancel() {
                    process.terminate()
                    throw VoiceDecoderError.cancelled
                }
                if Date() >= deadline {
                    process.terminate()
                    throw VoiceDecoderError.timeout
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            guard process.terminationStatus == 0 else { throw VoiceDecoderError.processFailed }
            let metadata = try outputURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let size = metadata.fileSize, size > 0, size <= maximumPCMBytes else { throw VoiceDecoderError.invalidPCM }
            let pcm = try Data(contentsOf: outputURL, options: .mappedIfSafe)
            guard pcm.count == size, pcm.count.isMultiple(of: 2) else { throw VoiceDecoderError.invalidPCM }
            return .init(pcmData: pcm, sampleRate: outputSampleRate, channels: 1)
        } catch let error as VoiceDecoderError {
            throw error
        } catch {
            throw VoiceDecoderError.ioFailure
        }
    }

    private static func defaultExecutableURL() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        let candidates: [String?] = [
            environment["WECHAT_ARCHIVE_SILK_DECODER"],
            Bundle.main.url(forResource: "silk_v3_decoder", withExtension: nil)?.path(),
            "/opt/homebrew/bin/silk_v3_decoder",
            "/usr/local/bin/silk_v3_decoder"
        ]
        return candidates.compactMap { $0 }.map(URL.init(fileURLWithPath:)).first(where: { isSafeExecutable($0) })
    }

    private static func isSafeExecutable(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return false }
        return FileManager.default.isExecutableFile(atPath: candidate.path())
    }

    private func isSafeExecutable(_ url: URL) -> Bool { Self.isSafeExecutable(url) }
}

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
