import AppKit
import ImageIO
import UniformTypeIdentifiers
import PPasteCore

/// User-facing opt-out, toggled from the menu-bar menu. Default ON.
enum LinkPreviewSettings {
    static let key = "fetchLinkPreviews"
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Fetches a page title and preview image for link clips, in the background.
///
/// This is ppaste's only network access. Safety rules: http(s) only, public hosts only
/// (see `LinkPreviewPolicy`), short timeouts, size caps, no cookies/credentials/cache,
/// generic User-Agent, one attempt per clip, silent failure.
final class LinkPreviewFetcher {
    static let htmlLimit = 1_000_000
    static let imageLimit = 2_000_000
    static let maxImagePixels = 640
    static let userAgent = "Mozilla/5.0 (Macintosh) LinkPreview/1.0"

    private let store: ClipStore
    private let imageDir: URL
    private let session: URLSession
    private let guardDelegate = RedirectGuard()
    private var continuation: AsyncStream<ClipItem>.Continuation?

    /// Clip ids with a fetch queued or running. Main thread only.
    private(set) var pendingIDs: Set<Int64> = []
    /// Called on the main thread whenever a preview arrives or the pending set changes.
    var onChange: (() -> Void)?

    init(store: ClipStore, imageDir: URL) {
        self.store = store
        self.imageDir = imageDir
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        session = URLSession(configuration: cfg, delegate: guardDelegate, delegateQueue: nil)

        let (stream, cont) = AsyncStream<ClipItem>.makeStream()
        continuation = cont
        Task.detached(priority: .utility) { [weak self] in
            for await item in stream { await self?.process(item) } // one at a time
        }
    }

    /// Queue a freshly saved link clip. Must be called on the main thread.
    func enqueue(_ item: ClipItem) {
        guard LinkPreviewSettings.isEnabled, item.kind == .link, item.linkFetchedAt == nil,
              let id = item.id, !pendingIDs.contains(id),
              let url = Self.pageURL(from: item.text), LinkPreviewPolicy.isFetchable(url) else { return }
        pendingIDs.insert(id)
        onChange?()
        continuation?.yield(item)
    }

    static func pageURL(from text: String?) -> URL? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              var comps = URLComponents(string: t) else { return nil }
        comps.fragment = nil
        return comps.url
    }

    // MARK: - Pipeline (background)

    private func process(_ item: ClipItem) async {
        guard let id = item.id else { return }
        var title: String?, imagePath: String?, isIcon = false
        if LinkPreviewSettings.isEnabled, let page = Self.pageURL(from: item.text) {
            if let html = await fetch(page, limit: Self.htmlLimit, accept: "text/html,application/xhtml+xml", expect: .html) {
                let text = String(data: html, encoding: .utf8) ?? String(decoding: html, as: UTF8.self)
                let meta = LinkMetadataParser.parse(html: text, baseURL: page)
                title = meta.title
                let candidates: [(URL, Bool)] = [(meta.imageURL, false), (meta.iconURL, true),
                    (LinkMetadataParser.defaultFaviconURL(for: page), true)]
                    .compactMap { u, icon in u.map { ($0, icon) } }
                var seen = Set<URL>()
                for (url, icon) in candidates where seen.insert(url).inserted {
                    guard LinkPreviewSettings.isEnabled, LinkPreviewPolicy.isFetchable(url) else { continue }
                    if let data = await fetch(url, limit: Self.imageLimit, accept: "image/*", expect: .image),
                       let png = Self.thumbnailPNG(from: data) {
                        let dest = imageDir.appendingPathComponent("\(item.contentHash).png")
                        if (try? png.write(to: dest, options: .atomic)) != nil {
                            imagePath = dest.path; isIcon = icon
                            break
                        }
                    }
                }
            }
        }
        let stored = (try? store.saveLinkPreview(id: id, title: title, imagePath: imagePath, imageIsIcon: isIcon)) ?? false
        if !stored, let imagePath { try? FileManager.default.removeItem(atPath: imagePath) } // clip deleted meanwhile
        await MainActor.run {
            pendingIDs.remove(id)
            onChange?()
        }
    }

    private enum Expect { case html, image }

    /// GET with a hard byte cap. Returns nil on any failure. HTML is truncated at the cap (head is usually early);
    /// images over the cap are rejected.
    private func fetch(_ url: URL, limit: Int, accept: String, expect: Expect) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpShouldHandleCookies = false
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("en", forHTTPHeaderField: "Accept-Language")
        do {
            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            switch expect {
            case .html: if !type.isEmpty && !type.contains("html") { return nil }
            case .image:
                if !type.isEmpty && !type.hasPrefix("image/") { return nil }
                if type.contains("svg") { return nil }
                if http.expectedContentLength > Int64(limit) { return nil }
            }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { return expect == .html ? data : nil }
            }
            return data.isEmpty ? nil : data
        } catch { return nil }
    }

    /// Decode and downscale with ImageIO, re-encoding as PNG (also rejects anything that isn't a real image).
    static func thumbnailPNG(from data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

/// Re-applies the fetch policy to every redirect hop and keeps cookies/credentials out.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, LinkPreviewPolicy.isFetchable(url) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
