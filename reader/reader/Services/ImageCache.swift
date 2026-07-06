//
//  ImageCache.swift
//  reader
//

import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Downloads article images once and stores them content-addressed
/// (SHA256 of the source URL) so the reading pane can serve local copies
/// through the reader-asset:// scheme, fully offline.
actor ImageCache {

    /// Shared with LocalAssetSchemeHandler, which serves these files.
    nonisolated static var directoryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ImageCache", directoryHint: .isDirectory)
    }

    private static let knownExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "heic", "bmp", "ico", "tiff",
    ]

    private let session: URLSession
    private var inFlight: [URL: Task<String?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        // The request timeout only fires on idle; a dripping host would
        // otherwise pin a refresh or a saved-page snapshot for minutes.
        // 30 s is the absolute per-image budget.
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
        try? FileManager.default.createDirectory(
            at: Self.directoryURL, withIntermediateDirectories: true)
    }

    /// Returns the cached asset file name ("<sha256>.<ext>"), downloading on
    /// first sight; nil when the download fails (the caller then leaves the
    /// remote URL in place and CSP shows a broken-image placeholder).
    func cache(_ remote: URL) async -> String? {
        if let existing = Self.existingAssetName(for: remote) {
            return existing
        }
        if let task = inFlight[remote] {
            return await task.value
        }
        let task = Task<String?, Never> { [session] in
            await Self.download(remote, using: session)
        }
        inFlight[remote] = task
        let result = await task.value
        inFlight[remote] = nil
        return result
    }

    /// The extension may come from the URL or (for extension-less CDN URLs)
    /// from the response Content-Type, so an existing asset is looked up
    /// across all candidate names for the URL hash.
    private nonisolated static func existingAssetName(for remote: URL) -> String? {
        let hash = sha256Hex(remote.absoluteString)
        for ext in knownExtensions.union(["img"]) {
            let name = "\(hash).\(ext)"
            if FileManager.default.fileExists(atPath: directoryURL.appending(path: name).path) {
                return name
            }
        }
        return nil
    }

    /// URL extension when recognized, else the response Content-Type's
    /// preferred extension — the scheme handler later derives the MIME back
    /// from this name, and SVG in particular renders only with the right one.
    nonisolated static func assetName(for remote: URL, mimeType: String?) -> String {
        let hash = sha256Hex(remote.absoluteString)
        let urlExtension = remote.pathExtension.lowercased()
        if knownExtensions.contains(urlExtension) {
            return "\(hash).\(urlExtension)"
        }
        if let mimeType,
           let preferred = UTType(mimeType: mimeType)?.preferredFilenameExtension?.lowercased(),
           knownExtensions.contains(preferred) {
            return "\(hash).\(preferred)"
        }
        return "\(hash).img"
    }

    private nonisolated static func download(
        _ remote: URL,
        using session: URLSession
    ) async -> String? {
        do {
            let (temporary, response) = try await session.download(for: URLRequest(url: remote))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            let name = assetName(for: remote, mimeType: http.mimeType)
            let destination = directoryURL.appending(path: name)
            // A concurrent process may have won the race; replacing is fine —
            // the content is addressed by source URL either way.
            _ = try? FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            return FileManager.default.fileExists(atPath: destination.path) ? name : nil
        } catch {
            return nil
        }
    }
}

private nonisolated func sha256Hex(_ string: String) -> String {
    SHA256.hash(data: Data(string.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}
