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
        context.coordinator.installTraitObserver(on: pdfView)
        pdfView.applyScrollEdgeEffect()
        context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.installTraitObserver(on: pdfView)
        pdfView.applyScrollEdgeEffect()
        context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
        context.coordinator.scheduleReadingAppearanceRefresh(on: pdfView, for: colorScheme)
        guard pdfView.document !== model.document else { return }
        
        let state = model.stateForInitialRestore()
        if state != nil {
            context.coordinator.beginRestoring()
            model.cancelPendingSave()
        }
        
        pdfView.document = model.document
        context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
        if let document = model.document {
            pdfView.layoutDocumentView()
            context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
            if let state {
                pdfView.restore(state, document: document)
                context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
                DispatchQueue.main.async { [weak pdfView, document] in
                    guard let pdfView, pdfView.document === document else { return }
                    _ = pdfView.restoreViewportAnchor(state, document: document)
                    context.coordinator.applyReadingAppearance(to: pdfView, for: colorScheme)
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
        private weak var observedPDFView: PDFView?
        private var traitObservation: UITraitChangeRegistration?
        private var lastReadingAppearanceSignature: String?
        private var readingAppearanceRefreshWorkItem: DispatchWorkItem?
        
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
        
        @MainActor
        func installTraitObserver(on pdfView: PDFView) {
            guard observedPDFView !== pdfView else { return }
            traitObservation = nil
            observedPDFView = pdfView
            
            traitObservation = pdfView.registerForTraitChanges([
                UITraitUserInterfaceStyle.self,
                UITraitActiveAppearance.self,
                UITraitLayoutDirection.self,
                UITraitDisplayScale.self
            ]) { [weak self] (pdfView: PDFView, _) in
                DispatchQueue.main.async { [weak self, weak pdfView] in
                    guard let self, let pdfView else { return }
                    self.applyReadingAppearanceForCurrentTraits(to: pdfView)
                    self.scheduleReadingAppearanceRefreshForCurrentTraits(on: pdfView)
                }
            }
        }
        
        @MainActor
        func applyReadingAppearance(to pdfView: PDFView, for colorScheme: ColorScheme) {
            pdfView.overrideUserInterfaceStyle = .unspecified
            pdfView.backgroundColor = .systemBackground
            pdfView.documentView?.backgroundColor = .clear
            pdfView.documentView?.layer.filters = nil
            if pdfView.applyPrivateReadingAppearance(isDark: colorScheme == .dark, lastSignature: &lastReadingAppearanceSignature) {
                pdfView.invalidateRenderedPages()
            }
        }
        
        @MainActor
        func applyReadingAppearanceForCurrentTraits(to pdfView: PDFView) {
            applyReadingAppearance(to: pdfView, for: pdfView.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        }
        
        @MainActor
        func scheduleReadingAppearanceRefresh(on pdfView: PDFView, for colorScheme: ColorScheme) {
            readingAppearanceRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                pdfView.layoutIfNeeded()
                pdfView.documentView?.layoutIfNeeded()
                self.applyReadingAppearance(to: pdfView, for: colorScheme)
            }
            readingAppearanceRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }
        
        @MainActor
        func scheduleReadingAppearanceRefreshForCurrentTraits(on pdfView: PDFView) {
            readingAppearanceRefreshWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak pdfView] in
                guard let self, let pdfView else { return }
                pdfView.layoutIfNeeded()
                pdfView.documentView?.layoutIfNeeded()
                self.applyReadingAppearanceForCurrentTraits(to: pdfView)
            }
            readingAppearanceRefreshWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
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
    
    func applyPrivateReadingAppearance(isDark: Bool, lastSignature: inout String?) -> Bool {
        let traits = effectivePDFRenderingTraitCollection(isDark: isDark)
        let pageBackgroundColor = resolvedPDFPageBackgroundColor(with: traits)
        let signature = readingAppearanceSignature(isDark: isDark, color: pageBackgroundColor, traits: traits)
        if lastSignature == signature {
            return false
        }
        lastSignature = signature
        
        privateSetBool("setAllowsDarkAppearanceContent:", isDark)
        privateSetObject("setDarkModeBackgroundColor:", pageBackgroundColor)
        privateSetObject("setPageColor:", pageBackgroundColor)
        privateSetBool("enableBackgroundImages:", true)
        
        guard let renderingProperties = privateObject("renderingProperties") as? NSObject else { return true }
        renderingProperties.privateSetObject("setTraitCollection:", traits)
        renderingProperties.privateSetInteger("setAppearanceStyle:", traits.userInterfaceStyle.rawValue)
        renderingProperties.privateSetObject("setDarkModePageBackgroundColor:", pageBackgroundColor)
        renderingProperties.privateSetObject("setPageColor:", pageBackgroundColor)
        renderingProperties.privateSetBool("setEnableBackgroundImages:", true)
        renderingProperties.privateSetBool("setEnableTileUpdates:", true)
        
        document?.privateSetObject("setRenderingProperties:", renderingProperties)
        return true
    }
    
    func readingAppearanceSignature(isDark: Bool, color: UIColor, traits: UITraitCollection) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [
            isDark ? "dark" : "light",
            String(format: "%.4f", red),
            String(format: "%.4f", green),
            String(format: "%.4f", blue),
            String(format: "%.4f", alpha),
            "style=\(traits.userInterfaceStyle.rawValue)",
            "level=\(traits.userInterfaceLevel.rawValue)",
            "scale=\(traits.displayScale)",
            "bounds=\(Int(bounds.width))x\(Int(bounds.height))",
            "window=\(Int(window?.bounds.width ?? 0))x\(Int(window?.bounds.height ?? 0))"
        ].joined(separator: "|")
    }
    
    func effectivePDFRenderingTraitCollection(isDark: Bool) -> UITraitCollection {
        let baseTraits = window?.traitCollection ?? traitCollection
        return baseTraits.modifyingTraits { traits in
            traits.userInterfaceStyle = isDark ? .dark : .light
        }
    }
    
    func resolvedPDFPageBackgroundColor(with traits: UITraitCollection) -> UIColor {
        var resolvedColor = UIColor.systemBackground.resolvedColor(with: traits)
        traits.performAsCurrent {
            resolvedColor = UIColor.systemBackground.resolvedColor(with: traits)
        }
        return resolvedColor
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
