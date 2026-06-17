import Foundation

struct StoredDocumentRecord: Codable, Sendable {
    var displayName: String
    var lastKnownURL: URL?
    var bookmarkData: Data?
    var state: PersistedPDFViewState?
    var updatedAt: Date
}

struct PersistedPDFViewState: Codable, Equatable, Sendable {
    var pageIndex: Int?
    var destinationPoint: CodablePoint?
    var destinationZoom: Double?
    var viewportPageIndex: Int?
    var viewportPagePoint: CodablePoint?
    var viewportAnchor: CodablePoint?
    var scaleFactor: Double
    var minScaleFactor: Double
    var maxScaleFactor: Double
    var autoScales: Bool
    var displayModeRaw: Int
    var displayDirectionRaw: Int
    var displayBoxRaw: Int
    var displaysPageBreaks: Bool
    var pageBreakMargins: CodableEdgeInsets
    var displaysAsBook: Bool
    var displaysRTL: Bool
    var pageShadowsEnabled: Bool
    var visiblePageIndexes: [Int]
    var selection: PersistedSelection?
    var updatedAt: Date
}

struct CodablePoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

struct CodableEdgeInsets: Codable, Equatable, Sendable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double
}

struct PersistedSelection: Codable, Equatable, Sendable {
    var pageRanges: [PersistedSelectionPage]
}

struct PersistedSelectionPage: Codable, Equatable, Sendable {
    var pageIndex: Int
    var ranges: [PersistedRange]
}

struct PersistedRange: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
}

actor ViewerStateStore {
    static let shared = ViewerStateStore()

    private struct StoreFile: Codable {
        var documents: [String: StoredDocumentRecord] = [:]
    }

    private let storeURL: URL
    private var loadedFile: StoreFile?

    init() {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Preview++", isDirectory: true)
        storeURL = supportURL.appendingPathComponent("ViewerState.json")
    }

    func record(for key: String) async throws -> StoredDocumentRecord? {
        try loadIfNeeded()
        return loadedFile?.documents[key]
    }

    func upsertRecord(key: String, displayName: String, url: URL?, bookmarkData: Data?, state: PersistedPDFViewState?) async throws {
        try loadIfNeeded()

        var file = loadedFile ?? StoreFile()
        let previous = file.documents[key]
        file.documents[key] = StoredDocumentRecord(
            displayName: displayName,
            lastKnownURL: url ?? previous?.lastKnownURL,
            bookmarkData: bookmarkData ?? previous?.bookmarkData,
            state: state ?? previous?.state,
            updatedAt: Date()
        )
        loadedFile = file
        try write(file)
    }

    private func loadIfNeeded() throws {
        guard loadedFile == nil else { return }

        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            loadedFile = StoreFile()
            return
        }

        let data = try Data(contentsOf: storeURL)
        loadedFile = try JSONDecoder().decode(StoreFile.self, from: data)
    }

    private func write(_ file: StoreFile) throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: storeURL, options: [.atomic])
    }
}
