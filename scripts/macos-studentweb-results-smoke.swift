@preconcurrency import AppKit
import Foundation
import SwiftUI
import WebKit
@testable import ScholiaMac

actor ResultsMemoryVault {
    var data: Data?
    var failWrites = false
    func read() -> Data? { data }
    func write(_ value: Data?) throws {
        if failWrites { throw StudyError.message("Synthetic failure") }
        data = value
    }
    func setFailure(_ value: Bool) { failWrites = value }
    func corrupt() { data = Data(#"[{"courseCode":"TEST1000","passed":true,"grade":"PRIVATE"}]"#.utf8) }
}

@main
@MainActor
struct StudentwebResultsSmoke {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                print("PASS: Studentweb routing/session cleanup, minimal Keychain storage, passed-course advice and follow-ups, degree-plan lookup, provider serialization, web isolation, native filtering and light/dark rendering")
                exit(0)
            } catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        let rows = try StudentwebResults.parse(#"[{"courseCode":"TDT4100","passed":true},{"courseCode":"TMA4100","passed":false},{"courseCode":"PRIVATE1000","passed":true}]"#)
        precondition(rows.count == 3)
        precondition(StudentwebResults.resultsPage(StudentwebResults.resultsURL))
        for url in ["https://fsweb.no.evil.test/studentweb/resultater.jsf", "http://fsweb.no/studentweb/resultater.jsf",
            "https://user:secret@fsweb.no/studentweb/resultater.jsf", "https://fsweb.no:444/studentweb/resultater.jsf",
            "https://fsweb.no/studentweb/start.jsf", "https://fsweb.no/studentweb/resultater.jsf/more"] {
            precondition(!StudentwebResults.resultsPage(URL(string: url)!))
        }
        for malformed in [
            #"{"rows":[]}"#, #"[{"courseCode":"TEST1000","passed":1}]"#,
            #"[{"courseCode":"TEST1000","passed":"true"}]"#,
            #"[{"courseCode":"TEST1000","passed":null}]"#,
            #"[{"courseCode":"test1000","passed":true}]"#,
            #"[{"courseCode":"TEST1000\n","passed":true}]"#,
            #"[{"courseCode":"TDT4100-26H","passed":true}]"#,
            #"[{"courseCode":"PRIVATE@example.invalid","passed":true}]"#,
            #"[{"courseCode":"TEST1000","passed":true,"grade":"PRIVATE"}]"#,
            #"[{"courseCode":"TEST1000","passed":true},{"courseCode":"TEST1000","passed":false}]"#,
            String(repeating: "PRIVATE", count: 20_000)
        ] {
            do { _ = try StudentwebResults.parse(malformed); preconditionFailure("Invalid schema accepted") }
            catch { precondition(!error.localizedDescription.contains("PRIVATE")) }
        }
        let tooMany = (1000...2000).map { StudyCourseCompletion(courseCode: "TEST\($0)", passed: true) }
        precondition((try? StudentwebResults.parse(String(decoding: JSONEncoder().encode(tooMany), as: UTF8.self))) == nil)
        precondition(StudyCourseCompletionRules.status(for: "TDT4100-26H", in: rows) == true)
        precondition(StudyCourseCompletionRules.status(for: "TMA4100", in: rows) == false)
        precondition(StudyCourseCompletionRules.status(for: "OTHER1000", in: rows) == nil)
        precondition(StudyCourseCompletionRules.status(for: "MYTDT4100", in: rows) == nil)
        precondition(StudyCourseCompletionRules.status(for: "TDT4100 title", in: rows) == nil)

        // Request flow without opening a real account or automating WebKit.
        var navigation = StudentwebResultsNavigation()
        precondition(!StudentwebResultsNavigation.showsSignIn(StudentwebResults.resultsURL))
        precondition(!StudentwebResultsNavigation.showsSignIn(URL(string: "https://fsweb.no/studentweb/start.jsf")!))
        precondition(StudentwebResultsNavigation.showsSignIn(StudentwebResultsNavigation.loginURL))
        precondition(StudentwebResultsNavigation.showsSignIn(URL(string: "https://idp.feide.no/simplesaml/")!))
        precondition(navigation.next(for: StudentwebResults.resultsURL) == .read)
        precondition(navigation.next(for: URL(string: "https://fsweb.no/studentweb/velgInstitusjon.jsf")!) == .institution)
        precondition(navigation.next(for: StudentwebResultsNavigation.loginURL) == .feide)
        precondition(navigation.next(for: StudentwebResultsNavigation.loginURL) == .wait)
        precondition(navigation.next(for: URL(string: "https://idp.feide.no/simplesaml/module.php/core/loginuserpass.php")!) == .wait)
        precondition(navigation.next(for: URL(string: "https://fsweb.no/studentweb/start.jsf")!) == .results)
        precondition(navigation.next(for: URL(string: "https://fsweb.no/studentweb/start.jsf")!) == .wait)
        precondition(navigation.next(for: StudentwebResults.resultsURL) == .read)
        precondition(navigation.next(for: URL(string: "https://fsweb.no.evil.test/studentweb/login.jsf")!) == .wait)
        var wrongInstitution = StudentwebResultsNavigation()
        precondition(wrongInstitution.next(for: URL(string: "https://fsweb.no/studentweb/login.jsf?inst=OTHER")!) == .institution)
        var pinNavigation = StudentwebResultsNavigation(automaticFeide: false)
        precondition(pinNavigation.next(for: StudentwebResultsNavigation.loginURL) == .wait)
        precondition(pinNavigation.next(for: StudentwebResultsNavigation.loginURL) == .wait)
        precondition(pinNavigation.next(for: URL(string: "https://fsweb.no/studentweb/forsiden.jsf")!) == .results)
        precondition(pinNavigation.next(for: StudentwebResults.resultsURL) == .read)
        var liveLanding = StudentwebResultsNavigation(automaticFeide: false)
        precondition(liveLanding.next(for: URL(string: "https://fsweb.no/studentweb/index.jsf")!) == .results)

        let connection = StudentwebResultsConnection()
        let firstSession = StudentwebImportSession(resultsMode: true, connection: connection)
        let secondSession = StudentwebImportSession(resultsMode: true, connection: connection)
        precondition(firstSession.websiteDataStore === secondSession.websiteDataStore)
        precondition(!firstSession.websiteDataStore.isPersistent)
        precondition(StudentwebImportSession().websiteDataStore !== firstSession.websiteDataStore)
        precondition(StudentwebResultsConnection().dataStore !== connection.dataStore)
        firstSession.finish(); firstSession.finish() // Closing twice is safe.
        await connection.prepare()
        precondition(connection.dataStore === secondSession.websiteDataStore)
        secondSession.finish()
        connection.disconnect()
        await connection.prepare()
        precondition(connection.dataStore !== secondSession.websiteDataStore && !connection.dataStore.isPersistent)
        precondition(!secondSession.connectionIsCurrent)
        let oldSession = StudentwebImportSession(resultsMode: true, connection: connection)
        connection.disconnect()
        let newSession = StudentwebImportSession(resultsMode: true, connection: connection)
        oldSession.finish() // Late cleanup targets the old store, not a new login.
        await connection.prepare()
        precondition(!oldSession.connectionIsCurrent && newSession.connectionIsCurrent)
        newSession.finish()

        let browserSession = StudentwebImportSession(resultsMode: true)
        browserSession.completions = rows; browserSession.resultsPageReady = true
        browserSession.clearResults()
        precondition(browserSession.completions.isEmpty && !browserSession.resultsPageReady)
        browserSession.completions = rows; browserSession.finish()
        precondition(browserSession.completions.isEmpty)

        // Exercise the real macOS Keychain with synthetic data and a unique
        // disposable item, interaction disabled. Never open a user's vault.
        let account = "studentweb-results-smoke-\(UUID())"
        let encodedRows = try JSONEncoder().encode(rows)
        do {
            _ = try await ProviderKeychain.courseCompletionData(account: account, replacement: encodedRows, writing: true)
            let saved = try await ProviderKeychain.courseCompletionData(account: account)
            _ = try await ProviderKeychain.courseCompletionData(account: account, replacement: Data("[]".utf8), writing: true)
            let updated = try await ProviderKeychain.courseCompletionData(account: account)
            _ = try await ProviderKeychain.courseCompletionData(account: account, writing: true)
            let deleted = try await ProviderKeychain.courseCompletionData(account: account)
            precondition(saved == encodedRows && updated == Data("[]".utf8) && deleted == nil)
        } catch {
            _ = try? await ProviderKeychain.courseCompletionData(account: account, writing: true)
            throw error
        }

        let vault = ResultsMemoryVault()
        let persistence = StudyCourseCompletionStore(load: { _ in await vault.read() }, save: { try await vault.write($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-results-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root), completionStore: persistence)
        let exams = [
            StudyExam(id: "passed", courseCode: "TDT4100", date: "2027-12-10", startTime: "09:00", endTime: "13:00"),
            StudyExam(id: "unpassed", courseCode: "TMA4100", date: "2027-12-11", startTime: "09:00", endTime: "13:00")
        ]
        model.library.courses = [StudyCourse(name: "Programming", code: "TDT4100-26H"), StudyCourse(name: "Calculus", code: "TMA4100")]
        model.library.examPlan = exams
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let libraryBefore = try encoder.encode(model.library)
        await model.loadCourseCompletions()
        try await model.replaceCourseCompletions(rows)
        precondition(model.coursePassed("TDT4100") == true && model.coursePassed("TMA4100") == false)
        let libraryAfter = try encoder.encode(model.library)
        precondition(libraryAfter == libraryBefore, "Import must not mutate shared course, favorite or exam data")
        model.flush()
        let exportedLibrary = root.appendingPathComponent("privacy-check-export.json")
        try model.store.exportJSON(to: exportedLibrary)
        let libraryOnDisk = try Data(contentsOf: exportedLibrary)
        precondition(!String(decoding: libraryOnDisk, as: UTF8.self).contains("PRIVATE1000"))
        let stored = await vault.read()!
        let object = try JSONSerialization.jsonObject(with: stored) as! [[String: Any]]
        precondition(object.allSatisfy { Set($0.keys) == ["courseCode", "passed"] })
        let restarted = StudyWorkspaceModel(store: StudyLibraryStore(root: root), completionStore: persistence)
        await restarted.loadCourseCompletions()
        precondition(restarted.courseCompletions == rows)
        await vault.setFailure(true)
        do { try await model.replaceCourseCompletions([]); preconditionFailure("Failed deletion succeeded") }
        catch { precondition(model.courseCompletions == rows) }
        await vault.setFailure(false)

        let configuration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "openai"), model: "fixture",
            endpoint: "http://127.0.0.1:1", apiKey: "fixture", language: .english, fastClaudeMode: false)
        try await verifyAdvice(model, rows: rows, configuration: configuration)
        let ranking = #"{"courseLimit":2,"rankedCourses":[{"courseKey":"TDT4100","reason":"Programming"},{"courseKey":"TMA4100","reason":"Calculus"}]}"#
        var wirePayloads: [Data] = []
        let mock: StudyCompletion = { messages, config, _ in
            let input = messages[0].attachments!.first { $0.fileName == "exam-plan.json" }!.extractedText
            precondition(!input.contains("passedCourseCodes") && !input.contains("PRIVATE1000"))
            if let lookup = try lookupReply(messages) {
                return CompletionResult(text: lookup, providerID: "openai", providerName: "Fixture", model: "fixture")
            }
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            let request = try ProviderClient().buildRequest(prepared: prepared, configuration: config, endpoint: URL(string: config.endpoint)!)
            let wire = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: request.httpBody!), options: .sortedKeys)
            let isAdvice = messages[0].content.contains(StudyExamRecommender.adviceInstructions)
            if !isAdvice { wirePayloads.append(wire) }
            return CompletionResult(text: isAdvice ? "Synthetic advice." : ranking, providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        let request = StudyExamRecommendationRequest(exams: exams, interests: "Programming and maths")
        let responseWith = try await model.recommendExams(request, using: AppModel.shared, configuration: configuration, complete: mock)
        let local = StudyCourseCompletionRules.filtering(responseWith, completions: model.courseCompletions, exams: exams)
        precondition(local.selectedExamIDs == ["unpassed"] && local.choices.count == 1)
        precondition(local.excluded.last?.reason.contains("Already passed") == true)
        precondition(responseWith.selectedExamIDs == ["passed", "unpassed"], "Local filtering cannot contaminate the shared response")

        try await render(model)
        try await model.replaceCourseCompletions([])
        let deletedData = await vault.read()
        precondition(deletedData == nil && model.courseCompletions.isEmpty)
        _ = try await model.recommendExams(request, using: AppModel.shared, configuration: configuration, complete: mock)
        precondition(Set(wirePayloads).count == 1, "Ranking provider requests must remain identical with and without saved results")
        await restarted.loadCourseCompletions(allowInteraction: true)
        precondition(restarted.courseCompletions.isEmpty)
        // Account/institution replacement must drop old statuses, not merge them.
        try await model.replaceCourseCompletions(rows)
        let replacement = [StudyCourseCompletion(courseCode: "OTHER1000", passed: true)]
        try await model.replaceCourseCompletions(replacement)
        precondition(model.coursePassed("TDT4100") == nil && model.coursePassed("OTHER1000") == true)
        await vault.corrupt()
        await model.loadCourseCompletions(allowInteraction: true)
        precondition(model.courseCompletions.isEmpty && model.courseCompletionsError != nil)
        precondition(model.courseCompletionsError?.contains("PRIVATE") == false)
        try await model.replaceCourseCompletions([])
        let clearedData = await vault.read()
        precondition(clearedData == nil, "Corrupt data must still be deletable")
    }

    static func lookupReply(_ messages: [ConversationMessage]) throws -> String? {
        guard messages[0].content.contains(StudyPlanIndex.retrievalInstructions) else { return nil }
        let json = messages[0].attachments!.first { $0.fileName == "degree-catalogue.json" }!.extractedText
        precondition(json.utf16.count < 9000 && !json.contains("TTK4100"), "Lookup selection must not get whole course lists")
        let catalogue = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let plans = catalogue["plans"] as! [[String: Any]]
        var queries: [[String: Any]] = []
        for plan in plans {
            let code = plan["programmeCode"] as! String, focus = plan["focus"] as! [String: Any]
            if let year = focus["studyYear"] as? Int {
                queries.append(["kind": "year", "programmeCode": code, "studyYear": year,
                    "term": focus["term"]!, "branchPath": focus["branchPath"]!])
            } else if messages[0].content.contains("TTK4100 or TFY4330") {
                queries.append(["kind": "courses", "programmeCode": code, "courseCodes": [code == "MTTK" ? "TTK4100" : "TFY4330"]])
            }
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["queries": queries]), as: UTF8.self)
    }

    static func verifyAdvice(_ model: StudyWorkspaceModel, rows: [StudyCourseCompletion],
        configuration: ProviderConfiguration) async throws {
        let exams = model.library.examPlan ?? []
        let request = StudyExamRecommendationRequest(exams: exams, interests: "What should I prepare next?", mode: .advice)
        var sent: [[String: Any]] = []
        let mock: StudyCompletion = { messages, config, _ in
            let input = messages[0].attachments!.first { $0.fileName == "exam-plan.json" }!.extractedText
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            for id in ["openai", "anthropic", "cohere", "ollama", "codex"] {
                let provider = ProviderCatalog.provider(id: id)
                let config = ProviderConfiguration(provider: provider, model: provider.defaultModel, endpoint: provider.endpoint,
                    apiKey: "fixture", language: .english, fastClaudeMode: false)
                let wire = try ProviderClient().buildRequest(prepared: prepared, configuration: config, endpoint: URL(string: config.endpoint)!)
                let body = try JSONSerialization.jsonObject(with: wire.httpBody!) as! [String: Any]
                let content = (body["messages"] as! [[String: Any]]).last!["content"] as! String
                for attachment in messages[0].attachments! { precondition(content.contains(attachment.extractedText)) }
            }
            if let lookup = try lookupReply(messages) {
                precondition(input.contains("passedCourseCodes"), "Private pass codes are available to native lookup selection")
                return CompletionResult(text: lookup, providerID: "openai", providerName: "Fixture", model: "fixture")
            }
            sent.append(try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any])
            precondition(messages[0].content.contains(StudyExamRecommender.passedCourseInstructions))
            return CompletionResult(text: "Synthetic advice.", providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        _ = try await model.recommendExams(request, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
        precondition(sent.last!["passedCourseCodes"] as? [String] == ["PRIVATE1000", "TDT4100"],
            "Include every passed course, even outside the exam plan; omit failed courses")
        var followUp = request
        followUp.interests = "How does that change my priorities?"
        followUp.history = [.init(role: .user, content: request.interests), .init(role: .assistant, content: "Synthetic advice.")]
        try await model.replaceCourseCompletions(rows + [.init(courseCode: "NEW1000", passed: true)])
        _ = try await model.recommendExams(followUp, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
        precondition(sent.last!["passedCourseCodes"] as? [String] == ["NEW1000", "PRIVATE1000", "TDT4100"])
        precondition((sent.last!["conversation"] as? [[String: String]])?.count == 2)
        try await model.replaceCourseCompletions([])
        _ = try await model.recommendExams(followUp, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
        precondition(sent.last!["passedCourseCodes"] as? [String] == [], "Deleted statuses must not survive in subsequent context")
        try await model.replaceCourseCompletions(rows)
        let stale: StudyCompletion = { _, _, _ in
            try await model.replaceCourseCompletions([])
            return CompletionResult(text: "Outdated advice.", providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        do {
            _ = try await model.recommendExams(request, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: stale)
            preconditionFailure("Advice from a changed pass snapshot was accepted")
        } catch { precondition(error.localizedDescription.contains("passed courses changed")) }
        precondition(!model.examRecommendationBusy && model.library.examPlan == exams)
        try await model.replaceCourseCompletions(rows)

        // A reopened workspace must load the private Keychain store before the
        // first advice request. A failed read must not silently omit the list.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-advice-passes-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try JSONEncoder().encode(rows)
        let restarted = StudyWorkspaceModel(store: StudyLibraryStore(root: root), completionStore: .init(load: { _ in data }, save: { _ in }))
        restarted.library.examPlan = exams
        _ = try await restarted.recommendExams(request, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
        precondition(restarted.courseCompletionsLoaded && sent.last!["passedCourseCodes"] as? [String] == ["PRIVATE1000", "TDT4100"])
        let broken = StudyWorkspaceModel(store: StudyLibraryStore(root: root), completionStore: .init(load: { _ in throw StudyError.message("Synthetic vault failure") }, save: { _ in }))
        broken.library.examPlan = exams
        let sentCount = sent.count
        do {
            _ = try await broken.recommendExams(request, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
            preconditionFailure("Unreadable statuses were silently omitted")
        } catch { precondition(error.localizedDescription.contains("Passed courses could not be opened")) }
        precondition(sent.count == sentCount && !broken.examRecommendationBusy)

        for codes in [["PRIVATE@example.invalid"], Array(repeating: "TEST1000", count: 1001)] {
            precondition((try? StudyExamRecommender.messages(request, courses: [], passedCourseCodes: codes)) == nil)
        }
        let index = try StudyPlanIndex.bundled.get()
        precondition(index.byPlan["MTTK:2023"]?.count == 1299 && index.byPlan["MTNANO:2023"]?.count == 333)
        precondition(index.course("TTK4100").first { $0.planID == "MTTK:2023" }?.studyYear == 1 &&
            index.course("TFY4330").first { $0.planID == "MTNANO:2023" }?.studyYear == 3)
        precondition(index.year(programmeCode: "MTTK", admissionYear: 2023, studyYear: 5).isEmpty)
        precondition(index.missingPeriods(index.catalog.plans["MTTK:2023"]!) == [9, 10])
        var comparison = request; comparison.interests = "TTK4100 or TFY4330 for MTTK and MTNANO?"
        _ = try await model.recommendExams(comparison, using: AppModel.shared, includePassedCourses: true, configuration: configuration, complete: mock)
        let lookup = #"{"queries":[{"kind":"courses","programmeCode":"MTTK","courseCodes":["TTK4100"]},{"kind":"courses","programmeCode":"MTNANO","courseCodes":["TFY4330"]}]}"#
        let retrieved = try index.retrieve(lookup, selections: nil)
        let messages = try StudyExamRecommender.messages(comparison, courses: [], passedCourseCodes: ["TDT4100"], degreeReference: retrieved)
        let reference = messages[0].attachments!.first { $0.fileName == "degree-plans.json" }!.extractedText
        let context = try JSONSerialization.jsonObject(with: Data(reference.utf8)) as! [String: Any]
        precondition(context["scope"] as? String == "retrieved-plans" && (context["results"] as? [[String: Any]])?.count == 2)
        precondition(messages[0].content.contains(StudyPlanIndex.instructions))

        // Public selections must survive request decoding and override earlier chat scope.
        precondition(index.admissionYears("MTTK") == Array((2009...2026).reversed()))
        precondition(index.admissionYears("MTNANO") == index.admissionYears("MTTK"))
        precondition(index.defaultSelection("MTTK").admissionYear == 2023)
        let selection = StudyPlanSelection(programmeCode: "MTTK", admissionYear: 2023,
            studyYear: 4, term: "autumn", branchPath: ["MTTK-RFRO"])
        comparison.degreeSelections = [selection]
        comparison.history = [.init(role: .user, content: "MTNANO"), .init(role: .assistant, content: "Earlier advice.")]
        comparison = try JSONDecoder().decode(StudyExamRecommendationRequest.self, from: JSONEncoder().encode(comparison))
        let branchLookup = #"{"queries":[{"kind":"year","programmeCode":"MTTK","studyYear":4,"term":"autumn","branchPath":["MTTK-RFRO"]}]}"#
        let chosenMessages = try StudyExamRecommender.messages(comparison, courses: [], passedCourseCodes: ["TEST1000"],
            degreeReference: index.retrieve(branchLookup, selections: comparison.degreeSelections))
        let chosenJSON = chosenMessages[0].attachments!.first { $0.fileName == "degree-plans.json" }!.extractedText
        let envelope = try JSONSerialization.jsonObject(with: Data(chosenJSON.utf8)) as! [String: Any]
        let chosen = (envelope["results"] as! [[String: Any]])[0]["data"] as! [String: Any]
        precondition(chosen["scope"] as? String == "selected-plans")
        let plans = chosen["plans"] as! [[String: Any]], nodes = chosen["nodes"] as! [String: [String: Any]]
        precondition(plans.count == 1 && plans[0]["planID"] as? String == "MTTK:2023")
        precondition(plans[0]["selectedPeriods"] as? [Int] == [7])
        precondition(Set(nodes.values.compactMap { $0["directionCode"] as? String }) == Set(["MTTK-RFRO"]))
        _ = try await model.recommendExams(comparison, using: AppModel.shared, includePassedCourses: true,
            configuration: configuration, complete: mock)
        var missing = selection; missing.studyYear = 5
        let missingJSON = try index.reference(question: "MTTK", selections: [missing])!
        let empty = try JSONSerialization.jsonObject(with: Data(missingJSON.utf8)) as! [String: Any]
        precondition((empty["courses"] as! [String: Any]).isEmpty)
        for invalid in [StudyPlanSelection(programmeCode: "MTTK", admissionYear: 2027),
            StudyPlanSelection(programmeCode: "MTTK", admissionYear: 2023, studyYear: 6),
            StudyPlanSelection(programmeCode: "MTNANO", admissionYear: 2023, branchPath: ["MTTK-RFRO"])] {
            precondition((try? index.retrievalCatalogue([invalid])) == nil)
        }
        for invalid in [#"{"queries":[{"kind":"year","programmeCode":"MTTK","studyYear":true}]}"#,
            #"{"queries":[{"kind":"year","programmeCode":"MTTK","studyYear":1,"admissionYear":2024}]}"#,
            #"{"queries":[{"kind":"courses","programmeCode":"UNSELECTED","courseCodes":["TTK4100"]}]}"#] {
            precondition((try? index.retrieve(invalid, selections: nil)) == nil)
        }
        var invalidCalls = 0
        let invalidModel: StudyCompletion = { _, _, _ in
            invalidCalls += 1
            return CompletionResult(text: "Invalid lookup selection", providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        do {
            _ = try await model.recommendExams(comparison, using: AppModel.shared, includePassedCourses: true,
                configuration: configuration, complete: invalidModel)
            preconditionFailure("An invalid lookup response became advice")
        } catch { precondition(invalidCalls == 2 && !model.examRecommendationBusy) }
        comparison.degreeSelections = []
        let disabled = try StudyExamRecommender.messages(comparison, courses: [], passedCourseCodes: ["TEST1000"])
        precondition(disabled[0].attachments!.count == 1, "Degree opt-out keeps the independent passed-course context")
    }

    static func render(_ model: StudyWorkspaceModel) async throws {
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 570),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: StudyCourseCompletionsView(workspace: model).tint(StudyPalette.accent))
        window.orderFront(nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(600))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("studentweb-results-\(name).png"))
        }
        let index = try StudyPlanIndex.bundled.get()
        window.setContentSize(NSSize(width: 700, height: 630))
        window.contentView = NSHostingView(rootView: StudyPlanSelectionView(index: index, selections: .constant([
            .init(programmeCode: "MTTK", admissionYear: 2023, studyYear: 4, term: "autumn", branchPath: ["MTTK-RFRO"]),
            .init(programmeCode: "MTNANO", admissionYear: 2023, studyYear: 3, branchPath: ["MTNANO-BT"])
        ])).padding(18).frame(width: 700, height: 630, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(500))
        let view = window.contentView!; view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("degree-plan-selectors-native.png"))
    }
}
