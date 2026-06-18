import SwiftUI
import UIKit

struct PDFDocumentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: PDFViewerModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    private let fileURL: URL?

    init(file: PDFFile, fileURL: URL?) {
        self.fileURL = fileURL
        _model = StateObject(wrappedValue: PDFViewerModel(file: file, fileURL: fileURL))
    }

    var body: some View {
        content
            .background(DocumentGroupNavigationBarHider())
            .background(DocumentSceneDeduplicator(fileURL: fileURL))
            .toolbarRole(.automatic)
            .task {
                await model.load()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active {
                    model.flush()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            NavigationSplitView(columnVisibility: $columnVisibility) {
                PDFThumbnailSidebarView(model: model)
                    .background(SplitViewWidthConfigurator(width: 130))
                    .navigationSplitViewColumnWidth(min: 130, ideal: 130, max: 130)
            } detail: {
                PDFKitView(model: model)
                    .ignoresSafeArea(.container, edges: .top)
                    .navigationTitle(model.displayName)
                    .navigationBarTitleDisplayMode(.inline)
                    .previewNavigationDocument(fileURL)
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItemGroup(placement: .topBarTrailing) {
                            Button {
                                model.pdfView.autoScales = true
                                model.capture(from: model.pdfView, immediate: true)
                            } label: {
                                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                            }
                            .accessibilityLabel("Zoom to Fit")
                        }
                    }
            }
            .navigationSplitViewStyle(.balanced)
        case .failed(let message):
            ContentUnavailableView("Could not open PDF", systemImage: "doc.text.magnifyingglass", description: Text(message))
                .navigationTitle(model.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .previewNavigationDocument(fileURL)
        }
    }
}

private struct SplitViewWidthConfigurator: UIViewControllerRepresentable {
    let width: CGFloat

    func makeUIViewController(context: Context) -> Controller {
        Controller(width: width)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.width = width
        controller.configureSplitView()
    }

    final class Controller: UIViewController {
        var width: CGFloat

        init(width: CGFloat) {
            self.width = width
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            configureSplitView()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            configureSplitView()
        }

        func configureSplitView() {
            guard let splitViewController else { return }
            splitViewController.minimumPrimaryColumnWidth = width
            splitViewController.preferredPrimaryColumnWidth = width
            splitViewController.maximumPrimaryColumnWidth = width
            splitViewController.preferredPrimaryColumnWidthFraction = 0
            splitViewController.preferredSplitBehavior = .tile
        }
    }
}

private struct DocumentGroupNavigationBarHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hideOuterNavigationBar()
    }

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            hideOuterNavigationBar()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            hideOuterNavigationBar()
        }

        func hideOuterNavigationBar() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let navigationController = self.outerDocumentNavigationController else { return }
                navigationController.setNavigationBarHidden(true, animated: false)
            }
        }

        private var outerDocumentNavigationController: UINavigationController? {
            var current = parent
            while let viewController = current {
                if let navigationController = viewController as? UINavigationController,
                   !(navigationController.parent is UISplitViewController) {
                    return navigationController
                }
                current = viewController.parent
            }
            return nil
        }
    }
}

private struct DocumentSceneDeduplicator: UIViewControllerRepresentable {
    let fileURL: URL?

    func makeUIViewController(context: Context) -> Controller {
        Controller(fileURL: fileURL)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.fileURL = fileURL
        controller.deduplicateIfNeeded()
    }

    final class Controller: UIViewController {
        var fileURL: URL? {
            didSet {
                if fileURL != oldValue {
                    unregisterCurrentSession()
                    registeredDocumentKey = nil
                    registeredSessionID = nil
                }
            }
        }

        private var registeredDocumentKey: String?
        private var registeredSessionID: String?

        init(fileURL: URL?) {
            self.fileURL = fileURL
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            Self.unregisterSession(documentKey: registeredDocumentKey, sessionID: registeredSessionID)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            deduplicateIfNeeded()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            deduplicateIfNeeded()
        }

