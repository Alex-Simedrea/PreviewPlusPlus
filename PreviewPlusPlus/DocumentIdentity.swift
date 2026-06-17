import CryptoKit
import Foundation

enum DocumentIdentity {
    static func key(for url: URL) -> String {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().absoluteString
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
