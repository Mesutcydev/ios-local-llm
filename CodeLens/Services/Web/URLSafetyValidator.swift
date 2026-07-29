import Foundation
import Network

// MARK: - URLSafetyValidator
// Blocks SSRF, localhost, link-local, and private-network targets BEFORE
// any URLSession request leaves the device. Re-validates every redirect hop
// because a public URL can 302 to `http://10.0.0.1/admin` and we must not
// follow it.
//
// This file is security-critical. Do not relax the blocklist without review.

public actor URLSafetyValidator {

    public init() {}

    public struct Verdict: Sendable {
        public let isSafe: Bool
        public let reason: String
        public let resolvedIPs: [String]
    }

    /// Validate `url`. Returns `.isSafe == false` with reason when blocked.
    /// Always succeeds (does not throw) so call sites can branch.
    public func validate(_ url: URL) async -> Verdict {
        // 1. Scheme
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .init(isSafe: false, reason: "scheme must be http(s)", resolvedIPs: [])
        }

        // 2. Host present
        guard let host = url.host, !host.isEmpty else {
            return .init(isSafe: false, reason: "missing host", resolvedIPs: [])
        }
        let lowerHost = host.lowercased()

        // 3. Obvious blocked hostnames before DNS
        if lowerHost == "localhost" || lowerHost.hasSuffix(".local") || lowerHost.hasSuffix(".internal") {
            return .init(isSafe: false, reason: "private hostname '\(lowerHost)'", resolvedIPs: [])
        }
        // metadata service IPs occasionally hardcoded
        if ["169.254.169.254", "metadata.google.internal", "metadata.aws.internal"].contains(lowerHost) {
            return .init(isSafe: false, reason: "cloud-metadata host", resolvedIPs: [])
        }

        // 4. Resolve and check every returned IP
        let ips = await Self.resolve(host: host)
        if ips.isEmpty {
            return .init(isSafe: false, reason: "DNS resolution failed", resolvedIPs: [])
        }
        for ip in ips {
            if Self.isPrivateOrReserved(ip) {
                return .init(
                    isSafe: false,
                    reason: "resolves to private/reserved IP \(ip)",
                    resolvedIPs: ips
                )
            }
        }
        return .init(isSafe: true, reason: "ok", resolvedIPs: ips)
    }

    /// Two back-to-back validations with matching resolved IPs. Mitigates
    /// DNS rebinding between the pre-fetch check and the actual request.
    public func validateStable(_ url: URL) async -> Verdict {
        let first = await validate(url)
        guard first.isSafe else { return first }
        let second = await validate(url)
        guard second.isSafe else { return second }
        if Set(first.resolvedIPs) != Set(second.resolvedIPs) {
            return .init(
                isSafe: false,
                reason: "DNS resolution changed between checks",
                resolvedIPs: second.resolvedIPs
            )
        }
        return first
    }

    /// Convenience for validating a redirect chain in one call.
    public func validateChain(_ urls: [URL]) async -> Verdict {
        for u in urls {
            let v = await validate(u)
            if !v.isSafe { return v }
        }
        return .init(isSafe: true, reason: "ok", resolvedIPs: [])
    }

    // MARK: - DNS

    private static func resolve(host: String) async -> [String] {
        // POSIX getaddrinfo on a background thread.
        await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var hints = addrinfo()
                hints.ai_family = AF_UNSPEC
                hints.ai_socktype = SOCK_STREAM
                var info: UnsafeMutablePointer<addrinfo>? = nil
                let status = getaddrinfo(host, nil, &hints, &info)
                guard status == 0, let head = info else {
                    cont.resume(returning: [])
                    return
                }
                defer { freeaddrinfo(head) }
                var out: [String] = []
                var ptr: UnsafeMutablePointer<addrinfo>? = head
                while let cur = ptr?.pointee {
                    var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(cur.ai_addr, cur.ai_addrlen,
                                   &buf, socklen_t(buf.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        out.append(String(cString: buf))
                    }
                    ptr = cur.ai_next
                }
                cont.resume(returning: out)
            }
        }
    }

    // MARK: - Private-IP table

    /// True if `ip` is loopback, private, link-local, CGNAT, ULA, or otherwise
    /// non-public. Covers IPv4 + IPv6 ranges the spec calls out plus a few
    /// adjacent ranges (multicast, documentation) that should also never be
    /// fetched from a user app.
    public static func isPrivateOrReserved(_ ip: String) -> Bool {
        if ip.contains(":") { return isPrivateIPv6(ip) }
        return isPrivateIPv4(ip)
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return true }   // malformed → treat as unsafe
        let a = parts[0], b = parts[1]
        switch a {
        case 0:                                 return true   // 0.0.0.0/8
        case 10:                                return true   // 10/8
        case 127:                               return true   // 127/8 loopback
        case 169 where b == 254:                return true   // 169.254/16 link-local + metadata
        case 172 where (16...31).contains(b):   return true   // 172.16/12
        case 192 where b == 168:                return true   // 192.168/16
        case 192 where b == 0:                  return true   // 192.0.0/24, 192.0.2/24 docs
        case 100 where (64...127).contains(b):  return true   // 100.64/10 CGNAT
        case 198 where (b == 18 || b == 19):    return true   // 198.18/15 benchmarking
        case 203 where b == 0:                  return true   // 203.0.113/24 docs
        case 224...239:                         return true   // multicast
        case 240...255:                         return true   // reserved / broadcast
        default:                                return false
        }
    }

    private static func isPrivateIPv6(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::1" || lower == "::" { return true }              // loopback / unspecified
        if lower.hasPrefix("fe80:") || lower.hasPrefix("fe80::") { return true }  // link-local
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }         // fc00::/7 ULA
        if lower.hasPrefix("ff") { return true }                                  // multicast
        // IPv4-mapped (::ffff:10.0.0.1) — re-check the IPv4 portion
        if let v4 = lower.split(separator: ":").last, v4.contains(".") {
            return isPrivateIPv4(String(v4))
        }
        return false
    }
}
