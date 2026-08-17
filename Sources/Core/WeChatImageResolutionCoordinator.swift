import Foundation

/// Privacy-safe outcome for one locally located attachment variant.
public struct WeChatImageDecodedVariant: Equatable, Sendable {
    public let present: Bool
    public let decoded: Bool
    public let format: WeChatDecodedImageFormat?
    public let dimensionsAvailable: Bool

    public init(present: Bool, decoded: Bool, format: WeChatDecodedImageFormat?, dimensionsAvailable: Bool) {
        self.present = present
        self.decoded = decoded
        self.format = format
        self.dimensionsAvailable = dimensionsAvailable
    }

    static let missing = WeChatImageDecodedVariant(present: false, decoded: false, format: nil, dimensionsAvailable: false)
    static let pending = WeChatImageDecodedVariant(present: true, decoded: false, format: nil, dimensionsAvailable: false)
}

/// In-memory outcome for one bounded image-resolution run. The corresponding
/// report writer intentionally serializes only its privacy-safe projection.
public struct WeChatImageResolutionRun: Equatable, Sendable {
    public let sampledRecordCount: Int
    public let resolution: WeChatImageMessageResolution?
    public let keyDerivationAvailable: Bool
    public let keyVerificationPassed: Bool
    public let thumbnail: WeChatImageDecodedVariant
    public let main: WeChatImageDecodedVariant
    public let hd: WeChatImageDecodedVariant
    public let diagnostics: [WeChatImageResolutionDiagnostic]

    public init(
        sampledRecordCount: Int,
        resolution: WeChatImageMessageResolution?,
        keyDerivationAvailable: Bool,
        keyVerificationPassed: Bool,
        thumbnail: WeChatImageDecodedVariant,
        main: WeChatImageDecodedVariant,
        hd: WeChatImageDecodedVariant,
        diagnostics: [WeChatImageResolutionDiagnostic]
    ) {
        self.sampledRecordCount = sampledRecordCount
        self.resolution = resolution
        self.keyDerivationAvailable = keyDerivationAvailable
        self.keyVerificationPassed = keyVerificationPassed
        self.thumbnail = thumbnail
        self.main = main
        self.hd = hd
        self.diagnostics = diagnostics
    }

    public var imageConfirmed: Bool {
        keyVerificationPassed && [thumbnail, main, hd].contains(where: { $0.decoded && $0.format?.isImageEvidence == true })
    }
}

/// Bounded Phase 3A.2 workflow. It evaluates no more than 100 Type 3 rows,
/// finds one deterministic resource/file chain, and stops once that chain has
/// yielded a verified decoded image.
public struct WeChatImageResolutionCoordinator: Sendable {
    private let maximumDATBytes = 128 * 1_024 * 1_024

    public init() {}

    public func resolveFirstImage(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        accountRoot: URL,
        calendar: Calendar = .current
    ) throws -> WeChatImageResolutionRun {
        try resolveFirstImage(
            exportRoot: exportRoot,
            candidate: candidate,
            accountRoot: accountRoot,
            keyProvider: WeChatKVCommImageKeyProvider(),
            calendar: calendar
        )
    }

    public func resolveFirstImage(
        exportRoot: URL,
        candidate: MessageTableCandidate,
        accountRoot: URL,
        keyProvider: any WeChatImageKeyProvider,
        calendar: Calendar = .current
    ) throws -> WeChatImageResolutionRun {
        guard let typeColumn = candidate.columns.first(where: {
            ["local_type", "msg_type", "message_type", "type"].contains($0.lowercased())
        }) else {
            throw ArchiveError.invalidInput
        }
        let records = try WeChatMessageSampleReader().read(
            exportRoot: exportRoot,
            candidate: candidate,
            whereIntegerColumn: typeColumn,
            equals: 3,
            sampleLimit: 100
        )
        let resolver = WeChatImageMessageResolver()
        var firstResolution: WeChatImageMessageResolution?
        for record in records {
            let resolution = try resolver.resolve(
                message: record,
                candidate: candidate,
                exportRoot: exportRoot,
                accountRoot: accountRoot,
                calendar: calendar
            )
            if firstResolution == nil { firstResolution = resolution }
            guard resolution.resourceMatch != .notFound,
                  resolution.fileBase != nil,
                  resolution.assets.preferredURL != nil else { continue }
            return try finish(
                sampledRecordCount: records.count,
                resolution: resolution,
                accountRoot: accountRoot,
                keyProvider: keyProvider
            )
        }
        let diagnostics = firstResolution?.diagnostics ?? [.messageResourceNotFound]
        return WeChatImageResolutionRun(
            sampledRecordCount: records.count,
            resolution: firstResolution,
            keyDerivationAvailable: false,
            keyVerificationPassed: false,
            thumbnail: .missing,
            main: .missing,
            hd: .missing,
            diagnostics: diagnostics
        )
    }

