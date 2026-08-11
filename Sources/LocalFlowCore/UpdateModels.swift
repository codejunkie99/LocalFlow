import Foundation

public struct LocalFlowVersion: RawRepresentable, Codable, Sendable, Hashable, Comparable {
    public let rawValue: String
    private let components: [Int]

    public init(_ rawValue: String) throws {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0,
              String(major) == parts[0],
              String(minor) == parts[1],
              String(patch) == parts[2]
        else {
            throw VersionError.invalid(rawValue)
        }
        self.rawValue = rawValue
        self.components = [major, minor, patch]
    }

    public init(rawValue: String) {
        self = try! LocalFlowVersion(rawValue)
    }

    public static func < (lhs: LocalFlowVersion, rhs: LocalFlowVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }

    private enum VersionError: Error {
        case invalid(String)
    }
}

public struct LocalFlowReleaseManifest: Codable, Sendable, Equatable {
    public let version: LocalFlowVersion
    public let commit: String
    public let sourceURL: URL
    public let sourceSHA256: String

    public init(
        version: LocalFlowVersion,
        commit: String,
        sourceURL: URL,
        sourceSHA256: String
    ) throws {
        guard Self.isValidCommit(commit) else {
            throw ManifestError.invalidCommit
        }
        guard Self.isValidSHA256(sourceSHA256) else {
            throw ManifestError.invalidChecksum
        }
        self.version = version
        self.commit = commit
        self.sourceURL = sourceURL
        self.sourceSHA256 = sourceSHA256
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(LocalFlowVersion.self, forKey: .version),
            commit: container.decode(String.self, forKey: .commit),
            sourceURL: container.decode(URL.self, forKey: .sourceURL),
            sourceSHA256: container.decode(String.self, forKey: .sourceSHA256)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case commit
        case sourceURL = "source_url"
        case sourceSHA256 = "source_sha256"
    }

    private static func isValidCommit(_ commit: String) -> Bool {
        (commit.count == 40 || commit.count == 64)
            && commit.allSatisfy {
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }
    }

    private static func isValidSHA256(_ digest: String) -> Bool {
        digest.count == 64
            && digest.allSatisfy {
                ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
            }
    }

    private enum ManifestError: Error {
        case invalidCommit
        case invalidChecksum
    }
}

public enum UpdateState: Sendable, Equatable {
    case idle
    case checking
    case downloading(progress: Double)
    case building
    case installing
    case current
    case ready(version: LocalFlowVersion)
    case failed(UpdateFailure)
}

public enum UpdateFailure: String, Error, Sendable, Equatable {
    case network
    case invalidManifest
    case checksumMismatch
    case unsafeArchive
    case buildFailed
    case signingIdentityMissing
    case signatureMismatch
    case databaseBackupFailed
    case replacementFailed
    case relaunchFailed
}
