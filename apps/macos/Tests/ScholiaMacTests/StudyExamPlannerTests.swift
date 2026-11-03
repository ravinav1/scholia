import Foundation
import XCTest
@testable import ScholiaMac

final class StudyExamPlannerTests: XCTestCase {
    func testExamSearchFindsCodeNameComponentAndDatesWithoutChangingPlan() {
        let first = StudyExam(id: "final", courseCode: "TDT-4100", courseName: "Programméring", date: "2026-12-15", selected: true)
        let second = StudyExam(id: "midterm", courseCode: "TDT4100", courseName: "Programming", component: "Midterm", kind: "midterm", date: "2026-10-15")
        let third = StudyExam(id: "math", courseCode: "TMA4100", courseName: "Matematikk", date: "2026-12-16", selected: true)
        let plan = [first, second, third]
        XCTAssertEqual(StudyExamSearch.filter(plan, query: " tdt 4100 ").map(\.id), ["final", "midterm"])
        XCTAssertEqual(StudyExamSearch.filter(plan, query: "TDT4100 final").map(\.id), ["final"])
        XCTAssertEqual(StudyExamSearch.filter(plan, query: "programmering 2026-12").map(\.id), ["final"])
        XCTAssertEqual(StudyExamSearch.filter(plan, query: "midterm").map(\.id), ["midterm"])
        XCTAssertTrue(StudyExamSearch.filter(plan, query: "missing").isEmpty)
        XCTAssertEqual(StudyExamSearch.filter(plan, query: "   "), plan)
        XCTAssertEqual(plan.map(\.selected), [true, false, true])
        XCTAssertEqual(StudyExamPlanAnalysis(plan).selected.count, 2)
    }

    func testAddExamSearchMergesLibraryAndCatalogCoursesWithoutInventingExamDates() {
        let library = [StudyCourse(name: "My programming course", code: "TDT4100-26H")]
        let catalog = [StudyPlanCatalog.Course(code: "TDT4100", version: "1", name: "Programming", credits: 7.5, kind: "course"),
            StudyPlanCatalog.Course(code: "TMA4100", version: "1", name: "Matematikk", credits: 7.5, kind: "course"),
            StudyPlanCatalog.Course(code: "CHOICE", version: nil, name: "Choose electives", credits: nil, kind: "requirement")]
        let options = StudyExamSearch.courses(library: library, catalog: catalog)
        XCTAssertEqual(options.map(\.code), ["TDT4100", "TMA4100"])
        XCTAssertEqual(options.first?.name, "My programming course")
        XCTAssertTrue(options.first?.inLibrary == true)
        XCTAssertEqual(options.filter { StudyExamSearch.matches($0.searchText, query: "matematikk") }.map(\.code), ["TMA4100"])
        let draft = StudyExam(courseCode: options[1].code, courseName: options[1].name)
        XCTAssertTrue(draft.date.isEmpty && draft.startTime.isEmpty && draft.endTime.isEmpty)
    }

    private func exam(_ id: String, date: String = "2026-12-15", start: String = "09:00", end: String = "13:00", selected: Bool = true) -> StudyExam {
        StudyExam(id: id, courseCode: "TDT4100", courseName: "Programming", component: "Final exam", date: date,
            startTime: start, endTime: end, selected: selected)
    }

