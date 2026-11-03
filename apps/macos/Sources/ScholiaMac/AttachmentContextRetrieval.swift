import CryptoKit
import Foundation

/// Query-specific excerpts of immutable saved extraction. Original files are
/// never reopened, and persisted attachments are never replaced by excerpts.
enum AttachmentContextRetrieval {
    struct Result: Sendable {
        var messages: [ConversationMessage]
        var summary: String?
        var originalCharacters: Int
        var includedCharacters: Int
        var retrievedFiles: Int
        var elapsedMilliseconds: Double
    }

    static let fullFileThreshold = 24_000
    static let maximumRequestCharacters = 240_000
    private static let cache = ChunkCache()
    private static let broadQuestion = try! NSRegularExpression(pattern:
        #"(?i)\b(entire|whole|complete|overview|summari[sz]e|summary|all (?:files|pages|sources|parts)|full project|relationships?|topology|architecture|explain (?:the |this )?(?:project|model)|how .{0,30}(?:project|model).{0,20}work|forstå .{0,20}(?:prosjekt|modell)|gjennomgå|how .{0,35}(?:connect|relate|fit together)|understand (?:the |this )?(?:project|model)|oppsummer\w*|oversikt|hele|alle fil\w*|sammenheng\w*)\b"#)
    private static let stopWords: Set<String> = Set((
        "a an the and or to of in is are was were be for with from this that these those it its as at by on " +
        "what which why how does do can could would should will please explain tell me about my your file files continue elaborate more further again " +
        "i we you they them us our det den de der dette denne disse en et og eller til av er var for med fra " +
        "hva hvilken hvilke hvorfor hvordan kan skal vil forklare forklar meg min mitt om"
    ).split(separator: " ").map(String.init))

    static func prepare(messages: [ConversationMessage], question: String) -> Result {
        let started = Date()
        let files = messages.flatMap { $0.role == .user ? $0.attachments ?? [] : [] }
            .filter { $0.includedInContext && !$0.isImage }
        let original = files.reduce(0) { $0 + ($1.textCorpusUTF16Count ?? $1.extractedText.utf16.count) }
        let retrievalQuestion = contextualQuestion(question, messages: messages)
        let queryTerms = Set(tokens(retrievalQuestion).filter { !stopWords.contains($0) })
        let broad = question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBroad(question)
        let locationRequest = retrievalQuestion.range(of: #"(?i)\b(?:pages?|side|sider|lines?|linje|linjer)\s+\d+"#, options: .regularExpression) != nil
        let pending = files.filter { $0.requestTextPrepared != true }
        let allowance = min(180_000, maximumRequestCharacters / max(1, pending.count))
        let latest = messages.lastIndex { $0.role == .user && ($0.attachments ?? []).contains {
            $0.includedInContext && !$0.isImage && $0.requestTextPrepared != true
        } }
        var retrieved = 0
        var unavailable = 0
        var output = messages
        // Same UUID means the same attachment; a later explicit version wins.
        // Distinct UUIDs/paths are never merged just because names match.
        var seen = Set<UUID>()
        for index in output.indices.reversed() where output[index].role == .user {
            output[index].attachments = output[index].attachments?.compactMap { attachment in
                guard seen.insert(attachment.id).inserted else { return nil }
                guard attachment.includedInContext, !attachment.isImage, attachment.requestTextPrepared != true else { return attachment }
                if Task.isCancelled { return attachment }
                var full = attachment
                var failure: String?
                do { full.extractedText = try AttachmentTextCorpusStore.text(for: attachment) }
                catch {
                    unavailable += 1
                    failure = "The complete saved extraction could not be opened: \(error.localizedDescription) Only the retained preview is available; it is not complete evidence."
                    full.readStatus = full.extractedText.isEmpty ? .unreadable : .partial
                    full.textCorpusID = nil
                    full.textCorpusUTF16Count = nil
                }
                let units = full.extractedText.utf16.count
                var result = full
                if units > min(fullFileThreshold, allowance), full.effectiveReadStatus != .unreadable {
                    if let targeted = locationExcerpt(full, question: retrievalQuestion, budget: min(24_000, allowance)) {
                        result = targeted
                    } else if !broad, !locationRequest, !queryTerms.isEmpty,
                              let focused = retrieve(full, question: retrievalQuestion, terms: queryTerms, budget: min(14_000, allowance)) {
                        result = focused
                    } else if units > allowance {
                        result = overview(full, budget: allowance, noMatch: !broad && !queryTerms.isEmpty)
                    }
                }
                if result.extractedText != full.extractedText {
                    retrieved += 1
                    // Older inline attachments also remain available to the
                    // attachment-only tool after their prompt copy is narrowed.
                    if result.textCorpusID == nil, failure == nil,
                       let reference = try? AttachmentTextCorpusStore.store(full.extractedText) {
                        result.textCorpusID = reference.id
                        result.textCorpusUTF16Count = reference.utf16Count
                    }
                }
                let scope = index == latest ? "Latest explicit attachment set" : "Earlier conversation attachment; do not substitute it for a newer or differently named source"
                let identity = "\(scope). Attachment UUID: \(attachment.id.uuidString). Originating user-message UUID: \(messages[index].id.uuidString)."
                result.readDetail = [identity, failure, result.readDetail].compactMap { $0 }.joined(separator: " ")
                if failure != nil {
                    result.textCorpusID = attachment.textCorpusID
                    result.textCorpusUTF16Count = attachment.textCorpusUTF16Count
                }
                result.requestTextPrepared = true
                return result
            }
        }
        let included = output.flatMap { $0.attachments ?? [] }
            .filter(\.includedInContext).reduce(0) { $0 + $1.extractedText.utf16.count }
        let summary = retrieved == 0 && unavailable == 0 ? nil
            : "Attachment excerpts · \(retrieved) file\(retrieved == 1 ? "" : "s") · \(included.formatted()) of \(original.formatted()) saved characters"
                + (unavailable == 0 ? "" : " · \(unavailable) full-text source\(unavailable == 1 ? "" : "s") unavailable")
        return Result(messages: output, summary: summary, originalCharacters: original,
            includedCharacters: included, retrievedFiles: retrieved,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1_000)
    }

    private static func isBroad(_ question: String) -> Bool {
        StudyReadingRetrieval.isCrossSourceMapping(question)
            || broadQuestion.firstMatch(in: question, range: NSRange(location: 0, length: (question as NSString).length)) != nil
    }

    private static func contextualQuestion(_ question: String, messages: [ConversationMessage]) -> String {
        let currentTerms = Set(tokens(question).filter { !stopWords.contains($0) })
        let refersBack = question.range(of: #"(?i)\b(that|this|those|it|them|same|den|det|denne|samme)\b"#,
            options: .regularExpression) != nil
        guard currentTerms.isEmpty || (refersBack && currentTerms.count <= 2), !isBroad(question) else { return question }
        var users = messages.filter { $0.role == .user }
        if users.last?.content.trimmingCharacters(in: .whitespacesAndNewlines)
            == question.trimmingCharacters(in: .whitespacesAndNewlines) { users.removeLast() }
        for previous in users.reversed() {
            let text = previous.content
            let terms = Set(tokens(text).filter { !stopWords.contains($0) })
            // Generic whole-project setup is not a useful anchor for an unclear
            // follow-up. Keep full evidence when there is no specific prior question.
            if !terms.isEmpty, !isBroad(text) { return text + "\n" + question }
        }
        return question
    }

    private static func retrieve(_ attachment: MessageAttachment, question: String,
                                 terms: Set<String>, budget: Int) -> MessageAttachment? {
        let index = cache.index(text: attachment.extractedText, corpusID: attachment.textCorpusID, query: terms)
        let source = attachment.extractedText as NSString
        guard index.chunks.count > 3 else { return nil }
        let average = Double(index.chunks.reduce(0) { $0 + $1.length }) / Double(index.chunks.count)
        let exactPhrase = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ranked = index.chunks.enumerated().compactMap { position, chunk -> (Int, Double)? in
            let matches = terms.intersection(chunk.frequencies.keys)
            guard !matches.isEmpty else { return nil }
            var score = 0.0
            for term in matches {
                let frequency = Double(chunk.frequencies[term] ?? 0)
                let documentFrequency = Double(index.documentFrequencies[term] ?? 0)
                let idf = log(1 + (Double(index.chunks.count) - documentFrequency + 0.5) / (documentFrequency + 0.5))
                score += idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(chunk.length) / max(1, average)))
                if chunk.identifiers.contains(term) { score += 2 * idf }
            }
            score *= 1 + Double(matches.count) / Double(terms.count)
            if exactPhrase.count > 5 && source.substring(with: chunk.range).lowercased().contains(exactPhrase) { score += 6 }
            return (position, score)
        }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        // A vocabulary miss is not evidence that the source is irrelevant. Keep
        // its complete extracted text instead of hiding potentially useful facts.
        guard let best = ranked.first, best.1 > 0 else { return nil }
        let bestTerms = terms.intersection(index.chunks[best.0].frequencies.keys)
        let hasDistinctiveTerm = bestTerms.contains { Double(index.documentFrequencies[$0] ?? 0) / Double(index.chunks.count) < 0.45 }
        guard hasDistinctiveTerm || bestTerms.count >= 2 else { return nil }
        var retained = TextInputPolicy.bounded(index.manifest, maximumUTF16Units: max(0, budget / 4))
        if retained != index.manifest { retained += "\n[Manifest excerpt; the complete inventory remains in the saved corpus.]" }
        for dependency in index.smallDependencies where retained.utf16.count + dependency.utf16.count < budget / 3 {
            retained += "\n\n" + dependency
        }
        let bodyBudget = max(0, budget - retained.utf16.count - 1_000)
        guard bodyBudget >= 400 else { return nil }
        var selected = Set<Int>()
        var used = 0
        for (position, _) in ranked {
            let chunk = index.chunks[position]
            if used + chunk.range.length + 180 <= bodyBudget || selected.isEmpty {
                selected.insert(position)
                used += chunk.range.length + 180
            }
        }
        // Saved project containers put their manifest and extraction warnings
        // before EXTRACTED CONTENT. Keep that inventory in every focused request.
        let snippets = selected.sorted().map { position -> String in
            let chunk = index.chunks[position]
            let member = chunk.member.map { " · \($0)" } ?? ""
            let range = NSRange(location: chunk.range.location, length: min(chunk.range.length, bodyBudget))
            return "[\(attachment.fileName)\(member) · extracted characters \(range.location + 1)–\(NSMaxRange(range))]\n\(source.substring(with: range))"
        }
        let notice = "Focused retrieval searched all \(source.length) characters of the saved extracted text. \(selected.count) of \(index.chunks.count) passages are included; other passages are omitted from this request, not deleted from the saved corpus. An omitted passage is not evidence of absence. Use attachment_search or attachment_read with this attachment UUID for needed missing evidence. Original extraction limits still apply."
        let text = notice + (retained.isEmpty ? "" : "\n\n" + retained) + "\n\n" + snippets.joined(separator: "\n\n")
        // Do not pay retrieval overhead or imply savings for a mostly manifest file.
        guard text.utf16.count < attachment.extractedText.utf16.count * 3 / 4 else { return nil }
        var result = attachment
        result.extractedText = TextInputPolicy.bounded(text, maximumUTF16Units: budget)
        result.readStatus = .partial
        result.readDetail = [attachment.readDetail, "Query-specific excerpts are supplied; the saved original extraction remains available. Retrieval uses exact words, identifiers, and cached lexical ranking; no original files were reopened."].compactMap { $0 }.joined(separator: " ")
        return result
    }

