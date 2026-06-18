import Darwin
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
            let result = pdfView.applyPrivateReadingAppearance(isDark: colorScheme == .dark, lastSignature: &lastReadingAppearanceSignature)
            model?.updateReadingAppearance(result.appearance)
            if result.didChange {
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
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: PDFViewerModel
    @StateObject private var thumbnailStore = PDFThumbnailStore()
    
    private var readingAppearance: PDFReadingAppearance {
        model.readingAppearance ?? model.pdfView.readingAppearance(isDark: colorScheme == .dark)
    }
    
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<(model.document?.pageCount ?? 0), id: \.self) { index in
                    PDFPageThumbnailView(
                        model: model,
                        pageIndex: index,
                        thumbnail: thumbnailStore.image(
                            for: index,
                            document: model.document,
                            appearance: readingAppearance
                        )
                    )
                }
            }
            .padding(.vertical, 8)
        }
        .task(id: PDFThumbnailRenderRequest(document: model.document, appearance: readingAppearance)) {
            await thumbnailStore.render(document: model.document, appearance: readingAppearance)
        }
    }
}

private struct PDFPageThumbnailView: View {
    @ObservedObject var model: PDFViewerModel
    let pageIndex: Int
    let thumbnail: UIImage?
    
    private var isSelected: Bool {
        model.currentPageIndex == pageIndex
    }
    
    var body: some View {
        Button {
            model.goToPage(at: pageIndex)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(uiColor: .systemBackground))
                
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 100)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .frame(width: 100)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .background(Color.gray.opacity(0.25))
                        .clipShape(.rect(cornerRadius: 8))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct PDFThumbnailRenderRequest: Equatable {
    var documentID: ObjectIdentifier?
    var pageCount: Int
    var renderSignature: String
    
    init(document: PDFDocument?, appearance: PDFReadingAppearance) {
        documentID = document.map(ObjectIdentifier.init)
        pageCount = document?.pageCount ?? 0
        renderSignature = appearance.renderSignature
    }
}

private struct PDFThumbnailCacheKey: Hashable {
    var documentID: ObjectIdentifier
    var pageIndex: Int
    var renderSignature: String
}

@MainActor
private final class PDFThumbnailStore: ObservableObject {
    @Published private var thumbnails: [PDFThumbnailCacheKey: UIImage] = [:]
    private var documentID: ObjectIdentifier?
    
    func image(for pageIndex: Int, document: PDFDocument?, appearance: PDFReadingAppearance) -> UIImage? {
        guard let document else { return nil }
        let documentID = ObjectIdentifier(document)
        let key = PDFThumbnailCacheKey(documentID: documentID, pageIndex: pageIndex, renderSignature: appearance.renderSignature)
        return thumbnails[key]
    }
    
    func render(document: PDFDocument?, appearance: PDFReadingAppearance) async {
        guard let document else {
            documentID = nil
            thumbnails = [:]
            return
        }
        
        let currentDocumentID = ObjectIdentifier(document)
        if documentID != currentDocumentID {
            documentID = currentDocumentID
            thumbnails = [:]
        }
        
        let size = CGSize(width: 152, height: 208)
        var renderedThumbnails: [PDFThumbnailCacheKey: UIImage] = [:]
        
        for pageIndex in 0..<document.pageCount {
            let key = PDFThumbnailCacheKey(documentID: currentDocumentID, pageIndex: pageIndex, renderSignature: appearance.renderSignature)
            guard thumbnails[key] == nil else { continue }
            guard let page = document.page(at: pageIndex) else { continue }
            guard !Task.isCancelled else { return }
            
            renderedThumbnails[key] = autoreleasepool {
                page.thumbnail(of: size, for: .cropBox, appearance: appearance)
            }
            
            if pageIndex.isMultiple(of: 8) {
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
        }
        
        guard !Task.isCancelled else { return }
        var nextThumbnails = thumbnails.filter { key, _ in
            key.documentID != currentDocumentID || key.renderSignature == appearance.renderSignature
        }
        nextThumbnails.merge(renderedThumbnails) { _, new in new }
        
        if nextThumbnails.count != thumbnails.count || !renderedThumbnails.isEmpty {
            thumbnails = nextThumbnails
        }
    }
}

private extension PDFPage {
    func thumbnail(of size: CGSize, for box: PDFDisplayBox, appearance: PDFReadingAppearance) -> UIImage {
        guard appearance.isDark else { return thumbnail(of: size, for: box) }
        return privateDarkModeThumbnail(of: size, for: box, backgroundColor: appearance.backgroundColor) ?? thumbnail(of: size, for: box)
    }
    
