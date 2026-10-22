import Foundation
import AppKit
import PDFKit
import CoreText
import ImageIO

/// Converts documents, PDFs and spreadsheets — **without bundling a runtime**.
///
/// Native-first, mirroring the subject app's capabilities but not its weight
/// (it ships a full JRE twice for Apache POI). Zest uses:
///   • `NSAttributedString` (AppKit) — reads/writes docx, doc, rtf, rtfd, odt,
///     html, txt entirely in-process; also renders any of them to PDF.
///   • `PDFKit` — PDF → image, PDF → text, and image → PDF.
///   • `soffice` (LibreOffice headless) — *optional, located at runtime, never
///     bundled* — for the formats the native stack can't do (pptx/xlsx/ods …).
public struct DocumentBackend: Converter {
    public let identifier = "document"
    public let soffice: URL?

    public init(soffice: URL? = nil) {
        self.soffice = soffice ?? ToolLocator.find("soffice", extraPaths: ["/Applications/LibreOffice.app/Contents/MacOS"])
    }

    /// Formats the AppKit document engine can read / write.
    private static let attrReadable: Set<String> = ["txt", "md", "rtf", "rtfd", "html", "doc", "docx", "odt"]
    private static let attrWritable: Set<String> = ["txt", "rtf", "rtfd", "html", "doc", "docx", "odt"]
    private static let rasterTargets: Set<String> = ["png", "jpg", "tiff"]
    /// Formats that require LibreOffice (no native path).
    private static let heavy: Set<String> = ["pptx", "ppt", "xlsx", "xls", "ods", "csv", "tsv"]

    public func supports(from source: MediaFormat, to target: MediaFormat) -> Bool {
        let s = source.id, t = target.id
        if s == "pdf", Self.rasterTargets.contains(t) || t == "txt" || t == "md" || Self.attrWritable.contains(t) { return true }
        if source.category == .image, t == "pdf" { return true }
        if Self.attrReadable.contains(s), Self.attrWritable.contains(t) || t == "pdf" { return true }
        if soffice != nil {                                   // heavy office via LibreOffice
            let docish = Self.heavy.union(Self.attrReadable).union(["pdf"])
            if Self.heavy.contains(s), docish.contains(t) { return true }
            if docish.contains(s), Self.heavy.contains(t) { return true }
        }
        return false
    }

    public func convert(_ request: ConversionRequest, progress: ProgressHandler?) async throws -> ConversionResult {
        let start = Date()
        let s = request.source.id, t = request.target.id
        progress?(0.1)

        if soffice != nil, Self.heavy.contains(s) || Self.heavy.contains(t) {
            try libreConvert(request)
        } else if s == "pdf", Self.rasterTargets.contains(t) {
            try pdfToImage(request)
        } else if s == "pdf", t == "txt" || t == "md" {
            try pdfToText(request)
        } else if s == "pdf", Self.attrWritable.contains(t) {
            let text = pdfText(request.input)
            try await MainActor.run { try self.write(attributed: NSAttributedString(string: text), to: request.output, id: t) }
        } else if request.source.category == .image, t == "pdf" {
            try imageToPDF(request)
        } else if Self.attrReadable.contains(s), t == "pdf" {
            // NSAttributedString's HTML importer is WebKit-backed and must run on the main actor.
            try await MainActor.run { try self.docToPDF(self.read(request.input, id: s), to: request.output) }
        } else if Self.attrReadable.contains(s), Self.attrWritable.contains(t) {
            try await MainActor.run { try self.write(attributed: self.read(request.input, id: s), to: request.output, id: t) }
        } else {
            throw ConversionError.unsupportedPair(request.source, request.target)
        }

        progress?(1.0)
        return ConversionResult(output: request.output, bytes: fileSize(request.output), elapsed: Date().timeIntervalSince(start))
    }

    // MARK: - AppKit document engine (native, in-process)

