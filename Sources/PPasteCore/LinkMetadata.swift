import Foundation

/// What we learned about a page from its HTML.
public struct LinkMetadata: Equatable, Sendable {
    public var title: String?
    public var imageURL: URL?
    public var iconURL: URL?
    public init(title: String? = nil, imageURL: URL? = nil, iconURL: URL? = nil) {
        self.title = title; self.imageURL = imageURL; self.iconURL = iconURL
    }
}

/// Pure, dependency-free HTML metadata extraction. Tolerates garbage input.
public enum LinkMetadataParser {
    public static let maxTitleLength = 200

    /// Parse title, preview image and icon out of `html`, resolving relative URLs against `baseURL`.
    public static func parse(html: String, baseURL: URL) -> LinkMetadata {
        var doc = html
        doc = replace(doc, pattern: "<!--.*?-->")
        doc = replace(doc, pattern: "<script\\b.*?</script\\s*>")
        doc = replace(doc, pattern: "<style\\b.*?</style\\s*>")
        if let end = doc.range(of: "</head", options: .caseInsensitive) { doc = String(doc[..<end.lowerBound]) }

        var metas: [String: String] = [:]   // first value wins
        var icons: [(priority: Int, size: Int, href: String)] = []

        for m in matches(tagRegex, in: doc) {
            guard let tag = m[1]?.lowercased(), let attrText = m[2] else { continue }
            let attrs = parseAttributes(attrText)
            if tag == "meta" {
                guard let key = (attrs["property"] ?? attrs["name"])?.lowercased(),
                      let content = attrs["content"], metas[key] == nil else { continue }
                metas[key] = content
            } else if let rel = attrs["rel"]?.lowercased(), let href = attrs["href"] {
                let tokens = rel.split(whereSeparator: \.isWhitespace).map(String.init)
                if tokens.contains("mask-icon") { continue }
                if tokens.contains(where: { $0.hasPrefix("apple-touch-icon") }) {
                    icons.append((0, sizeValue(attrs["sizes"]), href))
                } else if tokens.contains("icon") {
                    icons.append((1, sizeValue(attrs["sizes"]), href))
                }
            }
        }

        var title: String?
        for key in ["og:title", "twitter:title"] {
            if let t = clean(metas[key]) { title = t; break }
        }
        if title == nil, let m = matches(titleRegex, in: doc).first, let inner = m[1] { title = clean(inner) }

        var imageURL: URL?
        for key in ["og:image", "og:image:secure_url", "og:image:url", "twitter:image", "twitter:image:src"] {
            if let u = resolve(metas[key], against: baseURL) { imageURL = u; break }
        }

        let best = icons.sorted { ($0.priority, -$0.size) < ($1.priority, -$1.size) }
            .lazy.compactMap { resolve($0.href, against: baseURL) }.first

        return LinkMetadata(title: title, imageURL: imageURL, iconURL: best)
    }

    /// `/favicon.ico` on the page's origin, used when the page declares no icon.
    public static func defaultFaviconURL(for pageURL: URL) -> URL? {
        URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL
    }

    // MARK: - Helpers

    static func resolve(_ raw: String?, against base: URL) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let decoded = decodeEntities(raw)
        let collapsed = decoded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxTitleLength))
    }

    private static func sizeValue(_ sizes: String?) -> Int {
        guard let first = sizes?.lowercased().split(whereSeparator: \.isWhitespace).first,
              let w = first.split(separator: "x").first, let n = Int(w) else { return 0 }
        return n
    }

    private static let tagRegex = try! NSRegularExpression(
        pattern: "<(meta|link)\\b((?:\"[^\"]*\"|'[^']*'|[^>\"'])*)>", options: [.caseInsensitive])
    private static let titleRegex = try! NSRegularExpression(
        pattern: "<title\\b[^>]*>(.*?)</title\\s*>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let attrRegex = try! NSRegularExpression(
        pattern: "([^\\s\"'<>/=]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+)))?")

    private static func replace(_ s: String, pattern: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
    }

    /// Capture groups as optional strings (index 0 is the whole match).
    private static func matches(_ re: NSRegularExpression, in s: String) -> [[String?]] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: s).map { String(s[$0]) }
            }
        }
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for m in matches(attrRegex, in: text) {
            guard let name = m[1]?.lowercased(), out[name] == nil else { continue }
            out[name] = decodeEntities(m[2] ?? m[3] ?? m[4] ?? "")
        }
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "copy": "\u{A9}",
        "reg": "\u{AE}", "trade": "\u{2122}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "middot": "\u{B7}", "bull": "\u{2022}",
    ]

    /// Decode the common named entities plus decimal/hex numeric references. Unknown ones are left as-is.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") {
                let body = String(s[s.index(after: i)..<semi])
                if let rep = decodeEntityBody(body) {
                    out += rep
                    i = s.index(after: semi)
                    continue
                }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private static func decodeEntityBody(_ body: String) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") { value = UInt32(digits.dropFirst(), radix: 16) }
            else { value = UInt32(digits, radix: 10) }
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[body]
    }
}
