import CryptoKit
import Foundation

enum ContentPollSource: Sendable { case canvas, mathWiki
    var interval: TimeInterval { self == .canvas ? CanvasCourseFileSync.checkInterval : MathWikiClient.checkInterval }
}

// Keep the statistical policy in sync with packages/core/src/content-polling.js.
// Unix seconds are intentional: the model has the same portable representation
// in the native and hosted libraries. No course text or credentials are stored.
struct ContentPollingModel: Codable, Sendable {
    struct Bin: Codable, Sendable {
        var hours = 0.0
        var events = 0.0
        var days: [Double] = []
    }
    enum Reason: Sendable { case regular, predicted }
    var version = 1
    var timeZone = "Europe/Oslo"
    var bins: [String: Bin] = [:]
    var failures = 0
    var extraChecks: [Double] = []
    var attemptedAt: Double?
    var observedAt: Double?
    var updatedAt: Double?
    var retryAfter: Double?
    var signature: String?
    private static let hour = 3600.0, day = 86400.0

    func recentExtras(at time: Double) -> [Double] { extraChecks.filter { $0 > time - Self.day } }

    mutating func attempt(at date: Date, reason: Reason) {
        let time = date.timeIntervalSince1970
        attemptedAt = time
        extraChecks = recentExtras(at: time)
        if reason == .predicted { extraChecks.append(time) }
    }

    private func slot(at time: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? TimeZone(identifier: "Europe/Oslo")!
        let parts = calendar.dateComponents([.weekday, .hour], from: Date(timeIntervalSince1970: time))
        return ((parts.weekday ?? 1) - 1) * 24 + (parts.hour ?? 0)
    }

    mutating func observe(at date: Date, signature next: String, complete: Bool, interval: TimeInterval) {
        let time = date.timeIntervalSince1970
        guard complete else {
            failures = min(10, failures + 1)
            retryAfter = time + min(Self.hour, interval * pow(2, Double(failures - 1)))
            observedAt = nil; signature = nil
            return
        }
        let elapsed = time - (observedAt ?? time)
        let decay = pow(2, -max(0, time - (updatedAt ?? time)) / (28 * Self.day))
        for key in Array(bins.keys) {
            bins[key]!.hours *= decay; bins[key]!.events *= decay
            bins[key]!.days.removeAll { $0 <= time - 84 * Self.day }
        }
        // Only intervals bracketed by two complete, recent observations teach
        // the model. First imports and offline catch-up don't date a publication.
        if let signature, elapsed > 0, elapsed <= 30 * 60, let observedAt {
            let changed = signature != next
            var start = observedAt
            while start < time {
                let end = min(time, (floor(start / 60) + 1) * 60), middle = (start + end) / 2
                let key = String(slot(at: middle))
                var bin = bins[key] ?? Bin()
                bin.hours += (end - start) / Self.hour
                if changed {
                    bin.events += (end - start) / elapsed
                    let day = floor(middle / Self.day) * Self.day
                    if !bin.days.contains(day) { bin.days.append(day) }
                    bin.days = Array(bin.days.suffix(8))
                }
                bins[key] = bin
                start = end
            }
        }
        updatedAt = time; observedAt = time; signature = next
        failures = 0; retryAfter = nil
    }

    func rate(at time: Double) -> Double {
        guard signature != nil, let observedAt, time >= observedAt, time - observedAt <= 30 * 60 else { return 0 }
        let current = slot(at: time)
        let decay = pow(2, -max(0, time - (updatedAt ?? time)) / (28 * Self.day))
        func aggregate(_ includes: (Int) -> Bool) -> (hours: Double, days: Int, rate: Double) {
            var hours = 0.0, events = 0.0, days = Set<Double>()
            for (key, bin) in bins where includes(Int(key) ?? -1) {
                hours += bin.hours * decay; events += bin.events * decay
                days.formUnion(bin.days.filter { $0 > time - 84 * Self.day })
            }
            return (hours, days.count, (events + 0.1) / (hours + 2))
        }
        let baseline = aggregate { _ in true }
        guard baseline.hours >= 8 else { return 0 }
        return [aggregate { $0 % 24 == current % 24 }, aggregate { $0 == current }]
            .filter { $0.days >= 3 && $0.hours >= 1 && $0.rate >= 0.5 && $0.rate >= baseline.rate * 3 }
            .map(\.rate).max() ?? 0
    }

    func decision(at date: Date, interval: TimeInterval, lastRegular: Date?, workspaceExtras: [Double]) -> Reason? {
        let time = date.timeIntervalSince1970
        guard time >= (retryAfter ?? 0), time - (attemptedAt ?? -.infinity) >= interval / 2 else { return nil }
        guard let lastRegular, date.timeIntervalSince(lastRegular) < interval else { return .regular }
        let extras = recentExtras(at: time)
        guard extras.count < 2, workspaceExtras.filter({ $0 > time - Self.day }).count < 8,
            !extras.contains(where: { time - $0 < Self.hour }),
            lastRegular.timeIntervalSince1970 + interval - time >= 30 else { return nil }
        return rate(at: time) > 0 ? .predicted : nil
    }

    static func signature(_ items: [CanvasMaterialReference], source: ContentPollSource) -> String {
        let rows = items.filter { source == .mathWiki ? $0.isMathWiki : !$0.isMathWiki && !$0.isCourseWebsite }
            .sorted { $0.id < $1.id }.map { ref -> [String] in
                [ref.id, ref.title, ref.fileName ?? "", ref.version.hasPrefix("unvalidated:") ? "" : ref.version,
                    ref.byteCount.map(String.init) ?? ""]
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(rows)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension StudyCourse {
    subscript(polling source: ContentPollSource) -> ContentPollingModel {
        get {
            (source == .canvas ? canvasPolling : mathWikiPolling) ?? ContentPollingModel(
                timeZone: canvasOrigin?.contains("ntnu.no") == true ? "Europe/Oslo" : TimeZone.current.identifier)
        }
        set {
            if source == .canvas { canvasPolling = newValue } else { mathWikiPolling = newValue }
        }
    }
    mutating func observeContent(_ catalog: CanvasMaterialCatalog, at date: Date, includingWiki: Bool = true) {
        self[polling: .canvas].observe(at: date, signature: ContentPollingModel.signature(catalog.items, source: .canvas),
            complete: catalog.completeKinds.isSuperset(of: [.files, .pages, .assignments, .syllabus])
                && catalog.moduleOrderComplete && catalog.linkedContentComplete,
            interval: ContentPollSource.canvas.interval)
        if includingWiki, MathWikiScope.course(self)?.terms.isEmpty == false {
            self[polling: .mathWiki].attempt(at: date, reason: .regular)
            mathWikiUpdateAttemptedAt = date
            self[polling: .mathWiki].observe(at: date, signature: ContentPollingModel.signature(catalog.items, source: .mathWiki),
                complete: catalog.mathWikiComplete, interval: ContentPollSource.mathWiki.interval)
        }
    }
}