    func testAdviceIncludesUnselectedOverlapsAndIncompleteExamsWithoutChangingIntent() throws {
        let first = exam("one")
        var second = exam("two", selected: false); second.courseCode = "TMA4100"
        var unknown = exam("unknown", start: "", end: "", selected: false); unknown.courseCode = "TFE4146"
        var flexible = exam("flexible"); flexible.flexible = true
        let exams = [first, second, unknown, flexible]
        let request = StudyExamRecommendationRequest(exams: exams, interests: "Which overlapping exam should I take?", mode: .advice)
        let input = try StudyExamRecommender.input(request, courses: [])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        let overlaps = try XCTUnwrap(payload["overlaps"] as? [[String: String]])
        XCTAssertEqual(payload["question"] as? String, request.interests)
        XCTAssertEqual(payload["overlapCount"] as? Int, 3)
        XCTAssertEqual(overlaps.filter { $0["status"] == "collision" }.count, 1)
        XCTAssertEqual(overlaps.filter { $0["status"] == "possible" }.count, 2)
        XCTAssertFalse(overlaps.contains { $0["firstId"] == "flexible" || $0["secondId"] == "flexible" })
        XCTAssertEqual(request.exams, exams)
        let courses = try XCTUnwrap(payload["courses"] as? [[String: Any]])
        let calculus = try XCTUnwrap(courses.first { $0["courseCode"] as? String == "TMA4100" })
        XCTAssertEqual((calculus["exams"] as? [[String: Any]])?.first?["selected"] as? Bool, false)
    }

