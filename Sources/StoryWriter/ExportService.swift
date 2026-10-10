import AppKit
import CoreGraphics

enum ExportFormat: String, CaseIterable, Identifiable {
    case docx = "Word document", pdf = "PDF", epub = "EPUB book", html = "Web page", markdown = "Markdown", rtf = "Rich text", txt = "Plain text"
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .docx: return "docx"; case .pdf: return "pdf"; case .epub: return "epub"; case .html: return "html"; case .markdown: return "md"; case .rtf: return "rtf"; case .txt: return "txt" }
    }
    var explanation: String {
        switch self {
        case .docx: return "Editable in Word and Pages, with rich text formatting."
        case .pdf: return "A paginated document for reading, printing, and sharing."
        case .epub: return "A reflowable book with a chapter navigation menu."
        case .html: return "A self-contained page with formatting and embedded images."
        case .markdown: return "Portable text with headings, emphasis, links, and inline images."
        case .rtf: return "Formatted text compatible with most desktop editors."
        case .txt: return "Unformatted UTF-8 text."
        }
    }
}

@MainActor
enum ExportService {
    static func manuscript(project: StoryProject, chapters: [Chapter]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Georgia-Bold", size: 28) ?? NSFont.boldSystemFont(ofSize: 28), .foregroundColor: NSColor.black]
        result.append(NSAttributedString(string: project.title + "\n", attributes: heading))
        if !project.author.isEmpty { result.append(NSAttributedString(string: "By \(project.author)\n", attributes: WritingStyle.attributes)) }
        result.append(NSAttributedString(string: "\n", attributes: WritingStyle.attributes))
        for (index, chapter) in chapters.enumerated() {
            result.append(NSAttributedString(string: chapter.title + "\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black]))
            result.append(ObjectTags.publicationText(chapter.attributedText))
            if index < chapters.count - 1 { result.append(NSAttributedString(string: "\n\n\n", attributes: WritingStyle.attributes)) }
        }
        // System text colors are appearance-dependent. Resolve them for a light publication.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            var colors: [(NSRange, NSColor)] = []
            result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                if let color = value as? NSColor, let resolved = color.usingColorSpace(.deviceRGB) { colors.append((range, resolved)) }
            }
            for (range, color) in colors { result.addAttribute(.foregroundColor, value: color, range: range) }
        }
        return result
    }

    static func export(project: StoryProject, chapters: [Chapter], format: ExportFormat, to url: URL) throws {
        guard !chapters.isEmpty else { throw ProjectError.invalid("Add a chapter before exporting your manuscript.") }
        let text = manuscript(project: project, chapters: chapters)
        switch format {
        case .docx, .rtf:
            let type: NSAttributedString.DocumentType = format == .docx ? .officeOpenXML : .rtf
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
            try data.write(to: url, options: .atomic)
        case .txt: try text.string.write(to: url, atomically: true, encoding: .utf8)
        case .html:
            let renderer = PublicationRenderer()
            let sections = chapters.map { "<section><h2>\($0.title.xmlEscaped)</h2>\(renderer.html($0.attributedText))</section>" }.joined(separator: "\n")
            let page = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"/><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"/><title>\(project.title.xmlEscaped)</title><style>\(PublicationRenderer.styles)</style></head><body><h1>\(project.title.xmlEscaped)</h1>\(project.author.isEmpty ? "" : "<p class=\"author\">\(project.author.xmlEscaped)</p>")\(sections)</body></html>"
            try page.write(to: url, atomically: true, encoding: .utf8)
        case .markdown:
            let renderer = PublicationRenderer()
            let body = "# \(renderer.escapeMarkdown(project.title))\n\n" + (project.author.isEmpty ? "" : "By \(renderer.escapeMarkdown(project.author))\n\n") + chapters.map { "## \(renderer.escapeMarkdown($0.title))\n\n\(renderer.markdown($0.attributedText))" }.joined(separator: "\n\n")
            try body.write(to: url, atomically: true, encoding: .utf8)
        case .pdf: try pdf(text, to: url)
        case .epub: try epub(project: project, chapters: chapters, to: url)
        }
    }

    static func copyForWebsite(_ chapter: Chapter) throws {
        let renderer = PublicationRenderer()
        let text = ObjectTags.publicationText(chapter.attributedText)
        let html = "<html><head><meta charset=\"utf-8\"/></head><body>\(renderer.html(text))</body></html>"
        let rtf = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents(); pasteboard.setString(chapter.plainText, forType: .string); pasteboard.setString(html, forType: .html); pasteboard.setData(rtf, forType: .rtf)
    }

