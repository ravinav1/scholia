import CryptoKit
import Foundation

/// Chooses reading evidence from the already loaded full document index. The
/// saved pages are never reopened; token statistics are reused between questions.
enum StudyReadingRetrieval {
    struct Plan: Sendable {
        var priority: [Int]
        var requested: [Int]
        var matched: [Int]
        var broad: Bool
        var local: Bool
        var noMatch: Bool
        var inheritedQuestion: Bool
        var indexedPages: Int
        var budget: Int
        var matchingTerms: [String]
        var unresolvedPageReference: Bool
    }
    struct Statistics: Sendable { var builds: Int; var hits: Int }
    struct Intent: Sendable {
        var question: String
        var terms: Set<String>
        var broad: Bool
        var local: Bool
        var inherited: Bool
    }
    private static let cache = PageCache()
    static var statistics: Statistics { cache.statistics }
    private static let stopWords = Set((
        "a an the and or to of in is are was were be being for with from this that these those it its as at by on " +
        "what which why how does do did can could would should will please explain tell give summarize summarise summary overview entire whole complete me about my your i we you " +
        "they them us our has have had meaning mean understand show find locate search where anywhere elsewhere use uses used using value values know known knowledge " +
        "also again more detail details page pages current previous next here there reading text passage selected " +
        "selection equation equations formula formulas figure figures chapter chapters section sections document " +
        "book compendium doc docs pdf according said says question answer step steps work works really exactly compare between " +
        "theorem theorems lemma lemmas proof proofs prove proved proving result results derivation derive derives derived " +
        "discuss discusses discussed discussing definition definitions example examples proposition propositions " +
        "det den de der dette denne disse en et og eller til av er var for med fra hva hvilken hvilke hvorfor " +
        "hvordan kan skal vil forklare forklar meg min mitt om siden side sider her der hele dokument dokumentet " +
        "lesing teksten tekst avsnitt ligning likning formel figur finn vis mer betyr sammenlign oppsummer oversikt"
    ).split(separator: " ").map(String.init))
    private static let broadPattern = #"(?i)\b(?:overview|summari[sz]e|summary|entire|whole|complete (?:document|book|compendium|reading)|all (?:pages|chapters|sections)|oppsummer\w*|oversikt|hele (?:dokument\w*|boka?|kompendi\w*)|alle (?:sid\w*|kapitl\w*))\b"#
    private static let localPattern = #"(?i)\b(?:this|current|selected)\s+(?:page|passage|paragraph|equation|formula|figure|selection)|\b(?:on this page|right here|denne siden|denne sida|dette avsnittet|denne (?:ligningen|likningen|formelen|figuren))\b"#
    private static let pagePattern = #"(?i)\b(?:pages?|p\.?|side|sider)\s*\d+(?:\s*[-–]\s*\d+)?(?:\s*(?:,|and\b|og\b|&)\s*\d+(?:\s*[-–]\s*\d+)?)*"#
    private static let mappingPattern = #"(?i)\b(?:(?:which|what)\s+(?:parts|chapters|sections)|hvilke\s+(?:deler|kapitler|avsnitt))\b[^?.!\n]{0,160}\b(?:relevan\w*|relat\w*|appl\w*|connect\w*|bruk\w*|knytt\w*|forbind\w*|sammenheng\w*)\b"#

    /// Mapping a reading's chapters to a project needs coverage beyond pages
    /// that happen to repeat the project's product name or block identifiers.
    static func isCrossSourceMapping(_ question: String) -> Bool {
        guard question.range(of: mappingPattern, options: .regularExpression) != nil else { return false }
        if question.range(of: localPattern, options: .regularExpression) != nil {
            return question.range(of: #"(?i)\b(?:compendium|document|book|textbook|reading|pdf|kompendi\w*|dokument\w*|boken|boka|lærebok\w*|pensum)\b"#,
                options: .regularExpression) != nil
        }
        return true
    }