    func testGeneralAdviceWorksWithoutExamsAndHasNoSelection() throws {
        let request = StudyExamRecommendationRequest(exams: [], interests: "How should I prioritize revision?", mode: .advice)
        XCTAssertNoThrow(try StudyExamRecommender.input(request, courses: []))
        XCTAssertThrowsError(try StudyExamRecommender.input(.init(exams: [], interests: "Help me choose"), courses: []))
        XCTAssertThrowsError(try StudyExamRecommender.input(.init(exams: [], interests: " ", mode: .advice), courses: []))
        let result = try StudyExamRecommender.checkedAdvice("  **Take A over B** for your programming goal.\n")
        XCTAssertEqual(result.advice, "**Take A over B** for your programming goal.")
        XCTAssertTrue(result.choices.isEmpty && result.excluded.isEmpty && result.selectedExamIDs.isEmpty)
        XCTAssertThrowsError(try StudyExamRecommender.checkedAdvice("  "))
        XCTAssertThrowsError(try StudyExamRecommender.checkedAdvice(String(repeating: "x", count: 200_001)))
        let legacy = try JSONDecoder().decode(StudyExamRecommendationRequest.self, from: Data(#"{"exams":[],"interests":"Robotics"}"#.utf8))
        XCTAssertNil(legacy.mode)
        XCTAssertThrowsError(try JSONDecoder().decode(StudyExamRecommendationRequest.self, from: Data(#"{"exams":[],"interests":"Robotics","mode":"unknown"}"#.utf8)))
    }

    func testLargePlanAndSpecificQuestionSurviveProviderSerialization() throws {
        let question = "Should i take the exam for TTK4100 or TFY4330, which is for MTTK first year and MTNANO third year respectively for the best progression?"
        let exams = (0..<500).map { index -> StudyExam in
            var row = exam("exam-\(index)", selected: index.isMultiple(of: 2))
            row.courseCode = index == 498 ? "TFY4330" : index == 499 ? "TTK4100" : "AAA\(1000 + index)"
            return row
        }
        for mode in [StudyExamRecommendationMode.advice, .selection] {
            let request = StudyExamRecommendationRequest(exams: exams, interests: question, mode: mode)
            let input = try StudyExamRecommender.input(request, courses: [])
            XCTAssertGreaterThan(input.utf16.count, PromptBuilder.maxMessageCharacters)
            let messages = try StudyExamRecommender.messages(request, courses: [])
            XCTAssertTrue(messages[0].content.contains(question), "The question must be explicit outside reference data")
            let prepared = try PromptBuilder.prepare(messages: messages, capture: nil, languagePreference: .english)
            for providerID in ["openai", "anthropic", "cohere", "ollama", "codex"] {
                let provider = ProviderCatalog.provider(id: providerID)
                let config = ProviderConfiguration(provider: provider, model: provider.defaultModel,
                    endpoint: provider.endpoint, apiKey: "fixture", language: .english, fastClaudeMode: false)
                let wire = try ProviderClient().buildRequest(prepared: prepared, configuration: config,
                    endpoint: XCTUnwrap(URL(string: provider.endpoint)))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(wire.httpBody)) as? [String: Any])
                let sent = try XCTUnwrap((body["messages"] as? [[String: Any]])?.last?["content"] as? String)
                XCTAssertTrue(sent.contains(question), "\(providerID) must retain the exact question")
                XCTAssertTrue(sent.contains(input), "\(providerID) must retain the complete, valid plan JSON")
            }
            XCTAssertEqual(request.exams, exams)
        }
    }

    func testOversizedReferenceFailsBeforeSendingPartialAdvice() throws {
        let exams = (0..<500).map { index -> StudyExam in
            var row = exam("exam-\(index)")
            row.courseCode = "AAA\(1000 + index)"
            row.courseName = String(repeating: "N", count: 180)
            row.component = String(repeating: "C", count: 120)
            return row
        }
        let request = StudyExamRecommendationRequest(exams: exams, interests: "Help me choose", mode: .advice)
        XCTAssertThrowsError(try StudyExamRecommender.messages(request, courses: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("too large to send in full"))
        }
        XCTAssertThrowsError(try StudyExamRecommender.messages(
            .init(exams: [], interests: String(repeating: "😀", count: 2001), mode: .advice), courses: []))
    }

    func testOverlapBoundariesSelectionAndUnknownTimes() {
        let first = exam("one")
        XCTAssertTrue(StudyExamPlanner.collisions([first, exam("two", start: "13:00", end: "15:00")]).isEmpty)
        XCTAssertTrue(StudyExamPlanner.collisions([first, exam("two", selected: false)]).isEmpty)
        XCTAssertTrue(StudyExamPlanner.collisions([first, exam("two", date: "2026-12-16", start: "", end: "")]).isEmpty)
        XCTAssertEqual(StudyExamPlanner.collisions([first, exam("two", start: "12:59", end: "15:00")]).first?.possible, false)
        XCTAssertEqual(StudyExamPlanner.collisions([first, exam("two", start: "", end: "")]).first?.possible, true)
        XCTAssertTrue(StudyExamPlanner.collisions([first, exam("two", date: "", start: "", end: "")]).isEmpty)
    }

    func testFollowUpsRetainLongAnswersAndValidateConversationRoles() throws {
        let history: [StudyExamAdviceMessage] = [
            .init(role: .user, content: "TTK4100 or TFY4330 for progression?"),
            .init(role: .assistant, content: String(repeating: "Original comparison. ", count: 700) + "FINAL DETAIL"),
            .init(role: .user, content: "My goal is MTTK."),
            .init(role: .assistant, content: "That changes the recommendation.")
        ]
        let request = StudyExamRecommendationRequest(exams: [exam("one")], interests: "Why that course?", mode: .advice, history: history)
        let input = try StudyExamRecommender.input(request, courses: [])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
        XCTAssertEqual(payload["question"] as? String, request.interests)
        let conversation = try XCTUnwrap(payload["conversation"] as? [[String: String]])
        XCTAssertEqual(conversation.map { $0["content"] }, history.map(\.content))
        let prepared = try PromptBuilder.prepare(messages: StudyExamRecommender.messages(request, courses: []), capture: nil, languagePreference: .english)
        XCTAssertTrue(prepared.messages[0].content.contains(input))
        XCTAssertTrue(prepared.messages[0].content.contains("FINAL DETAIL"))
        XCTAssertThrowsError(try StudyExamRecommender.checkedHistory(history, advice: false))
        XCTAssertThrowsError(try StudyExamRecommender.checkedHistory([history[0]], advice: true))
        XCTAssertThrowsError(try StudyExamRecommender.checkedHistory([history[1], history[0]], advice: true))
        XCTAssertThrowsError(try StudyExamRecommender.checkedHistory([history[0], .init(role: .assistant, content: String(repeating: "x", count: 160001))], advice: true))
    }

    func testPastDatesRespectOsloTodayAndMultiDayExams() {
        let today = "2026-10-10"
        XCTAssertTrue(StudyExamPlanner.isPast(exam("past", date: "2026-10-09"), today: today))
        XCTAssertFalse(StudyExamPlanner.isPast(exam("today", date: today), today: today))
        XCTAssertFalse(StudyExamPlanner.isPast(exam("unknown", date: "", start: "", end: ""), today: today))
        var ongoing = exam("ongoing", date: "2026-10-08"); ongoing.endDate = today
        XCTAssertFalse(StudyExamPlanner.isPast(ongoing, today: today))
        XCTAssertTrue(StudyExamPlanner.isPast(ongoing, today: "2026-10-11"))
        XCTAssertEqual(StudyExamPlanner.dayString(ISO8601DateFormatter().date(from: "2026-10-09T22:30:00Z")!), today)
    }

    func testFocusCoursesUseNextSelectedExamDate() {
        var late = exam("late", date: "2026-12-10"); late.courseCode = "LATE1000"
        var early = exam("early", date: "2026-11-01"); early.courseCode = "EARLY1000"
        var old = late; old.id = "past"; old.date = "2026-09-01"
        var unselected = late; unselected.id = "set-aside"; unselected.date = "2026-10-15"; unselected.selected = false
        var unknown = exam("unknown", date: "", start: "", end: ""); unknown.courseCode = "UNKNOWN1000"; unknown.flexible = true
        let courses = ["LATE1000", "UNKNOWN1000", "EARLY1000"].map { StudyCourse(name: $0, code: $0) }
        XCTAssertEqual(StudyExamPlanner.focusCourses([old, late, early, unknown, unselected], courses: courses, today: "2026-10-10").map(\.code),
            ["EARLY1000", "LATE1000", "UNKNOWN1000"])
    }

    func testOvernightAndLongExams() throws {
        var overnight = exam("night", start: "22:00", end: "02:00")
        XCTAssertThrowsError(try StudyExamPlanner.normalized([overnight]))
        overnight.endDate = "2026-12-16"
        XCTAssertNoThrow(try StudyExamPlanner.normalized([overnight]))
        XCTAssertEqual(StudyExamPlanner.collisions([overnight, exam("morning", date: "2026-12-16", start: "01:00", end: "03:00")]).first?.possible, false)
        XCTAssertTrue(StudyExamPlanner.collisions([overnight, exam("morning", date: "2026-12-16", start: "02:00", end: "03:00")]).isEmpty)
    }

    func testFlexibleComparisonDisappearsOnceBothExamsAreSelected() throws {
        let fixed = exam("written")
        var flexible = exam("oral")
        flexible.courseCode = "TMA4100"
        let original = [fixed, flexible]
        let pair = try XCTUnwrap(StudyExamPlanAnalysis(original).choices.first)
        let adjusted = try StudyExamPlanner.setFlexibleTiming(original, id: flexible.id, flexible: true)
        XCTAssertTrue(StudyExamPlanAnalysis(adjusted).conflicts.isEmpty)
        XCTAssertTrue(StudyExamPlanAnalysis(adjusted).choices.isEmpty, "Both selected exams fit, so no choice remains.")

        let setAside = try StudyExamPlanner.setSelected(adjusted, id: fixed.id, selected: false)
        XCTAssertEqual(StudyExamPlanAnalysis(setAside).choices, [pair], "The fixed exam stays available to choose.")
        let chosen = try StudyExamPlanner.setSelected(setAside, id: fixed.id, selected: true)
        XCTAssertEqual(chosen, adjusted, "Selecting the fixed exam must retain the flexible exam and its timing.")
        XCTAssertTrue(StudyExamPlanAnalysis(chosen).choices.isEmpty, "Selecting the remaining exam resolves the choice.")
        let reloaded = try JSONDecoder().decode([StudyExam].self, from: JSONEncoder().encode(chosen))
        XCTAssertTrue(StudyExamPlanAnalysis(reloaded).choices.isEmpty, "Resolved pairs stay hidden after reopening.")
        XCTAssertEqual(StudyExamPlanAnalysis(reloaded).selected.count, 2)

        let bothFlexible = try StudyExamPlanner.setFlexibleTiming(chosen, id: fixed.id, flexible: true)
        XCTAssertTrue(StudyExamPlanAnalysis(bothFlexible).choices.isEmpty)
        let flexibleSetAside = try StudyExamPlanner.setSelected(chosen, id: flexible.id, selected: false)
        XCTAssertEqual(StudyExamPlanAnalysis(flexibleSetAside).choices, [pair], "Either exam can still be selected independently.")
        let neitherSelected = try StudyExamPlanner.setSelected(setAside, id: flexible.id, selected: false)
        XCTAssertTrue(StudyExamPlanAnalysis(neitherSelected).choices.isEmpty)

        let reverted = try StudyExamPlanner.setFlexibleTiming(chosen, id: flexible.id, flexible: false)
        XCTAssertEqual(StudyExamPlanAnalysis(reverted).conflicts, [pair])
        XCTAssertEqual(StudyExamPlanAnalysis(reverted).choices, [pair], "Restoring fixed timing brings the choice back.")
        XCTAssertTrue(StudyExamPlanAnalysis([chosen[0]]).choices.isEmpty)
        XCTAssertThrowsError(try StudyExamPlanner.setSelected(chosen, id: "removed", selected: true))

        var third = exam("third"); third.courseCode = "TFE4100"
        let remaining = StudyExamPlanAnalysis(chosen + [third])
        XCTAssertEqual(remaining.conflicts, StudyExamPlanner.collisions([fixed, third]), "Unrelated fixed overlaps still need resolving.")
        XCTAssertEqual(remaining.choices, remaining.conflicts, "Only the remaining fixed-time overlap needs a choice.")
    }

    func testIndividualCourseExamSelectionPreservesOtherComponents() throws {
        var midterm = exam("midterm", date: "2026-10-09", start: "09:00", end: "11:00")
        midterm.courseCode = "TTK4250"; midterm.component = "Midterm"; midterm.kind = "midterm"
        var final = exam("final", date: "2026-12-10", start: "15:00", end: "19:00")
        final.courseCode = midterm.courseCode
        var other = final; other.id = "other"; other.courseCode = "OTHER1000"
        let original = [final, other, midterm]
        XCTAssertEqual(StudyExamPlanner.collisions(original).count, 1)

        let midtermOnly = try StudyExamPlanner.setSelected(original, id: final.id, selected: false)
        var expectedFinal = final; expectedFinal.selected = false
        XCTAssertEqual(midtermOnly, [expectedFinal, other, midterm], "Selecting only a midterm leaves its final and other courses intact.")
        XCTAssertTrue(StudyExamPlanAnalysis(midtermOnly).conflicts.isEmpty, "An unselected final does not create a clash.")
        XCTAssertEqual(try JSONDecoder().decode([StudyExam].self, from: JSONEncoder().encode(midtermOnly)), midtermOnly)

        let neither = try StudyExamPlanner.setSelected(midtermOnly, id: midterm.id, selected: false)
        let finalOnly = try StudyExamPlanner.setSelected(neither, id: final.id, selected: true)
        XCTAssertEqual(finalOnly.filter { $0.courseKey == midterm.courseKey && $0.selected }.map(\.id), [final.id])
        XCTAssertEqual(StudyExamPlanAnalysis(finalOnly).conflicts.count, 1)
        XCTAssertEqual(finalOnly.first(where: { $0.id == other.id }), other)

        let refreshed = try StudyExamPlanner.importing(StudyExamImport(exams: [midterm, final]), into: midtermOnly)
        XCTAssertEqual(refreshed, midtermOnly, "Refreshing the same exam dates preserves the individual selections.")
    }

    func testStrictValidationDoesNotNormalizeImpossibleDates() throws {
        XCTAssertNil(StudyExamPlanner.day("2026-02-29"))
        XCTAssertNotNil(StudyExamPlanner.day("2028-02-29"))
        XCTAssertThrowsError(try StudyExamPlanner.normalized([exam("bad", date: "2026-02-30")]))
        XCTAssertThrowsError(try StudyExamPlanner.normalized([exam("bad", start: "24:00")]))
        XCTAssertThrowsError(try StudyExamPlanner.normalized([exam("one"), exam("one")]))
        XCTAssertThrowsError(try StudyExamPlanner.normalized((0...500).map { exam(String($0)) }))
        var bad = exam("bad")
        bad.endDate = "2026-12-14"
        XCTAssertThrowsError(try StudyExamPlanner.normalized([bad]))
    }

    func testStudentwebPreviewGroupsComponentsWithoutRetainingPersonalDetails() throws {
        let imported = StudyExamPlanner.parseStudentweb("""
        Studentnummer: 123456
        TDT4100 Object-oriented programming
        Midterm 15.10.2026 09:00–11:00
        Final exam 15.12.2026 09:00–13:00
        E-post: private@example.com
        TMA4115 Calculus
        Skriftlig skoleeksamen
        16.12.2026
        09:00 - 13:00
        """)
        XCTAssertEqual(imported.exams.count, 3)
        XCTAssertEqual(imported.exams.map(\.kind), ["midterm", "final", "final"])
        XCTAssertEqual(imported.exams.map(\.courseCode), ["TDT4100", "TDT4100", "TMA4115"])
        XCTAssertTrue(imported.exams.allSatisfy { !$0.selected && $0.source == "studentweb" })
        XCTAssertEqual(imported.exams.last?.endTime, "13:00")
        XCTAssertNoThrow(try StudyExamPlanner.normalized(imported.exams))
        let encoded = String(data: try JSONEncoder().encode(imported.exams), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("private@example.com"))
        XCTAssertFalse(encoded.contains("123456"))
        XCTAssertTrue(StudyExamPlanner.parseStudentweb("Exam 15.12.2026 09:00–13:00").exams.isEmpty)
    }

    func testLibraryRoundTripAndExistingLibraries() throws {
        var library = StudyLibrary()
        library.examPlan = [exam("one")]
        let reopened = try JSONDecoder().decode(StudyLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertEqual(reopened.examPlan, library.examPlan)
        library.examPlan = nil
        let older = try JSONDecoder().decode(StudyLibrary.self, from: JSONEncoder().encode(library))
        XCTAssertNil(older.examPlan)
    }

    @MainActor func testStaleSaveCannotOverwriteAnotherSurface() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        let initial = exam("one")
        try model.replaceExamPlan([initial], base: [])
        XCTAssertThrowsError(try model.replaceExamPlan([], base: []))
        XCTAssertEqual(model.library.examPlan, [initial])
        var invalid = initial
        invalid.date = "2026-02-30"
        XCTAssertThrowsError(try model.replaceExamPlan([invalid], base: [initial]))
        XCTAssertEqual(model.library.examPlan, [initial])
        model.flush()
        XCTAssertEqual(try model.store.load().examPlan, [initial])
    }

    @MainActor func testChoicesKeepCourseComponentsTogetherAndFavoriteOnlyClearSelections() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        let programming = StudyCourse(name: "Programming", code: "TDT4100-26H")
        let calculus = StudyCourse(name: "Calculus", code: "TMA4100")
        model.library.courses = [programming, calculus]
        let midterm = exam("midterm", date: "2026-10-10")
        let final = exam("final")
        var other = exam("calculus"); other.courseCode = "TMA4100"
        let initial = [midterm, final, other]
        try model.replaceExamPlan(initial, base: [])
        XCTAssertFalse(model.library.courses.contains(where: \.isFavorite))
        let chosen = try StudyExamPlanner.resolveConflict(initial, keep: other.id, drop: final.id)
        XCTAssertEqual(chosen.map(\.selected), [false, false, true])
        try model.replaceExamPlan(chosen, base: initial)
        XCTAssertFalse(model.library.courses[0].isFavorite)
        XCTAssertTrue(model.library.courses[1].isFavorite)
        XCTAssertThrowsError(try StudyExamPlanner.resolveConflict(chosen, keep: other.id, drop: final.id))
        model.flush()
        XCTAssertTrue(try model.store.load().courses[1].isFavorite)
    }
}
