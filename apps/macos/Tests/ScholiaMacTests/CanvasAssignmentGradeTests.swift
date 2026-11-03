import XCTest
@testable import ScholiaMac

final class CanvasAssignmentGradeTests: XCTestCase {
    private func details(_ submission: [String: Any] = [:], assignment: [String: Any] = [:]) -> CanvasAssignmentDetails {
        var record: [String: Any] = ["grading_type": "points", "points_possible": 10]
        record.merge(assignment) { _, new in new }
        var value: [String: Any] = ["workflow_state": "graded", "score": 0, "grade": "0"]
        value.merge(submission) { _, new in new }
        record["submission"] = value
        return CanvasAssignmentDetails(record: record)
    }

    func testZeroAndGradingSchemes() {
        XCTAssertEqual(details().gradeLabel, "0 / 10")
        XCTAssertEqual(details(["missing": true]).gradeLabel, "0 / 10")
        XCTAssertEqual(details(["missing": true]).status, .notSubmitted)
        XCTAssertEqual(details(["grade": "A-"], assignment: ["grading_type": "letter_grade"]).gradeLabel, "A-")
        XCTAssertEqual(details(["grade": "80%"], assignment: ["grading_type": "percent"]).gradeLabel, "80%")
        XCTAssertEqual(details(["grade": "complete"], assignment: ["grading_type": "pass_fail"]).gradeLabel, "Complete")
        XCTAssertEqual(details(["grade": "incomplete"], assignment: ["grading_type": "pass_fail"]).gradeLabel, "Incomplete")
        XCTAssertEqual(details(["grade_matches_current_submission": false]).gradeLabel, "0 / 10 (previous attempt)")
        XCTAssertNil(details(["score": false]).score)
        XCTAssertEqual(details(["score": "0"]).score, 0)
    }

    func testHiddenUnpostedAndExcusedGradesAreDiscarded() {
        for submission: [String: Any] in [["posted_at": NSNull()], ["grade_hidden": true], ["excused": true], ["assignment_visible": false]] {
            let value = details(submission)
            XCTAssertNil(value.grade)
            XCTAssertNil(value.score)
            XCTAssertNil(value.gradeLabel)
        }
        XCTAssertNil(details(assignment: ["post_manually": true]).gradeLabel)
        XCTAssertNil(details(assignment: ["muted": true]).gradeLabel)
        XCTAssertEqual(details(["posted_at": "2026-09-27T12:00:00Z"], assignment: ["post_manually": true]).gradeLabel, "0 / 10")
    }

    func testOldCachedAssignmentStillDecodesWithoutGradeFields() throws {
        let data = Data(#"{"submissionTypes":["online_upload"],"status":"graded","missing":false,"locked":false}"#.utf8)
        let value = try JSONDecoder().decode(CanvasAssignmentDetails.self, from: data)
        XCTAssertEqual(value.status, .graded)
        XCTAssertNil(value.gradeLabel)
        XCTAssertEqual(try JSONDecoder().decode(CanvasAssignmentDetails.self, from: JSONEncoder().encode(details())).gradeLabel, "0 / 10")
    }

    func testGradeOnlyRefreshUpdatesCatalogWithoutChangingDocumentVersion() {
        let prior = CanvasMaterialReference(id: "assignments:1", kind: .assignments, remoteID: "1", title: "Problem set", sourceURL: "https://canvas.example/courses/1/assignments/1", version: "unchanged", assignment: details())
        var latest = prior
        latest.assignment = details(["score": 9, "grade": "9"])
        let result = CanvasCatalogChanges.reconcile(previous: [prior], catalog: CanvasMaterialCatalog(items: [latest], warnings: [], completeKinds: [.assignments]))
        XCTAssertEqual(result.changes.updated, [prior.id])
        XCTAssertEqual(result.items.first?.assignment?.gradeLabel, "9 / 10")
        XCTAssertEqual(result.items.first?.version, prior.version)
    }
}
