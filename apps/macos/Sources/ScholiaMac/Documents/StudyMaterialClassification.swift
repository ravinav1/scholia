import Foundation

/// A compact, versioned analysis saved with a document. Rendering an inventory never opens a PDF or runs OCR.
struct StudyMaterialClassification: Codable, Equatable, Sendable {
    var version: Int
    var categoryID: String
    var categoryTitle: String
    var categoryOrder: Int
    var confidence: String
    var basis: String
    var topic: String?
    var extractionMethod: String
    var sampledPages: [Int]
}

enum StudyMaterialClassifier {
    static let version = 1
    static let categories: [String: (title: String, order: Int)] = [
        "information": ("Course information", 0), "lectures": ("Lecture notes", 10),
        "notes": ("Notes", 15), "readings": ("Readings", 20),
        "exercises": ("Exercises & assignments", 30), "solutions": ("Solutions", 35),
        "exams": ("Exams", 40), "code": ("Code & notebooks", 50), "data": ("Data & tables", 60),
        "documents": ("Documents", 70), "other": ("Other materials", 90), "assets": ("Course assets", 100),
    ]
    private struct Rule: Sendable {
        var id: String
        var label: NSRegularExpression
        var cues: [NSRegularExpression]
        init(_ id: String, _ label: String, _ cues: [String]) {
            self.id = id
            self.label = try! NSRegularExpression(pattern: label, options: .caseInsensitive)
            self.cues = cues.map { try! NSRegularExpression(pattern: $0, options: .caseInsensitive) }
        }
    }
    private static let rules: [Rule] = [
        Rule("information", #"\b(?:syllabus|kursplan|course overview|emnebeskrivelse|course information)\b"#,
             [#"\b(?:learning outcomes|læringsutbytte)\b"#, #"\b(?:assessment|vurderingsform|grading policy)\b"#, #"\b(?:office hours|course coordinator|emneansvarlig)\b"#]),
        Rule("lectures", #"\b(?:lecture|lectures|forelesning|forelesningsnotater|slides|lecture notes)\b|\b(?:forel|forelesning|lecture|lec)[ -]*\d+|^l\d+\b"#,
             [#"\b(?:today's lecture|today we|in this lecture|dagens forelesning)\b"#, #"\b(?:next lecture|previous lecture|forrige forelesning)\b"#, #"\b(?:learning objectives|lecture outline)\b"#]),
        Rule("notes", #"\b(?:notes|notater|notat|notebook|handwritten|håndskrevne|summary|sammendrag)\b"#,
             [#"\b(?:my notes|study notes|revision notes|egne notater)\b"#, #"\b(?:key ideas|remember|husk)\b"#]),
        Rule("readings", #"\b(?:reading|readings|pensum|chapter|kapittel|textbook|article|artikkel)\b"#,
             [#"\babstract\b"#, #"\b(?:references|bibliography|referanser)\b"#, #"\b(?:doi|isbn|issn)\b"#, #"\b(?:journal|published|copyright)\b"#]),
        Rule("exercises", #"\b(?:exercise|assignment|problem set|øving|oving|oppgave|homework|lab|semesteroppgave|prosjektoppgave)\b|\b(?:oving|øving|exercise|assignment)[ -]*\d+"#,
             [#"\b(?:submit|submission|innlevering|leveres)\b"#, #"\b(?:deadline|due date|frist)\b"#, #"\b(?:problem|exercise|oppgave)\s*\d+\b"#, #"\b(?:calculate|show that|prove that|beregn|vis at)\b"#]),
        Rule("solutions", #"\b(?:solutions?(?!\s+of\b)(?!\s+to\s+(?!(?:exercises?|assignments?|problems?|exam|homework|øving|oppgave)\b))|answer key|worked answers|løsningsforslag|losningsforslag|fasit|løsninger)\b"#,
             [#"\b(?:solution to (?:exercise|assignment|problem)|worked solution|suggested solution)\b"#, #"\b(?:answer key|correct answer|fasit|løsningsforslag)\b"#]),
        Rule("exams", #"\b(?:exam|examination|eksamen|past paper|midterm|final exam|kontinuasjonseksamen)\b"#,
             [#"\b(?:exam duration|examination time|eksamenstid)\b"#, #"\b(?:allowed aids|permitted materials|hjelpemidler)\b"#, #"\b(?:candidate number|kandidatnummer|exam code)\b"#, #"\b(?:total marks|points available|poeng totalt)\b"#]),
    ]
    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }
    /// Front matter plus evenly spaced pages prevents a cover or a single incidental word from deciding a whole file.
    static func sampleIndices(count: Int, limit: Int = 12) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        if count <= limit { return Array(0..<count) }
        var indices = Set(0..<min(3, limit))
        let remaining = limit - indices.count
        if remaining > 0 {
            for step in 1...remaining { indices.insert(Int(Double(count - 1) * Double(step) / Double(remaining))) }
        }
        return indices.sorted()
    }
    static func analyze(title: String, fileName: String?, kind: StudyDocumentKind?, pages: [StudyPage] = [],
                        materialKind: CanvasMaterialKind? = nil) -> StudyMaterialClassification {
        let titleText = normalized(String(title.prefix(500)))
        let fileText = normalized(String((fileName ?? "").prefix(500)))
        let ext = URL(fileURLWithPath: fileName ?? title).pathExtension.lowercased()
        let recognized = pages.indices.filter { ["ocr", "mixed"].contains(pages[$0].extractionMethod ?? "") }
        let recovered = sampleIndices(count: recognized.count, limit: 3).map { recognized[$0] }
        let indices = Set(sampleIndices(count: pages.count, limit: recovered.isEmpty ? 12 : 9) + recovered).sorted()
        let sampled = indices.map { pages[$0] }.filter { page in
            !["ocr", "mixed"].contains(page.extractionMethod ?? "") || (page.ocrConfidence ?? 1) >= 0.55
        }
        // Fixed evidence budget: even 4,000-page books only score 48 KB of text.
        let excerpts = sampled.map { String($0.text.prefix(4_000)) }
        let headings = excerpts.map { text in
            text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.prefix(5).filter { $0.count <= 160 }
        }
        var scores: [String: Int] = [:]
        var sources: [String: Set<String>] = [:]
        func score(_ id: String, _ value: Int, _ source: String) {
            scores[id, default: 0] += value
            sources[id, default: []].insert(source)
        }
        let combined = excerpts.joined(separator: "\n")
        for rule in rules {
            if matches(rule.label, titleText) { score(rule.id, 6, "title") }
            // A matching filename is corroboration, not a second independent vote for the same title.
            if fileText.caseInsensitiveCompare(titleText) != .orderedSame, matches(rule.label, fileText) {
                score(rule.id, 2, "filename")
            }
            let headerPages = headings.filter { lines in
                lines.contains { line in
                    let prefix = String(line.trimmingCharacters(in: CharacterSet(charactersIn: "# *\t")).prefix(110))
                    guard let match = rule.label.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) else { return false }
                    // Category words buried in a prose sentence are not document headings.
                    return match.range.location <= 28 && !prefix.contains(". ")
                }
            }.count
            if headerPages > 0 { score(rule.id, 8 + min(2, headerPages - 1), "content headings") }
            let cueCount = rule.cues.filter { matches($0, combined) }.count
            // Multiple distinct semantic cues are required; repetition cannot inflate the score.
            if cueCount >= 2 { score(rule.id, min(8, cueCount * 2), "document contents") }
        }
        if materialKind == .assignments { score("exercises", 24, "Canvas assignment") }
        if materialKind == .syllabus { score("information", 24, "Canvas syllabus") }
        if kind == .code || kind == .notebook || ext == "ipynb" || StudyFileFormats.codeExtensions.contains(ext) {
            score("code", 7, "file format")
        }
        if ["csv", "tsv", "xlsx", "xls", "ods"].contains(ext) { score("data", 12, "table format") }
        if ["ppt", "pptx", "odp", "key"].contains(ext) { score("lectures", 5, "presentation format") }
        let assetPattern = #"(?:^|\b)(?:icon|logo|divider|banner|footer|header)(?:\b|[-\d])|\bhovedlogo\b"#
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (kind == .image || StudyDocumentImporter.imageExtensions.contains(ext)),
           (titleText + " " + fileText).range(of: assetPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            score("assets", 14, "image filename")
        }
        // A solution heading is more specific than the exercise it answers. An exam form's structural evidence
        // similarly outweighs numbered problems, which are common to both assignments and exams.
        if (scores["solutions"] ?? 0) >= 8 { scores["exercises"] = max(0, (scores["exercises"] ?? 0) - 5) }
        if (scores["exams"] ?? 0) >= 10 { scores["exercises"] = max(0, (scores["exercises"] ?? 0) - 4) }
        if (scores["lectures"] ?? 0) >= 6 { scores["notes"] = max(0, (scores["notes"] ?? 0) - 4) }
        let ranking = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let best = ranking.first
        let margin = (best?.value ?? 0) - (ranking.dropFirst().first?.value ?? 0)
        let confident = (best?.value ?? 0) >= 5 && margin >= 2
        let id = confident ? best!.key : (materialKind == nil || materialKind == .files || kind != nil ? "documents" : "other")
        let info = categories[id]!
        let confidence = !confident ? "low" : best!.value >= 10 && margin >= 4 ? "high" : "medium"
        let evidence = (sources[id] ?? []).sorted().joined(separator: ", ")
        let ocrCount = sampled.filter { $0.extractionMethod == "ocr" || $0.extractionMethod == "mixed" }.count
        let hasText = sampled.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let textCount = sampled.filter { $0.extractionMethod != "ocr" && !$0.text.isEmpty }.count
        let method = !hasText ? "none" : ocrCount == 0 ? "text" : textCount == 0 ? "ocr" : "mixed"
        let basis = confident ? "Based on \(evidence)\(ocrCount > 0 ? "; includes on-device OCR" : "")"
            : hasText ? "Content is ambiguous; kept in Documents" : "Content not indexed; based on available metadata"
        return StudyMaterialClassification(version: version, categoryID: id, categoryTitle: info.title,
            categoryOrder: info.order, confidence: confidence, basis: basis,
            topic: topic(in: headings, title: title), extractionMethod: method,
            sampledPages: sampled.map(\.number))
    }
    private static func topic(in pages: [[String]], title: String) -> String? {
        for lines in pages {
            for raw in lines.prefix(4) {
                var line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "# *\t"))
                guard line.count >= 5, line.count <= 100, !line.contains("http"), !line.contains("@"),
                      !line.contains("|"), !line.contains("="), !line.contains(". "), !line.hasSuffix("."),
                      line.range(of: #"^\d+[ /.-]\d+[ /.-]\d+|^(?:page|side|copyright|©|author|by|professor|department|university)\b"#, options: [.regularExpression, .caseInsensitive]) == nil,
                      line.split(separator: " ").count >= 2 else { continue }
                let substantive = line
                    .replacingOccurrences(of: #"\b[a-zæøå]{2,10}[- ]?\d{3,6}(?:[- ]\d{2}[hvs])?\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .replacingOccurrences(of: #"\b(?:lecture notes|course notes|study notes|lecture|lectures|notes|slides|forelesning|forelesningsnotater|notater|course information|exercises?|assignments?)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: CharacterSet.letters.inverted)
                guard !substantive.isEmpty else { continue }
                line = line.replacingOccurrences(of: #"^(?:lecture|forelesning|chapter|kapittel|exercise|assignment|øving|oving|notes|notater)\s*\d*\s*[:–—-]\s*"#,
                    with: "", options: [.regularExpression, .caseInsensitive])
                guard line.count >= 5, line.caseInsensitiveCompare(title) != .orderedSame,
                      line.range(of: #"^(?:lecture|exercise|assignment|problem|oppgave|chapter|page|forelesning|øving|oving)\s*\d*\s*$|^(?:lecture notes|study notes|answer key|course information|learning outcomes|learning objectives|table of contents)$"#,
                         options: [.regularExpression, .caseInsensitive]) == nil else { continue }
                return line
            }
        }
        return nil
    }
}
