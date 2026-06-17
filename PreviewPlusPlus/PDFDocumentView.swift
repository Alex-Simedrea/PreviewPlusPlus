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
                    .background(SplitViewWidthConfigurator(width: 112))
                    .navigationSplitViewColumnWidth(min: 112, ideal: 112, max: 112)
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
