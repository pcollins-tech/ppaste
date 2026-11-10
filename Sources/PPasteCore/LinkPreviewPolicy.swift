import Foundation

/// Decides whether ppaste may make a network request for a copied URL.
/// Conservative on purpose: anything that looks private, internal or secret-bearing is skipped.
public enum LinkPreviewPolicy {
    public static func isFetchable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        if host.hasSuffix(".") { host.removeLast() }
        guard isPublicHost(host) else { return false }
        return !hasSensitiveParameters(url)
    }

    static let internalSuffixes = [".localhost", ".local", ".internal", ".lan", ".home", ".home.arpa",
                                   ".corp", ".intranet", ".private", ".localdomain", ".test", ".invalid"]

    static func isPublicHost(_ host: String) -> Bool {
        if host.contains(":") { return false }                   // IPv6 literals: skip entirely
        if host == "localhost" { return false }
        var addr = in_addr()
        if inet_aton(host, &addr) != 0 { return isPublicIPv4(UInt32(bigEndian: addr.s_addr)) }
        if !host.contains(".") { return false }                   // single-label names are intranet hosts
        if internalSuffixes.contains(where: host.hasSuffix) { return false }
        return true
    }

    static func isPublicIPv4(_ ip: UInt32) -> Bool {
        let a = ip >> 24, b = (ip >> 16) & 0xFF
        switch (a, b) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false        // CGNAT
        case (169, 254): return false             // link-local
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0): return false               // IETF / documentation
        case (198, 18...19): return false         // benchmarking
        case (224...255, _): return false         // multicast / reserved
        default: return true
        }
    }

    private static let sensitiveFragments = [
        "token", "secret", "passw", "pwd", "apikey", "auth", "signature", "credential", "session",
        "jwt", "privatekey", "accesskey", "bearer",
    ]
    private static let sensitiveExact: Set<String> = ["key", "sig", "sid", "code", "otp", "pass", "pw", "ticket"]

    static func isSensitiveName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let normalised = lower.filter { $0 != "-" && $0 != "_" && $0 != "." }
        if sensitiveExact.contains(normalised) { return true }
        if let last = lower.split(whereSeparator: { "-_.".contains($0) }).last, sensitiveExact.contains(String(last)) { return true }
        return sensitiveFragments.contains { normalised.contains($0) }
    }

    static func hasSensitiveParameters(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if comps.queryItems?.contains(where: { isSensitiveName($0.name) }) == true { return true }
        // OAuth-style fragments such as #access_token=...
        if let frag = comps.fragment, frag.contains("=") {
            for pair in frag.split(separator: "&") {
                if isSensitiveName(String(pair.split(separator: "=", maxSplits: 1).first ?? "")) { return true }
            }
        }
        return false
    }
}
