import Foundation

/// Converts the native encoder's BER container lengths to DER before embedding
/// it in a PDF. Used only on CMSEncoder output, never to relax input validation.
enum PDFCertificateDER {
    /// Inspect CMS structure before Security decodes it: a PDF detached
    /// signature must bind the supplied ByteRange, never an embedded payload.
    static func requireDetachedSignedData(_ data: Data) throws {
        guard data.count <= 2 * 1_048_576 else { throw PDFCertificateError.invalidEnvelope }
        let bytes = [UInt8](data)
        func elements(_ range: Range<Int>) throws -> [Element] { try PDFCertificateDER.elements(bytes, in: range) }
        let root = try elements(0..<bytes.count)
        guard root.count == 1, root[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        let contentInfo = try elements(root[0].body)
        let signedDataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02]
        guard contentInfo.count == 2, contentInfo[0].tag == 0x06,
              Array(bytes[contentInfo[0].body]) == signedDataOID, contentInfo[1].tag == 0xA0 else { throw PDFCertificateError.invalidEnvelope }
        let wrapper = try elements(contentInfo[1].body)
        guard wrapper.count == 1, wrapper[0].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        let signedData = try elements(wrapper[0].body)
        guard signedData.count >= 4, signedData[0].tag == 0x02, signedData[1].tag == 0x31,
              signedData[2].tag == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        let encapsulated = try elements(signedData[2].body)
        let dataOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x01]
        guard encapsulated.count == 1, encapsulated[0].tag == 0x06,
              Array(bytes[encapsulated[0].body]) == dataOID else { throw PDFCertificateError.invalidEnvelope }
    }

    /// One DER value: its single-byte tag and the range of its content bytes.
    typealias Element = (tag: UInt8, body: Range<Int>)

    /// Splits a run of definite-length DER values. Untrusted input: rejects
    /// multi-byte tags, indefinite lengths, lengths past the range, and more
    /// than `maximumCount` values, so a hostile structure cannot grow work.
    static func elements(_ bytes: [UInt8], in range: Range<Int>, maximumCount: Int = 64) throws -> [Element] {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { throw PDFCertificateError.invalidEnvelope }
        var offset = range.lowerBound, result: [Element] = []
        while offset < range.upperBound {
            guard result.count < maximumCount, offset + 2 <= range.upperBound else { throw PDFCertificateError.invalidEnvelope }
            let tag = bytes[offset], first = bytes[offset + 1]; offset += 2
            guard tag & 0x1F != 0x1F, first != 0x80 else { throw PDFCertificateError.invalidEnvelope }
            var length = Int(first)
            if first > 0x80 {
                let count = Int(first & 0x7F)
                guard count <= 4, offset + count <= range.upperBound else { throw PDFCertificateError.invalidEnvelope }
                length = 0
                for byte in bytes[offset..<(offset + count)] { length = length * 256 + Int(byte) }
                offset += count
            }
            guard length <= range.upperBound - offset else { throw PDFCertificateError.invalidEnvelope }
            result.append((tag, offset..<(offset + length))); offset += length
        }
        return result
    }

    static func encode(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 2 * 1_048_576 else { throw PDFCertificateError.invalidEnvelope }
        let bytes = [UInt8](data)
        var offset = 0, nodes = 0
        func value(limit: Int, depth: Int) throws -> Data {
            nodes += 1
            guard depth < 64, nodes <= 20_000, offset + 2 <= limit else { throw PDFCertificateError.invalidEnvelope }
            let start = offset, tag = bytes[offset]
            guard tag != 0 else { throw PDFCertificateError.invalidEnvelope }
            offset += 1
            if tag & 0x1F == 0x1F {
                var count = 0
                repeat {
                    guard offset < limit, count < 5 else { throw PDFCertificateError.invalidEnvelope }
                    let last = bytes[offset] & 0x80 == 0
                    offset += 1; count += 1
                    if last { break }
                } while true
            }
            let encodedTag = Data(bytes[start..<offset])
            guard offset < limit else { throw PDFCertificateError.invalidEnvelope }
            let firstLength = bytes[offset]; offset += 1
            let indefinite = firstLength == 0x80
            var length = Int(firstLength)
            if firstLength > 0x80 {
                let count = Int(firstLength & 0x7F)
                guard count <= 4, offset + count <= limit else { throw PDFCertificateError.invalidEnvelope }
                length = 0
                for byte in bytes[offset..<(offset + count)] { length = length * 256 + Int(byte) }
                offset += count
            }
            let constructed = tag & 0x20 != 0
            guard !indefinite || constructed else { throw PDFCertificateError.invalidEnvelope }
            guard indefinite || length <= limit - offset else { throw PDFCertificateError.invalidEnvelope }
            let end = indefinite ? limit : offset + length
            var body = Data()
            if constructed {
                // A CMS envelope uses sequences, sets and explicit context tags;
                // constructed universal string types need different canonicalization.
                guard tag & 0xC0 != 0 || tag == 0x30 || tag == 0x31 else { throw PDFCertificateError.invalidEnvelope }
                var children: [Data] = []
                while offset < end {
                    if indefinite, offset + 1 < end, bytes[offset] == 0, bytes[offset + 1] == 0 { break }
                    children.append(try value(limit: end, depth: depth + 1))
                }
                if indefinite {
                    guard offset + 1 < end, bytes[offset] == 0, bytes[offset + 1] == 0 else { throw PDFCertificateError.invalidEnvelope }
                    offset += 2
                } else { guard offset == end else { throw PDFCertificateError.invalidEnvelope } }
                // In the CMSEncoder SignedData structure, certificates / CRLs
                // are implicit SETs at depth 3 and signer attributes at depth 5.
                let implicitCMSSet = [3, 5].contains(depth) && [UInt8(0xA0), 0xA1].contains(tag)
                if tag == 0x31 || implicitCMSSet { children.sort { $0.lexicographicallyPrecedes($1) } }
                for child in children { body.append(child) }
            } else {
                body = Data(bytes[offset..<end]); offset = end
            }
            var result = encodedTag
            result.append(contentsOf: encodedLength(body.count))
            result.append(body)
            return result
        }
        let result = try value(limit: bytes.count, depth: 0)
        guard offset == bytes.count, result.first == 0x30 else { throw PDFCertificateError.invalidEnvelope }
        return result
    }

    private static func encodedLength(_ count: Int) -> [UInt8] {
        if count < 128 { return [UInt8(count)] }
        var remaining = count, bytes: [UInt8] = []
        while remaining > 0 { bytes.insert(UInt8(remaining & 0xFF), at: 0); remaining >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }
}