    private func finish(
        sampledRecordCount: Int,
        resolution: WeChatImageMessageResolution,
        accountRoot: URL,
        keyProvider: any WeChatImageKeyProvider
    ) throws -> WeChatImageResolutionRun {
        var diagnostics = resolution.diagnostics
        let decoder = WeChatImageDatDecoder()
        let initialVariants = variantPlaceholders(for: resolution.assets)
        guard let probeURL = resolution.assets.preferredURL else {
            return run(
                sampled: sampledRecordCount,
                resolution: resolution,
                keyAvailable: false,
                keyVerified: false,
                variants: initialVariants,
                diagnostics: diagnostics
            )
        }
        let probeData = try readDAT(at: probeURL)
        let version = decoder.version(for: probeData)
        guard version != .unknown else {
            diagnostics.append(.datFormatUnknown)
            return run(sampled: sampledRecordCount, resolution: resolution, keyAvailable: false, keyVerified: false, variants: initialVariants, diagnostics: diagnostics)
        }

        let keyCandidates: [WeChatImageKeyMaterial]
        switch version {
        case .v2:
            keyCandidates = try keyProvider.keyCandidates(accountRoot: accountRoot)
            if keyCandidates.isEmpty {
                diagnostics.append(.imageKeyUnavailable)
                return run(sampled: sampledRecordCount, resolution: resolution, keyAvailable: false, keyVerified: false, variants: initialVariants, diagnostics: diagnostics)
            }
        case .v1, .legacy:
            keyCandidates = [WeChatImageKeyMaterial(aesKey: Data(repeating: 0, count: 16), xorKey: 0)]
        case .unknown:
            keyCandidates = []
        }

        guard let acceptedKey = acceptedKey(from: keyCandidates, probeData: probeData, decoder: decoder) else {
            diagnostics.append(version == .v2 ? .imageKeyRejected : .datDecodeFailed)
            return run(sampled: sampledRecordCount, resolution: resolution, keyAvailable: version == .v2, keyVerified: false, variants: initialVariants, diagnostics: diagnostics)
        }

        let variants = try decodeVariants(assets: resolution.assets, key: acceptedKey, decoder: decoder)
        let decodedVariants = [variants.thumbnail, variants.main, variants.hd]
        if decodedVariants.contains(where: { $0.present && !$0.decoded }) { diagnostics.append(.datDecodeFailed) }
        if decodedVariants.contains(where: { $0.present && $0.decoded && $0.format == .unknown }) { diagnostics.append(.decodedImageUnknown) }
        if decodedVariants.contains(where: { $0.decoded && $0.format?.isImageEvidence == true }) { diagnostics.append(.decodedImageVerified) }
        return run(
            sampled: sampledRecordCount,
            resolution: resolution,
            keyAvailable: version == .v2,
            keyVerified: decodedVariants.contains(where: { $0.decoded && $0.format?.isImageEvidence == true }),
            variants: variants,
            diagnostics: diagnostics
        )
    }

    private func acceptedKey(
        from candidates: [WeChatImageKeyMaterial],
        probeData: Data,
        decoder: WeChatImageDatDecoder
    ) -> WeChatImageKeyMaterial? {
        for candidate in candidates {
            if let decoded = try? decoder.decode(probeData, keyMaterial: candidate), decoded.format.isImageEvidence {
                return candidate
            }
        }
        return nil
    }

    private func variantPlaceholders(for assets: WeChatImageAssetSet) -> (thumbnail: WeChatImageDecodedVariant, main: WeChatImageDecodedVariant, hd: WeChatImageDecodedVariant) {
        (
            thumbnail: assets.thumbnailURL == nil ? .missing : .pending,
            main: assets.mainURL == nil ? .missing : .pending,
            hd: assets.hdURL == nil ? .missing : .pending
        )
    }

    private func decodeVariants(
        assets: WeChatImageAssetSet,
        key: WeChatImageKeyMaterial,
        decoder: WeChatImageDatDecoder
    ) throws -> (thumbnail: WeChatImageDecodedVariant, main: WeChatImageDecodedVariant, hd: WeChatImageDecodedVariant) {
        (
            thumbnail: try decodeVariant(at: assets.thumbnailURL, key: key, decoder: decoder),
            main: try decodeVariant(at: assets.mainURL, key: key, decoder: decoder),
            hd: try decodeVariant(at: assets.hdURL, key: key, decoder: decoder)
        )
    }

    private func decodeVariant(at url: URL?, key: WeChatImageKeyMaterial, decoder: WeChatImageDatDecoder) throws -> WeChatImageDecodedVariant {
        guard let url else { return .missing }
        do {
            let decoded = try decoder.decode(readDAT(at: url), keyMaterial: key)
            return WeChatImageDecodedVariant(
                present: true,
                decoded: true,
                format: decoded.format,
                dimensionsAvailable: decoded.dimensions != nil
            )
        } catch {
            return .pending
        }
    }

    private func readDAT(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= maximumDATBytes else { throw ArchiveError.invalidInput }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    private func run(
        sampled: Int,
        resolution: WeChatImageMessageResolution,
        keyAvailable: Bool,
        keyVerified: Bool,
        variants: (thumbnail: WeChatImageDecodedVariant, main: WeChatImageDecodedVariant, hd: WeChatImageDecodedVariant),
        diagnostics: [WeChatImageResolutionDiagnostic]
    ) -> WeChatImageResolutionRun {
        WeChatImageResolutionRun(
            sampledRecordCount: sampled,
            resolution: resolution,
            keyDerivationAvailable: keyAvailable,
            keyVerificationPassed: keyVerified,
            thumbnail: variants.thumbnail,
            main: variants.main,
            hd: variants.hd,
            diagnostics: Array(NSOrderedSet(array: diagnostics)) as? [WeChatImageResolutionDiagnostic] ?? diagnostics
        )
    }
}

private extension WeChatDecodedImageFormat {
    var isImageEvidence: Bool {
        switch self {
        case .jpeg, .png, .gif, .webp, .heic, .wxgf: true
        case .unknown: false
        }
    }
}
