import Foundation
import PDFKit
import SwiftUI
import UIKit

@MainActor
final class PDFViewerModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var document: PDFDocument?
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var currentPageIndex = 0
    @Published private(set) var readingAppearance: PDFReadingAppearance?

    let pdfView = PDFView()
    let displayName: String

    private let fileURL: URL?
    private var documentKey: String?
    private var bookmarkData: Data?
    private var accessURL: URL?
    private var didStartSecurityAccess = false
    private var latestState: PersistedPDFViewState?
    private var pendingRestoreState: PersistedPDFViewState?
    private var saveTask: Task<Void, Never>?

    init(file: PDFFile, fileURL: URL?) {
        self.fileURL = fileURL
        displayName = fileURL?.lastPathComponent ?? "PDF"
    }

    deinit {
        saveTask?.cancel()
        if didStartSecurityAccess {
            accessURL?.stopAccessingSecurityScopedResource()
        }
    }

    func load() async {
        loadState = .loading

        do {
            if let fileURL {
                let key = DocumentIdentity.key(for: fileURL)
                documentKey = key
                accessURL = fileURL
                didStartSecurityAccess = fileURL.startAccessingSecurityScopedResource()
                bookmarkData = try makeBookmarkData(for: fileURL)

                let storedRecord = try await ViewerStateStore.shared.record(for: key)
                pendingRestoreState = storedRecord?.state

                guard let loaded = PDFDocument(url: fileURL) else {
                    throw ViewerError("PDFKit could not open this file.")
                }
                try accept(loaded)

                try await ViewerStateStore.shared.upsertRecord(
                    key: key,
                    displayName: displayName,
                    url: fileURL,
                    bookmarkData: bookmarkData,
                    state: storedRecord?.state
                )
            } else {
                throw ViewerError("This document did not provide a readable file URL.")
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    func stateForInitialRestore() -> PersistedPDFViewState? {
        let state = pendingRestoreState
        pendingRestoreState = nil
        return state
    }

    func capture(from pdfView: PDFView, immediate: Bool = false) {
        guard let pdfDocument = pdfView.document else { return }
        if let currentPage = pdfView.currentPage, let index = pdfDocument.safeIndex(for: currentPage) {
            currentPageIndex = index
        }
        latestState = PersistedPDFViewState.capture(from: pdfView, document: pdfDocument)

        saveTask?.cancel()
        let delay: UInt64 = immediate ? 0 : 450_000_000
        saveTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            await self?.saveLatestState()
        }
    }

    func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    func flush() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            await self?.saveLatestState()
        }
    }

    func goToPage(at index: Int) {
        guard let document, let page = document.page(at: index) else { return }
        currentPageIndex = index
        pdfView.go(to: page)
        capture(from: pdfView)
    }

    func updateReadingAppearance(_ appearance: PDFReadingAppearance) {
        if readingAppearance != appearance {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.readingAppearance != appearance else { return }
                self.readingAppearance = appearance
            }
        }
    }

    private func saveLatestState() async {
        guard let documentKey, let latestState else { return }

        do {
            try await ViewerStateStore.shared.upsertRecord(
                key: documentKey,
                displayName: displayName,
                url: fileURL,
                bookmarkData: bookmarkData,
                state: latestState
            )
        } catch {
            loadState = .failed("Could not save viewer state: \(error.localizedDescription)")
        }
    }

    private func accept(_ pdfDocument: PDFDocument) throws {
        guard !pdfDocument.isLocked else {
            throw ViewerError("Locked or password-protected PDFs are not supported yet.")
        }
        document = pdfDocument
        loadState = .loaded
    }

    private func makeBookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

