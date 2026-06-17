import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    init() {}

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}
