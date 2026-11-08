@preconcurrency import AppKit
import Foundation
import SwiftUI
@testable import ScholiaMac

@main
@MainActor
struct ExamPlannerSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: native opening-page import refresh, flexible and fixed timing roundtrips, cached validation, chronological sorting, recommendations, selection, overlap boundaries, overnight dates, validation, persistence, favorites, conflict choices, fresh Canvas submissions, stale saves, light/dark rendering"); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        app.run()
    }

    static func recommendationPromptChecks() throws {
        let question = "Should i take the exam for TTK4100 or TFY4330, which is for MTTK first year and MTNANO third year respectively for the best progression?"
        let exams = (0..<500).map { index in
            StudyExam(id: "exam-\(index)",
                courseCode: index == 498 ? "TFY4330" : index == 499 ? "TTK4100" : "AAA\(1000 + index)",
                courseName: "Course \(index)", date: "2026-12-10", startTime: "09:00", endTime: "13:00",
                selected: index.isMultiple(of: 2))
        }
        for mode in [StudyExamRecommendationMode.advice, .selection] {
            let request = StudyExamRecommendationRequest(exams: exams, interests: question, mode: mode)
            let input = try StudyExamRecommender.input(request, courses: [])
            precondition(input.utf16.count > PromptBuilder.maxMessageCharacters)
            let messages = try StudyExamRecommender.messages(request, courses: [])
            precondition(messages[0].content.contains(question), "Keep the exact student request outside reference data")
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            for providerID in ["openai", "anthropic", "cohere", "ollama", "codex"] {
                let provider = ProviderCatalog.provider(id: providerID)
                let config = ProviderConfiguration(provider: provider, model: provider.defaultModel,
                    endpoint: provider.endpoint, apiKey: "fixture", language: .english, fastClaudeMode: false)
                let wire = try ProviderClient().buildRequest(prepared: prepared, configuration: config,
                    endpoint: URL(string: provider.endpoint)!)
                let body = try JSONSerialization.jsonObject(with: wire.httpBody!) as! [String: Any]
                let sent = (body["messages"] as! [[String: Any]]).last!["content"] as! String
                precondition(sent.contains(question) && sent.contains(input),
                    "\(providerID) must receive the question and the complete plan, beyond the chat-message limit")
            }
            precondition(request.exams == exams)
        }
        let history: [StudyExamAdviceMessage] = [.init(role: .user, content: question),
            .init(role: .assistant, content: String(repeating: "Original comparison. ", count: 700) + "END OF ADVICE")]
        let followUp = StudyExamRecommendationRequest(exams: Array(exams.suffix(2)), interests: "Why that course?", mode: .advice, history: history)
        let preparedFollowUp = try PromptBuilder.prepare(messages: StudyExamRecommender.messages(followUp, courses: []), capture: nil, languagePreference: .english)
        let followUpInput = try StudyExamRecommender.input(followUp, courses: [])
        precondition(preparedFollowUp.messages[0].content.contains(followUpInput)
            && preparedFollowUp.messages[0].content.contains("END OF ADVICE"), "Long prior answers and the original question survive in follow-up context")
        precondition((try? StudyExamRecommender.checkedHistory([history[0]], advice: true)) == nil)
        precondition((try? StudyExamRecommender.checkedHistory(history, advice: false)) == nil)
        let oversized = exams.map { exam in
            var row = exam
            row.courseName = String(repeating: "N", count: 180)
            row.component = String(repeating: "C", count: 120)
            return row
        }
        do {
            _ = try StudyExamRecommender.messages(.init(exams: oversized, interests: question, mode: .advice), courses: [])
            preconditionFailure("An oversized plan must fail visibly rather than send partial reference data")
        } catch {
            precondition(error.localizedDescription.contains("too large to send in full"))
        }
    }

    static func run() async throws {
        try recommendationPromptChecks()
        pastAndFocusChecks()
        try flexibleTimingChecks()
        let courseSelectionPreview = try courseSelectionChecks()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExamSmokeAssignmentProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CanvasClient(origin: URL(string: "https://canvas.refresh.test")!, token: "fixture", session: session)
        let before = try await client.assignmentUpdates(courseID: 1)
        let after = try await client.assignmentUpdates(courseID: 1)
        precondition(before.first?.assignment?.status == .notSubmitted)
        precondition(after.first?.assignment?.status == .submitted)
        precondition(before.first?.version == after.first?.version)
        precondition(!ExamSmokeAssignmentProtocol.state.conditional)

        precondition(StudentwebExtraction.trusted(StudentwebExtraction.startURL))
        precondition(StudentwebExtraction.trusted(URL(string: "https://fsweb.no/studentweb/?faces-redirect=true")!))
        precondition(!StudentwebExtraction.trusted(URL(string: "https://fsweb.no/studentweb-evil/")!))
        precondition(StudentwebExtraction.examPage(StudentwebExtraction.startURL))
        precondition(StudentwebExtraction.examPage(URL(string: "https://fsweb.no/studentweb/start.jsf")!))
        precondition(StudentwebExtraction.examPage(URL(string: "https://fsweb.no/studentweb/forside.jsf")!))
        for url in ["https://fsweb.no/studentweb/aktiveEmner.jsf", "http://fsweb.no/studentweb/start.jsf", "https://fsweb.no.evil.test/studentweb/start.jsf", "https://fsweb.no/studentweb/login.jsf", "https://fsweb.no:444/studentweb/start.jsf", "https://user:secret@fsweb.no/studentweb/start.jsf"] {
            precondition(!StudentwebExtraction.examPage(URL(string: url)!))
        }
        let extracted = StudentwebExtraction.parse(#"{"rows":[{"tokens":"TET5100\nAssessment\nDate: 10.12.2026\nTime: 09:00–13:00","component":"Final exam"}],"sourceCount":1}"#)
        precondition(extracted.exams.count == 1 && extracted.exams[0].courseName.isEmpty && !extracted.exams[0].selected)
        precondition(extracted.replacesStudentweb)
        var retained = extracted.exams[0]; retained.selected = true; retained.courseName = "Electromagnetic Analysis"
        let invented = StudyExam(courseCode: "TDT4186", date: "2026-12-01", source: "studentweb")
        let manual = StudyExam(courseCode: "MAN1000", date: "2026-11-01", selected: true)
        let refreshed = try StudyExamPlanner.importing(extracted, into: [invented, retained, manual])
        precondition(refreshed == [manual, retained], "Opening-page refresh must remove stale Studentweb dates and preserve matching intent and manual entries")
        let pastedAgain = try StudyExamPlanner.importing(StudyExamImport(exams: [invented]), into: refreshed)
        let refreshedAgain = try StudyExamPlanner.importing(extracted, into: refreshed)
        precondition(pastedAgain.count == 3 && refreshedAgain == refreshed)
        let repeated = StudentwebExtraction.parse(#"{"rows":[{"tokens":"MEDT8002\nAssessment\nDate: 18.11.2026\nTime: 09:00","component":"Exam release"},{"tokens":"MEDT8002\nAssessment\nDate: 18.11.2026\nTime: 09:00","component":"Exam release"},{"tokens":"MA3408\nAssessment\nDate: 26.11.2026 – 27.11.2026","component":"Exam period"},{"tokens":"TEST1000\nAssessment","component":"Exam"}],"sourceCount":4}"#)
        precondition(repeated.sourceCount == 4 && repeated.exams.count == 4 && repeated.warnings.isEmpty)
        precondition(repeated.exams[0].component == "Exam release" && repeated.exams[2].endDate == "2026-11-27")
        precondition(repeated.exams[3].date.isEmpty, "Undated source rows must remain incomplete instead of disappearing")
        var sameDay = repeated.exams; sameDay[1].selected = true
        let repeatedRefresh = try StudyExamPlanner.importing(repeated, into: sameDay)
        precondition(repeatedRefresh == sameDay, "Repeated imports preserve distinct IDs and selection for identical-looking rows")
        precondition(Set(repeatedRefresh.map(\.id)).count == 4)
        var manualMatch = sameDay[0]; manualMatch.id = "manual-match"; manualMatch.source = "manual"
        let mixed = try StudyExamPlanner.importing(repeated, into: [sameDay[0], manualMatch])
        precondition(mixed.count == 4 && mixed[0] == manualMatch, "Manual matches may represent only one source row")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-exams-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        let text = """
        Studentnummer: 12345678901
        TDT4100 Object-oriented programming
        Midterm 14.10.2026 09:00–11:00
        Final exam 10.12.2026 09:00–13:00
        Trekkfrist: 01.12.2026
        Sensurdato: 30.12.2026
        E-post: private@example.com
        TMA4100 Calculus
        Skriftlig skoleeksamen
        Dato
        10. desember 2026
        Tid: 12:00–16:00
        TFE4146 Sensors
        Final exam 10.12.2026
        """
        var exams = StudyExamPlanner.parseStudentweb(text).exams
        precondition(exams.count == 4)
        precondition(exams[0].kind == "midterm" && exams[1].kind == "final")
        precondition(exams[0].courseKey == exams[1].courseKey)
        precondition(exams.allSatisfy { !$0.selected })
        precondition(exams[2].date == "2026-12-10" && exams[2].endTime == "16:00")
        precondition(exams[2].courseCode == "TMA4100")
        for index in exams.indices { exams[index].selected = true }
        let conflicts = StudyExamPlanner.collisions(exams)
        precondition(conflicts.filter { !$0.possible }.count == 1 && conflicts.filter(\.possible).count == 2)
        var next = exams[1]; next.id = "next"; next.startTime = "13:00"; next.endTime = "15:00"
        precondition(StudyExamPlanner.collisions([exams[1], next]).isEmpty)
        next.startTime = "12:59"
        precondition(StudyExamPlanner.collisions([exams[1], next]).first?.possible == false)
        next.selected = false
        precondition(StudyExamPlanner.collisions([exams[1], next]).isEmpty)
        next.selected = true; next.date = ""; next.startTime = ""; next.endTime = ""
        precondition(StudyExamPlanner.collisions([exams[1], next]).isEmpty)
        var overnight = exams[1]; overnight.startTime = "22:00"; overnight.endTime = "02:00"
        precondition((try? StudyExamPlanner.normalized([overnight])) == nil)
        overnight.endDate = "2026-12-11"
        precondition((try? StudyExamPlanner.normalized([overnight])) != nil)
        next.date = "2026-12-11"; next.startTime = "01:00"; next.endTime = "03:00"
        precondition(StudyExamPlanner.collisions([overnight, next]).first?.possible == false)
        precondition(StudyExamPlanner.day("2026-02-29") == nil && StudyExamPlanner.day("2028-02-29") != nil)
        precondition((try? StudyExamPlanner.normalized([exams[0], exams[0]])) == nil)
        precondition(StudyExamPlanner.parseStudentweb("TDT4100 Programming\nUnrelated event 01.01.2026\nBirth date 02.02.2000").exams.isEmpty)
        let duration = StudyExamPlanner.parseStudentweb("TDT4100 Programming\nFinal exam 10.12.2026\n09:00\n4 timer").exams
        precondition(duration.first?.endTime == "13:00")
        try model.replaceExamPlan(exams, base: [])
        precondition((try? model.replaceExamPlan([], base: [])) == nil)
        precondition(model.library.examPlan == exams)
        var invalid = exams[0]; invalid.date = "2026-02-30"
        precondition((try? model.replaceExamPlan([invalid], base: exams)) == nil)
        let programming = StudyCourse(name: "Programming", code: "TDT4100-26H")
        let calculus = StudyCourse(name: "Calculus", code: "TMA4100")
        model.library.courses = [programming, calculus]
        precondition(StudyExamPlanner.favoriteCourseIDs(exams, courses: model.library.courses).isEmpty)
        var chosen = try StudyExamPlanner.resolveConflict(exams, keep: exams[2].id, drop: exams[1].id)
        precondition(!chosen[0].selected && !chosen[1].selected && chosen[2].selected)
        chosen[3].selected = false
        try model.replaceExamPlan(chosen, base: exams)
        precondition(!model.library.courses[0].isFavorite && model.library.courses[1].isFavorite)
        try model.replaceExamPlan(exams, base: chosen)
        precondition(!model.library.courses[1].isFavorite)
        let chronological = [exams[2], exams[1], exams[0]].sorted(by: StudyExamPlanner.chronological)
        precondition(chronological.map(\.id) == [exams[0].id, exams[1].id, exams[2].id])
        let ranking = #"{"courseLimit":3,"rankedCourses":[{"courseKey":"TDT4100","reason":"Programming helps with your robotics goals."},{"courseKey":"TMA4100","reason":"Calculus supports modelling."},{"courseKey":"TFE4146","reason":"Sensors connect robots to the world."}]}"#
        let recommended = try StudyExamRecommender.checked(ranking, exams: exams)
        precondition(recommended.selectedExamIDs == [exams[0].id, exams[1].id], "A recommendation must retain all components and exclude clashing or incomplete courses")
        precondition(recommended.excluded.count == 2 && recommended.excluded[1].reason.contains("missing"))
        precondition((try? StudyExamRecommender.checked(ranking.replacingOccurrences(of: "TDT4100", with: "INVENTED"), exams: exams)) == nil)
        let required = ranking.replacingOccurrences(of: #""courseLimit":3"#, with: #""courseLimit":3,"requiredCourseKeys":["TMA4100"]"#)
        let requiredAdvice = try StudyExamRecommender.checked(required, exams: exams)
        precondition(requiredAdvice.selectedExamIDs == [exams[2].id])
        let impossible = ranking.replacingOccurrences(of: #""courseLimit":3"#, with: #""courseLimit":3,"requiredCourseKeys":["TDT4100","TMA4100"]"#)
        precondition((try? StudyExamRecommender.checked(impossible, exams: exams)) == nil)
        let providerConfiguration = ProviderConfiguration(provider: ProviderCatalog.provider(id: "openai"), model: "fixture", endpoint: "http://127.0.0.1:1", apiKey: "fixture", language: .english, fastClaudeMode: false)
        let recommend: StudyCompletion = { messages, _, _ in
            if messages[0].content.contains(StudyPlanIndex.retrievalInstructions) {
                return CompletionResult(text: #"{"queries":[]}"#, providerID: "openai", providerName: "Fixture", model: "fixture")
            }
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            precondition(prepared.messages[0].content.contains("Robotics") && !prepared.messages[0].content.contains("private@example.com"))
            if messages[0].content.contains(StudyExamRecommender.adviceInstructions) {
                precondition(prepared.messages[0].content.contains("\"overlapCount\":3"))
                if prepared.messages[0].content.contains("Why that one?") {
                    precondition(prepared.messages[0].content.contains("\"conversation\"")
                        && prepared.messages[0].content.contains("Take TDT4100 over TMA4100"))
                    return CompletionResult(text: "Because of your earlier Robotics goal.", providerID: "openai", providerName: "Fixture", model: "fixture")
                }
                return CompletionResult(text: "**Take TDT4100 over TMA4100** for your robotics goals; their finals overlap. Confirm TFE4146's missing times.", providerID: "openai", providerName: "Fixture", model: "fixture")
            }
            return CompletionResult(text: ranking, providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        let advice = try await model.recommendExams(.init(exams: exams, interests: "Robotics"), using: AppModel.shared,
            configuration: providerConfiguration, complete: recommend)
        precondition(advice.selectedExamIDs == recommended.selectedExamIDs && model.library.examPlan == exams
            && !model.examRecommendationBusy, "Recommendations must not change saved selections")
        let generalAdvice = try await model.recommendExams(.init(exams: exams, interests: "Robotics: which overlapping exam should I take?", mode: .advice), using: AppModel.shared,
            configuration: providerConfiguration, complete: recommend)
        precondition(generalAdvice.advice?.contains("Take TDT4100 over TMA4100") == true && generalAdvice.selectedExamIDs.isEmpty
            && model.library.examPlan == exams && !model.examRecommendationBusy, "Advice compares overlapping courses without applying a selection")
        let unselected = exams.map { value in var exam = value; exam.selected = false; return exam }
        let adviceInput = try StudyExamRecommender.input(.init(exams: unselected, interests: "Which exam should I take?", mode: .advice), courses: [])
        precondition(adviceInput.contains("\"overlapCount\":3") && adviceInput.contains("\"selected\":false")
            && adviceInput.contains("\"status\":\"possible\"") && adviceInput.contains("\"status\":\"collision\""),
            "Advice must consider unselected alternatives and distinguish confirmed from possible overlaps")
        let emptyAdviceInput = try StudyExamRecommender.input(.init(exams: [], interests: "How should I revise?", mode: .advice), courses: [])
        precondition(emptyAdviceInput.contains("\"courses\":[]"), "General advice must work before dates are added")
        precondition((try? StudyExamRecommender.checkedAdvice("  ")) == nil)
        let legacyRequest = try JSONDecoder().decode(StudyExamRecommendationRequest.self, from: Data(#"{"exams":[],"interests":"Robotics"}"#.utf8))
        precondition(legacyRequest.mode == nil, "Existing clients must retain selection behavior")
        let staleRecommendation: StudyCompletion = { _, _, _ in
            model.library.examPlan?[0].date = "2026-10-15"
            return CompletionResult(text: ranking, providerID: "openai", providerName: "Fixture", model: "fixture")
        }
        let staleAdvice = try? await model.recommendExams(.init(exams: exams, interests: "Robotics"), using: AppModel.shared,
            configuration: providerConfiguration, complete: staleRecommendation)
        precondition(staleAdvice == nil && !model.examRecommendationBusy)
        model.library.examPlan = exams
        model.flush()
        let savedLibrary = try store.load()
        precondition(savedLibrary.examPlan == exams)
        let encoded = String(data: try JSONEncoder().encode(savedLibrary), encoding: .utf8)!
        precondition(!encoded.contains("private@example.com") && !encoded.contains("12345678901"))
        let old = try JSONDecoder().decode(StudyLibrary.self, from: JSONEncoder().encode(StudyLibrary()))
        precondition(old.examPlan == nil)

        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 820), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StudyExamScheduleView(workspace: model).environmentObject(AppModel.shared).tint(StudyPalette.accent).accentColor(StudyPalette.accent))
        window.orderFront(nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(300))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("exam-planner-native-\(name).png"))
        }
        var flexiblePreview = exams
        flexiblePreview[2].selected = false
        flexiblePreview[3].flexible = true
        try model.replaceExamPlan(flexiblePreview, base: exams)
        window.appearance = NSAppearance(named: .aqua)
        try await Task.sleep(for: .milliseconds(300))
        let flexibleView = window.contentView!
        flexibleView.layoutSubtreeIfNeeded()
        if let scroll = scrollView(in: flexibleView) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 480))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
        }
        let flexibleBitmap = flexibleView.bitmapImageRepForCachingDisplay(in: flexibleView.bounds)!
        flexibleView.cacheDisplay(in: flexibleView.bounds, to: flexibleBitmap)
        try flexibleBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("exam-planner-native-flexible.png"))

        let resolvedPreview = try StudyExamPlanner.setSelected(Array(flexiblePreview.suffix(2)), id: exams[2].id, selected: true)
        try model.replaceExamPlan(resolvedPreview, base: flexiblePreview)
        precondition(StudyExamPlanAnalysis(model.library.examPlan ?? []).choices.isEmpty,
            "Saving both selected exams removes their resolved flexible pair")
        try await Task.sleep(for: .milliseconds(300))
        flexibleView.layoutSubtreeIfNeeded()
        if let scroll = scrollView(in: flexibleView) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(150))
        }
        let resolvedBitmap = flexibleView.bitmapImageRepForCachingDisplay(in: flexibleView.bounds)!
        flexibleView.cacheDisplay(in: flexibleView.bounds, to: resolvedBitmap)
        try resolvedBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("exam-planner-native-resolved.png"))
        try model.replaceExamPlan(exams, base: resolvedPreview)
        precondition(model.library.examPlan == exams, "The flexible preview must not alter the plan used by persistence and API checks")

        window.setContentSize(NSSize(width: 540, height: 430))
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 18) {
            Text("Course selection").font(.system(size: 24, design: .serif))
            Text("Expand a course to choose individual exams. You can take a midterm without its final.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            StudyExamCourseSelectionRow(exams: courseSelectionPreview.filter { $0.courseCode == "TTK4250" },
                selectExam: { _, _ in }, selectCourse: { _ in })
            StudyExamCourseSelectionRow(exams: courseSelectionPreview.filter { $0.courseCode == "OTHER1000" },
                selectExam: { _, _ in }, selectCourse: { _ in })
            Spacer(minLength: 0)
        }.padding(24).frame(width: 540, height: 430)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(StudyPalette.accent).accentColor(StudyPalette.accent))
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            try await Task.sleep(for: .milliseconds(300))
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("exam-course-selection-\(name).png"))
        }
        try await searchControlsChecks(window: window, workspace: model, output: output)
        window.close()


    }

    static func searchControlsChecks(window: NSWindow, workspace: StudyWorkspaceModel, output: URL) async throws {
        let original = workspace.library.examPlan ?? []
        let code = original.first?.courseCode ?? "TDT4100"
        precondition(StudyExamSearch.filter(original, query: " \(code.lowercased()) ").allSatisfy { $0.courseCode == code })
        precondition(StudyExamSearch.filter(original, query: "NO_SUCH_EXAM").isEmpty)
        let catalog = try StudyPlanIndex.bundled.get()
        let options = StudyExamSearch.courses(library: workspace.library.courses, catalog: Array(catalog.catalog.courses.values))
        precondition(options.contains { $0.code == "TMA4100" })
        precondition(Set(options.map(\.id)).count == options.count)
        let names = options.filter { StudyExamSearch.matches($0.searchText, query: "tdt 4100") }
        precondition(names.count == 1 && names[0].code == "TDT4100")
        window.setContentSize(NSSize(width: 1200, height: 900))
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = NSHostingView(rootView: StudyExamPlannerView(workspace: workspace, initialSearch: code)
            .environmentObject(AppModel.shared).tint(StudyPalette.accent))
        try await Task.sleep(for: .milliseconds(500))
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields($0) }
        }
        let search = fields(window.contentView!).first { $0.placeholderString == "Search course, exam component, or date" }
        precondition(search?.stringValue == code, "The planner opens with a functioning search field")
        let rows = fields(window.contentView!).filter { $0.placeholderString == "Course code" }
        precondition(!rows.isEmpty && rows.allSatisfy { $0.stringValue == code }, "Only matching editable exams are displayed")
        for (name, root) in [("exam-search-native", window.contentView!)] {
            root.layoutSubtreeIfNeeded()
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            root.cacheDisplay(in: root.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(name).png"))
        }
        window.setContentSize(NSSize(width: 660, height: 610))
        window.contentView = NSHostingView(rootView: StudyExamCoursePicker(courses: workspace.library.courses, exams: original,
            onAdd: { _ in preconditionFailure("Searching must not add an exam") }, initialQuery: "TMA4100")
            .tint(StudyPalette.accent))
        try await Task.sleep(for: .milliseconds(500))
        precondition(fields(window.contentView!).contains { $0.placeholderString == "Search courses by code or name" && $0.stringValue == "TMA4100" })
        let picker = window.contentView!
        picker.layoutSubtreeIfNeeded()
        picker.displayIfNeeded()
        let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds)!
        picker.cacheDisplay(in: picker.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("exam-add-search-native.png"))
        precondition(workspace.library.examPlan == original, "Search and opening the add picker never change the saved plan")
        print("PASS: native exam search, filtered editor rows, searchable course picker, deduplication and unchanged saved plan")
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    static func pastAndFocusChecks() {
        let today = "2026-10-10"
        let past = StudyExam(id: "past", courseCode: "LATE1000", date: "2026-10-09", startTime: "09:00", endTime: "13:00", selected: true)
        let late = StudyExam(id: "late", courseCode: "LATE1000", date: "2026-12-10", startTime: "09:00", endTime: "13:00", selected: true)
        let early = StudyExam(id: "early", courseCode: "EARLY1000", date: today, startTime: "09:00", endTime: "13:00", selected: true)
        let undated = StudyExam(id: "undated", courseCode: "UNKNOWN1000", selected: true, flexible: true)
        var ongoing = past; ongoing.endDate = "2026-10-11"
        precondition(StudyExamPlanner.isPast(past, today: today))
        precondition(!StudyExamPlanner.isPast(early, today: today) && !StudyExamPlanner.isPast(undated, today: today)
            && !StudyExamPlanner.isPast(ongoing, today: today), "Today, undated and ongoing exams remain active")
        ongoing.endDate = today
        precondition(!StudyExamPlanner.isPast(ongoing, today: today))
        let courses = ["LATE1000", "UNKNOWN1000", "EARLY1000"].map { StudyCourse(name: $0, code: $0) }
        precondition(StudyExamPlanner.focusCourses([past, late, early, undated], courses: courses, today: today).map(\.code)
            == ["EARLY1000", "LATE1000", "UNKNOWN1000"], "Focus courses use the next selected exam date, with undated courses last")
        let osloNight = ISO8601DateFormatter().date(from: "2026-10-09T22:30:00Z")!
        precondition(StudyExamPlanner.dayString(osloNight) == today)
    }

    static func courseSelectionChecks() throws -> [StudyExam] {
        let midterm = StudyExam(id: "course-midterm", courseCode: "TTK4250", component: "Midterm", kind: "midterm",
            date: "2026-10-09", startTime: "09:00", endTime: "11:00", selected: true)
        let final = StudyExam(id: "course-final", courseCode: "TTK4250", component: "Final exam", kind: "final",
            date: "2026-12-10", startTime: "15:00", endTime: "19:00", selected: true)
        var other = final; other.id = "other-course"; other.courseCode = "OTHER1000"
        let original = [final, other, midterm]
        precondition(StudyExamPlanner.collisions(original).count == 1)
        let midtermOnly = try StudyExamPlanner.setSelected(original, id: final.id, selected: false)
        var expectedFinal = final; expectedFinal.selected = false
        precondition(midtermOnly == [expectedFinal, other, midterm],
            "Taking only a midterm must not remove its final or change another course")
        precondition(StudyExamPlanAnalysis(midtermOnly).conflicts.isEmpty,
            "An unselected final must not create an overlap")
        let neither = try StudyExamPlanner.setSelected(midtermOnly, id: midterm.id, selected: false)
        let finalOnly = try StudyExamPlanner.setSelected(neither, id: final.id, selected: true)
        precondition(finalOnly.filter { $0.courseKey == midterm.courseKey && $0.selected }.map(\.id) == [final.id]
            && StudyExamPlanAnalysis(finalOnly).conflicts.count == 1 && finalOnly.first(where: { $0.id == other.id }) == other,
            "Selecting only the final leaves the midterm off and restores its overlap")
        let refreshed = try StudyExamPlanner.importing(StudyExamImport(exams: [midterm, final]), into: midtermOnly)
        precondition(refreshed == midtermOnly, "Refreshing dates must preserve individual component selections")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-course-exams-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root), workspace = StudyWorkspaceModel(store: store)
        try workspace.replaceExamPlan(original, base: [])
        try workspace.replaceExamPlan(midtermOnly, base: original)
        workspace.flush()
        let saved = try store.load()
        precondition(saved.examPlan == midtermOnly, "Midterm-only selections must survive saving and reopening")
        try workspace.replaceExamPlan(finalOnly, base: midtermOnly)
        try workspace.replaceExamPlan(midtermOnly, base: finalOnly)
        precondition(workspace.library.examPlan == midtermOnly, "Undo restores the previous component choices")
        workspace.flush()
        return midtermOnly
    }

    static func flexibleTimingChecks() throws {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        let fixed = StudyExam(id: "fixed", courseCode: "TDT4100", component: "Written exam", date: "2026-12-10",
            startTime: "09:00", endTime: "13:00", selected: true, source: "studentweb")
        var oral = StudyExam(id: "oral", courseCode: "TMA4100", component: "Oral exam", date: fixed.date,
            startTime: "10:00", endTime: "12:00", selected: true, source: "studentweb", flexible: true)

        // Plans written before timing overrides existed must migrate by component, not lose the saved plan.
        func legacy(_ exam: StudyExam, component: String) throws -> StudyExam {
            var object = try JSONSerialization.jsonObject(with: encoder.encode(exam)) as! [String: Any]
            object.removeValue(forKey: "flexible")
            object["component"] = component
            return try decoder.decode(StudyExam.self, from: JSONSerialization.data(withJSONObject: object))
        }
        for label in ["Oral exam", "MUNTLIG EKSAMEN", "Final oral examination"] {
            let migrated = try legacy(oral, component: label)
            precondition(migrated.flexible && migrated.selected && migrated.date == oral.date && migrated.id == oral.id,
                "Legacy oral exams default to flexible without changing dates, IDs or selections")
        }
        let legacyWritten = try legacy(fixed, component: "Written exam")
        let legacyUnrelated = try legacy(fixed, component: "Temporal analysis")
        precondition(!legacyWritten.flexible)
        precondition(!legacyUnrelated.flexible, "Oral matching must use whole words")
        oral.flexible = false
        let explicitFixed = try decoder.decode(StudyExam.self, from: encoder.encode(oral))
        precondition(explicitFixed == oral && !explicitFixed.flexible,
            "An explicit fixed-time override on an oral exam must survive saving and loading")
        oral.flexible = true
        let savedFlexible = try decoder.decode(StudyExam.self, from: encoder.encode(oral))
        precondition(savedFlexible == oral)

        let importedOral = StudentwebExtraction.parse(#"{"rows":[{"tokens":"TMA4100\nAssessment\nDate: 10.12.2026\nTime: 10:00–12:00","component":"Oral exam"}],"sourceCount":1}"#)
        precondition(importedOral.exams.count == 1 && importedOral.exams[0].flexible,
            "New opening-page oral exams default to flexible")
        precondition(StudyExamPlanner.parseStudentweb("TMA4100 Calculus\nMuntlig eksamen 10.12.2026 10:00–12:00").exams.first?.flexible == true)
        var importedFixed = importedOral.exams[0]
        importedFixed.id = "fixed-oral-import"; importedFixed.flexible = false; importedFixed.selected = true
        importedFixed.courseName = "Saved course name"
        let fixedRefresh = try StudyExamPlanner.importing(importedOral, into: [importedFixed])
        precondition(fixedRefresh == [importedFixed], "A matching Studentweb refresh must preserve explicit fixed timing on an oral exam")
        var repeatedOral = importedFixed
        repeatedOral.id = "flexible-oral-import"; repeatedOral.flexible = true; repeatedOral.selected = false
        var multiple = importedOral
        multiple.exams.append(importedOral.exams[0])
        let multipleRefresh = try StudyExamPlanner.importing(multiple, into: [importedFixed, repeatedOral])
        precondition(multipleRefresh == [importedFixed, repeatedOral],
            "Separate matching components preserve their own fixed/flexible overrides and selection independently")

        let conflicting = [fixed, explicitFixed]
        precondition(StudyExamPlanner.collisions(conflicting).count == 1)
        let flexible = try StudyExamPlanner.setFlexibleTiming(conflicting, id: explicitFixed.id, flexible: true)
        precondition(flexible == [fixed, oral] && StudyExamPlanner.collisions(flexible).isEmpty,
            "Ignoring a flexible overlap must retain both exams, their dates and their selections")
        let pair = StudyExamPlanAnalysis(conflicting).choices
        precondition(StudyExamPlanAnalysis(flexible).choices.isEmpty,
            "Marking flexible resolves and hides a pair when both exams are selected")
        let setAside = try StudyExamPlanner.setSelected(flexible, id: fixed.id, selected: false)
        precondition(StudyExamPlanAnalysis(setAside).choices == pair,
            "A set-aside fixed exam remains available alongside a flexible exam")
        let both = try StudyExamPlanner.setSelected(setAside, id: fixed.id, selected: true)
        precondition(both == flexible, "Choosing the fixed exam must keep the flexible exam selected")
        precondition(StudyExamPlanAnalysis(both).choices.isEmpty,
            "Selecting the remaining exam removes the resolved choice")
        let reopened = try JSONDecoder().decode([StudyExam].self, from: JSONEncoder().encode(both))
        precondition(StudyExamPlanAnalysis(reopened).choices.isEmpty && reopened.allSatisfy(\.selected),
            "Resolved flexible pairs stay hidden after reopening")
        let bothFlexible = try StudyExamPlanner.setFlexibleTiming(both, id: fixed.id, flexible: true)
        precondition(StudyExamPlanAnalysis(bothFlexible).choices.isEmpty)
        let flexibleSetAside = try StudyExamPlanner.setSelected(both, id: oral.id, selected: false)
        precondition(StudyExamPlanAnalysis(flexibleSetAside).choices == pair,
            "Either exam can still be selected independently")
        let neitherSelected = try StudyExamPlanner.setSelected(setAside, id: oral.id, selected: false)
        precondition(StudyExamPlanAnalysis(neitherSelected).choices.isEmpty)
        precondition(StudyExamPlanAnalysis([fixed]).choices.isEmpty)
        precondition((try? StudyExamPlanner.setSelected(both, id: "removed", selected: true)) == nil)
        var third = fixed; third.id = "third-fixed"; third.courseCode = "OTHER1000"
        let remaining = StudyExamPlanAnalysis(both + [third])
        precondition(remaining.conflicts == StudyExamPlanner.collisions([fixed, third]) && remaining.choices == remaining.conflicts,
            "Flexible choices do not hide other fixed-time clashes")
        let restored = try StudyExamPlanner.setFlexibleTiming(flexible, id: oral.id, flexible: false)
        precondition(restored == conflicting && StudyExamPlanner.collisions(restored).count == 1,
            "Reverting a timing override must restore the original overlap")
        precondition(StudyExamPlanAnalysis(restored).choices == pair,
            "Restoring fixed timing brings the choice back")
        precondition((try? StudyExamPlanner.setFlexibleTiming(flexible, id: "removed", flexible: false)) == nil)
        var uncertain = explicitFixed; uncertain.startTime = ""; uncertain.endTime = ""
        precondition(StudyExamPlanner.collisions([fixed, uncertain]).first?.possible == true)
        uncertain.flexible = true
        precondition(!uncertain.needsTiming && StudyExamPlanner.collisions([fixed, uncertain]).isEmpty
            && StudyExamPlanAnalysis([fixed, uncertain]).choices.isEmpty)
        var undated = uncertain; undated.date = ""
        let analyzed = StudyExamPlanAnalysis([fixed, undated])
        precondition(analyzed.selected.count == 2 && analyzed.flexibleCount == 1 && analyzed.unknown == 0
            && analyzed.conflicts.isEmpty && analyzed.byID[undated.id] == undated && analyzed.days[""] == [undated])
        let fixedAnalysis = StudyExamPlanAnalysis(conflicting)
        precondition(fixedAnalysis.conflictsByID[fixed.id] == fixedAnalysis.conflicts
            && fixedAnalysis.conflictsByID[oral.id] == fixedAnalysis.conflicts && fixedAnalysis.flexibleCount == 0)
        let courses = [StudyCourse(name: "Programming", code: fixed.courseCode), StudyCourse(name: "Calculus", code: oral.courseCode)]
        precondition(StudyExamPlanner.favoriteCourseIDs([fixed, undated], courses: courses) == Set(courses.map(\.id)),
            "Flexible exams may be selected alongside complete fixed exams without losing course favorites")

        // Cached row validation must react to edits/removals, while selection and timing overrides cannot hide invalid values.
        var cache = StudyExamValidationCache()
        cache.update(flexible)
        precondition(cache.valid && cache.errors.isEmpty)
        var invalid = oral; invalid.date = "2026-02-30"
        cache.update([fixed, invalid])
        precondition(!cache.valid && cache.errors[oral.id] != nil)
        let dateError = cache.errors[oral.id]
        invalid.selected = false; invalid.flexible = false
        cache.update([fixed, invalid])
        precondition(!cache.valid && cache.errors[oral.id] == dateError)
        invalid.date = oral.date
        cache.update([fixed, invalid])
        precondition(cache.valid && cache.errors.isEmpty, "Correcting an invalid date must clear the cached error")
        invalid.startTime = "25:00"
        cache.update([fixed, invalid])
        precondition(!cache.valid && cache.errors[oral.id] != nil)
        cache.update([fixed])
        precondition(cache.valid && cache.errors[oral.id] == nil, "Removing an invalid row must remove its cached error")
        cache.update([fixed, fixed])
        precondition(!cache.valid, "The cache must still reject duplicate identifiers")
        cache.update([fixed])
        precondition(cache.valid)
        invalid = oral; invalid.courseCode = ""; invalid.courseName = ""
        cache.update([fixed, invalid])
        precondition(!cache.valid && cache.errors[oral.id] != nil, "Name edits must invalidate validation too")
        cache.update([fixed, oral])
        precondition(cache.valid && cache.errors.isEmpty)

        let ranking = #"{"courseLimit":2,"rankedCourses":[{"courseKey":"TDT4100","reason":"Programming foundation."},{"courseKey":"TMA4100","reason":"Mathematical foundation."}]}"#
        let flexibleAdvice = try StudyExamRecommender.checked(ranking, exams: flexible)
        precondition(Set(flexibleAdvice.selectedExamIDs) == Set(flexible.map(\.id)) && flexibleAdvice.excluded.isEmpty)
        let fixedAdvice = try StudyExamRecommender.checked(ranking, exams: conflicting)
        precondition(fixedAdvice.selectedExamIDs == [fixed.id] && fixedAdvice.excluded.count == 1,
            "The recommender must respect an explicit fixed override even on an oral exam")
        let undatedAdvice = try StudyExamRecommender.checked(ranking, exams: [fixed, undated])
        precondition(Set(undatedAdvice.selectedExamIDs) == Set([fixed.id, undated.id]))
        undated.flexible = false
        let incompleteAdvice = try StudyExamRecommender.checked(ranking, exams: [fixed, undated])
        precondition(incompleteAdvice.selectedExamIDs == [fixed.id] && incompleteAdvice.excluded[0].reason.contains("missing"))
        let input = try StudyExamRecommender.input(.init(exams: [fixed, oral], interests: "Computing"), courses: courses)
        let request = try JSONSerialization.jsonObject(with: Data(input.utf8)) as! [String: Any]
        let requestCourses = request["courses"] as! [[String: Any]]
        let flags = requestCourses.flatMap { $0["exams"] as! [[String: Any]] }.map { $0["flexible"] as! Bool }
        precondition(flags == [false, true], "Recommendation input must explicitly include each timing override")

        var largePlan: [StudyExam] = []
        for index in 0..<91 {
            let date = String(format: "2026-12-%02d", index % 20 + 1)
            let startTime = String(format: "%02d:00", 9 + index % 4)
            let endTime = String(format: "%02d:00", 13 + index % 4)
            let exam = StudyExam(id: "performance-\(index)", courseCode: "PERF\(1000 + index)",
                date: date, startTime: startTime, endTime: endTime,
                selected: true, flexible: index % 7 == 0)
            largePlan.append(exam)
        }
        let analysisStart = Date.timeIntervalSinceReferenceDate
        var analyzedPairs = 0
        for _ in 0..<50 { analyzedPairs += StudyExamPlanAnalysis(largePlan).conflicts.count }
        let analysisMilliseconds = (Date.timeIntervalSinceReferenceDate - analysisStart) * 1000 / 50
        var largeCache = StudyExamValidationCache()
        largeCache.update(largePlan)
        precondition(largeCache.valid && analyzedPairs > 0)
        let cacheStart = Date.timeIntervalSinceReferenceDate
        var changes = largePlan
        for index in 0..<100 {
            changes[index % changes.count].selected.toggle()
            largeCache.update(changes)
        }
        let cacheMilliseconds = (Date.timeIntervalSinceReferenceDate - cacheStart) * 1000 / 100
        precondition(largeCache.valid && largeCache.errors.isEmpty)
        print(String(format: "Native 91-row timing: analysis %.3f ms; cached selection validation %.3f ms (%d pairs)",
            analysisMilliseconds, cacheMilliseconds, analyzedPairs / 50))
    }
}

private final class AssignmentResponseState: @unchecked Sendable {
    let lock = NSLock()
    var count = 0
    var conditional = false
    func next(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        conditional = conditional || request.value(forHTTPHeaderField: "If-None-Match") != nil
            || request.value(forHTTPHeaderField: "If-Modified-Since") != nil
        return count
    }
}
private final class ExamSmokeAssignmentProtocol: URLProtocol, @unchecked Sendable {
    static let state = AssignmentResponseState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "canvas.refresh.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let number = Self.state.next(request)
        let status = number == 1 ? "unsubmitted" : "submitted"
        let records: [[String: Any]] = [["id": 1, "name": "Exercise", "updated_at": "unchanged", "submission_types": ["online_upload"],
            "submission": ["workflow_state": status]]]
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "ETag": "unchanged", "Cache-Control": "max-age=3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: records))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
