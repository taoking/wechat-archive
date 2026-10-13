import Darwin
import Foundation

/// Uses only Zstandard's stable simple API. Local library discovery never
/// depends on message content. Functions are stateless and thread safe.
final class NativeZstdPayloadRuntime: @unchecked Sendable {
    private typealias Decode = @convention(c) (UnsafeMutableRawPointer?, Int, UnsafeRawPointer?, Int) -> Int
    private typealias FrameSize = @convention(c) (UnsafeRawPointer?, Int) -> UInt64
    private typealias CompressedSize = @convention(c) (UnsafeRawPointer?, Int) -> Int
    private typealias IsError = @convention(c) (Int) -> UInt32
    static let shared: NativeZstdPayloadRuntime? = load()
    private let handle: UnsafeMutableRawPointer
    private let decode: Decode
    private let frameSize: FrameSize
    private let compressedSize: CompressedSize
    private let isError: IsError

    private init?(path: String) {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        guard let decode = dlsym(handle, "ZSTD_decompress"),
              let frameSize = dlsym(handle, "ZSTD_getFrameContentSize"),
              let compressedSize = dlsym(handle, "ZSTD_findFrameCompressedSize"),
              let isError = dlsym(handle, "ZSTD_isError") else { dlclose(handle); return nil }
        self.handle = handle
        self.decode = unsafeBitCast(decode, to: Decode.self)
        self.frameSize = unsafeBitCast(frameSize, to: FrameSize.self)
        self.compressedSize = unsafeBitCast(compressedSize, to: CompressedSize.self)
        self.isError = unsafeBitCast(isError, to: IsError.self)
    }

    deinit { dlclose(handle) }

    func decompress(_ data: Data) -> Data? {
        let maximum = 8 * 1_024 * 1_024
        guard data.count >= 4, data.count <= 4 * 1_024 * 1_024,
              data.starts(with: [0x28, 0xb5, 0x2f, 0xfd]) else { return nil }
        return data.withUnsafeBytes { source in
            let size = frameSize(source.baseAddress, source.count)
            guard size != UInt64.max - 1, size == UInt64.max || size <= UInt64(maximum) else { return nil }
            let firstFrame = compressedSize(source.baseAddress, source.count)
            guard isError(firstFrame) == 0 else { return nil }
            let capacity = size == UInt64.max || firstFrame != source.count ? maximum : max(1, Int(size))
            var output = Data(count: capacity)
            let count = output.withUnsafeMutableBytes { decode($0.baseAddress, capacity, source.baseAddress, source.count) }
            guard isError(count) == 0, count > 0, count <= maximum, count <= capacity else { return nil }
            output.removeSubrange(count..<output.count)
            return output
        }
    }

    private static func load() -> NativeZstdPayloadRuntime? {
        let bundled = Bundle.main.bundleURL.appending(path: "Contents/Frameworks/libzstd.dylib").path()
        for path in [bundled, "/opt/homebrew/opt/zstd/lib/libzstd.dylib", "/usr/local/opt/zstd/lib/libzstd.dylib"] {
            if let runtime = NativeZstdPayloadRuntime(path: path) { return runtime }
        }
        return nil
    }
}
