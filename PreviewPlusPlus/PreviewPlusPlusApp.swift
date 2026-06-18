import SwiftUI

@main
struct PreviewPlusPlusApp: App {
    var body: some Scene {
        DocumentGroupLaunchScene("Preview++")

        DocumentGroup(viewing: PDFFile.self) { configuration in
            PDFDocumentView(file: configuration.document, fileURL: configuration.fileURL)
                .toolbarRole(.automatic)
        }
    }
}