    private static func overview(_ attachment: MessageAttachment, budget: Int, noMatch: Bool) -> MessageAttachment {
        let source = attachment.extractedText as NSString
        let count = min(64, max(1, budget / 2_600))
        let notice = "Coverage overview of all \(source.length) saved extracted characters. Distributed excerpts include the beginning, middle, and end; this request does not contain the entire source. The complete extraction remains available through attachment_search and attachment_read using this attachment UUID."
            + (noMatch ? " No confident keyword match was found. This is not evidence that the requested topic is absent; search a distinctive identifier or ask for clarification before drawing a project-specific conclusion." : "")
        let allowance = max(0, (budget - notice.utf16.count - 100) / count - 160)
        var blocks: [String] = []
        for position in 0..<count where allowance > 0 {
            if Task.isCancelled { break }
            let start = position * max(0, source.length - allowance) / max(1, count - 1)
            let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(allowance, source.length - start)))
            let piece = TextInputPolicy.bounded(source.substring(with: range), maximumUTF16Units: allowance)
            blocks.append("[\(attachment.fileName) · extracted characters \(range.location + 1)–\(range.location + piece.utf16.count) of \(source.length)]\n" + piece)
        }
        var result = attachment
        result.extractedText = TextInputPolicy.bounded(notice + "\n\n" + blocks.joined(separator: "\n\n"), maximumUTF16Units: budget)
        result.readStatus = .partial
        result.readDetail = [attachment.readDetail, "Distributed overview excerpts are supplied; omitted source text remains saved and searchable."].compactMap { $0 }.joined(separator: " ")
        return result
    }

    private static func locationExcerpt(_ attachment: MessageAttachment, question: String, budget: Int) -> MessageAttachment? {
        let source = attachment.extractedText as NSString
        guard source.length > budget else { return nil }
        let regex = try! NSRegularExpression(pattern: #"(?i)\b(pages?|side|sider|lines?|linje|linjer)\s+(\d+)(?:\s*[-–]\s*(\d+))?"#)
        let request = question as NSString
        var ranges: [(NSRange, String)] = []
        for match in regex.matches(in: question, range: NSRange(location: 0, length: request.length)) {
            let unit = request.substring(with: match.range(at: 1)).lowercased()
            guard let first = Int(request.substring(with: match.range(at: 2))), first > 0 else { continue }
            let last = match.range(at: 3).location == NSNotFound ? first : max(first, Int(request.substring(with: match.range(at: 3))) ?? first)
            if unit.hasPrefix("line") || unit.hasPrefix("linj") {
                var offset = 0, number = 1, start: Int?
                while offset < source.length, number <= last {
                    if Task.isCancelled { return nil }
                    let range = source.lineRange(for: NSRange(location: offset, length: 0))
                    if number == first { start = range.location }
                    offset = NSMaxRange(range)
                    if let start, number == last || offset == source.length {
                        ranges.append((NSRange(location: start, length: offset - start), "extracted lines \(first)–\(number)"))
                    }
                    number += 1
                }
            } else {
                let markers = try! NSRegularExpression(pattern: #"(?im)^\[Page\s+(\d+)\]\s*$"#)
                let matches = markers.matches(in: attachment.extractedText, range: NSRange(location: 0, length: source.length))
                for (index, marker) in matches.enumerated() {
                    guard let page = Int(source.substring(with: marker.range(at: 1))), page >= first, page <= last else { continue }
                    let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
                    ranges.append((NSRange(location: marker.range.location, length: end - marker.range.location), "PDF page \(page)"))
                }
            }
        }
        let memberPattern = try! NSRegularExpression(pattern: #"(?m)^--- File: (.+?) \[(?:complete|partial|unreadable)\].*---$"#)
        let members = memberPattern.matches(in: attachment.extractedText, range: NSRange(location: 0, length: source.length))
        for (index, member) in members.enumerated() {
            let name = source.substring(with: member.range(at: 1))
            let basename = (name as NSString).lastPathComponent
            guard question.localizedCaseInsensitiveContains(name)
                || (!((basename as NSString).pathExtension).isEmpty && question.localizedCaseInsensitiveContains(basename)) else { continue }
            let end = index + 1 < members.count ? members[index + 1].range.location : source.length
            ranges.append((NSRange(location: member.range.location, length: end - member.range.location), "member \(name)"))
        }
        guard !ranges.isEmpty else { return nil }
        var blocks: [String] = []
        let allowance = max(0, (budget - 600) / ranges.count - 180)
        guard allowance > 0 else { return nil }
        for (range, label) in ranges {
            let piece = TextInputPolicy.bounded(source.substring(with: range), maximumUTF16Units: allowance)
            blocks.append("[\(attachment.fileName) · \(label) · extracted characters \(range.location + 1)–\(range.location + piece.utf16.count)]\n" + piece)
        }
        var result = attachment
        result.extractedText = TextInputPolicy.bounded("Requested locations from the full saved extraction (\(source.length) characters). Only the labeled ranges below are in this request. Continue with attachment_read for omitted portions; source text has not been discarded.\n\n" + blocks.joined(separator: "\n\n"), maximumUTF16Units: budget)
        result.readStatus = .partial
        result.readDetail = [attachment.readDetail, "Exact page, extracted-line, or archive-member locations were selected from the complete saved extraction."].compactMap { $0 }.joined(separator: " ")
        return result
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .filter { !$0.isEmpty }.map(String.init)
    }

    private struct Chunk: Sendable {
        var range: NSRange
        var member: String?
        var frequencies: [String: Int]
        var identifiers: Set<String>
        var length: Int
    }
    private struct Index: Sendable {
        var chunks: [Chunk]
        var documentFrequencies: [String: Int]
        var manifest: String
        var smallDependencies: [String]
    }
    private static func makeIndex(text: String, query: Set<String>) -> Index {
        let source = text as NSString
        let marker = "\n\nEXTRACTED CONTENT\n"
        let boundary = source.range(of: marker)
        let manifest = boundary.location == NSNotFound ? "" : source.substring(to: NSMaxRange(boundary))
        let memberPattern = try! NSRegularExpression(pattern: #"(?m)^--- File: (.+?) \[(?:complete|partial|unreadable)\].*---$"#)
        let memberMatches = memberPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        let members = memberMatches.map { (range: $0.range, name: source.substring(with: $0.range(at: 1))) }
        var smallDependencies: [String] = []
        var dependencyUnits = 0
        for (number, member) in members.enumerated() {
            let end = number + 1 < members.count ? members[number + 1].range.location : source.length
            let range = NSRange(location: member.range.location, length: end - member.range.location)
            let ext = (member.name as NSString).pathExtension.lowercased()
            if ["m", "json", "yaml", "yml", "ini", "cfg", "csv"].contains(ext), range.length <= 4_000,
               dependencyUnits + range.length <= 12_000 {
                smallDependencies.append(source.substring(with: range)); dependencyUnits += range.length
            }
        }
        var chunks: [Chunk] = []
        let queryOnly = source.length > 4_000_000
        var offset = boundary.location == NSNotFound ? 0 : NSMaxRange(boundary)
        while offset < source.length {
            if Task.isCancelled { break }
            let range = source.rangeOfComposedCharacterSequences(for:
                NSRange(location: offset, length: min(2_400, source.length - offset)))
            let value = source.substring(with: range)
            let words = tokens(value)
            let frequencies = Dictionary(words.filter { !queryOnly || query.contains($0) }.map { ($0, 1) }, uniquingKeysWith: +)
            let identifiers = Set(value.split { !$0.isLetter && !$0.isNumber && $0 != "_" }
                .filter { token in token.contains("_") || token.contains(where: \.isUppercase) || token.contains(where: \.isNumber) }
                .map { $0.lowercased() }.filter { !queryOnly || query.contains($0) })
            chunks.append(Chunk(range: range,
                member: members.last { $0.range.location <= range.location }?.name,
                frequencies: frequencies, identifiers: identifiers, length: max(1, words.count)))
            if NSMaxRange(range) >= source.length { break }
            let next = NSMaxRange(range) - 240
            offset = NSMaxRange(source.rangeOfComposedCharacterSequence(at: max(offset, next)))
        }
        var frequencies: [String: Int] = [:]
        for chunk in chunks { for term in chunk.frequencies.keys { frequencies[term, default: 0] += 1 } }
        return Index(chunks: chunks, documentFrequencies: frequencies, manifest: manifest, smallDependencies: smallDependencies)
    }

    private final class ChunkCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (Index, Int)] = [:]
        private var order: [String] = []
        private var units = 0
        func index(text: String, corpusID: String?, query: Set<String>) -> Index {
            let key = (corpusID ?? SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined())
                + (text.utf16.count > 4_000_000 ? ":" + query.sorted().joined(separator: "\u{0}") : "")
            if let cached = lock.withLock({ entries[key]?.0 }) { return cached }
            let index = makeIndex(text: text, query: query)
            let cost = index.chunks.reduce(0) { $0 + 128 + $1.frequencies.count * 96 + $1.identifiers.count * 48 }
            lock.withLock {
                guard entries[key] == nil, cost <= 24_000_000, !Task.isCancelled else { return }
                while !order.isEmpty && (order.count >= 48 || units + cost > 32_000_000) {
                    let oldest = order.removeFirst()
                    if let removed = entries.removeValue(forKey: oldest) { units -= removed.1 }
                }
                entries[key] = (index, cost); order.append(key); units += cost
            }
            return index
        }
    }
}