    private func read(_ url: URL, id: String) throws -> NSAttributedString {
        let type = Self.docType(for: id)
        if let attr = try? NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) { return attr }
        if let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return attr }
        throw ConversionError.io("could not read document: \(url.lastPathComponent)")
    }

    private func write(attributed: NSAttributedString, to url: URL, id: String) throws {
        let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                       documentAttributes: [.documentType: Self.docType(for: id)])
        try data.write(to: url)
    }

    private static func docType(for id: String) -> NSAttributedString.DocumentType {
        switch id {
        case "rtf":            return .rtf
        case "rtfd":           return .rtfd
        case "html", "htm":    return .html
        case "doc":            return .docFormat
        case "docx":           return .officeOpenXML
        case "odt":            return .openDocument
        default:               return .plain   // txt, md
        }
    }

    // MARK: - PDF rendering (PDFKit + CoreText)

    /// Lay the attributed string out across US-Letter pages into a PDF.
    private func docToPDF(_ attributed: NSAttributedString, to url: URL) throws {
        let pageSize = CGSize(width: 612, height: 792)   // US Letter, 72 dpi
        let margin: CGFloat = 54
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConversionError.io("could not create PDF context")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        // A CGPDFContext is already bottom-left / y-up — the orientation CoreText
        // expects — so draw directly, with NO flip (flipping rendered text
        // upside-down and bottom-anchored). The frame fills from its top edge down.
        let path = CGPath(rect: CGRect(x: margin, y: margin,
                                       width: pageSize.width - 2 * margin,
                                       height: pageSize.height - 2 * margin), transform: nil)
        var cursor = 0
        let total = attributed.length
        while cursor < total {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(cursor, 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            // Advance by what fit; if nothing fit (a run taller than the page),
            // step one glyph so content is neither dropped silently nor looped forever.
            cursor += visible.length > 0 ? visible.length : 1
        }
        context.closePDF()
    }

    private func pdfText(_ url: URL) -> String {
        PDFDocument(url: url)?.string ?? ""
    }

    private func pdfToText(_ request: ConversionRequest) throws {
        let text = pdfText(request.input)
        guard !text.isEmpty else {
            throw ConversionError.io("no extractable text in PDF (an image-only/scanned PDF needs OCR)")
        }
        try text.data(using: .utf8)?.write(to: request.output)
    }

    private func pdfToImage(_ request: ConversionRequest) throws {
        guard let document = PDFDocument(url: request.input), let page = document.page(at: 0) else {
            throw ConversionError.io("could not open PDF: \(request.input.lastPathComponent)")
        }
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2.0                               // ~144 dpi
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError.io("could not create bitmap context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.io("could not rasterize PDF page") }
        guard let uti = ImageBackend.utiFor(request.target),
              let dest = CGImageDestinationCreateWithURL(request.output as CFURL, uti as CFString, 1, nil) else {
            throw ConversionError.io("could not create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.io("image encode failed") }
    }

    private func imageToPDF(_ request: ConversionRequest) throws {
        guard let image = NSImage(contentsOf: request.input), let page = PDFPage(image: image) else {
            throw ConversionError.io("could not load image: \(request.input.lastPathComponent)")
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: request.output) else { throw ConversionError.io("could not write PDF") }
    }

    // MARK: - LibreOffice adapter (optional, located at runtime, never bundled)

    private func libreConvert(_ request: ConversionRequest) throws {
        guard let soffice else { throw ConversionError.toolNotFound("soffice (LibreOffice)") }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zest-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let out = try ProcessRunner.run(soffice, [
            "--headless", "--norestore",
            "--convert-to", request.target.primaryExtension,
            "--outdir", tmp.path, request.input.path,
        ])
        guard out.code == 0 else { throw ConversionError.toolFailed(code: out.code, stderr: out.stderr) }
        let produced = tmp.appendingPathComponent(request.input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(request.target.primaryExtension)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConversionError.io("LibreOffice produced no output")
        }
        try? FileManager.default.removeItem(at: request.output)
        try FileManager.default.moveItem(at: produced, to: request.output)
    }

    private func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? Int) ?? 0
    }
}
