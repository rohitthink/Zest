import Foundation

/// Removes metadata from image files losslessly — without re-encoding the image
/// samples. Clean-room implementations of standard container techniques:
///   • JPEG  — drop APP1 (Exif/XMP), APP13 (IPTC), COM segments; keep scan data.
///   • PNG   — drop tEXt/iTXt/zTXt/eXIf/tIME chunks; keep pixels and color chunks.
///   • HEIC  — ISO-BMFF (ISO/IEC 14496-12) box walk that zeroes the Exif/XMP item
///             payloads *in place*, leaving every box size and `iloc` offset
///             unchanged so the coded image is byte-for-byte untouched.
public enum MetadataStripper {

    public struct Report: Sendable {
        public var format: String
        public var bytesErased: Int
        public var method: String
    }

    /// Dispatch by format id. Returns nil if the format isn't handled or parsing
    /// looked unsafe (caller should fall back to a metadata-dropping re-encode).
    public static func strip(_ data: Data, formatID: String) -> (data: Data, report: Report)? {
        switch formatID {
        case "jpg":
            guard let out = stripJPEG(data) else { return nil }
            return (out, Report(format: "jpg", bytesErased: data.count - out.count, method: "jpeg-segments"))
        case "png":
            guard let out = stripPNG(data) else { return nil }
            return (out, Report(format: "png", bytesErased: data.count - out.count, method: "png-chunks"))
        case "heic":
            var copy = data
            guard let report = stripISOBMFF(&copy) else { return nil }
            return (copy, report)
        default:
            return nil
        }
    }

    // MARK: - JPEG

