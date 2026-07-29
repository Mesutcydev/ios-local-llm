import Foundation

// Minimal ASN.1 DER encoder — only the primitives needed for a
// self-signed P-256 X.509 certificate. No general-purpose ASN.1 library.
enum DER {

    static func tlv(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        [tag] + encodeLength(body.count) + body
    }

    static func sequence(_ body: [UInt8]) -> [UInt8] { tlv(tag: 0x30, body) }
    static func set(_ body: [UInt8]) -> [UInt8]       { tlv(tag: 0x31, body) }
    static func integer(_ bytes: [UInt8]) -> [UInt8]  { tlv(tag: 0x02, bytes) }
    static func oid(_ bytes: [UInt8]) -> [UInt8]      { tlv(tag: 0x06, bytes) }
    static func utf8String(_ s: String) -> [UInt8]    { tlv(tag: 0x0C, Array(s.utf8)) }
    static func utcTime(_ s: String) -> [UInt8]       { tlv(tag: 0x17, Array(s.utf8)) }

    // BIT STRING: 0x00 prefix = 0 unused bits
    static func bitString(_ bytes: [UInt8]) -> [UInt8] {
        tlv(tag: 0x03, [0x00] + bytes)
    }

    // [n] EXPLICIT tag
    static func contextExplicit(tag n: UInt8, _ body: [UInt8]) -> [UInt8] {
        tlv(tag: 0xA0 | n, body)
    }

    // MARK: - Length encoding

    private static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 0x80 {
            return [UInt8(length)]
        } else if length < 0x100 {
            return [0x81, UInt8(length)]
        } else {
            return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
        }
    }
}