    private static func pdf(_ text: NSAttributedString, to url: URL) throws {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager(); storage.addLayoutManager(manager)
        var containers: [NSTextContainer] = []
        var laidOut = 0
        repeat {
            let container = NSTextContainer(containerSize: NSSize(width: 468, height: 660))
            container.lineFragmentPadding = 0; manager.addTextContainer(container)
            let range = manager.glyphRange(for: container)
            containers.append(container)
            if NSMaxRange(range) <= laidOut && storage.length > 0 { throw ProjectError.invalid("Could not paginate this document. Check for oversized embedded media.") }
            laidOut = NSMaxRange(range)
        } while laidOut < manager.numberOfGlyphs
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw ProjectError.invalid("Could not create PDF data.") }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw ProjectError.invalid("Could not create PDF document.") }
        for (index, container) in containers.enumerated() {
            context.beginPDFPage(nil); context.saveGState()
            context.translateBy(x: 0, y: 792); context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = manager.glyphRange(for: container)
            manager.drawBackground(forGlyphRange: range, at: NSPoint(x: 72, y: 60)); manager.drawGlyphs(forGlyphRange: range, at: NSPoint(x: 72, y: 60))
            ("\(index + 1)" as NSString).draw(at: NSPoint(x: 300, y: 754), withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.gray])
            NSGraphicsContext.restoreGraphicsState(); context.restoreGState(); context.endPDFPage()
        }
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    private static func epub(project: StoryProject, chapters: [Chapter], to url: URL) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("StoryWriter-EPUB-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let content = temporary.appendingPathComponent("OEBPS", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("images"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: temporary.appendingPathComponent("mimetype"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: temporary.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        let renderer = PublicationRenderer(embedImages: false)
        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>"
        var spine = "", navigation = ""
        for (index, chapter) in chapters.enumerated() {
            let file = "chapter-\(index + 1).xhtml", identifier = "chapter\(index + 1)"
            let html = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>\(chapter.title.xmlEscaped)</title><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head><body><h1>\(chapter.title.xmlEscaped)</h1>\(renderer.html(chapter.attributedText))</body></html>"
            try html.write(to: content.appendingPathComponent(file), atomically: true, encoding: .utf8)
            manifest += "<item id=\"\(identifier)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"\(identifier)\"/>"
            navigation += "<li><a href=\"\(file)\">\(chapter.title.xmlEscaped)</a></li>"
        }
        for (filename, data) in renderer.images {
            try data.write(to: content.appendingPathComponent("images/\(filename)"))
            manifest += "<item id=\"\(filename.replacingOccurrences(of: ".", with: "-"))\" href=\"images/\(filename)\" media-type=\"image/png\"/>"
        }
        let nav = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><head><title>Contents</title></head><body><nav epub:type=\"toc\" id=\"toc\"><h1>\(project.title.xmlEscaped)</h1><ol>\(navigation)</ol></nav></body></html>"
        try nav.write(to: content.appendingPathComponent("nav.xhtml"), atomically: true, encoding: .utf8)
        try PublicationRenderer.styles.write(to: content.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
        let language = UserDefaults.standard.string(forKey: "writingLanguage") == "de" ? "de" : "en"
        let opf = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:identifier id=\"book-id\">urn:uuid:\(project.id.uuidString)</dc:identifier><dc:title>\(project.title.xmlEscaped)</dc:title><dc:creator>\(project.author.xmlEscaped)</dc:creator><dc:language>\(language)</dc:language><meta property=\"dcterms:modified\">\(formatter.string(from: Date()))</meta></metadata><manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"
        try opf.write(to: content.appendingPathComponent("content.opf"), atomically: true, encoding: .utf8)
        let archive = temporary.appendingPathComponent("book.epub")
        try zip(arguments: ["-q", "-X", "-0", archive.path, "mimetype"], in: temporary)
        try zip(arguments: ["-q", "-X", "-r", "-9", archive.path, "META-INF", "OEBPS"], in: temporary)
        try Data(contentsOf: archive).write(to: url, options: .atomic)
    }

    private static func zip(arguments: [String], in directory: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/zip"); process.arguments = arguments; process.currentDirectoryURL = directory
        let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProjectError.invalid("Could not package EPUB: \(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "archive error")") }
    }
}