    /// Keep SOI, APP0/JFIF, quantization/Huffman/frame tables and the entire scan;
    /// remove APP1 (Exif/XMP), APP13 (IPTC), and comment segments.
    public static func stripJPEG(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 3, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        var i = 2
        let n = b.count
        while i + 1 < n {
            guard b[i] == 0xFF else { return nil } // malformed before scan
            let marker = b[i + 1]
            if marker == 0xD9 { out.append(contentsOf: [0xFF, 0xD9]); return Data(out) } // EOI
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {   // standalone markers
                out.append(contentsOf: [0xFF, marker]); i += 2; continue
            }
            if marker == 0xDA {                                      // SOS: copy rest verbatim
                out.append(contentsOf: b[i...]); return Data(out)
            }
            guard i + 3 < n else { return nil }
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])          // includes the 2 length bytes
            let segmentEnd = i + 2 + length
            guard length >= 2, segmentEnd <= n else { return nil }
            let strip = (marker == 0xE1 || marker == 0xED || marker == 0xFE)
            if !strip { out.append(contentsOf: b[i..<segmentEnd]) }
            i = segmentEnd
        }
        return Data(out)
    }

    // MARK: - PNG

    public static func stripPNG(_ data: Data) -> Data? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<8]) == signature else { return nil }
        let stripTypes: Set<String> = ["tEXt", "iTXt", "zTXt", "eXIf", "tIME"]
        var out: [UInt8] = signature
        var i = 8
        while i + 8 <= b.count {
            let length = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 0 else { return nil }
            let type = String(bytes: b[(i + 4)..<(i + 8)], encoding: .ascii) ?? ""
            let chunkEnd = i + 12 + length                           // len(4) + type(4) + data + crc(4)
            guard chunkEnd <= b.count else { return nil }
            if !stripTypes.contains(type) { out.append(contentsOf: b[i..<chunkEnd]) }
            i = chunkEnd
            if type == "IEND" { break }
        }
        return Data(out)
    }

    // MARK: - HEIC / ISO-BMFF (offset-preserving)

    private struct Box { let type: String; let contentStart: Int; let end: Int }

    private static func readInt(_ b: [UInt8], _ offset: Int, _ size: Int, limit: Int) -> Int? {
        guard size > 0, offset >= 0, offset + size <= limit else { return nil }
        var v = 0
        for k in 0..<size { v = (v << 8) | Int(b[offset + k]) }
        return v
    }

    private static func boxes(_ b: [UInt8], _ start: Int, _ end: Int) -> [Box] {
        var result: [Box] = []
        var p = start
        while p + 8 <= end {
            guard var size = readInt(b, p, 4, limit: end) else { break }
            let type = String(bytes: b[(p + 4)..<(p + 8)], encoding: .ascii) ?? ""
            var header = 8
            if size == 1 {
                guard let large = readInt(b, p + 8, 8, limit: end) else { break }
                size = large; header = 16
            } else if size == 0 {
                size = end - p
            }
            guard size >= header, p + size <= end else { break }
            result.append(Box(type: type, contentStart: p + header, end: p + size))
            p += size
        }
        return result
    }

    /// Human-readable trace of the ISO-BMFF parse, for debugging which step bails.
    public static func diagnoseISOBMFF(_ data: Data) -> String {
        let b = [UInt8](data)
        var lines: [String] = []
        let top = boxes(b, 0, b.count)
        lines.append("top-level: " + top.map { "\($0.type)[\($0.end - $0.contentStart + 8)]" }.joined(separator: " "))
        guard let meta = top.first(where: { $0.type == "meta" }) else { return (lines + ["no meta"]).joined(separator: "\n") }
        let children = boxes(b, meta.contentStart + 4, meta.end)
        lines.append("meta children: " + children.map(\.type).joined(separator: " "))
        guard let iinf = children.first(where: { $0.type == "iinf" }) else { return (lines + ["no iinf"]).joined(separator: "\n") }
        guard b.indices.contains(iinf.contentStart) else { return (lines + ["iinf truncated"]).joined(separator: "\n") }
        let iinfVersion = Int(b[iinf.contentStart])
        var p = iinf.contentStart + 4
        let countSize = iinfVersion == 0 ? 2 : 4
        let count = readInt(b, p, countSize, limit: iinf.end) ?? -1
        p += countSize
        lines.append("iinf v\(iinfVersion) entry_count=\(count)")
        var items: [(Int, String)] = []
        for entry in boxes(b, p, iinf.end) where entry.type == "infe" {
            guard b.indices.contains(entry.contentStart) else { continue }
            let ev = Int(b[entry.contentStart])
            var q = entry.contentStart + 4
            let idSize = ev >= 3 ? 4 : 2
            let id = readInt(b, q, idSize, limit: entry.end) ?? -1
            q += idSize + 2
            let type = (q + 4 <= entry.end) ? (String(bytes: b[q..<(q + 4)], encoding: .ascii) ?? "?") : "?"
            items.append((id, type))
        }
        lines.append("infe items: " + items.map { "\($0.0):\($0.1)" }.joined(separator: " "))
        guard let iloc = children.first(where: { $0.type == "iloc" }) else { return (lines + ["no iloc"]).joined(separator: "\n") }
        guard b.indices.contains(iloc.contentStart) else { return (lines + ["iloc truncated"]).joined(separator: "\n") }
        let ilocVersion = Int(b[iloc.contentStart])
        lines.append("iloc v\(ilocVersion)")
        var r = iloc.contentStart + 4
        let sb1 = readInt(b, r, 1, limit: iloc.end) ?? 0
        let sb2 = readInt(b, r + 1, 1, limit: iloc.end) ?? 0
        r += 2
        let offSize = (sb1 >> 4) & 0xF, lenSize = sb1 & 0xF, baseSize = (sb2 >> 4) & 0xF
        let idxSize = (ilocVersion == 1 || ilocVersion == 2) ? (sb2 & 0xF) : 0
        lines.append("iloc sizes off=\(offSize) len=\(lenSize) base=\(baseSize) idx=\(idxSize)")
        let icSize = ilocVersion < 2 ? 2 : 4
        let itemCount = readInt(b, r, icSize, limit: iloc.end) ?? -1
        r += icSize
        lines.append("iloc item_count=\(itemCount)")
        let idat = children.first(where: { $0.type == "idat" })
        let targetSet = Set(items.filter { ["Exif", "mime", "uri "].contains($0.1) }.map(\.0))
        for _ in 0..<max(0, itemCount) {
            let idSize = ilocVersion < 2 ? 2 : 4
            guard let itemID = readInt(b, r, idSize, limit: iloc.end) else { lines.append("bail@id r=\(r)"); break }
            r += idSize
            var method = 0
            if ilocVersion == 1 || ilocVersion == 2 {
                method = (readInt(b, r, 2, limit: iloc.end) ?? 0) & 0xF; r += 2
            }
            r += 2
            let base = baseSize > 0 ? (readInt(b, r, baseSize, limit: iloc.end) ?? -1) : 0
            r += baseSize
            guard let extentCount = readInt(b, r, 2, limit: iloc.end) else { lines.append("bail@ec item \(itemID)"); break }
            r += 2
            for _ in 0..<extentCount {
                if idxSize > 0 { r += idxSize }
                let eo = offSize > 0 ? (readInt(b, r, offSize, limit: iloc.end) ?? -1) : 0
                r += offSize
                let el = lenSize > 0 ? (readInt(b, r, lenSize, limit: iloc.end) ?? -1) : 0
                r += lenSize
                if targetSet.contains(itemID) {
                    lines.append("metadata item \(itemID) method=\(method) base=\(base) extOff=\(eo) extLen=\(el) idatStart=\(idat?.contentStart ?? -1)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Zero the payloads of Exif/XMP/URI metadata items in place. Returns nil on
    /// any parse surprise so the caller can fall back safely.
    public static func stripISOBMFF(_ data: inout Data) -> Report? {
        let b = [UInt8](data)
        guard let meta = boxes(b, 0, b.count).first(where: { $0.type == "meta" }) else { return nil }
        let metaChildrenStart = meta.contentStart + 4            // meta is a FullBox (version+flags)
        guard metaChildrenStart <= meta.end else { return nil }
        let children = boxes(b, metaChildrenStart, meta.end)
        guard let iinf = children.first(where: { $0.type == "iinf" }),
              let iloc = children.first(where: { $0.type == "iloc" }) else { return nil }

        // --- iinf: collect item ids whose type is Exif / mime (XMP) / uri ---
        guard b.indices.contains(iinf.contentStart) else { return nil }
        let iinfVersion = Int(b[iinf.contentStart])
        var p = iinf.contentStart + 4
        let countSize = iinfVersion == 0 ? 2 : 4
        guard readInt(b, p, countSize, limit: iinf.end) != nil else { return nil }
        p += countSize
        var targetIDs = Set<Int>()
        for entry in boxes(b, p, iinf.end) where entry.type == "infe" {
            guard b.indices.contains(entry.contentStart) else { continue }
            let ev = Int(b[entry.contentStart])
            var q = entry.contentStart + 4
            let idSize = ev >= 3 ? 4 : 2
            guard let id = readInt(b, q, idSize, limit: entry.end) else { continue }
            q += idSize + 2                                       // + protection_index
            guard q + 4 <= entry.end else { continue }
            let itemType = String(bytes: b[q..<(q + 4)], encoding: .ascii) ?? ""
            if itemType == "Exif" || itemType == "mime" || itemType == "uri " { targetIDs.insert(id) }
        }
        if targetIDs.isEmpty { return Report(format: "heic", bytesErased: 0, method: "isobmff-none") }

        // --- iloc: resolve the byte ranges of those items (construction_method 0) ---
        guard b.indices.contains(iloc.contentStart) else { return nil }
        let ilocVersion = Int(b[iloc.contentStart])
        var r = iloc.contentStart + 4
        guard let sizeByte1 = readInt(b, r, 1, limit: iloc.end),
              let sizeByte2 = readInt(b, r + 1, 1, limit: iloc.end) else { return nil }
        r += 2
        let offsetSize = (sizeByte1 >> 4) & 0xF
        let lengthSize = sizeByte1 & 0xF
        let baseOffsetSize = (sizeByte2 >> 4) & 0xF
        let indexSize = (ilocVersion == 1 || ilocVersion == 2) ? (sizeByte2 & 0xF) : 0
        let itemCountSize = ilocVersion < 2 ? 2 : 4
        guard let itemCount = readInt(b, r, itemCountSize, limit: iloc.end) else { return nil }
        r += itemCountSize

        // Always consume every field of every item so the cursor stays in sync;
        // decide per-extent whether to erase. construction_method 0 = file
        // offset, 1 = relative to the `idat` box; others are left untouched.
        let idat = children.first(where: { $0.type == "idat" })
        var ranges: [(Int, Int)] = []
        for _ in 0..<itemCount {
            let idSize = ilocVersion < 2 ? 2 : 4
            guard let itemID = readInt(b, r, idSize, limit: iloc.end) else { return nil }
            r += idSize
            var method = 0
            if ilocVersion == 1 || ilocVersion == 2 {
                guard let raw = readInt(b, r, 2, limit: iloc.end) else { return nil }
                method = raw & 0xF
                r += 2
            }
            r += 2                                                // data_reference_index
            let baseOffset = baseOffsetSize > 0 ? (readInt(b, r, baseOffsetSize, limit: iloc.end) ?? -1) : 0
            guard baseOffset >= 0 else { return nil }
            r += baseOffsetSize
            guard let extentCount = readInt(b, r, 2, limit: iloc.end) else { return nil }
            r += 2
            for _ in 0..<extentCount {
                if indexSize > 0 { r += indexSize }
                let extentOffset = offsetSize > 0 ? (readInt(b, r, offsetSize, limit: iloc.end) ?? -1) : 0
                guard extentOffset >= 0 else { return nil }
                r += offsetSize
                let extentLength = lengthSize > 0 ? (readInt(b, r, lengthSize, limit: iloc.end) ?? -1) : 0
                guard extentLength >= 0 else { return nil }
                r += lengthSize
                guard targetIDs.contains(itemID) else { continue }
                let absolute: Int
                switch method {
                case 0: absolute = baseOffset + extentOffset
                case 1: guard let idat else { continue }; absolute = idat.contentStart + baseOffset + extentOffset
                default: continue
                }
                ranges.append((absolute, extentLength))
            }
        }
        guard !ranges.isEmpty else { return nil }

        var mutable = b
        var erased = 0
        for (offset, length) in ranges {
            guard length > 0, offset >= 0, offset + length <= mutable.count else { return nil }
            for k in offset..<(offset + length) { mutable[k] = 0 }
            erased += length
        }
        data = Data(mutable)
        return Report(format: "heic", bytesErased: erased, method: "isobmff-inplace-zero")
    }
}