    static func isBroad(_ question: String) -> Bool {
        if isCrossSourceMapping(question) { return true }
        guard question.range(of: broadPattern, options: .regularExpression) != nil else { return false }
        if question.range(of: localPattern, options: .regularExpression) != nil,
           question.range(of: #"(?i)\b(?:whole|entire|all (?:pages|chapters)|hele (?:dokument\w*|kompendi\w*))\b"#, options: .regularExpression) == nil { return false }
        return true
    }

    static func plan(index: StudyDocumentIndex, current: Int, pageCount: Int, question: String,
                     selection: String, previousQuestions: [String], budget: Int) -> Plan {
        let pages = index.pages.sorted { $0.number < $1.number }
        let available = Set(pages.map(\.number))
        let request = intent(question: question, selection: selection, previousQuestions: previousQuestions, pageCount: pageCount)
        let broad = request.broad, local = request.local, inherited = request.inherited
        let requested = StudyContextBuilder.explicitPages(in: request.question, count: pageCount)
        let query = request.terms
        let purelyLocal = local && !inherited && queryTerms(question).isEmpty && requested.isEmpty
        let search = query.isEmpty || purelyLocal ? nil : cache.index(pages)
        let ranked = search.map { rank($0, terms: query) } ?? []
        let matchingTerms = query.sorted {
            let left = search?.documentFrequencies[$0] ?? 0, right = search?.documentFrequencies[$1] ?? 0
            return left == right ? $0.count > $1.count : left < right
        }
        let matched = ranked.prefix(6).map(\.number)
        var priority: [Int]
        let effectiveBudget: Int
        if broad {
            effectiveBudget = max(0, min(budget, StudyContextBuilder.documentBudget))
            // Distribute overview coverage over the entire document, rather
            // than exhausting the budget on its opening chapters.
            let limit = max(1, effectiveBudget / 500)
            let distributed: [Int]
            if pages.count <= limit { distributed = pages.map(\.number) }
            else {
                distributed = (0..<limit).map { position in
                    pages[position * max(0, pages.count - 1) / max(1, limit - 1)].number
                }
            }
            priority = [current] + requested + matched + [pages.first?.number, pages.last?.number].compactMap { $0 } + distributed
        } else if requested.isEmpty && (query.isEmpty || purelyLocal) {
            effectiveBudget = max(0, min(budget, 16_000))
            priority = [current, current - 1, current + 1]
        } else {
            effectiveBudget = max(0, min(budget, 40_000))
            priority = [current] + requested + matched
            if matched.isEmpty && requested.isEmpty { priority += [current - 1, current + 1] }
            else if let best = matched.first { priority += [best - 1, best + 1] }
        }
        var seen = Set<Int>()
        priority = priority.filter { available.contains($0) && seen.insert($0).inserted }
        return Plan(priority: priority, requested: requested, matched: matched, broad: broad,
            local: !broad && requested.isEmpty && (query.isEmpty || purelyLocal), noMatch: !purelyLocal && !query.isEmpty && ranked.isEmpty,
            inheritedQuestion: inherited, indexedPages: pages.count, budget: effectiveBudget,
            matchingTerms: matchingTerms,
            unresolvedPageReference: request.question.range(of: pagePattern, options: .regularExpression) != nil && requested.isEmpty)
    }

    static func intent(question: String, selection: String, previousQuestions: [String], pageCount: Int) -> Intent {
        let broad = isBroad(question)
        let explicitLocal = question.range(of: localPattern, options: .regularExpression) != nil
        var effective = question
        var inherited = false
        if !broad, !explicitLocal, selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           queryTerms(question).isEmpty, question.range(of: pagePattern, options: .regularExpression) == nil,
           let previous = previousQuestions.reversed().first(where: {
               !queryTerms($0).isEmpty || !StudyContextBuilder.explicitPages(in: $0, count: pageCount).isEmpty
           }) {
            effective = previous
            inherited = true
        }
        let local = !broad && (explicitLocal || (!inherited && queryTerms(question).isEmpty
            && StudyContextBuilder.explicitPages(in: question, count: pageCount).isEmpty))
        return Intent(question: effective, terms: queryTerms(effective + " " + selection), broad: broad,
            local: local, inherited: inherited)
    }

    static func meaningfulTerms(_ text: String) -> Set<String> { queryTerms(text) }

    static func excerpt(_ text: String, matching terms: [String], allowance: Int) -> (text: String, shortened: Bool) {
        let source = text as NSString
        guard source.length > allowance else { return (text, false) }
        var target: NSRange?
        for term in terms.prefix(32) {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            if let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_])" + escaped + "(?![\\p{L}\\p{N}_])", options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) {
                target = match.range
                break
            }
        }
        let start = min(max(0, (target?.location ?? 0) - allowance / 3), max(0, source.length - allowance))
        let range = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(allowance, source.length - start)))
        let piece = TextInputPolicy.bounded(source.substring(with: range), maximumUTF16Units: allowance)
        return ("[Excerpt from page text characters \(range.location + 1)–\(range.location + piece.utf16.count) of \(source.length).]\n" + piece, true)
    }

    private static func queryTerms(_ text: String) -> Set<String> {
        let clean = text.replacingOccurrences(of: pagePattern, with: " ", options: .regularExpression)
        return Set(tokens(clean).filter { !stopWords.contains($0) })
    }
    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .filter { !$0.isEmpty }.map(String.init)
    }
    private struct PageTerms: Sendable {
        var number: Int
        var frequencies: [String: Int]
        var length: Int
    }
    private struct Index: Sendable {
        var pages: [PageTerms]
        var documentFrequencies: [String: Int]
        var averageLength: Double
    }
    private struct Match { var number: Int; var score: Double }
    private static func rank(_ index: Index, terms: Set<String>) -> [Match] {
        guard !terms.isEmpty else { return [] }
        return index.pages.compactMap { page in
            let matches = terms.intersection(page.frequencies.keys)
            guard !matches.isEmpty else { return nil }
            let score = matches.reduce(0.0) { total, term in
                let frequency = Double(page.frequencies[term] ?? 0)
                let documentFrequency = Double(index.documentFrequencies[term] ?? 0)
                let idf = log(1 + (Double(index.pages.count) - documentFrequency + 0.5) / (documentFrequency + 0.5))
                return total + idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * Double(page.length) / max(1, index.averageLength)))
            } * (1 + Double(matches.count) / Double(terms.count))
            return Match(number: page.number, score: score)
        }.sorted { $0.score == $1.score ? $0.number < $1.number : $0.score > $1.score }
    }

    private final class PageCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (Index, Int)] = [:]
        private var order: [String] = []
        private var units = 0
        private var builds = 0
        private var hits = 0
        var statistics: Statistics { lock.withLock { Statistics(builds: builds, hits: hits) } }
        func index(_ pages: [StudyPage]) -> Index {
            var digest = SHA256()
            var cost = 0
            for page in pages {
                let data = Data(page.text.utf8)
                digest.update(data: Data("\(page.number):\(data.count):".utf8))
                digest.update(data: data)
                cost += data.count
            }
            let key = digest.finalize().map { String(format: "%02x", $0) }.joined()
            if let cached = lock.withLock({ () -> Index? in
                guard let result = entries[key]?.0 else { return nil }
                hits += 1
                return result
            }) { return cached }
            var frequencies: [String: Int] = [:]
            let indexed = pages.map { page in
                let words = tokens(page.text)
                let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
                for term in counts.keys { frequencies[term, default: 0] += 1 }
                return PageTerms(number: page.number, frequencies: counts, length: max(1, words.count))
            }
            let result = Index(pages: indexed, documentFrequencies: frequencies,
                averageLength: Double(indexed.reduce(0) { $0 + $1.length }) / Double(max(1, indexed.count)))
            lock.withLock {
                builds += 1
                guard entries[key] == nil, cost <= 8_000_000 else { return }
                while !order.isEmpty && (order.count >= 8 || units + cost > 16_000_000) {
                    let first = order.removeFirst()
                    if let old = entries.removeValue(forKey: first) { units -= old.1 }
                }
                entries[key] = (result, cost); order.append(key); units += cost
            }
            return result
        }
    }
}
