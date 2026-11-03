import Foundation
import ImageIO
import zlib

struct StudyFileContents {
    var pages: [StudyPage]
    var images: [String: Data] = [:]
    var notice: String?
}

enum StudyFileFormats {
    static let codeExtensions: Set<String> = [
        "py", "pyw", "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "java", "kt", "kts", "c", "h", "cc", "cpp", "cxx",
        "hpp", "cs", "fs", "go", "rs", "rb", "php", "sh", "zsh", "bash", "fish", "sql", "r", "rmd", "m", "jl", "lua",
        "pl", "scala", "sc", "dart", "vue", "svelte", "css", "scss", "sass", "less", "json", "xml", "yaml", "yml",
        "toml", "ini", "cfg", "conf", "cmake", "make", "dockerfile", "graphql", "proto", "v", "sv", "vhd", "vhdl",
        "asm", "s", "f", "f90", "f95", "ipynb",
    ]
    static let officeExtensions: Set<String> = [
        "docx", "docm", "dotx", "pptx", "pptm", "ppsx", "xlsx", "xlsm", "xltx", "odt", "ods", "odp",
    ]
    static let previewExtensions: Set<String> = ["doc", "ppt", "xls", "rtf", "rtfd", "pages", "numbers", "key", "epub"]

    static func language(_ ext: String) -> String {
        [
            "py": "python", "pyw": "python", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
            "ts": "typescript", "tsx": "typescript", "jsx": "javascript", "h": "c", "hpp": "cpp", "cc": "cpp",
            "rs": "rust", "sh": "bash", "zsh": "bash", "kt": "kotlin", "yml": "yaml", "m": "matlab", "jl": "julia",
        ][ext] ?? ext
    }
    static func fenced(_ text: String, language: String = "") -> String {
        let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let safeLanguage = String(language.filter { $0.isLetter || $0.isNumber }.prefix(24))
        return "\(fence)\(safeLanguage)\n\(text)\n\(fence)"
    }
    static func code(_ text: String, name: String) -> [StudyPage] {
        let lines = text.components(separatedBy: "\n")
        let lang = language(URL(fileURLWithPath: name).pathExtension.lowercased())
        return stride(from: 0, to: lines.count, by: 160).map { start in
            let end = min(start + 160, lines.count)
            return StudyPage(
                number: start / 160 + 1,
                text: "### Lines \(start + 1)–\(end)\n\n"
                    + fenced(lines[start..<end].joined(separator: "\n"), language: lang))
        }
    }
    static func image(_ data: Data) -> Data? {
        guard data.count <= 12_000_000,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let cg = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1_800,
                ] as CFDictionary)
        else { return nil }
        return ImageEncoding.jpegData(from: cg)
    }
    static func notebook(_ data: Data) throws -> StudyFileContents {
        guard let book = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cells = book["cells"] as? [[String: Any]], !cells.isEmpty, cells.count <= 4_000
        else { throw StudyError.message("This notebook has no readable cells or exceeds 4,000 cells.") }
        func content(_ value: Any?) -> String { value as? String ?? (value as? [String])?.joined() ?? "" }
        let metadata = book["metadata"] as? [String: Any]
        let lang = (metadata?["language_info"] as? [String: Any])?["name"] as? String ?? "python"
        var result = StudyFileContents(pages: [])
        var characters = 0
        var imageBytes = 0
        for (index, cell) in cells.enumerated() {
            try Task.checkCancellation()
            let source = content(cell["source"])
            let isCode = cell["cell_type"] as? String == "code"
            var text =
                "### Cell \(index + 1)\(isCode ? " · \(lang)" : "")\n\n"
                + (isCode ? fenced(source, language: lang) : source)
            if ((cell["metadata"] as? [String: Any])?["scholia"] as? [String: Any])?["outputsFromEarlierSource"]
                as? Bool == true
            {
                text +=
                    "\n\n> Saved outputs below come from before this cell was edited. The edited code has not been run."
            }
            var images: [String] = []
            for output in cell["outputs"] as? [[String: Any]] ?? [] {
                let values = output["data"] as? [String: Any] ?? [:]
                let plain = content(output["text"]).isEmpty ? content(values["text/plain"]) : content(output["text"])
                if !plain.isEmpty {
                    text += "\n\n**Output**\n\n" + fenced(plain)
                } else if let html = values["text/html"] {
                    text += "\n\n" + StudyHTML.plainText(content(html))
                } else if let markdown = values["text/markdown"] {
                    text += "\n\n" + content(markdown)
                }
                if let traceback = output["traceback"] as? [String] {
                    text += "\n\n**Saved error**\n\n" + fenced(traceback.joined(separator: "\n"))
                }
                for mime in ["image/png", "image/jpeg"] {
                    let encoded = content(values[mime])
                    if !encoded.isEmpty, let decoded = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                        let jpeg = image(decoded)
                    {
                        imageBytes += jpeg.count
                        guard imageBytes <= 32_000_000 else {
                            throw StudyError.message("Notebook images exceed the 32 MB preview limit.")
                        }
                        let name = "cell-\(index + 1)-\(images.count + 1).jpg"
                        result.images[name] = jpeg
                        images.append(name)
                        break
                    }
                }
                if values.keys.contains(where: {
                    $0.contains("widget") || $0.contains("plotly") || $0 == "image/svg+xml"
                }), images.isEmpty {
                    result.notice =
                        "Interactive widgets and SVG-only outputs are not executed. Saved text and raster outputs are available."
                }
            }
            characters += text.utf16.count
            guard characters <= StudyDocumentImporter.maximumCharacters else {
                throw StudyError.message("The notebook exceeds 8 million extracted characters.")
            }
            result.pages.append(StudyPage(number: index + 1, text: text, images: images.isEmpty ? nil : images))
        }
        return result
    }

    static func office(_ data: Data, extension ext: String) throws -> StudyFileContents {
        let archive = try StudyOfficeArchive(data: data)
        func xml(_ path: String) throws -> XMLDocument {
            let bytes = try archive.read(path)
            guard let source = String(data: bytes, encoding: .utf8),
                !source.localizedCaseInsensitiveContains("<!DOCTYPE"),
                !source.localizedCaseInsensitiveContains("<!ENTITY")
            else { throw StudyError.message("This Office XML contains unsupported entities or encoding.") }
            return try XMLDocument(data: bytes, options: [.nodeLoadExternalEntitiesNever])
        }
        func nodes(_ node: XMLNode, _ name: String) -> [XMLNode] {
            (try? node.nodes(forXPath: ".//*[local-name()='\(name)']")) ?? []
        }
        func attr(_ node: XMLNode, _ name: String) -> String {
            (node as? XMLElement)?.attribute(forName: name)?.stringValue ?? ""
        }
        func paragraphs(_ node: XMLNode) -> String {
            nodes(node, "p").map { p in
                let text = nodes(p, "t").map { $0.stringValue ?? "" }.joined()
                let style = nodes(p, "pStyle").first.map { attr($0, "w:val") } ?? ""
                let prefix =
                    style.lowercased().hasPrefix("heading")
                    ? String(repeating: "#", count: min(6, Int(style.filter(\.isNumber)) ?? 2)) + " " : ""
                return prefix + text
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        func relationships(_ path: String) throws -> [String: String] {
            guard archive.names.contains(path) else { return [:] }
            return nodes(try xml(path), "Relationship").reduce(into: [:]) { result, node in
                if attr(node, "TargetMode") != "External" { result[attr(node, "Id")] = attr(node, "Target") }
            }
        }
        var result = StudyFileContents(
            pages: [],
            notice:
                "Reading view preserves text, tables, and embedded images. Use Original layout for the document's full formatting; macros and external content are not executed."
        )
        func append(_ text: String, from path: String, node: XMLNode, relationships relPath: String) throws {
            let rels = try relationships(relPath)
            var images: [String] = []
            for blip in nodes(node, "blip") {
                guard let target = rels[attr(blip, "r:embed")], !target.contains(":") else { continue }
                let base = URL(fileURLWithPath: "/" + path).deletingLastPathComponent()
                let resolved =
                    (target.hasPrefix("/") ? URL(fileURLWithPath: target) : base.appendingPathComponent(target))
                    .standardizedFileURL.path.dropFirst()
                guard resolved.contains("/media/"), archive.names.contains(String(resolved)) else { continue }
                if let jpeg = image(try archive.read(String(resolved))) {
                    let name = "page-\(result.pages.count + 1)-\(images.count + 1).jpg"
                    result.images[name] = jpeg
                    images.append(name)
                }
            }
            result.pages.append(
                StudyPage(number: result.pages.count + 1, text: text, images: images.isEmpty ? nil : images))
        }
        if ["docx", "docm", "dotx"].contains(ext) {
            let doc = try xml("word/document.xml")
            let body = nodes(doc, "body").first ?? doc
            var text = ""
            var section = XMLElement(name: "section")
            func flush() throws {
                guard !text.isEmpty || section.childCount > 0 else { return }
                try append(
                    text, from: "word/document.xml", node: section, relationships: "word/_rels/document.xml.rels")
                text = ""
                section = XMLElement(name: "section")
            }
            for node in body.children ?? [] {
                let part: String
                if node.localName == "tbl" {
                    let rows = nodes(node, "tr").map { row in
                        nodes(row, "tc").map {
                            paragraphs($0).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(
                                of: "|", with: "\\|")
                        }
                    }
                    part = table(rows)
                } else if node.localName == "p" {
                    part = paragraphsWrapper(node, nodes: nodes)
                } else {
                    continue
                }
                if text.count + part.count > 5_000 && !text.isEmpty { try flush() }
                if !part.isEmpty { text += (text.isEmpty ? "" : "\n\n") + part }
                if let copied = node.copy() as? XMLNode { section.addChild(copied) }
            }
            try flush()
        } else if ["pptx", "pptm", "ppsx"].contains(ext) {
            let rels = try relationships("ppt/_rels/presentation.xml.rels")
            let presentation = try xml("ppt/presentation.xml")
            let slides = nodes(presentation, "sldId").compactMap { rels[attr($0, "r:id")] }.map {
                $0.hasPrefix("/")
                    ? String($0.dropFirst())
                    : URL(fileURLWithPath: "/ppt/" + $0).standardizedFileURL.path.dropFirst().description
            }
            let paths =
                slides.isEmpty
                ? archive.names.filter {
                    $0.range(of: #"^ppt/slides/slide\d+\.xml$"#, options: .regularExpression) != nil
                }.sorted { $0.localizedStandardCompare($1) == .orderedAscending } : slides
            for (index, path) in paths.enumerated() {
                let doc = try xml(path)
                try append(
                    "# Slide \(index + 1)\n\n" + paragraphs(doc), from: path, node: doc,
                    relationships: "ppt/slides/_rels/" + URL(fileURLWithPath: path).lastPathComponent + ".rels")
            }
        } else if ["xlsx", "xlsm", "xltx"].contains(ext) {
            result.notice =
                "Reading view shows cells and saved formula results. Open Original layout for formatting, charts, and images. Formulas are not recalculated."
            let shared =
                archive.names.contains("xl/sharedStrings.xml")
                ? nodes(try xml("xl/sharedStrings.xml"), "si").map {
                    nodes($0, "t").map { $0.stringValue ?? "" }.joined()
                } : []
            let rels = try relationships("xl/_rels/workbook.xml.rels")
            let book = try xml("xl/workbook.xml")
            for sheet in nodes(book, "sheet") {
                guard let target = rels[attr(sheet, "r:id")] else { continue }
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                let doc = try xml(path)
                let sheetName = attr(sheet, "name")
                let rows = nodes(doc, "row").map { row -> [String] in
                    var values: [String] = []
                    for cell in nodes(row, "c") {
                        let address = attr(cell, "r")
                        let column = address.uppercased().prefix(while: \.isLetter).reduce(0) {
                            $0 * 26 + Int($1.asciiValue ?? 65) - 64
                        }
                        guard column > 0, column <= 256 else {
                            result.notice =
                                "Reading view shows the first 256 columns and cached cell values. Open Original layout to see the complete workbook."
                            continue
                        }
                        while values.count < column { values.append("") }
                        let raw = nodes(cell, "v").first?.stringValue ?? nodes(cell, "t").first?.stringValue ?? ""
                        let formula = nodes(cell, "f").first?.stringValue
                        let value =
                            attr(cell, "t") == "s"
                            ? Int(raw).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? raw : raw
                        values[column - 1] = (value + (formula.map { value.isEmpty ? "=\($0)" : " (=\($0))" } ?? ""))
                            .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
                    }
                    return [attr(row, "r")] + values
                }
                for start in stride(from: 0, to: max(1, rows.count), by: 100) {
                    let part = Array(rows.dropFirst(start).prefix(100))
                    let width = part.map(\.count).max() ?? 1
                    let header = ["Row"] + (1..<max(1, width)).map(columnName)
                    result.pages.append(
                        StudyPage(number: result.pages.count + 1, text: "# \(sheetName)\n\n" + table([header] + part)))
                }
            }
        } else {
            result.notice =
                "Reading view contains extracted OpenDocument text. Open Original layout for tables, images, and full formatting."
            let doc = try xml("content.xml")
            let text = nodes(doc, "p").map { $0.stringValue ?? "" }.joined(separator: "\n\n")
            result.pages = chunks(text).enumerated().map { StudyPage(number: $0.offset + 1, text: $0.element) }
        }
        guard !result.pages.isEmpty, result.pages.count <= 4_000,
            result.pages.reduce(0, { $0 + $1.text.utf16.count }) <= StudyDocumentImporter.maximumCharacters,
            result.images.values.reduce(0, { $0 + $1.count }) <= 32_000_000
        else { throw StudyError.message("This Office document exceeds the reading limits or has no readable content.") }
        return result
    }

    private static func paragraphsWrapper(_ paragraph: XMLNode, nodes: (XMLNode, String) -> [XMLNode]) -> String {
        let text = nodes(paragraph, "t").map { $0.stringValue ?? "" }.joined()
        let style = (nodes(paragraph, "pStyle").first as? XMLElement)?.attribute(forName: "w:val")?.stringValue ?? ""
        return (style.lowercased().hasPrefix("heading") ? "## " : "") + text
    }
    private static func columnName(_ number: Int) -> String {
        var n = number
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(65 + n % 26)!) + result
            n /= 26
        }
        return result
    }
    private static func table(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let width = rows.map(\.count).max() ?? 0
        guard width > 0 else { return "" }
        func row(_ values: [String]) -> String {
            "| " + (values + Array(repeating: "", count: max(0, width - values.count))).joined(separator: " | ") + " |"
        }
        return ([row(rows[0]), row(Array(repeating: "---", count: width))] + rows.dropFirst().map(row)).joined(
            separator: "\n")
    }
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > 5_000 && !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n\n") + paragraph
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.isEmpty ? [""] : chunks
    }
}

