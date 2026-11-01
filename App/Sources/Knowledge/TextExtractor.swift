import CryptoKit
import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

struct ExtractedDocument: Sendable {
    var kind: String
    var pages: [(locator: String, text: String)]
    var note: String
    var hash: String
}

/// Reads text out of files and photos on the device: plain text, PDFs (with OCR for scanned pages), and images (Vision).
enum TextExtractor {
    static let maxBytes = 25_000_000
    static let maxCharacters = 2_000_000
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "yaml", "yml", "xml", "log", "ini", "toml", "tex", "rst",
        "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "rb", "php", "sh", "sql", "css", "scss",
    ]

    static func extract(fileAt url: URL) throws -> ExtractedDocument {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw KnowledgeError("\(url.lastPathComponent) is larger than 25 MB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try extract(data: data, name: url.lastPathComponent)
    }

    static func extract(data: Data, name: String) throws -> ExtractedDocument {
        guard data.count <= maxBytes else { throw KnowledgeError("\(name) is larger than 25 MB.") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let ext = (name as NSString).pathExtension.lowercased()

        if ext == "pdf" || data.starts(with: Data("%PDF".utf8)) { return try pdf(data, hash: hash) }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) || UIImage(data: data) != nil && !textExtensions.contains(ext) {
            return try image(data, hash: hash)
        }
        if ["rtf", "rtfd"].contains(ext) {
            let text = (try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
            return try document(kind: "text", text: text, note: "", hash: hash, name: name)
        }
        if ["html", "htm"].contains(ext) {
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: #"<(script|style)[\s\S]*?</\1>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            return try document(kind: "text", text: text, note: "", hash: hash, name: name)
        }
        guard textExtensions.contains(ext) || ext.isEmpty || String(data: data.prefix(4096), encoding: .utf8) != nil else {
            throw KnowledgeError("\(name): this kind of file isn't supported yet. Use text, PDF, or an image.")
        }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .isoLatin1) else {
            throw KnowledgeError("\(name) couldn't be read as text.")
        }
        return try document(kind: "text", text: text, note: "", hash: hash, name: name)
    }

    // MARK: Kinds

    private static func document(kind: String, text: String, note: String, hash: String, name: String) throws -> ExtractedDocument {
        let trimmed = String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KnowledgeError("\(name) has no text in it.") }
        return ExtractedDocument(kind: kind, pages: [("", trimmed)], note: note, hash: hash)
    }

    private static func pdf(_ data: Data, hash: String) throws -> ExtractedDocument {
        guard let pdf = PDFDocument(data: data) else { throw KnowledgeError("That PDF couldn't be opened.") }
        if pdf.isLocked { throw KnowledgeError("That PDF is password protected.") }
        var pages: [(locator: String, text: String)] = []
        var ocrPages = 0
        var characters = 0
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index), characters < maxCharacters else { continue }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count < 25, ocrPages < 60 {            // a scanned page: read it with Vision instead
                let bounds = page.bounds(for: .mediaBox)
                let width: CGFloat = 1600
                let image = page.thumbnail(of: CGSize(width: width, height: width * bounds.height / max(bounds.width, 1)), for: .mediaBox)
                if let cg = image.cgImage { text = recognize(cg, orientation: .up); ocrPages += 1 }
            }
            guard !text.isEmpty else { continue }
            characters += text.count
            pages.append(("page \(index + 1)", text))
        }
        guard !pages.isEmpty else { throw KnowledgeError("No text could be read from that PDF.") }
        return ExtractedDocument(kind: "pdf", pages: pages, note: ocrPages > 0 ? "\(ocrPages) scanned page(s) read with text recognition" : "", hash: hash)
    }

    private static func image(_ data: Data, hash: String) throws -> ExtractedDocument {
        guard let image = UIImage(data: data), let cg = image.cgImage else { throw KnowledgeError("That image couldn't be opened.") }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let text = recognize(cg, orientation: orientation)
        let labels = classify(cg, orientation: orientation)
        var body = ""
        if !labels.isEmpty { body += "The image shows: " + labels.joined(separator: ", ") + ".\n" }
        if !text.isEmpty { body += "Text in the image:\n" + text }
        guard !body.isEmpty else { throw KnowledgeError("Nothing readable was found in that image.") }
        return ExtractedDocument(kind: "image", pages: [("", body)], note: text.isEmpty ? "No text found; described by what it shows" : "Text read with text recognition", hash: hash)
    }

    // MARK: Vision

    static func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func classify(_ image: CGImage, orientation: CGImagePropertyOrientation) -> [String] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        return (request.results ?? []).filter { $0.confidence > 0.35 }.prefix(6).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}

struct KnowledgeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