final class PublicationRenderer {
    static let styles = "body{font-family:Georgia,serif;max-width:46em;margin:3em auto;padding:0 1.5em;line-height:1.65;color:#252a28;background:#fff}h1,h2{line-height:1.25}section{margin-top:3em}p{margin:0 0 1em;white-space:pre-wrap}img{max-width:100%;height:auto}.author{color:#64706a}a{color:#256f5a}"
    var images: [(String, Data)] = []
    let embedImages: Bool
    init(embedImages: Bool = true) { self.embedImages = embedImages }

    func html(_ text: NSAttributedString) -> String {
        let string = text.string as NSString
        guard string.length > 0 else { return "<p></p>" }
        var position = 0, result = ""
        while position < string.length {
            let newline = string.range(of: "\n", options: [], range: NSRange(location: position, length: string.length - position))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: position, length: end - position)
            let paragraph = text.attribute(.paragraphStyle, at: position, effectiveRange: nil) as? NSParagraphStyle
            let alignment: String
            switch paragraph?.alignment { case .center: alignment = "center"; case .right: alignment = "right"; case .justified: alignment = "justify"; default: alignment = "left" }
            let indent = max(0, paragraph?.headIndent ?? 0)
            result += "<p style=\"text-align:\(alignment);margin-left:\(Int(indent))pt\">\(inlineHTML(text, range: range))</p>\n"
            position = end + 1
        }
        return result
    }

    private func inlineHTML(_ text: NSAttributedString, range: NSRange) -> String {
        var result = ""
        text.enumerateAttributes(in: range) { attributes, run, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment, let image = imageURL(attachment) { result += "<img src=\"\(image.xmlEscaped)\" alt=\"Story illustration\"/>"; return }
            var value = (text.string as NSString).substring(with: run).xmlEscaped.replacingOccurrences(of: "\r", with: "")
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask) { value = "<strong>\(value)</strong>" }
                if traits.contains(.italicFontMask) { value = "<em>\(value)</em>" }
                let family = (font.familyName ?? "Georgia").xmlEscaped
                value = "<span style=\"font-family:'\(family)';font-size:\(Int(font.pointSize))pt\">\(value)</span>"
            }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { value = "<u>\(value)</u>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { value = "<s>\(value)</s>" }
            if let link = Self.safeLink(attributes[.link]) { value = "<a href=\"\(link.xmlEscaped)\">\(value)</a>" }
            result += value
        }
        return result
    }

    func markdown(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, run, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment, let image = imageURL(attachment) { result += "![Story illustration](\(image))"; return }
            let source = (text.string as NSString).substring(with: run)
            let leading = String(source.prefix(while: { $0.isWhitespace }))
            let trailing = source.count > leading.count ? String(source.suffix(source.count - leading.count).reversed().prefix(while: { $0.isWhitespace }).reversed()) : ""
            let core = String(source.dropFirst(leading.count).dropLast(trailing.count))
            var value = escapeMarkdown(core)
            if !core.isEmpty {
                if let font = attributes[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.boldFontMask) { value = "**\(value)**" }
                    if traits.contains(.italicFontMask) { value = "*\(value)*" }
                }
                if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { value = "~~\(value)~~" }
                if (attributes[.underlineStyle] as? Int ?? 0) != 0 { value = "<u>\(value)</u>" }
                if let link = Self.safeLink(attributes[.link]) { value = "[\(value)](\(link.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))" }
            }
            result += leading + value + trailing
        }
        return result
    }

    func escapeMarkdown(_ value: String) -> String {
        var result = value.replacingOccurrences(of: "\\", with: "\\\\")
        for symbol in ["*", "_", "[", "]", "#", "`", "~", "<", ">"] { result = result.replacingOccurrences(of: symbol, with: "\\" + symbol) }
        return result
    }

    private static func safeLink(_ value: Any?) -> String? {
        let string = (value as? URL)?.absoluteString ?? value as? String
        guard let string, let url = URL(string: string), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return string
    }

    private func imageURL(_ attachment: NSTextAttachment) -> String? {
        let image = attachment.image ?? attachment.fileWrapper?.regularFileContents.flatMap(NSImage.init(data:))
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        if embedImages { return "data:image/png;base64,\(png.base64EncodedString())" }
        let name = "image-\(images.count + 1).png"; images.append((name, png)); return "images/\(name)"
    }
}