/// Reads only named, bounded ZIP parts in memory. Nothing is expanded onto disk
/// and macro/external relationships are never evaluated.
final class StudyOfficeArchive {
    struct Entry {
        var offset: Int
        var size: Int
        var expanded: Int
        var method: Int
        var crc: UInt32
    }
    let data: Data
    var entries: [String: Entry] = [:]
    var expandedBytes = 0
    var names: [String] { Array(entries.keys) }
    init(data: Data) throws {
        self.data = data
        func u16(_ n: Int) throws -> Int { Int(try readNumber(n, length: 2)) }
        func u32(_ n: Int) throws -> Int { Int(try readNumber(n, length: 4)) }
        guard data.count >= 22 else { throw StudyError.message("This is not a readable ZIP archive.") }
        var end: Int?
        for n in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try u32(n) == 0x0605_4b50 {
                end = n
                break
            }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else {
            throw StudyError.message("Multipart ZIP archives are unsupported.")
        }
        let count = try u16(end + 10)
        var position = try u32(end + 16)
        guard count <= 10_000 else { throw StudyError.message("This ZIP archive has too many parts.") }
        for _ in 0..<count {
            guard try u32(position) == 0x0201_4b50 else { throw StudyError.message("The ZIP archive is damaged.") }
            let flags = try u16(position + 8)
            let method = try u16(position + 10)
            let size = try u32(position + 20)
            let expanded = try u32(position + 24)
            let length = try u16(position + 28)
            let extra = try u16(position + 30)
            let comment = try u16(position + 32)
            let local = try u32(position + 42)
            guard position + 46 + length <= data.count else {
                throw StudyError.message("The ZIP archive is incomplete.")
            }
            let name = String(decoding: data[(position + 46)..<(position + 46 + length)], as: UTF8.self)
            guard flags & 1 == 0 else { throw StudyError.message("Unlock this archive before importing it.") }
            guard !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains("\\"),
                entries[name] == nil
            else { throw StudyError.message("The ZIP archive contains an invalid part name.") }
            entries[name] = Entry(
                offset: local, size: size, expanded: expanded, method: method,
                crc: try readNumber(position + 16, length: 4))
            position += 46 + length + extra + comment
        }
    }
    private func readNumber(_ offset: Int, length: Int) throws -> UInt32 {
        guard offset >= 0, offset + length <= data.count else {
            throw StudyError.message("The ZIP archive is incomplete.")
        }
        return (0..<length).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    func read(_ name: String) throws -> Data {
        try Task.checkCancellation()
        guard let item = entries[name], item.expanded <= 8_000_000, item.size <= 100_000_000 else {
            throw StudyError.message("An archive member is missing or too large.")
        }
        expandedBytes += item.expanded
        guard expandedBytes <= 64_000_000, try readNumber(item.offset, length: 4) == 0x0403_4b50 else {
            throw StudyError.message("The archive exceeds the extraction limit.")
        }
        let start =
            item.offset + 30 + Int(try readNumber(item.offset + 26, length: 2))
            + Int(try readNumber(item.offset + 28, length: 2))
        guard start >= 0, start + item.size <= data.count else {
            throw StudyError.message("An archive member is incomplete.")
        }
        let compressed = data.subdata(in: start..<(start + item.size))
        let result: Data
        if item.method == 0 {
            result = compressed
        } else if item.method == 8 {
            var output = Data(count: max(1, item.expanded))
            let valid = compressed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { buffer -> Bool in
                    var stream = z_stream()
                    stream.next_in = UnsafeMutablePointer<Bytef>(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
                    else { return false }
                    defer { inflateEnd(&stream) }
                    return inflate(&stream, Z_FINISH) == Z_STREAM_END && stream.total_out == item.expanded
                }
            }
            guard valid else { throw StudyError.message("An archive member could not be decompressed.") }
            result = Data(output.prefix(item.expanded))
        } else {
            throw StudyError.message("This ZIP compression format is unsupported.")
        }
        let checksum = result.withUnsafeBytes {
            crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(result.count))
        }
        guard result.count == item.expanded, UInt32(checksum) == item.crc else {
            throw StudyError.message("An archive member failed its integrity check.")
        }
        return result
    }
}