private struct ViewerError: LocalizedError {
    var message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

extension PersistedPDFViewState {
    @MainActor
    static func capture(from pdfView: PDFView, document: PDFDocument) -> PersistedPDFViewState {
        let destination = pdfView.currentDestination
        let viewportAnchor = ViewportAnchor.capture(from: pdfView, document: document)
        let pageIndex = destination?.page.flatMap { document.safeIndex(for: $0) }
            ?? pdfView.currentPage.flatMap { document.safeIndex(for: $0) }
            ?? viewportAnchor?.pageIndex

        return PersistedPDFViewState(
            pageIndex: pageIndex,
            destinationPoint: destination.map { CodablePoint(x: $0.point.x, y: $0.point.y) },
            destinationZoom: destination.map { Double($0.zoom) },
            viewportPageIndex: viewportAnchor?.pageIndex,
            viewportPagePoint: viewportAnchor?.pagePoint,
            viewportAnchor: viewportAnchor?.viewAnchor,
            scaleFactor: Double(pdfView.scaleFactor),
            minScaleFactor: Double(pdfView.minScaleFactor),
            maxScaleFactor: Double(pdfView.maxScaleFactor),
            autoScales: pdfView.autoScales,
            displayModeRaw: pdfView.displayMode.rawValue,
            displayDirectionRaw: pdfView.displayDirection.rawValue,
            displayBoxRaw: pdfView.displayBox.rawValue,
            displaysPageBreaks: pdfView.displaysPageBreaks,
            pageBreakMargins: CodableEdgeInsets(pdfView.pageBreakMargins),
            displaysAsBook: pdfView.displaysAsBook,
            displaysRTL: pdfView.displaysRTL,
            pageShadowsEnabled: pdfView.pageShadowsEnabled,
            visiblePageIndexes: pdfView.visiblePages.compactMap { document.safeIndex(for: $0) },
            selection: PersistedSelection(pdfView.currentSelection, document: document),
            updatedAt: Date()
        )
    }
}

private struct ViewportAnchor {
    var pageIndex: Int
    var pagePoint: CodablePoint
    var viewAnchor: CodablePoint

    @MainActor
    static func capture(from pdfView: PDFView, document: PDFDocument) -> ViewportAnchor? {
        let visiblePages = pdfView.visiblePages
        guard !visiblePages.isEmpty, !pdfView.bounds.isEmpty else { return nil }

        let probeY = min(pdfView.bounds.maxY - 1, pdfView.bounds.minY + 32)
        let probeX = pdfView.bounds.midX
        let pageFrames = visiblePages.compactMap { page -> (page: PDFPage, frame: CGRect, index: Int)? in
            guard let index = document.safeIndex(for: page) else { return nil }
            let frame = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page).standardized
            return (page, frame, index)
        }
        .sorted { $0.frame.minY < $1.frame.minY }

        guard let selected = pageFrames.first(where: { $0.frame.maxY >= probeY && $0.frame.minY <= pdfView.bounds.maxY })
            ?? pageFrames.first
        else {
            return nil
        }

        let pointInView = CGPoint(
            x: min(max(probeX, selected.frame.minX + 1), selected.frame.maxX - 1),
            y: min(max(probeY, selected.frame.minY + 1), selected.frame.maxY - 1)
        )
        let pagePoint = pdfView.convert(pointInView, to: selected.page)

        return ViewportAnchor(
            pageIndex: selected.index,
            pagePoint: CodablePoint(x: pagePoint.x, y: pagePoint.y),
            viewAnchor: CodablePoint(
                x: Double(pointInView.x / pdfView.bounds.width),
                y: Double(pointInView.y / pdfView.bounds.height)
            )
        )
    }
}

extension PDFDocument {
    func safeIndex(for page: PDFPage) -> Int? {
        let index = self.index(for: page)
        guard index != NSNotFound else { return nil }
        return index
    }
}

extension CodableEdgeInsets {
    init(_ edgeInsets: UIEdgeInsets) {
        top = Double(edgeInsets.top)
        left = Double(edgeInsets.left)
        bottom = Double(edgeInsets.bottom)
        right = Double(edgeInsets.right)
    }

    var uiEdgeInsets: UIEdgeInsets {
        UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}

extension PersistedSelection {
    init?(_ selection: PDFSelection?, document: PDFDocument) {
        guard let selection else { return nil }

        var pages: [PersistedSelectionPage] = []
        for page in selection.pages {
            let rangeCount = selection.numberOfTextRanges(on: page)
            guard rangeCount > 0 else { continue }

            let ranges = (0..<rangeCount).map { index in
                let range = selection.range(at: index, on: page)
                return PersistedRange(location: range.location, length: range.length)
            }
            guard let pageIndex = document.safeIndex(for: page) else { continue }
            pages.append(PersistedSelectionPage(pageIndex: pageIndex, ranges: ranges))
        }

        guard !pages.isEmpty else { return nil }
        pageRanges = pages
    }

    func restore(in document: PDFDocument) -> PDFSelection? {
        let restored = PDFSelection(document: document)

        for pageRange in pageRanges {
            guard let page = document.page(at: pageRange.pageIndex) else { continue }

            let selections = pageRange.ranges.compactMap { persistedRange -> PDFSelection? in
                let nsRange = NSRange(location: persistedRange.location, length: persistedRange.length)
                return page.selection(for: nsRange)
            }
            restored.add(selections)
        }

        return restored.pages.isEmpty ? nil : restored
    }
}