    func privateDarkModeThumbnail(of size: CGSize, for box: PDFDisplayBox, backgroundColor: UIColor) -> UIImage? {
        let selector = NSSelectorFromString("imageOfSize:forBox:withOptions:")
        guard
            responds(to: selector),
            let implementation = method(for: selector),
            let options = PrivatePDFPageImageOptions.darkModeOptions(backgroundColor: backgroundColor)
        else {
            return nil
        }
        
        typealias Function = @convention(c) (AnyObject, Selector, CGSize, Int, NSDictionary) -> UIImage?
        return unsafeBitCast(implementation, to: Function.self)(self, selector, size, box.rawValue, options)
    }
}

private enum PrivatePDFPageImageOptions {
    private nonisolated(unsafe) static let handle = dlopen("/System/Library/Frameworks/PDFKit.framework/PDFKit", RTLD_LAZY) ?? dlopen(nil, RTLD_LAZY)
    
    private nonisolated(unsafe) static let darkModeRenderingKey = pdfKitString(named: "PDFPageImageProperty_DarkModeRendering")
    private nonisolated(unsafe) static let backgroundColorKey = pdfKitString(named: "PDFPageImageProperty_BackgroundColor")
    private nonisolated(unsafe) static let drawAnnotationsKey = pdfKitString(named: "PDFPageImageProperty_DrawAnnotations")
    private nonisolated(unsafe) static let withRotationKey = pdfKitString(named: "PDFPageImageProperty_WithRotation")
    
    static func darkModeOptions(backgroundColor: UIColor) -> NSDictionary? {
        guard let darkModeRenderingKey else { return nil }
        
        let options = NSMutableDictionary()
        options[darkModeRenderingKey] = NSNumber(value: true)
        
        if let backgroundColorKey {
            options[backgroundColorKey] = backgroundColor
        }
        if let drawAnnotationsKey {
            options[drawAnnotationsKey] = NSNumber(value: true)
        }
        if let withRotationKey {
            options[withRotationKey] = NSNumber(value: true)
        }
        
        return options
    }
    
    private static func pdfKitString(named name: String) -> NSString? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return symbol.assumingMemoryBound(to: NSString.self).pointee
    }
}

struct PDFReadingAppearance: Hashable {
    var isDark: Bool
    var signature: String
    var renderSignature: String
    var backgroundColor: UIColor
    var traits: UITraitCollection
    
    static func == (lhs: PDFReadingAppearance, rhs: PDFReadingAppearance) -> Bool {
        lhs.signature == rhs.signature && lhs.renderSignature == rhs.renderSignature
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(signature)
        hasher.combine(renderSignature)
    }
}

private extension PDFView {
    func applyScrollEdgeEffect() {
        guard let scrollView = firstDescendant(of: UIScrollView.self) else { return }
        scrollView.contentInsetAdjustmentBehavior = .automatic
        scrollView.topEdgeEffect.style = .hard
        scrollView.bottomEdgeEffect.style = .automatic
    }
    
    func applyPrivateReadingAppearance(isDark: Bool, lastSignature: inout String?) -> (didChange: Bool, appearance: PDFReadingAppearance) {
        let appearance = readingAppearance(isDark: isDark)
        if lastSignature == appearance.renderSignature {
            return (false, appearance)
        }
        lastSignature = appearance.renderSignature
        
        privateSetBool("setAllowsDarkAppearanceContent:", isDark)
        privateSetObject("setDarkModeBackgroundColor:", appearance.backgroundColor)
        privateSetObject("setPageColor:", appearance.backgroundColor)
        privateSetBool("enableBackgroundImages:", true)
        
        guard let renderingProperties = privateObject("renderingProperties") as? NSObject else { return (true, appearance) }
        renderingProperties.privateSetObject("setTraitCollection:", appearance.traits)
        renderingProperties.privateSetInteger("setAppearanceStyle:", appearance.traits.userInterfaceStyle.rawValue)
        renderingProperties.privateSetObject("setDarkModePageBackgroundColor:", appearance.backgroundColor)
        renderingProperties.privateSetObject("setPageColor:", appearance.backgroundColor)
        renderingProperties.privateSetBool("setEnableBackgroundImages:", true)
        renderingProperties.privateSetBool("setEnableTileUpdates:", true)
        
        document?.privateSetObject("setRenderingProperties:", renderingProperties)
        return (true, appearance)
    }
    
    func readingAppearance(isDark: Bool) -> PDFReadingAppearance {
        let traits = effectivePDFRenderingTraitCollection(isDark: isDark)
        let pageBackgroundColor = resolvedPDFPageBackgroundColor(with: traits)
        let renderSignature = readingAppearanceRenderSignature(isDark: isDark, color: pageBackgroundColor, traits: traits)
        let signature = readingAppearanceSignature(isDark: isDark, color: pageBackgroundColor, traits: traits)
        return PDFReadingAppearance(
            isDark: isDark,
            signature: signature,
            renderSignature: renderSignature,
            backgroundColor: pageBackgroundColor,
            traits: traits
        )
    }
    
    func readingAppearanceRenderSignature(isDark: Bool, color: UIColor, traits: UITraitCollection) -> String {
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
            "scale=\(traits.displayScale)"
        ].joined(separator: "|")
    }
    
    func readingAppearanceSignature(isDark: Bool, color: UIColor, traits: UITraitCollection) -> String {
        [
            readingAppearanceRenderSignature(isDark: isDark, color: color, traits: traits),
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
