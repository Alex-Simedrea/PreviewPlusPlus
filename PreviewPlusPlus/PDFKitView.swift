import PDFKit
import SwiftUI
import UIKit

struct PDFKitView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: PDFViewerModel

    func makeUIView(context: Context) -> PDFView {
        let pdfView = model.pdfView
        pdfView.delegate = context.coordinator
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .systemBackground
        pdfView.pageShadowsEnabled = true

        context.coordinator.attach(to: pdfView)
        pdfView.applyScrollEdgeEffect()
        pdfView.applyReadingAppearance(for: colorScheme)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        pdfView.applyScrollEdgeEffect()
        pdfView.applyReadingAppearance(for: colorScheme)
        guard pdfView.document !== model.document else { return }

        let state = model.stateForInitialRestore()
        if state != nil {
            context.coordinator.beginRestoring()
            model.cancelPendingSave()
        }

        pdfView.document = model.document
        pdfView.applyReadingAppearance(for: colorScheme)
        if let document = model.document {
            pdfView.layoutDocumentView()
            pdfView.applyReadingAppearance(for: colorScheme)
            if let state {
                pdfView.restore(state, document: document)
                pdfView.applyReadingAppearance(for: colorScheme)
                DispatchQueue.main.async { [weak pdfView, document] in
                    guard let pdfView, pdfView.document === document else { return }
                    _ = pdfView.restoreViewportAnchor(state, document: document)
                    pdfView.applyReadingAppearance(for: colorScheme)
                }
                context.coordinator.endRestoringSoon()
            }
        } else {
            context.coordinator.endRestoring()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    final class Coordinator: NSObject, PDFViewDelegate {
        private weak var model: PDFViewerModel?
        private var isRestoring = false

        init(model: PDFViewerModel) {
            self.model = model
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @MainActor
        func attach(to pdfView: PDFView) {
            NotificationCenter.default.removeObserver(self)

            let names: [Notification.Name] = [
                .PDFViewPageChanged,
                .PDFViewScaleChanged,
                .PDFViewDisplayModeChanged,
                .PDFViewDisplayBoxChanged,
                .PDFViewVisiblePagesChanged,
                .PDFViewSelectionChanged
            ]

            for name in names {
                NotificationCenter.default.addObserver(self, selector: #selector(pdfViewDidChange(_:)), name: name, object: pdfView)
            }

            pdfView.pageOverlayViewProvider = nil
        }

        @MainActor @objc private func pdfViewDidChange(_ notification: Notification) {
            guard !isRestoring else { return }
            guard let pdfView = notification.object as? PDFView else { return }
            model?.capture(from: pdfView)
        }

        @MainActor
        func beginRestoring() {
            isRestoring = true
        }

        @MainActor
        func endRestoringSoon() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
                self?.isRestoring = false
            }
        }

        @MainActor
        func endRestoring() {
            isRestoring = false
        }
    }
}

struct PDFThumbnailSidebarView: View {
    @ObservedObject var model: PDFViewerModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(0..<(model.document?.pageCount ?? 0), id: \.self) { index in
                    PDFPageThumbnailView(model: model, pageIndex: index)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct PDFPageThumbnailView: View {
    @ObservedObject var model: PDFViewerModel
    let pageIndex: Int
    @State private var thumbnail: UIImage?

    private var isSelected: Bool {
        model.currentPageIndex == pageIndex
    }

    var body: some View {
        Button {
            model.goToPage(at: pageIndex)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(uiColor: .systemBackground))

                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(width: 76, height: 104)
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Color.accentColor : Color(uiColor: .separator).opacity(0.35), lineWidth: isSelected ? 2 : 0.5)
            }
            .shadow(color: .black.opacity(0.14), radius: 1.5, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .task(id: pageIndex) {
            guard thumbnail == nil, let page = model.document?.page(at: pageIndex) else { return }
            thumbnail = page.thumbnail(of: CGSize(width: 152, height: 208), for: .cropBox)
        }
    }
}

private extension PDFView {
    func applyScrollEdgeEffect() {
        guard let scrollView = firstDescendant(of: UIScrollView.self) else { return }
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.topEdgeEffect.style = .hard
        scrollView.bottomEdgeEffect.style = .automatic
    }

    func applyReadingAppearance(for colorScheme: ColorScheme) {
        overrideUserInterfaceStyle = .unspecified
        backgroundColor = .systemBackground
        documentView?.backgroundColor = .clear
        documentView?.layer.filters = nil
        applyPrivateReadingAppearance(isDark: colorScheme == .dark)
        invalidateRenderedPages()
    }

    func applyPrivateReadingAppearance(isDark: Bool) {
        let pageBackgroundColor = UIColor.systemBackground
        privateSetBool("setAllowsDarkAppearanceContent:", isDark)
        privateSetObject("setDarkModeBackgroundColor:", pageBackgroundColor)
        privateSetObject("setPageColor:", pageBackgroundColor)
        privateSetBool("enableBackgroundImages:", true)

        guard let renderingProperties = privateObject("renderingProperties") as? NSObject else { return }
        renderingProperties.privateSetObject("setTraitCollection:", traitCollection)
        renderingProperties.privateSetInteger("setAppearanceStyle:", traitCollection.userInterfaceStyle.rawValue)
        renderingProperties.privateSetObject("setDarkModePageBackgroundColor:", pageBackgroundColor)
        renderingProperties.privateSetObject("setPageColor:", pageBackgroundColor)
        renderingProperties.privateSetBool("setEnableBackgroundImages:", true)
        renderingProperties.privateSetBool("setEnableTileUpdates:", true)

        document?.privateSetObject("setRenderingProperties:", renderingProperties)
    }

    func invalidateRenderedPages() {
        setNeedsDisplay()
        documentView?.setNeedsDisplay()
        documentView?.setNeedsLayout()
        firstDescendant(of: UIScrollView.self)?.setNeedsDisplay()
    }

    func restore(_ state: PersistedPDFViewState, document: PDFDocument) {
        displayMode = PDFDisplayMode(rawValue: state.displayModeRaw) ?? .singlePageContinuous
        displayDirection = PDFDisplayDirection(rawValue: state.displayDirectionRaw) ?? .vertical
        displayBox = PDFDisplayBox(rawValue: state.displayBoxRaw) ?? .cropBox
        displaysPageBreaks = state.displaysPageBreaks
        pageBreakMargins = state.pageBreakMargins.uiEdgeInsets
        displaysAsBook = state.displaysAsBook
        displaysRTL = state.displaysRTL
        pageShadowsEnabled = state.pageShadowsEnabled
        minScaleFactor = state.minScaleFactor
        maxScaleFactor = state.maxScaleFactor
        autoScales = state.autoScales
        if !state.autoScales {
            scaleFactor = state.scaleFactor
        }
        layoutDocumentView()
        layoutIfNeeded()

        if restoreViewportAnchor(state, document: document) {
            // Restored using a precise visible-page anchor.
        } else if let pageIndex = state.pageIndex, let page = document.page(at: pageIndex) {
            if let point = state.destinationPoint {
                let destination = PDFDestination(page: page, at: CGPoint(x: point.x, y: point.y))
                if let zoom = state.destinationZoom {
                    destination.zoom = zoom
                }
                go(to: destination)
            } else {
                go(to: page)
            }
        } else if let firstPage = document.page(at: 0) {
            go(to: firstPage)
        }

        if let selection = state.selection?.restore(in: document) {
            currentSelection = selection
            scrollSelectionToVisible(nil)
        }
    }

    func restoreViewportAnchor(_ state: PersistedPDFViewState, document: PDFDocument) -> Bool {
        guard
            let pageIndex = state.viewportPageIndex,
            let pagePoint = state.viewportPagePoint,
            let page = document.page(at: pageIndex),
            let scrollView = firstDescendant(of: UIScrollView.self)
        else {
            return false
        }

        go(to: page)
        layoutDocumentView()
        layoutIfNeeded()

        let anchor = state.viewportAnchor ?? CodablePoint(x: 0.5, y: 0.5)
        let viewAnchor = CGPoint(
            x: bounds.width * CGFloat(anchor.x),
            y: bounds.height * CGFloat(anchor.y)
        )
        let currentViewPoint = convert(CGPoint(x: CGFloat(pagePoint.x), y: CGFloat(pagePoint.y)), from: page)
        var targetOffset = CGPoint(
            x: scrollView.contentOffset.x + currentViewPoint.x - viewAnchor.x,
            y: scrollView.contentOffset.y + currentViewPoint.y - viewAnchor.y
        )

        let inset = scrollView.adjustedContentInset
        let minX = -inset.left
        let minY = -inset.top
        let maxX = max(minX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)

        targetOffset.x = min(max(targetOffset.x, minX), maxX)
        targetOffset.y = min(max(targetOffset.y, minY), maxY)
        scrollView.setContentOffset(targetOffset, animated: false)
        return true
    }

}

private extension NSObject {
    func privateObject(_ selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector), let implementation = method(for: selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector) -> AnyObject?
        return unsafeBitCast(implementation, to: Function.self)(self, selector)
    }

    func privateSetObject(_ selectorName: String, _ object: AnyObject?) {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector), let implementation = method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        unsafeBitCast(implementation, to: Function.self)(self, selector, object)
    }

    func privateSetBool(_ selectorName: String, _ value: Bool) {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector), let implementation = method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: Function.self)(self, selector, value)
    }

    func privateSetInteger(_ selectorName: String, _ value: Int) {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector), let implementation = method(for: selector) else { return }
        typealias Function = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: Function.self)(self, selector, value)
    }
}

private extension UIView {
    func firstDescendant<T: UIView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T {
                return match
            }
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
