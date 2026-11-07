import Foundation

struct VisibleWindowContext: Equatable, Sendable {
    var applicationName: String
    var applicationBundleIdentifier: String?
    var applicationPID: pid_t
    var windowTitle: String?
    var sourceURL: String?
    var accessibleText: String?
    var openTabTitles: [String] = []
    var frontToBackIndex: Int
    var isPreferred: Bool
}

enum VisibleWorkspaceContext {
    static let maximumWindowCount = 3
    static let maximumContextCharacters = 6_000
    static let maximumTextCharactersPerWindow = 1_800
    static let maximumAttachedContextUTF16Units = 8_000
    private static let reservedWorkspaceContextUTF16Units = 3_500

    private static let ignoredQuestionTerms: Set<String> = [
        "about", "after", "again", "also", "and", "are", "can", "could", "does",
        "for", "from", "have", "how", "into", "just", "make", "more", "not", "please",
        "should", "that", "the", "their", "then", "there", "these", "they", "this", "those",
        "use", "what", "when", "where", "which", "who", "why", "will", "with", "would", "you",
        "your"
    ]

    nonisolated static func questionTerms(_ value: String) -> Set<String> {
        let words = value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count >= 2 && !ignoredQuestionTerms.contains($0) })
    }

    nonisolated static func relevanceScore(
        _ window: VisibleWindowContext,
        questionTerms: Set<String>
    ) -> Int {
        let titleTerms = self.questionTerms(window.windowTitle ?? "")
        let applicationTerms = self.questionTerms(window.applicationName)
        let textTerms = self.questionTerms(String((window.accessibleText ?? "").prefix(6_000)))
        let tabTerms = self.questionTerms(window.openTabTitles.joined(separator: " "))
        var score = window.isPreferred ? 120 : 0
        score += max(0, 10 - min(window.frontToBackIndex, 10))
        for term in questionTerms {
            if titleTerms.contains(term) { score += 24 }
            if applicationTerms.contains(term) { score += 16 }
            if textTerms.contains(term) { score += 5 }
            if tabTerms.contains(term) { score += 18 }
        }
        return score
    }

    nonisolated static func isChatGptDesktopWindow(_ window: VisibleWindowContext) -> Bool {
        let applicationName = window.applicationName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bundleIdentifier = (window.applicationBundleIdentifier ?? "").lowercased()
        return applicationName == "chatgpt"
            || bundleIdentifier == "com.openai.codex"
            || bundleIdentifier == "com.openai.chat"
            || bundleIdentifier.hasPrefix("com.openai.chat.")
    }

    nonisolated static func selectedWindows(
        from candidates: [VisibleWindowContext],
        question: String,
        includeChatGptDesktopContext: Bool = false
    ) -> [VisibleWindowContext] {
        guard !candidates.isEmpty else { return [] }
        let terms = questionTerms(question)
        let lowerQuestion = question.lowercased()
        let asksAboutWorkspace = [
            "this screen", "my screen", "on screen", "this window", "open window",
            "visible window", "what am i looking", "what is open", "compare", "across"
        ].contains { lowerQuestion.contains($0) }

        let ranked = candidates.sorted { left, right in
            let leftScore = relevanceScore(left, questionTerms: terms)
            let rightScore = relevanceScore(right, questionTerms: terms)
            if leftScore != rightScore { return leftScore > rightScore }
            return left.frontToBackIndex < right.frontToBackIndex
        }
        var selected: [VisibleWindowContext] = []
        var seen = Set<String>()
        func append(_ candidate: VisibleWindowContext) {
            let key = "\(candidate.applicationPID):\(candidate.windowTitle ?? "")"
            guard selected.count < maximumWindowCount, seen.insert(key).inserted else { return }
            selected.append(candidate)
        }

        // The application that was active before Scholia opened is the user's
        // strongest implicit reference, even for short or conversational asks.
        ranked.filter(\.isPreferred).forEach(append)

        // The first native Quick Chat turn explicitly carries over the visible
        // ChatGPT desktop conversation when it is available through Accessibility.
        if includeChatGptDesktopContext,
           let chatGptWindow = ranked.first(where: isChatGptDesktopWindow) {
            append(chatGptWindow)
        }

        if !terms.isEmpty {
            for candidate in ranked where !candidate.isPreferred {
                let metadata = questionTerms(
                    "\(candidate.applicationName) \(candidate.windowTitle ?? "")"
                )
                let body = questionTerms(String((candidate.accessibleText ?? "").prefix(6_000)))
                guard !terms.isDisjoint(with: metadata) || !terms.isDisjoint(with: body) else {
                    continue
                }
                append(candidate)
            }
        }

        let liberalMinimum = asksAboutWorkspace ? min(3, candidates.count) : min(2, candidates.count)
        if selected.count < liberalMinimum {
            for candidate in candidates.sorted(by: { $0.frontToBackIndex < $1.frontToBackIndex }) {
                append(candidate)
                if selected.count >= liberalMinimum { break }
            }
        }
        return selected
    }

    nonisolated static func formatted(
        candidates: [VisibleWindowContext],
        question: String,
        includeChatGptDesktopContext: Bool = false
    ) -> String? {
        let windows = selectedWindows(
            from: candidates,
            question: question,
            includeChatGptDesktopContext: includeChatGptDesktopContext
        )
        guard !windows.isEmpty else { return nil }
        var blocks = [
            "Relevant visible workspace captured on demand when the question was sent. "
                + "Use only windows that help answer the question; ignore unrelated content."
        ]
        var used = blocks[0].count
        for (index, window) in windows.enumerated() {
            var lines = ["Window \(index + 1)\(window.isPreferred ? " (active before Scholia)" : ""):"]
            lines.append("Application: \(window.applicationName)")
            if let title = clean(window.windowTitle) { lines.append("Title: \(title)") }
            if let url = clean(window.sourceURL) { lines.append("Location: \(url)") }
            let relatedTabs = correlatedTabTitles(
                window.openTabTitles,
                question: question,
                visibleText: window.accessibleText
            )
            if !relatedTabs.isEmpty {
                lines.append("Open browser tabs correlated with this screen:")
                lines.append(contentsOf: relatedTabs.map { "- \($0)" })
            }
            if let text = clean(window.accessibleText) {
                lines.append("Accessible visible text:")
                lines.append(String(text.prefix(maximumTextCharactersPerWindow)))
            }
            var block = lines.joined(separator: "\n")
            let remaining = maximumContextCharacters - used - 2
            guard remaining > 80 else { break }
            if block.count > remaining {
                block = String(block.prefix(max(1, remaining - 1))) + "…"
            }
            blocks.append(block)
            used += block.count + 2
        }
        return blocks.joined(separator: "\n\n")
    }

    nonisolated static func attaching(
        _ workspaceContext: String?,
        to capture: CapturedContent?
    ) -> CapturedContent? {
        guard let workspaceContext = clean(workspaceContext) else { return capture }
        var enriched = capture ?? CapturedContent(
            kind: .text,
            applicationName: "Visible workspace",
            windowTitle: "Relevant on-screen windows"
        )
        let existing = clean(enriched.context)
        guard let existing else {
            enriched.context = TextInputPolicy.bounded(
                workspaceContext,
                maximumUTF16Units: maximumAttachedContextUTF16Units
            )
            return enriched
        }
        let separator = "\n\n"
        let workspaceReserve = min(
            reservedWorkspaceContextUTF16Units,
            workspaceContext.utf16.count
        )
        let existingBudget = max(
            1,
            maximumAttachedContextUTF16Units - workspaceReserve - separator.utf16.count
        )
        let boundedExisting = TextInputPolicy.bounded(
            existing,
            maximumUTF16Units: existingBudget
        )
        let workspaceBudget = max(
            1,
            maximumAttachedContextUTF16Units
                - boundedExisting.utf16.count
                - separator.utf16.count
        )
        let boundedWorkspace = TextInputPolicy.bounded(
            workspaceContext,
            maximumUTF16Units: workspaceBudget
        )
        enriched.context = boundedExisting + separator + boundedWorkspace
        return enriched
    }

    nonisolated static func requestCapture(
        _ capture: CapturedContent?,
        workspaceContext: String?,
        automaticContextEnabled: Bool,
        compactContextEnabled: Bool = true,
        fullApplicationContext: ApplicationContextSnapshot? = nil
    ) -> CapturedContent? {
        guard automaticContextEnabled else {
            guard var directCapture = capture else { return nil }
            directCapture.context = nil
            directCapture.applicationName = nil
            directCapture.applicationBundleIdentifier = nil
            directCapture.applicationPID = nil
            directCapture.windowTitle = nil
            directCapture.sourceURL = nil
            return directCapture
        }
        if !compactContextEnabled {
            var fullCapture = capture ?? CapturedContent(kind: .text)
            if fullCapture.applicationName == nil {
                fullCapture.applicationName = fullApplicationContext?.applicationName
            }
            if fullCapture.applicationBundleIdentifier == nil {
                fullCapture.applicationBundleIdentifier = fullApplicationContext?.applicationBundleIdentifier
            }
            if fullCapture.applicationPID == nil {
                fullCapture.applicationPID = fullApplicationContext?.applicationPID
            }
            if fullCapture.windowTitle == nil {
                fullCapture.windowTitle = fullApplicationContext?.windowTitle
            }
            if fullCapture.sourceURL == nil {
                fullCapture.sourceURL = fullApplicationContext?.sourceURL
            }
            if clean(fullCapture.context) == nil {
                fullCapture.context = fullApplicationContext?.context
            }
            let hasContent = clean(fullCapture.text) != nil
                || fullCapture.imageData != nil
                || clean(fullCapture.context) != nil
                || clean(fullCapture.parentContext) != nil
                || clean(fullCapture.sourceTitle) != nil
            return hasContent ? fullCapture : nil
        }
        var compactCapture = capture
        if let existingContext = clean(compactCapture?.context) {
            compactCapture?.context = TextInputPolicy.bounded(
                existingContext,
                maximumUTF16Units: maximumAttachedContextUTF16Units
            )
        }
        return attaching(workspaceContext, to: compactCapture)
    }

    private nonisolated static func correlatedTabTitles(
        _ titles: [String],
        question: String,
        visibleText: String?
    ) -> [String] {
        let queryTerms = questionTerms(
            "\(question) \(String((visibleText ?? "").prefix(1_500)))"
        )
        return titles
            .map { title in
                let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let overlap = questionTerms(cleanTitle).intersection(queryTerms).count
                return (title: cleanTitle, score: overlap)
            }
            .filter { !$0.title.isEmpty }
            .sorted { left, right in
                if left.score != right.score { return left.score > right.score }
                return left.title.localizedStandardCompare(right.title) == .orderedAscending
            }
            .prefix(8)
            .map(\.title)
    }

    private nonisolated static func clean(_ value: String?) -> String? {
        let clean = String(value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
