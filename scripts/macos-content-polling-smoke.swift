import Foundation
@testable import ScholiaMac

extension CanvasDownloadSmoke {
    struct PollingFixture: Decodable {
        var start: String
        var days: Int
        var weekdays: [Int]
        var predict: String
    }

    static func trainedContentPolling(_ name: String = "daily", step: Double = 300) throws -> (ContentPollingModel, Date) {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/fixtures/content-polling.json")
        let fixtures = try JSONDecoder().decode([String: PollingFixture].self, from: Data(contentsOf: url))
        let fixture = fixtures[name]!, formatter = ISO8601DateFormatter()
        let start = formatter.date(from: fixture.start)!
        var model = ContentPollingModel(timeZone: "UTC"), revision = 0
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for day in 0..<fixture.days {
            let date = start.addingTimeInterval(Double(day) * 86400)
            for offset in stride(from: 8.0 * 3600, through: 18.0 * 3600, by: step) {
                if offset == 12.5 * 3600 && fixture.weekdays.contains(calendar.component(.weekday, from: date) - 1) { revision += 1 }
                model.observe(at: date.addingTimeInterval(offset), signature: String(revision), complete: true, interval: 300)
            }
        }
        let time = formatter.date(from: fixture.predict)!
        model.observe(at: time, signature: String(revision), complete: true, interval: 300)
        model.attempt(at: time, reason: .regular)
        return (model, time)
    }

    static func checkContentPolling() throws {
        for name in ["daily", "weekly"] {
            var (model, date) = try trainedContentPolling(name)
            let time = date.timeIntervalSince1970
            precondition(model.rate(at: time) >= 0.5)
            func reason(_ offset: Double, _ lastRegular: Date? = nil, extras: [Double] = []) -> ContentPollingModel.Reason? {
                model.decision(at: date.addingTimeInterval(offset), interval: 300, lastRegular: lastRegular ?? date, workspaceExtras: extras)
            }
            precondition(reason(149) == nil && reason(150) == .predicted)
            precondition(reason(150, extras: Array(repeating: time - 3600, count: 8)) == nil)
            precondition(reason(300, extras: Array(repeating: time - 3600, count: 8)) == .regular)
            model.attempt(at: date.addingTimeInterval(150), reason: .predicted)
            precondition(reason(151) == nil && reason(300) == .regular)
            model = try JSONDecoder().decode(ContentPollingModel.self, from: JSONEncoder().encode(model))
            precondition(reason(450, date.addingTimeInterval(300)) == nil, "Restart cannot reset the cooldown")
            precondition(model.extraChecks == [time + 150])
            model.extraChecks = [time - 7200, time - 3600]
            precondition(reason(150) == nil)
            model.observe(at: date.addingTimeInterval(300), signature: "failed", complete: false, interval: 300)
            precondition(reason(450) == nil && reason(600) == .regular)
            model.observe(at: date.addingTimeInterval(600), signature: "failed again", complete: false, interval: 300)
            precondition(reason(900) == nil && reason(1200) == .regular)
            model.observe(at: date.addingTimeInterval(1200), signature: "restored", complete: true, interval: 300)
            precondition(model.failures == 0 && model.retryAfter == nil)
        }
        let (slow, time) = try trainedContentPolling(), (fast, _) = try trainedContentPolling(step: 60)
        precondition(abs(slow.rate(at: time.timeIntervalSince1970) - fast.rate(at: time.timeIntervalSince1970)) < 0.001)
        var cold = ContentPollingModel()
        cold.observe(at: time, signature: "first import", complete: true, interval: 120)
        cold.observe(at: time.addingTimeInterval(86400), signature: "offline backlog", complete: true, interval: 120)
        precondition(cold.bins.isEmpty && cold.rate(at: time.timeIntervalSince1970) == 0)
        var ref = CanvasMaterialReference(id: "math-wiki:notes", kind: .files, remoteID: "notes", title: "Notes",
            sourceURL: "https://wiki.math.ntnu.no/notes", version: "unvalidated:1", byteCount: 123)
        let signature = ContentPollingModel.signature([ref], source: .mathWiki)
        ref.version = "unvalidated:2"
        precondition(signature == ContentPollingModel.signature([ref], source: .mathWiki))
        ref.byteCount = 124
        precondition(signature != ContentPollingModel.signature([ref], source: .mathWiki))
        print("PASS: native daily/weekly statistical learning, interval exposure, cold start/offline gaps, persisted shared budgets, regular cadence and failure backoff")
    }
}