        func deduplicateIfNeeded() {
            DispatchQueue.main.async { [weak self] in
                guard
                    let self,
                    let fileURL = self.fileURL,
                    let windowScene = self.view.window?.windowScene
                else {
                    return
                }

                let documentKey = DocumentIdentity.key(for: fileURL)
                let session = windowScene.session
                let targetIdentifiers = DocumentWindowRegistry.targetIdentifiers(for: fileURL)
                DocumentWindowRegistry.shared.configureActivationConditions(for: windowScene, targetIdentifiers: targetIdentifiers)

                if let existingSession = DocumentWindowRegistry.shared.existingSession(for: documentKey, excluding: session) {
                    UIApplication.shared.requestSceneSessionActivation(existingSession, userActivity: nil, options: nil)
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                    return
                }

                DocumentWindowRegistry.shared.register(documentKey: documentKey, session: session)
                self.registeredDocumentKey = documentKey
                self.registeredSessionID = session.persistentIdentifier
            }
        }

        private func unregisterCurrentSession() {
            Self.unregisterSession(documentKey: registeredDocumentKey, sessionID: registeredSessionID)
        }

        private nonisolated static func unregisterSession(documentKey: String?, sessionID: String?) {
            Task { @MainActor in
                DocumentWindowRegistry.shared.unregister(documentKey: documentKey, sessionID: sessionID)
            }
        }
    }
}

@MainActor
private final class DocumentWindowRegistry {
    static let shared = DocumentWindowRegistry()

    private var sessionIDsByDocumentKey: [String: String] = [:]

    private init() {}

    static func targetIdentifiers(for fileURL: URL) -> [String] {
        let documentKey = DocumentIdentity.key(for: fileURL)
        return Array(Set([
            "previewplusplus://document/\(documentKey)",
            fileURL.absoluteString,
            fileURL.standardizedFileURL.absoluteString,
            fileURL.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        ]))
    }

    func register(documentKey: String, session: UISceneSession) {
        pruneClosedSessions()
        sessionIDsByDocumentKey[documentKey] = session.persistentIdentifier
    }

    func unregister(documentKey: String?, sessionID: String?) {
        guard
            let documentKey,
            let sessionID,
            sessionIDsByDocumentKey[documentKey] == sessionID
        else {
            return
        }
        sessionIDsByDocumentKey.removeValue(forKey: documentKey)
    }

    func existingSession(for documentKey: String, excluding currentSession: UISceneSession) -> UISceneSession? {
        pruneClosedSessions()
        guard
            let existingSessionID = sessionIDsByDocumentKey[documentKey],
            existingSessionID != currentSession.persistentIdentifier
        else {
            return nil
        }

        return UIApplication.shared.openSessions.first { $0.persistentIdentifier == existingSessionID }
    }

    func configureActivationConditions(for windowScene: UIWindowScene, targetIdentifiers: [String]) {
        guard !targetIdentifiers.isEmpty else { return }

        let predicate = NSPredicate(format: "self IN %@", targetIdentifiers)
        windowScene.activationConditions.canActivateForTargetContentIdentifierPredicate = predicate
        windowScene.activationConditions.prefersToActivateForTargetContentIdentifierPredicate = predicate

        let activity = NSUserActivity(activityType: "ro.attractivestar.previewplusplus.document")
        activity.targetContentIdentifier = targetIdentifiers[0]
        activity.userInfo = ["targetIdentifiers": targetIdentifiers]
        windowScene.userActivity = activity
    }

    private func pruneClosedSessions() {
        let openSessionIDs = Set(UIApplication.shared.openSessions.map(\.persistentIdentifier))
        sessionIDsByDocumentKey = sessionIDsByDocumentKey.filter { _, sessionID in
            openSessionIDs.contains(sessionID)
        }
    }
}

private extension View {
    @ViewBuilder
    func previewNavigationDocument(_ url: URL?) -> some View {
        if let url {
            navigationDocument(url)
        } else {
            self
        }
    }
}
