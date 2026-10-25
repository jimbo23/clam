import Foundation

public struct ClamMarker: Codable, Equatable {
    public let priorSleepDisabled: Bool
    public let pid: Int32
    public let timestamp: Date

    public init(priorSleepDisabled: Bool, pid: Int32, timestamp: Date) {
        self.priorSleepDisabled = priorSleepDisabled
        self.pid = pid
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case priorSleepDisabled = "prior"
        case pid
        case timestamp
    }
}

public protocol MarkerStoring {
    func load() throws -> ClamMarker?
    func save(_ marker: ClamMarker) throws
    func remove() throws
}

public struct MarkerStore: MarkerStoring {
    private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ClamMarker? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClamMarker.self, from: data)
    }

    public func save(_ marker: ClamMarker) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(marker)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        // Commit the contents before callers are allowed to mutate system sleep.
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    public func remove() throws {
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
