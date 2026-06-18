import SwiftUI

@main
struct PreviewPlusPlusApp: App {
    var body: some Scene {
        DocumentGroup(viewing: PDFFile.self) { configuration in
            PDFDocumentView(file: configuration.document, fileURL: configuration.fileURL)
                .toolbarRole(.automatic)
        }
    }
}
