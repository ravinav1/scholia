@preconcurrency import AppKit
import PDFKit
import SwiftUI

@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func previewAssignmentAgenda() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-agenda-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let materials = (-180...15).map { offset in
            let day = Calendar.current.date(byAdding: .day, value: Int(floor(Double(offset) / 3)), to: now)!
            let due = Calendar.current.date(bySettingHour: [9, 22, 23][abs(offset % 3)], minute: 59, second: 59, of: day)!
            let id = String(offset + 200)
            var title = due > now ? "Upcoming exercise \(id)" : "Earlier exercise \(id)"
            if offset % 4 == 0 { title += " — matrix transformations and eigenvectors" }
            return CanvasMaterialReference(id: "assignments:\(id)", kind: .assignments, remoteID: id,
                title: title, sourceURL: "https://canvas.example/assignments/\(id)", version: "v1",
                assignment: CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
                    "due_at": ISO8601DateFormatter().string(from: due), "submission": ["workflow_state": "unsubmitted"]]))
        }
        let course = StudyCourse(name: "Linear algebra", code: "TMA4115", canvasID: 1,
            canvasMaterials: materials, catalogUpdatedAt: now)
        var library = StudyLibrary(courses: [course], canvasAssignmentsError: "Some Canvas statuses could not be refreshed. Retrying automatically.")
        if CommandLine.arguments.contains("--agenda-current-library") {
            library = try StudyLibraryStore().load()
            library.selectedDocumentID = nil
            library.selectedCourseID = nil
            for index in library.courses.indices {
                library.courses[index].documents = []
                library.courses[index].threads = []
            }
        }
        try store.save(library)
        let workspace = StudyWorkspaceModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 370, height: 720),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: StudyAssignmentAgendaView(workspace: workspace)
            .background(StudyPalette.paper(true)).environment(\.colorScheme, .dark)
            .tint(StudyPalette.accent).accentColor(StudyPalette.accent))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        try snapshot(window, at: output.appendingPathComponent("assignment-agenda.png"))
        // Refreshes and narrower windows must not leave invisible upcoming rows.
        if !CommandLine.arguments.contains("--agenda-current-library") {
            let upcoming = materials.firstIndex { ($0.assignment?.dueDate ?? .distantPast) > now }!
            workspace.library.courses[0].canvasMaterials?[upcoming].title += " — updated"
        }
        window.setContentSize(NSSize(width: 300, height: 650))
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(window, at: output.appendingPathComponent("assignment-agenda-compact.png"))
        window.orderOut(nil)
        print("PASS: assignment agenda previews with past and upcoming deadlines, refresh and compact sizing")
    }

    static func previewCanvasNewFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-new-files-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let refs = [1, 2, 3].map { id in
            CanvasMaterialReference(id: "files:\(id)", kind: .files, remoteID: String(id), title: "Lecture \(id) notes",
                fileName: "lecture-\(id).pdf", sourceURL: "https://canvas.example/courses/1/files/\(id)", version: "v1")
        }
        let course = StudyCourse(name: "Sensor fusion", code: "TTK4250-26H", canvasID: 1,
            canvasOrigin: "https://canvas.example", canvasMaterials: refs, catalogUpdatedAt: Date(), term: "2026 HØST",
            canvasFileSync: CanvasCourseFileSync(knownFileIDs: refs.map(\.id), pendingFileIDs: ["files:3"],
                checkedAt: Date(), summary: "1 new file waiting to download."))
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id))
        let workspace = StudyWorkspaceModel(store: store)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = NSHostingView(rootView: StudyCourseMaterialsView(workspace: workspace, course: course, askCourse: {})
                .background(StudyPalette.paper(dark)).environment(\.colorScheme, dark ? .dark : .light))
            try await Task.sleep(for: .milliseconds(250))
            try snapshot(window, at: output.appendingPathComponent("canvas-new-files-\(dark ? "dark" : "light").png"))
        }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.contentView = NSHostingView(rootView: StudyCourseLibraryView(workspace: workspace, createCourse: {})
            .background(StudyPalette.paper(true)).environment(\.colorScheme, .dark))
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, at: output.appendingPathComponent("canvas-new-files-library.png"))
        window.orderOut(nil)
        print("PASS: new-file course controls, queue badge and native library previews")
    }

    static func previewAssignmentFeedback() async throws {
        AssignmentFixtureProtocol.state.revision = 1
        let client = try assignmentClient()
        let catalog = try await client.catalog(courseID: 1)
        let reference = catalog.items.first { $0.remoteID == "3" }!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-feedback-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var course = StudyCourse(name: "Nonlinear systems", code: "TTK4215-26H", canvasOrigin: "https://canvas.example",
            canvasMaterials: [reference], term: "2026 HØST")
        var instructions = try StudyDocumentImporter.read(data: Data("# Assignment 5\n\nUse the state model to explain the covariance update.".utf8), name: "Assignment.md", store: store)
        instructions.sourceKey = reference.id
        course.documents = [instructions]
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, selectedAssignmentID: reference.id))
        let workspace = StudyWorkspaceModel(store: store)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let dark = name == "dark"
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView: StudyAssignmentFeedbackView(workspace: workspace,
                courseID: course.id, assignmentID: reference.id).padding(18)
                .background(StudyPalette.paper(dark)).environment(\.colorScheme, dark ? .dark : .light))
            try await Task.sleep(for: .milliseconds(250))
            try snapshot(window, at: output.appendingPathComponent("assignment-feedback-\(name).png"))
        }
        window.setContentSize(NSSize(width: 650, height: 700))
        window.contentView = NSHostingView(rootView: StudyAssignmentPageView(workspace: workspace, assignment: reference)
            .background(StudyPalette.paper(true)).environment(\.colorScheme, .dark))
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, at: output.appendingPathComponent("assignment-feedback-overview.png"))
        window.orderOut(nil)
        print("PASS: feedback comments, file controls and rubric native light/dark previews")
    }

    static func previewAssignmentStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-status-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let details = CanvasAssignmentDetails(record: ["submission_types": ["online_upload"],
            "due_at": "2026-09-22T21:59:59Z", "submission": ["workflow_state": "submitted"]])
        let a = CanvasMaterialReference(id: "assignments:3", kind: .assignments, remoteID: "3", title: "Assignment 3",
            sourceURL: "https://canvas.example/courses/1/assignments/3", version: "", assignment: details)
        var b = a
        b.id = "assignments:5"; b.remoteID = "5"; b.title = "Assignment 5"
        b.assignment?.dueAt = "2026-09-25T21:59:59Z"
        let courses = [
            StudyCourse(name: "Sensor Fusion", code: "TTK4250-26H", canvasMaterials: [a], term: "2026 HØST",
                assignmentProgress: [a.id: .handedIn]),
            StudyCourse(name: "Nonlinear Systems", code: "TTK4215-26H", canvasMaterials: [b], term: "2026 HØST",
                assignmentProgress: [b.id: .feedback])]
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: courses))
        let workspace = StudyWorkspaceModel(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.orderFront(nil)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let dark = name == "dark"
            window.appearance = NSAppearance(named: appearance)
            window.contentView = NSHostingView(rootView: StudyAssignmentsPageView(workspace: workspace)
                .background(StudyPalette.paper(dark)).environment(\.colorScheme, dark ? .dark : .light)
                .tint(StudyPalette.accent).accentColor(StudyPalette.accent))
            try await Task.sleep(for: .milliseconds(250))
            try snapshot(window, at: output.appendingPathComponent("assignment-status-\(name).png"))
        }
        window.setContentSize(NSSize(width: 390, height: 740))
        window.contentView = NSHostingView(rootView: StudyAssignmentAgendaView(workspace: workspace, initialFilter: .all)
            .background(StudyPalette.paper(true)).environment(\.colorScheme, .dark)
            .tint(StudyPalette.accent).accentColor(StudyPalette.accent))
        try await Task.sleep(for: .milliseconds(250))
        try snapshot(window, at: output.appendingPathComponent("assignment-status-compact.png"))
        window.orderOut(nil)
        print("PASS: assignment status light, dark and compact native previews")
    }

    static func checkCanvasFavorites() async throws {
        CanvasFixtureProtocol.state.revision = 1
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CanvasFixtureProtocol.self]
        let client = CanvasClient(
            origin: try CanvasAddress.origin("canvas.ntnu.no"), token: "fixture-token",
            session: URLSession(configuration: config))
        let remote = try await client.courses()
        precondition(remote.first { $0.id == 12 }?.favorite == true, "Canvas stars must survive course pagination")
        precondition(remote.first { $0.id == 11 }?.favorite == nil, "Omitted favorite metadata must remain unknown")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-favorites-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        let canvasCourse = workspace.library.courses.first { $0.canvasID == 12 }!
        let localCourse = workspace.library.courses.first { $0.canvasID == 11 }!
        precondition(canvasCourse.isFavorite && canvasCourse.favorite == nil && canvasCourse.canvasFavorite == true)
        workspace.toggleFavorite(canvasCourse.id)
        workspace.toggleFavorite(localCourse.id)
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(
            workspace.library.courses.first { $0.id == canvasCourse.id }?.isFavorite == false,
            "A local unstar must survive Canvas refresh")
        precondition(
            workspace.library.courses.first { $0.id == localCourse.id }?.isFavorite == true,
            "A local favorite must survive Canvas refresh")
        let ci = workspace.library.courses.firstIndex { $0.id == canvasCourse.id }!
        workspace.library.courses[ci].favorite = nil
        CanvasFixtureProtocol.state.revision = 2
        workspace.loadCanvasCourses(clientOverride: client)
        for _ in 0..<500 where workspace.canvasBusy { try await Task.sleep(for: .milliseconds(20)) }
        precondition(
            !workspace.library.courses[ci].isFavorite,
            "Courses without a local override must follow a removed Canvas star")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: workspace.store)
        precondition(reopened.library.courses.first { $0.id == localCourse.id }?.isFavorite == true)
        precondition(reopened.library.courses[ci].canvasFavorite == false)
        CanvasFixtureProtocol.state.revision = 1
        print("PASS: Canvas favorites import, pagination, local overrides, remote changes and persistence")
    }

    static func assignmentClient() throws -> CanvasClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AssignmentFixtureProtocol.self]
        return CanvasClient(
            origin: try CanvasAddress.origin("canvas.example"), token: "fixture-token",
            session: URLSession(configuration: config))
    }

    static func checkAssignmentProgress() throws {
        func details(_ submission: [String: Any]) -> CanvasAssignmentDetails {
            CanvasAssignmentDetails(record: ["submission_types": ["online_upload"], "grading_type": "points",
                "points_possible": 1, "submission": submission])
        }
        var submission: [String: Any] = ["workflow_state": "graded", "submitted_at": "2026-09-22T12:00:00Z",
            "posted_at": NSNull(), "score": 1, "grade": "1", "grade_matches_current_submission": true,
            "user_id": 42, "attempt": 2, "submission_comments": [[String: Any]]()]
        let awaiting = details(submission)
        precondition(awaiting.status == .submitted && awaiting.gradeLabel == nil && !awaiting.hasFeedback,
            "TTK4250-style hidden workflow grades must remain handed in awaiting a result")
        submission["posted_at"] = "2026-09-25T12:00:00Z"
        submission["submission_comments"] = [["author_id": 99, "comment": "Reviewed", "attempt": 2,
            "created_at": "2026-09-25T12:00:00Z"]]
        let graded = details(submission)
        precondition(graded.status == .graded && graded.gradeLabel == "1 / 1" && graded.hasFeedback,
            "A posted grade and feedback must be distinct from a submission receipt")
        submission["grade_matches_current_submission"] = false
        precondition(details(submission).status == .submitted && details(submission).gradeLabel == "1 / 1 (previous attempt)")
        submission["grade_matches_current_submission"] = true
        for comment: [String: Any] in [
            ["author_id": 42, "comment": "Student note", "attempt": 2],
            ["author_id": 99, "comment": "Old attempt", "attempt": 1],
            ["author_id": 99, "comment": "Earlier feedback", "created_at": "2026-09-21T12:00:00Z"],
            ["author_id": 99, "comment": "Hidden", "hidden": true],
            ["author_id": 99, "comment": "Draft", "draft": true]
        ] {
            submission["submission_comments"] = [comment]
            precondition(!details(submission).hasFeedback, "Student notes and unpublished/earlier feedback are not new feedback")
        }
        submission["submission_comments"] = [["author_id": 99, "attachments": [["id": 5]], "attempt": 2]]
        precondition(details(submission).hasFeedback)
        submission["submission_comments"] = [["author_id": 99, "media_comment": ["media_type": "audio"], "attempt": 2]]
        precondition(details(submission).hasFeedback)
        submission["submission_comments"] = [[String: Any]]()
        submission["rubric_assessment"] = ["criterion": ["points": 1, "comments": "Reviewed"]]
        precondition(details(submission).hasFeedback, "A visible rubric assessment is feedback")
        submission["grade_matches_current_submission"] = false
        precondition(!details(submission).hasFeedback, "An old rubric is not feedback on a new attempt")
        submission["grade_matches_current_submission"] = true
        submission["grade_hidden"] = true
        precondition(!details(submission).hasFeedback, "Hidden rubric results must stay hidden")
        submission["grade_hidden"] = false
        submission["score"] = 0; submission["grade"] = "0"
        precondition(details(submission).status == .graded && details(submission).gradeLabel == "0 / 1")
        submission["missing"] = true; submission.removeValue(forKey: "submitted_at")
        precondition(details(submission).status == .notSubmitted, "An automatic missing zero does not prove submission")
        let old = Data(#"{"submissionTypes":["online_upload"],"status":"graded","missing":false,"locked":false,"gradeVisible":false}"#.utf8)
        let oldDetails = try JSONDecoder().decode(CanvasAssignmentDetails.self, from: old)
        precondition(oldDetails.status == .submitted,
            "Existing libraries must stop presenting withheld grades as finished work")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-assignment-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = CanvasMaterialReference(id: "assignments:3", kind: .assignments, remoteID: "3", title: "Assignment 3",
            sourceURL: "https://canvas.example/courses/1/assignments/3", version: "unchanged", assignment: awaiting)
        let course = StudyCourse(name: "Estimation", code: "TTK4250", canvasMaterials: [reference], term: "2026 HØST")
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course]))
        let workspace = StudyWorkspaceModel(store: store)
        workspace.setAssignmentProgress(.feedback, id: reference.id, courseID: course.id)
        let corrected = workspace.library.courses[0].materials[0].assignment!
        precondition(corrected.status == .graded && corrected.hasFeedback && corrected.gradeLabel == nil)
        precondition(StudyAssignmentGroup.make(courses: workspace.library.courses, filter: .handedIn).isEmpty)
        precondition(StudyAssignmentGroup.make(courses: workspace.library.courses, filter: .graded).flatMap(\.items).count == 1)
        let encoded = try JSONEncoder().encode(corrected)
        let canvasCopy = try JSONDecoder().decode(CanvasAssignmentDetails.self, from: encoded)
        precondition(canvasCopy.status == .submitted && !canvasCopy.hasFeedback,
            "A local correction must never masquerade as Canvas metadata")
        workspace.library.courses[0].canvasMaterials = [reference]
        precondition(workspace.library.courses[0].materials[0].assignment?.status == .graded,
            "A Canvas refresh must preserve the user's local correction")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: store)
        precondition(reopened.library.courses[0].materials[0].assignment?.hasFeedback == true)
        reopened.setAssignmentProgress(.handedIn, id: reference.id, courseID: course.id)
        precondition(reopened.library.courses[0].materials[0].assignment?.status == .submitted)
        precondition(reopened.library.courses[0].materials[0].assignment?.hasFeedback == false)
        precondition(StudyAssignmentGroup.make(courses: reopened.library.courses, filter: .handedIn).flatMap(\.items).count == 1)
        precondition(StudyAssignmentGroup.make(courses: reopened.library.courses, filter: .due).isEmpty)
        reopened.setAssignmentProgress(nil, id: reference.id, courseID: course.id)
        precondition(reopened.library.courses[0].materials[0].assignment?.progressOverride == nil)
        reopened.flush()
        let cleared = try store.load()
        precondition(cleared.courses[0].assignmentProgress == nil)
        print("PASS: submitted versus graded work, hidden and previous grades, real feedback, local corrections, sync and persistence")
    }

    static func checkAssignmentFeedback() async throws {
        AssignmentFixtureProtocol.state.revision = 1
        defer { AssignmentFixtureProtocol.state.revision = 1 }
        AssignmentFixtureProtocol.attachments.set(data: try fixturePDF(), fail: false)
        let client = try assignmentClient()
        let catalog = try await client.catalog(courseID: 1)
        let reference = catalog.items.first { $0.remoteID == "3" }!
        let feedback = reference.assignment!.feedback!
        precondition(feedback.comments.count == 1 && feedback.comments[0].author == "Course instructor")
        precondition(feedback.comments[0].text.contains("\nPlease justify"))
        precondition(feedback.attachments.map(\.id) == ["506"] && feedback.attachments[0].name == "Assignment feedback.pdf")
        precondition(feedback.rubric.first?.title == "Reasoning" && feedback.rubric.first?.scoreLabel == "8 / 10"
            && feedback.rubric.first?.rating == "Good understanding" && feedback.rubric.first?.comment?.contains("positive") == true)
        let serialized = String(decoding: try JSONEncoder().encode(feedback), as: UTF8.self)
        precondition(!serialized.contains("never-persist") && !serialized.contains("Hidden feedback sentinel")
            && !serialized.contains("Student submission note"), "Save feedback without signed download links or hidden/student comments")
        let decoded = try JSONDecoder().decode(CanvasAssignmentFeedback.self, from: Data(serialized.utf8))
        precondition(decoded == feedback)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-feedback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let course = StudyCourse(name: "Feedback course", code: "TTK4215-26H", canvasID: 1,
            canvasOrigin: "https://canvas.example", canvasUserID: 42, canvasMaterials: [reference],
            assignmentProgress: [reference.id: .feedback])
        try store.save(StudyLibrary(courses: [course], canvasOrigin: "https://canvas.example", canvasUserID: 42))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        workspace.openAssignment(reference, courseID: course.id, clientOverride: client)
        for _ in 0..<500 where workspace.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.assignmentPreparing && workspace.assignmentFiles.isEmpty)
        precondition(workspace.assignmentFeedbackFiles.map(\.remoteID) == ["506"] && workspace.document == nil,
            "Feedback attachments must stay separate from instructions and download only when opened")
        workspace.draft = "Keep this feedback question"
        workspace.saveDraft()
        workspace.openAssignmentFile("files:506")
        for _ in 0..<500 where workspace.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.assignmentPreparing && workspace.assignment?.id == reference.id
            && workspace.document?.kind == .pdf && workspace.document?.sourceKey == "files:506",
            "Open must download feedback through the protected file endpoint and display it in the native assignment reader")
        precondition(workspace.draft == "Keep this feedback question")
        precondition(AssignmentFixtureProtocol.state.paths.contains("https://canvas.example/api/v1/files/506"))
        workspace.flush()
        let saved = try store.load()
        precondition(saved.courses[0].materials[0].assignment?.feedback == feedback)
        let reopened = StudyWorkspaceModel(store: store)
        let count = AssignmentFixtureProtocol.state.paths.count
        reopened.openAssignmentFile("files:506")
        for _ in 0..<500 where reopened.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!reopened.assignmentPreparing && reopened.document?.sourceKey == "files:506"
            && AssignmentFixtureProtocol.state.paths.count == count, "Saved feedback files must reopen offline without authentication")
        AssignmentFixtureProtocol.state.revision = 2
        await workspace.refreshAssignmentFeedback(courseID: course.id, assignmentID: reference.id, force: true, clientOverride: client)
        precondition(workspace.assignment?.assignment?.feedback?.comments.first?.text.hasPrefix("Follow-up:") == true)
        precondition(workspace.assignment?.assignment?.progressOverride == .feedback && workspace.assignment?.version == reference.version)
        let current = workspace.assignment!.assignment!
        let partial = CanvasAssignmentDetails(record: ["submission_types": ["online_upload"], "submission": ["workflow_state": "submitted"]])
        precondition(partial.retainingFeedback(from: current).feedback == current.feedback,
            "Missing optional submission details must not erase previously downloaded feedback")
        let resubmitted = CanvasAssignmentDetails(record: ["submission_types": ["online_upload"], "submission": [
            "workflow_state": "submitted", "attempt": 2, "submitted_at": "2026-09-29T12:00:00Z",
            "grade_matches_current_submission": false]])
        let retainedEarlier = resubmitted.retainingFeedback(from: current)
        precondition(retainedEarlier.feedback?.comments.first?.currentAttempt == false
            && retainedEarlier.feedback?.rubric.isEmpty == true && retainedEarlier.feedbackAvailable == false,
            "Preserved comments from a previous attempt remain readable without claiming new feedback")
        var removed = current
        removed.feedback?.comments = []
        removed.feedback?.rubric = []
        precondition(removed.retainingFeedback(from: current).feedback?.isEmpty == true,
            "An explicit empty response must clear feedback that was removed in Canvas")
        workspace.flush()
        print("PASS: feedback comments, rubric results, private attachments, metadata-only updates, native PDF opening and offline persistence")
    }

    static func checkAssignments() async throws {
        try checkAssignmentProgress()
        try await checkAssignmentFeedback()
        let client = try assignmentClient()
        AssignmentFixtureProtocol.state.revision = 1
        AssignmentFixtureProtocol.state.reset()
        let catalog = try await client.catalog(courseID: 1)
        precondition(catalog.warnings.isEmpty && catalog.completeKinds.contains(.assignments))
        precondition(
            catalog.items.filter { $0.kind == .assignments }.count == 8,
            "Pagination must include every visible assignment, including locked work")
        precondition(AssignmentFixtureProtocol.state.paths.contains { $0.contains("page=2") })
        var course = StudyCourse(
            name: "Linear algebra", code: "MATH101", canvasID: 1, canvasOrigin: "https://canvas.example",
            canvasMaterials: catalog.items, catalogUpdatedAt: Date(), term: "2026 HØST")
        let pending = StudyAssignment.list(courses: [course])
        precondition(pending.map(\.material.remoteID) == ["2", "9", "1", "7"])
        precondition(StudyAssignment.list(courses: [course], includeCompleted: true).count == 6)
        precondition(StudyAssignment.list(courses: [course], query: "MATH101").count == 4)
        precondition(StudyAssignment.list(courses: [course], query: "Exercise 9").count == 1)
        var anotherCourse = course
        anotherCourse.id = UUID()
        anotherCourse.code = "CS101"
        anotherCourse.term = "2025 HØST"
        anotherCourse.canvasMaterials = [catalog.items.first { $0.remoteID == "9" }!]
        let dashboard = StudyAssignment.list(courses: [course, anotherCourse], dueOnly: true)
        precondition(
            dashboard.count == 4 && Set(dashboard.map(\.id)).count == 4,
            "Dashboard deadlines span every workspace without conflating assignment IDs")
        precondition(
            dashboard.first?.material.remoteID == "2" && dashboard.last?.material.remoteID == "1",
            "Overdue and upcoming work stays in deadline order")
        precondition(
            dashboard.allSatisfy { $0.dueDate != nil && $0.details?.status.isComplete == false },
            "The dashboard excludes undated and completed work")
        let locked = catalog.items.first { $0.remoteID == "1" }!
        precondition(locked.assignment?.dueAt == "2026-09-29T12:00:00+02:00")
        precondition(locked.unavailableReason == "Locked in Canvas")
        let now = CanvasAssignmentDetails.date("2026-09-27T10:00:00.000Z")!
        let groups = StudyAssignmentGroup.make(courses: [course, anotherCourse], now: now)
        precondition(groups.map { $0.semester.id } == ["2026-autumn", "2026-autumn", "2025-autumn"])
        precondition(groups.map { $0.items.map(\.material.remoteID) } == [["2"], ["9", "1"], ["9"]])
        precondition(groups.map(\.timeframe) == [.overdue, .upcoming, .upcoming])
        let timeline = StudyAssignmentTimeline(groups: groups)
        let upcomingDates = timeline.upcoming.flatMap(\.items).compactMap(\.dueDate)
        precondition(upcomingDates == upcomingDates.sorted(), "The timeline interleaves semesters in date order")
        let archived = StudyAssignmentGroup.make(courses: [course], filter: .archive, now: now).flatMap(\.items)
        precondition(
            archived.map(\.material.remoteID) == ["3", "4", "7"], "Undated and completed work belongs in Archive")
        let handedIn = StudyAssignmentGroup.make(courses: [course], filter: .handedIn, now: now).flatMap(\.items)
        precondition(handedIn.isEmpty, "Handed in awaiting a grade must exclude graded work")
        let gradedItems = StudyAssignmentGroup.make(courses: [course], filter: .graded, now: now).flatMap(\.items)
        precondition(gradedItems.map(\.material.remoteID) == ["3"],
            "Graded must exclude pending, excused, missing and unknown submissions")
        let allGroups = StudyAssignmentGroup.make(courses: [course], filter: .all, now: now)
        precondition(allGroups.flatMap(\.items).count == 8)
        precondition(Set(["9", "1"]).isSubset(of: Set(allGroups.filter { $0.timeframe == .upcoming }.flatMap(\.items).map(\.material.remoteID))),
            "All assignments must retain future deadlines, including work that has not opened yet")
        precondition(CanvasAssignmentDetails(record: [:]).status == .unknown)
        precondition(CanvasAssignmentDetails(record: ["submission": ["workflow_state": "graded"]]).status.isHandedIn)
        let graded = catalog.items.first { $0.remoteID == "3" }!.assignment!
        precondition(graded.gradeLabel == "8 / 10", "Posted grades use the assignment grading scheme")
        precondition(graded.hasFeedback, "Current submission comments must be read from the student submissions endpoint")
        precondition(pending[0].details?.gradeLabel == "0 points", "Missing work retains its legitimate zero grade")
        let hiddenGrade = CanvasAssignmentDetails(record: [
            "grading_type": "points", "points_possible": 10,
            "submission": ["workflow_state": "graded", "grade": "10", "score": 10, "posted_at": NSNull()],
        ])
        precondition(hiddenGrade.grade == nil && hiddenGrade.score == nil && hiddenGrade.gradeLabel == nil)
        precondition(
            CanvasAssignmentDetails(record: ["submission": ["workflow_state": "pending_review"]]).status == .submitted)
        precondition(!CanvasSubmissionStatus.excused.isHandedIn && !CanvasSubmissionStatus.unknown.isComplete)
        var spanning = course
        spanning.term = "2026 HØST|2027 VÅR"
        var spring = locked
        spring.id = "assignments:spring"
        spring.assignment?.dueAt = "2027-02-01T12:00:00Z"
        var boundary = locked
        boundary.id = "assignments:now"
        boundary.assignment?.dueAt = "2026-09-27T12:00:00+02:00"
        spanning.canvasMaterials = [locked, spring, boundary, catalog.items.first { $0.remoteID == "2" }!]
        let multiTerm = StudyAssignmentGroup.make(courses: [spanning], now: now)
        precondition(
            multiTerm.map { $0.semester.id } == ["2026-autumn", "2026-autumn", "2027-spring"]
                && multiTerm.flatMap(\.items).count == 4)
        precondition(
            multiTerm.first?.items.map(\.material.id) == ["assignments:2", boundary.id],
            "Overdue work runs oldest first above the current date")
        let multiTermTimeline = StudyAssignmentTimeline(groups: multiTerm)
        precondition(multiTermTimeline.past.flatMap(\.items).map(\.material.id) == ["assignments:2", boundary.id])
        precondition(multiTermTimeline.upcoming.flatMap(\.items).map(\.material.id) == [locked.id, spring.id])
        let futureOnly = StudyAssignmentTimeline(groups: multiTerm.filter { $0.timeframe == .upcoming })
        precondition(futureOnly.past.isEmpty && futureOnly.upcoming.count == 2)
        let pastOnly = StudyAssignmentTimeline(groups: multiTerm.filter { $0.timeframe == .overdue })
        precondition(pastOnly.upcoming.isEmpty && pastOnly.past.count == 2)
        let emptyTimeline = StudyAssignmentTimeline(groups: [])
        precondition(emptyTimeline.past.isEmpty && emptyTimeline.upcoming.isEmpty)
        precondition(StudyAssignmentGroup.make(courses: [spanning], filter: .archive, now: now).isEmpty)
        precondition(locked.assignment?.availability(at: now) == "Not open yet")
        precondition(
            pending[0].details?.status == .notSubmitted, "A missing assignment graded zero still needs submission")
        precondition(pending[0].details?.statusLabel(at: now) == "Overdue")
        precondition(CanvasAssignmentDetails.date("2026-09-27T12:00:00+02:00") == now)
        precondition(CanvasAssignmentDetails.date("2026-09-27T12:00:00.123+02:00")!.timeIntervalSince(now) > 0.122)
        precondition(CanvasAssignmentDetails.date("invalid") == nil && CanvasAssignmentDetails.date(nil) == nil)

        AssignmentFixtureProtocol.state.revision = 2
        let refreshed = try await client.catalog(courseID: 1)
        let changes = CanvasCatalogChanges.reconcile(previous: catalog.items, catalog: refreshed)
        precondition(
            changes.changes.updated.contains("assignments:1") && changes.changes.updated.contains("assignments:9"),
            "Date and submission changes count even when updated_at is unchanged")
        precondition(
            changes.items.first { $0.remoteID == "1" }?.assignment?.dueAt == nil,
            "Removing a deadline must clear the old date")
        precondition(
            changes.items.first { $0.remoteID == "1" }?.version != locked.version,
            "Downloaded descriptions must not retain an old Due line")
        let refreshedDescription = try await client.material(refreshed.items.first { $0.remoteID == "9" }!, courseID: 1)
        precondition(refreshedDescription.version == refreshed.items.first { $0.remoteID == "9" }?.version)
        course.canvasMaterials = changes.items
        precondition(!StudyAssignment.list(courses: [course]).contains { $0.material.remoteID == "9" })

        let fallback = try await client.catalog(courseID: 2)
        precondition(!fallback.warnings.isEmpty && !fallback.completeKinds.contains(.assignments))
        precondition(fallback.items.first?.assignment?.dueAt == "2026-09-28T18:00:00Z")
        precondition(fallback.items.first?.moduleID == 55)
        let partial = try await client.catalog(courseID: 3)
        let retained = CanvasCatalogChanges.reconcile(previous: fallback.items, catalog: partial)
        precondition(
            retained.items.first?.assignment == fallback.items.first?.assignment,
            "Failed metadata requests must not erase known deadlines")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-assignments-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course], showingCourseLibrary: true, courseLibraryView: .assignments))
        let workspace = StudyWorkspaceModel(store: store)
        workspace.selectSemester("2026-autumn")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: store)
        precondition(reopened.courseLibraryView == .assignments && reopened.selectedSemesterID == "2026-autumn")
        precondition(reopened.library.courses[0].materials == changes.items)
        let dateGroups = StudyAssignmentDateGroup.make(pending)
        precondition(dateGroups.flatMap(\.items).count == pending.count && dateGroups.last?.date == nil)
        workspace.setAssignmentHidden("assignments:1", courseID: course.id, hidden: true)
        workspace.flush()
        let hiddenReopen = StudyWorkspaceModel(store: store)
        precondition(
            !StudyAssignment.list(courses: hiddenReopen.library.courses).contains { $0.material.id == "assignments:1" })
        precondition(
            StudyAssignmentGroup.make(courses: hiddenReopen.library.courses, filter: .hidden).flatMap(\.items).map(
                \.material.id) == ["assignments:1"])
        let completeList = StudyAssignment.list(
            courses: hiddenReopen.library.courses, includeCompleted: true, includeHidden: true, includeNonSubmission: true)
        let completeAgenda = StudyAssignmentGroup.make(
            courses: hiddenReopen.library.courses, filter: .all
        ).flatMap(\.items)
        precondition(
            completeList.count == StudyAssignment.list(courses: [course], includeCompleted: true, includeNonSubmission: true).count,
            "The complete course list must retain every assignment after hiding one")
        precondition(
            completeList.contains { $0.material.id == "assignments:1" && $0.isHidden },
            "All assignments must expose hidden rows with their actual visibility state")
        precondition(
            Set(completeAgenda.map(\.id)) == Set(completeList.map(\.id)),
            "The sidebar All filter must include the same complete list as the course view")
        precondition(completeAgenda.contains { $0.material.id == "assignments:1" && $0.isHidden })
        hiddenReopen.setAssignmentHidden("assignments:1", courseID: course.id, hidden: false)
        precondition(
            StudyAssignment.list(courses: hiddenReopen.library.courses).contains {
                $0.material.id == "assignments:1" && !$0.isHidden
            }, "Unhiding must restore the assignment to standard lists and clear its hidden state")

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(locked)) as! [String: Any]
        old.removeValue(forKey: "assignment")
        let legacy = try JSONDecoder().decode(
            CanvasMaterialReference.self, from: JSONSerialization.data(withJSONObject: old))
        precondition(legacy.assignment == nil, "Libraries saved before deadlines were added must remain readable")
        try await checkAssignmentOpening()
    }

    static func checkAssignmentOpening() async throws {
        try await checkLibraryWriterDurability()
        let links =
            #"<a href="/courses/1/files/501/download?download_frd=1&amp;x=2" data-api-endpoint="https://canvas.example/api/v1/courses/1/files/501">PDF</a><iframe src='/files/502/preview'></iframe><a href="https://evil.example/files/503">Other origin</a><a href="/courses/2/files/504">Other course</a><a href="javascript:alert(1)">Bad</a>"#
        precondition(
            CanvasAssignmentDetails.linkedFiles(in: links, origin: URL(string: "https://canvas.example")!, courseID: 1)
                == ["501", "502"])
        let assignmentPDF = try fixturePDF()
        let pdf = PDFDocument(data: assignmentPDF)!
        precondition((0..<pdf.pageCount).allSatisfy { !StudyOCRIndexing.sparse(pdf.page(at: $0)!.string!) },
            "Assignment navigation fixtures must not depend on the system OCR service")
        AssignmentFixtureProtocol.attachments.set(data: assignmentPDF, fail: false)
        AssignmentFixtureProtocol.state.revision = 1
        let client = try assignmentClient()
        let catalog = try await client.catalog(courseID: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-assignment-opening-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let course = StudyCourse(
            name: "Assignment fixture", canvasID: 1, canvasOrigin: "https://canvas.example",
            canvasMaterials: catalog.items)
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course], showingCourseLibrary: true))
        let workspace = StudyWorkspaceModel(store: store)
        let assignment = catalog.items.first { $0.remoteID == "9" }!
        @MainActor func settle() async throws {
            for _ in 0..<500 where workspace.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
            precondition(!workspace.assignmentPreparing,
                "Assignment opening must settle: \(workspace.fetchingMaterialID ?? "none"), \(workspace.assignmentNotice ?? "no notice"), requests: \(AssignmentFixtureProtocol.state.paths.suffix(8))")
        }
        workspace.openAssignment(assignment, courseID: course.id, clientOverride: client)
        try await settle()
        precondition(
            workspace.assignment?.id == assignment.id && workspace.document?.kind == .pdf
                && workspace.document?.sourceKey == "files:501",
            "Opening an assignment must automatically download and select its first PDF")
        precondition(
            workspace.assignmentText.contains("Show your work")
                && workspace.assignmentPDFs.map(\.id) == ["files:501", "files:502"])
        precondition(workspace.assignmentNotice == nil)
        precondition(
            workspace.assignmentFiles.map(\.id) == ["files:501", "files:502", "files:503", "files:504", "files:505"],
            "Included files must retain PDFs, source inputs and potential data in link order")
        let input = workspace.course!.documents.first { $0.sourceKey == "files:504" }!
        let potential = workspace.course!.documents.first { $0.sourceKey == "files:505" }!
        precondition(
            input.kind == .code && potential.kind == .code,
            "Unknown-extension UTF-8 simulation inputs and data must be readable without executing them")
        let originalInput = try Data(contentsOf: store.file(for: input))
        precondition(originalInput == Data(AssignmentFixtureProtocol.textFile("504").utf8))
        var contextCourse = workspace.course!
        let unrelated = try StudyDocumentImporter.read(
            data: Data("Unrelated course sentinel".utf8), name: "Unrelated.md", store: store)
        contextCourse.documents.append(unrelated)
        let context = StudyContextBuilder.build(
            document: workspace.document, index: try store.index(for: workspace.document!), currentPage: 1,
            question: "Help me understand this assignment", selection: "", course: contextCourse, store: store,
            includeCourse: false, assignment: workspace.assignment)
        precondition(
            context.text.contains("Show your work") && context.text.contains("units metal")
                && context.text.contains("pair_coeff * * Ni.eam")
                && context.text.contains("Nickel EAM potential fixture"),
            "A generic companion question must include instructions and actual linked-file contents with course context off"
        )
        precondition(
            context.sources.contains { $0.documentID == input.id }
                && context.sources.contains { $0.documentID == potential.id }
                && !context.text.contains("Unrelated course sentinel"))
        precondition(
            Set(context.sources.map(\.id)).count == context.sources.count,
            "Assignment references must not duplicate the current document or each other")
        let instructionsOnly = StudyContextBuilder.build(
            document: nil, index: nil, currentPage: 1,
            question: "Help me", selection: "", course: contextCourse, store: store,
            includeCourse: false, assignment: workspace.assignment)
        precondition(
            instructionsOnly.text.utf16.count <= StudyContextBuilder.assignmentBudget + 200,
            "Assignment context must remain within its separate bounded budget")
        workspace.navigate(to: StudySource(documentID: input.id, title: input.title, page: 1))
        precondition(
            workspace.assignment?.id == assignment.id && workspace.library.selectedAssignmentFileID == "files:504",
            "Following an included-file citation preserves assignment context")
        let owner = workspace.draftOwner
        workspace.library.selectedAssignmentID = "assignments:2"
        do {
            try workspace.validateDraftOwner(owner)
            preconditionFailure("A draft from another assignment must be rejected even on the same file")
        } catch {}
        workspace.library.selectedAssignmentID = assignment.id
        workspace.openAssignment(
            workspace.assignment!, courseID: course.id, fileID: "files:501", clientOverride: client)
        workspace.navigate(to: StudySource(documentID: input.id, title: input.title, page: 1))
        try await settle()
        precondition(
            workspace.document?.id == input.id && workspace.library.selectedAssignmentFileID == "files:504",
            "Late assignment preparation must not replace an included file selected through a citation")
        workspace.openAssignmentFile("files:504")
        try await settle()
        precondition(
            workspace.assignment?.id == assignment.id && workspace.document?.id == input.id
                && workspace.library.selectedAssignmentFileID == "files:504")
        let binary = try StudyDocumentImporter.read(data: Data([0, 1, 2, 3, 255]), name: "binary.eam", store: store)
        precondition(binary.kind == .preview, "Binary attachments must never be treated as source text")
        let empty = try StudyDocumentImporter.read(data: Data(" \n\t".utf8), name: "empty.nanowire", store: store)
        precondition(
            empty.unreadablePages == empty.pageCount, "Empty source markup must not imply readable companion content")
        workspace.openAssignment(
            workspace.assignment!, courseID: course.id, fileID: "files:502", clientOverride: client)
        try await settle()
        precondition(workspace.document?.sourceKey == "files:502", "PDF choices stay in the assignment page")
        workspace.flush()
        let reopened = StudyWorkspaceModel(store: store)
        precondition(
            reopened.assignment?.id == assignment.id && reopened.document?.sourceKey == "files:502"
                && !reopened.assignmentText.isEmpty)
        let requests = AssignmentFixtureProtocol.state.paths.count
        reopened.showCourseLibrary()
        reopened.openAssignment(assignment, courseID: course.id)
        for _ in 0..<500 where reopened.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(
            reopened.document?.sourceKey == "files:501" && AssignmentFixtureProtocol.state.paths.count == requests,
            "Saved assignment files remain readable when deadline refresh cannot authenticate")
        precondition(reopened.assignmentNotice?.contains("Deadline may be out of date") == true)
        workspace.openAssignment(assignment, courseID: course.id, clientOverride: client)
        workspace.showCourseLibrary()
        try await settle()
        precondition(
            workspace.isShowingLibrary && workspace.assignment == nil,
            "Finishing a download must not reopen an assignment after leaving it")
        workspace.openAssignment(
            catalog.items.first { $0.remoteID == "1" }!, courseID: course.id, clientOverride: client)
        try await settle()
        precondition(
            workspace.assignment?.assignment?.locked == true && workspace.document == nil && !workspace.assignmentPreparing)

        let failedStore = StudyLibraryStore(root: root.appendingPathComponent("failure"))
        try failedStore.save(StudyLibrary(courses: [course]))
        let failed = StudyWorkspaceModel(store: failedStore)
        AssignmentFixtureProtocol.attachments.set(data: try fixturePDF(), fail: true)
        failed.openAssignment(assignment, courseID: course.id, fileID: "files:502", clientOverride: client)
        for _ in 0..<500 where failed.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(
            !failed.assignmentPreparing && failed.assignment != nil && failed.document == nil && !failed.assignmentText.isEmpty
                && failed.assignmentNotice != nil)
        let incomplete = StudyContextBuilder.build(
            document: nil, index: nil, currentPage: 1,
            question: "Explain this", selection: "", course: failed.course!, store: failedStore,
            includeCourse: false, assignment: failed.assignment, assignmentFileNotices: failed.assignmentFileNotices)
        precondition(
            incomplete.text.contains("Formula sheet.pdf") && incomplete.text.contains("Contents are unavailable"),
            "Missing linked files must be identified instead of silently omitted")
        AssignmentFixtureProtocol.attachments.set(data: try fixturePDF(), fail: false)
        failed.openAssignment(failed.assignment!, courseID: course.id, clientOverride: client)
        for _ in 0..<500 where failed.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(
            failed.document?.sourceKey == "files:502" && failed.assignmentNotice == nil,
            "Retry preserves instructions and retries the chosen PDF")
        try await checkAssignmentPreparationDuringSync(course: course, assignment: assignment, client: client)
        print(
            "PASS: assignment included files, safe simulation text, bounded companion context, draft ownership, offline reopen, navigation, locked content and retry"
        )
    }

    static func checkAssignmentPreparationDuringSync(
        course: StudyCourse, assignment: CanvasMaterialReference, client: CanvasClient
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-assignment-concurrency-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        try store.save(StudyLibrary(courses: [course]))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in client })
        let previousPreloading = workspace.preloadFrequentCourses
        defer { workspace.preloadFrequentCourses = previousPreloading }
        workspace.preloadFrequentCourses = false
        // Preserve the unrelated sync's state throughout foreground preparation and cancellation.
        workspace.canvasBusy = true
        workspace.canvasStatus = "Saving course materials in the background"
        AssignmentFixtureProtocol.state.reset()
        AssignmentFixtureProtocol.attachments.delay = 0.3
        defer { AssignmentFixtureProtocol.attachments.delay = 0 }
        workspace.openAssignment(assignment, courseID: course.id, clientOverride: client)
        for _ in 0..<100 where !AssignmentFixtureProtocol.state.paths.contains(where: { $0.hasSuffix("501.pdf") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(workspace.assignmentPreparing && workspace.canvasBusy,
            "Included files must start downloading while a bulk Canvas sync is busy")
        precondition(AssignmentFixtureProtocol.state.paths.contains { $0.hasSuffix("501.pdf") })
        // Select a different included file while the first transfer is still in progress.
        workspace.openAssignment(assignment, courseID: course.id, fileID: "files:502", clientOverride: client)
        try await Task.sleep(for: .milliseconds(10))
        precondition(workspace.assignmentPreparing,
            "An older cancelled preparation must not clear its replacement's busy state")
        for _ in 0..<500 where workspace.assignmentPreparing { try await Task.sleep(for: .milliseconds(20)) }
        precondition(!workspace.assignmentPreparing && workspace.document?.sourceKey == "files:502",
            "The explicitly requested file must win over an earlier automatic selection")
        precondition(workspace.canvasBusy && workspace.canvasStatus == "Saving course materials in the background",
            "Assignment completion must neither stop the bulk sync nor replace its progress")
        precondition(workspace.assignmentNotice == nil && workspace.course!.documents.count == 6)
        precondition(Set(workspace.course!.documents.compactMap(\.sourceKey)).count == 6,
            "Rapid changes must not produce duplicate saved materials")
        workspace.draft = "Explain this assignment"
        for _ in 0..<100 where workspace.documentIndex == nil { try await Task.sleep(for: .milliseconds(10)) }
        precondition(workspace.canSend, "A background Canvas sync must not block the assignment companion")
        workspace.openAssignment(assignment, courseID: course.id, clientOverride: client)
        workspace.showCourseLibrary()
        try await Task.sleep(for: .milliseconds(20))
        precondition(!workspace.assignmentPreparing && workspace.assignment == nil && workspace.canvasBusy,
            "Leaving an assignment cancels only its preparation")
        print("PASS: assignment downloads during Canvas sync, foreground file switching, independent cancellation and companion access")
    }

    /// An isolated real backend for manual Chromium verification; never uses the user's library or Canvas session.
    static func previewAssignments() async throws {
        AssignmentFixtureProtocol.state.revision = 1
        let client = try assignmentClient()
        let catalog = try await client.catalog(courseID: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scholia-assignments-preview-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        var course = StudyCourse(
            name: "Linear algebra & differential equations", code: "MATH101-26H", canvasID: 1,
            canvasOrigin: "https://canvas.example", canvasMaterials: catalog.items, catalogUpdatedAt: Date(),
            term: "2026 HØST")
        // Keep an upcoming locked assignment in the preview even as real time advances.
        if let index = course.canvasMaterials?.firstIndex(where: { $0.remoteID == "1" }) {
            course.canvasMaterials?[index].assignment?.dueAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 86400))
        }
        // Save descriptions so Read assignment exercises native/web navigation offline.
        for material in catalog.items {
            var document = try StudyDocumentImporter.read(
                data: Data(
                    "# \(material.title)\n\nSolve the problems and upload your work in Canvas.\n\nThis is an isolated test assignment."
                        .utf8), name: "\(material.title).md", store: store)
            document.sourceKey = material.id
            document.sourceVersion = material.version
            document.sourceURL = material.sourceURL
            course.documents.append(document)
        }
        for id in ["501", "502", "503", "504", "505"] {
            let file = try await client.fileReference(id: id, courseID: 1)
            course.canvasMaterials?.append(file)
            let data =
                ["501", "502"].contains(id) ? try fixturePDF() : Data(AssignmentFixtureProtocol.textFile(id).utf8)
            var document = try StudyDocumentImporter.read(data: data, name: file.fileName!, store: store)
            document.title = file.title
            document.sourceKey = file.id
            document.sourceURL = file.sourceURL
            document.sourceVersion = file.version
            course.documents.append(document)
        }
        var second = course
        second.id = UUID()
        second.name = "Programming fundamentals"
        second.code = "CS101-26H"
        second.documents = []
        second.canvasMaterials = [catalog.items.first { $0.remoteID == "9" }!]
        var past = second
        past.id = UUID()
        past.name = "Past course"
        past.code = "PAST-25H"
        past.term = "2025 HØST"
        try store.save(
            StudyLibrary(
                courses: [course, second, past], showingCourseLibrary: true, courseLibraryView: .assignments,
                canvasCheckedAt: Date(), canvasRefreshSummary: "Fixture deadlines loaded."))
        let workspace = StudyWorkspaceModel(store: store)
        workspace.setCourseLibraryView(.all)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        controller.show()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(500))
        try snapshot(controller.window, at: output.appendingPathComponent("workspace-dashboard-assignments.png"))
        let server = StudyWebServer(
            app: AppModel.shared, workspace: workspace, assets: URL(fileURLWithPath: "dist/web"))
        server.start(port: 0)
        for _ in 0..<100 where server.address == nil { try await Task.sleep(for: .milliseconds(20)) }
        print("ASSIGNMENTS_PREVIEW \(server.address!.absoluteString)")
        fflush(stdout)
        if CommandLine.arguments.contains("--assignment-page-smoke") {
            let browser = Process()
            browser.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            browser.arguments = [
                "node", "scripts/smoke/browser/smoke-assignment-page.mjs", server.address!.absoluteString, output.path,
            ]
            let result: Int32 = await withCheckedContinuation { continuation in
                browser.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try browser.run() } catch { continuation.resume(returning: -1) }
            }
            precondition(result == 0, "Chromium assignment page smoke failed")
            func splitView(in view: NSView) -> NSSplitView? {
                if let split = view as? NSSplitView, split.isVertical, split.arrangedSubviews.count == 2 {
                    return split
                }
                return view.subviews.lazy.compactMap { splitView(in: $0) }.first
            }
            func pdfView(in view: NSView) -> PDFView? {
                if let pdf = view as? PDFView { return pdf }
                return view.subviews.lazy.compactMap { pdfView(in: $0) }.first
            }
            precondition(workspace.assignment != nil && workspace.document?.kind == .pdf && workspace.assignmentPDFFocused,
                         "An assignment PDF opens directly in focused reading with its chat")
            workspace.draft = "Help me understand the first problem without giving away the solution."
            workspace.saveDraft()
            let focusedAssignmentID = workspace.library.selectedAssignmentID
            let focusedDocumentID = workspace.library.selectedDocumentID
            let focusedThreadID = workspace.library.selectedThreadID
            let focusedDraft = workspace.draft
            let focusedPage = workspace.currentPage
            try await Task.sleep(for: .milliseconds(300))
            let split = splitView(in: controller.window.contentView!)!
            let pdf = pdfView(in: controller.window.contentView!)!
            precondition(split.arrangedSubviews[0].frame.width > split.arrangedSubviews[1].frame.width,
                         "The focused assignment PDF is the primary pane, with chat beside it")
            precondition(pdf.bounds.height > controller.window.contentView!.bounds.height * 0.55,
                         "Assignment instructions must not crowd the PDF out of its focused view")
            try snapshot(controller.window, at: output.appendingPathComponent("assignment-native-focus.png"))
            controller.window.setContentSize(NSSize(width: 1020, height: 740))
            try await Task.sleep(for: .milliseconds(300))
            precondition(split.arrangedSubviews[0].frame.width >= 420 && split.arrangedSubviews[1].frame.width >= 220,
                         "Focused PDF and chat both remain usable at the minimum window width")
            try snapshot(controller.window, at: output.appendingPathComponent("assignment-native-focus-compact.png"))
            controller.window.setContentSize(NSSize(width: 1420, height: 900))
            workspace.assignmentPDFFocused = false
            try await Task.sleep(for: .milliseconds(300))
            precondition(workspace.library.selectedAssignmentID == focusedAssignmentID
                            && workspace.library.selectedDocumentID == focusedDocumentID
                            && workspace.library.selectedThreadID == focusedThreadID
                            && workspace.draft == focusedDraft && workspace.currentPage == focusedPage,
                         "Returning to the assignment overview preserves its PDF, page, conversation and unsent draft")
            try snapshot(controller.window, at: output.appendingPathComponent("assignment-native.png"))
            workspace.assignmentPDFFocused = true
            try await Task.sleep(for: .milliseconds(300))
            precondition(workspace.library.selectedAssignmentID == focusedAssignmentID
                            && workspace.library.selectedThreadID == focusedThreadID && workspace.draft == focusedDraft,
                         "Re-entering PDF focus must not start a different conversation or clear the draft")
            let focusedContext = StudyContextBuilder.build(
                document: workspace.document, index: try store.index(for: workspace.document!),
                currentPage: workspace.currentPage, question: focusedDraft, selection: "",
                course: workspace.course!, store: store, includeCourse: false, assignment: workspace.assignment)
            precondition(focusedContext.text.contains("Solve the problems")
                            && focusedContext.sources.contains { $0.documentID == focusedDocumentID },
                         "Focused chat stays grounded in the assignment instructions and selected PDF")
            workspace.assignmentPDFFocused = false
            try await Task.sleep(for: .milliseconds(200))
            split.setPosition(85, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(300))
            precondition(
                split.arrangedSubviews[0].frame.width <= 100
                    && split.arrangedSubviews[1].frame.width > split.bounds.width * 0.85,
                "Native AI chat can expand to nearly the whole document workspace")
            try snapshot(controller.window, at: output.appendingPathComponent("assignment-native-wide-chat.png"))
            split.setPosition(split.bounds.width - 225, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(300))
            precondition(split.arrangedSubviews[1].frame.width < 250, "Native AI chat can also be narrowed")
            split.setPosition(split.bounds.width - 390, ofDividerAt: 0)
            print("PASS: Native assignment PDF focus keeps chat, context, page and draft; overview chat remains fully resizable")
            workspace.showAssignments()
            try await Task.sleep(for: .milliseconds(300))
            try snapshot(controller.window, at: output.appendingPathComponent("assignments-overview-native.png"))
            server.stop()
            return
        }
        while !Task.isCancelled { try await Task.sleep(for: .seconds(1)) }
        server.stop()
    }
}

final class AssignmentFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let state = CanvasFixtureState()
    static let attachments = AssignmentAttachmentFixture()
    private let stopLock = NSLock()
    private var stopped = false
    static func fileName(_ id: String) -> String {
        [
            "501": "Exercises.pdf", "502": "Formula sheet.pdf", "503": "notes.txt", "504": "in.nanowire",
            "505": "Ni.eam",
            "506": "Assignment feedback.pdf",
        ][id] ?? "notes.txt"
    }
    static func textFile(_ id: String) -> String {
        switch id {
        case "504":
            "# Tensile test input\nunits metal\natom_style atomic\npair_style eam\npair_coeff * * Ni.eam\nfix tensile all deform 1 z erate 0.001\n"
        case "505":
            "Nickel EAM potential fixture\n28 58.6934 3.5200 FCC\n1000 0.01 1000 0.01 5.0\n"
                + String(repeating: "0.1023 0.2301 0.5900 0.0321\n", count: 1000)
        default: "These notes belong to the tensile test assignment."
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        precondition(
            url.host == "canvas.example" && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token"
        )
        Self.state.record(url.absoluteString)
        let path = url.path
        let revision = Self.state.revision
        var status = 200
        var body: Any = [[String: Any]]()
        var headers = ["Content-Type": "application/json"]
        func assignment(_ id: Int) -> [String: Any] {
            var item: [String: Any] = [
                "id": id, "name": "Exercise \(id)", "updated_at": "unchanged", "published": true,
                "submission_types": ["online_upload"], "due_at": "2026-09-28T18:00:00Z",
                "submission": ["workflow_state": "unsubmitted"],
            ]
            switch id {
            case 1:
                item["locked_for_user"] = true
                item["unlock_at"] = "2026-09-28T00:00:00Z"
                item["due_at"] = revision == 1 ? "2026-09-29T12:00:00+02:00" : NSNull()
            case 2:
                item["due_at"] = "2026-09-20T18:00:00Z"
                item["submission"] = ["workflow_state": "graded", "score": 0, "missing": true]
            case 3:
                item["grading_type"] = "points"
                item["points_possible"] = 10
                item["rubric"] = [["id": "reasoning", "description": "Reasoning", "points": 10,
                    "ratings": [["id": "good", "description": "Good understanding"]]]]
                item["submission"] = [
                    "workflow_state": "graded", "submitted_at": "2026-09-26T12:00:00Z",
                    "posted_at": NSNull(), "score": 8, "grade": "8",
                ]
            case 4: item["submission"] = ["excused": true]
            case 5: item["submission_types"] = ["none"]
            case 6: item["submission_types"] = ["not_graded"]
            case 7:
                item["due_at"] = NSNull()
                item.removeValue(forKey: "submission")
            case 8: item["hidden_for_user"] = true
            case 9:
                item["description"] =
                    "<p>Show your work for both exercises.</p><a href=\"/courses/1/files/501/download\">Exercises.pdf</a><a href=\"/files/502/preview\">Formula sheet.pdf</a><a href=\"/files/503\">Notes</a><a href=\"/files/504\">in.nanowire</a><a href=\"/files/505\">Ni.eam</a>"
                if revision == 2 { item["submission"] = ["workflow_state": "pending_review"] }
            case 10: item["published"] = false
            default: break
            }
            if item["description"] == nil { item["description"] = "<p>Show your work.</p>" }
            return item
        }
        if path.hasSuffix(".pdf") {
            let (data, fail) = Self.attachments.value
            let response = HTTPURLResponse(
                url: url, statusCode: fail ? 503 : 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/pdf"])!
            let delay = Self.attachments.delay
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
                    guard !stopLock.withLock({ stopped }) else { return }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                }
            } else {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        } else if path.hasSuffix(".txt") {
            let id = url.deletingPathExtension().lastPathComponent
            let data = Data(Self.textFile(id).utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        } else if path == "/api/v1/users/self/profile" {
            body = ["id": 42, "name": "Feedback student"]
        } else if path == "/api/v1/courses/1/files/506" {
            status = 403
        } else if path.hasPrefix("/api/v1/courses/2/files/") || path.hasPrefix("/api/v1/courses/3/files/") {
            status = 403
        } else if path.hasPrefix("/api/v1/courses/1/files/") || path.hasPrefix("/api/v1/files/") {
            let id = path.components(separatedBy: "/").last!
            let name = Self.fileName(id)
            body = [
                "id": Int(id)!, "filename": name, "display_name": name, "updated_at": "file-v1", "size": 1000,
                "url": "https://canvas.example/\(id).\(["501", "502", "506"].contains(id) ? "pdf" : "txt")",
            ]
        } else if path == "/api/v1/courses/1/students/submissions" {
            precondition(request.value(forHTTPHeaderField: "If-None-Match") == nil)
            precondition(url.query?.contains("student_ids") != true, "Only request the signed-in student's submissions")
            body = [["assignment_id": 3, "user_id": 42, "workflow_state": "graded", "attempt": 1,
                "submitted_at": "2026-09-26T12:00:00Z", "posted_at": "2026-09-27T09:00:00Z",
                "score": 8, "grade": "8", "grade_matches_current_submission": true,
                "rubric_assessment": ["reasoning": ["points": 8, "rating_id": "good", "comments": "Explain why the covariance stays positive."]],
                "submission_comments": [
                    ["id": 30, "author_id": 99, "author_name": "Course instructor",
                        "comment": revision == 1 ? "Good work on the model.\nPlease justify the covariance update in part 3." : "Follow-up: the revised explanation is clear.",
                        "attempt": 1, "created_at": "2026-09-27T09:00:00Z",
                        "attachments": [["id": 506, "display_name": "Assignment feedback.pdf", "size": 1000,
                            "content-type": "application/pdf", "url": "https://canvas.example/private?verifier=never-persist"]]],
                    ["id": 31, "author_id": 42, "comment": "Student submission note", "attempt": 1],
                    ["id": 32, "author_id": 99, "comment": "Hidden feedback sentinel", "hidden": true]]]]
        } else if path.hasSuffix("/students/submissions") || path.hasSuffix("/submissions/self") {
            status = 403
        } else if path == "/api/v1/courses/1/assignments" {
            precondition(
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                    $0.name == "include[]" && $0.value == "submission"
                } == true)
            if url.query?.contains("page=2") == true {
                body = [assignment(9), assignment(10)]
            } else {
                body = (1...8).map(assignment)
                headers["Link"] = "<https://canvas.example\(path)?include[]=submission&page=2>; rel=\"next\""
            }
        } else if ["/api/v1/courses/2/assignments", "/api/v1/courses/3/assignments"].contains(path) {
            status = 403
        } else if ["/api/v1/courses/2/modules", "/api/v1/courses/3/modules"].contains(path) {
            body = [
                [
                    "id": 55, "name": "Module exercises", "items_count": 1,
                    "items": [["type": "Assignment", "content_id": 9, "title": "Exercise 9"]],
                ]
            ]
        } else if ["/api/v1/courses/1/assignments/1", "/api/v1/courses/1/assignments/3"].contains(path) {
            body = assignment(Int(url.lastPathComponent)!)
        } else if ["/api/v1/courses/1/assignments/9", "/api/v1/courses/2/assignments/9"].contains(path) {
            body = assignment(9)
        } else if path == "/api/v1/courses/3/assignments/9" {
            status = 403
        } else if ["/api/v1/courses/1", "/api/v1/courses/2", "/api/v1/courses/3"].contains(path) {
            body = ["syllabus_body": ""]
        } else {
            precondition(
                path.hasSuffix("/pages") || path.hasSuffix("/files") || path.hasSuffix("/modules") || path.hasSuffix("/folders"),
                "Unexpected fixture request: \(path)")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopLock.withLock { stopped = true } }
}

final class AssignmentAttachmentFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var fail = false
    private var responseDelay: Double = 0
    var delay: Double {
        get { lock.withLock { responseDelay } }
        set { lock.withLock { responseDelay = newValue } }
    }
    func set(data: Data, fail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        self.fail = fail
    }
    var value: (Data, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (data, fail)
    }
}

extension StudyWorkspaceSmoke {
    static func checkLibraryWriterDurability() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-writer-barrier-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let writer = StudyLibraryWriter(store: store)
        let file = root.appendingPathComponent("library.json")
        func snapshot(_ name: String) -> StudyLibrary { StudyLibrary(courses: [StudyCourse(name: name)]) }
        for index in 0..<128 { writer.save(snapshot("Queued \(index)"), onError: { _ in }) }
        try await writer.waitForPendingWrites()
        let latestQueued = try store.load()
        precondition(latestQueued.courses.first?.name == "Queued 127",
            "The durability barrier must wait for the newest coalesced snapshot")
        let saved = try Data(contentsOf: file)
        try await writer.waitForPendingWrites()
        let afterIdleBarrier = try Data(contentsOf: file)
        precondition(afterIdleBarrier == saved, "An idle barrier must not rewrite a captured snapshot")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("prevent atomic file replacement".utf8).write(to: file.appendingPathComponent("blocker"))
        writer.save(snapshot("Cannot save"), onError: { _ in })
        do {
            try await writer.waitForPendingWrites()
            preconditionFailure("The barrier must propagate a queued write failure")
        } catch {}
        do {
            try await writer.waitForPendingWrites()
            preconditionFailure("An idle barrier must retain the latest write failure")
        } catch {}
        try FileManager.default.removeItem(at: file)
        writer.save(snapshot("Recovered"), onError: { _ in })
        try await writer.waitForPendingWrites()
        let recovered = try store.load()
        precondition(recovered.courses.first?.name == "Recovered",
            "A successful save must clear the previous failure")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: file.appendingPathComponent("blocker"))
        do {
            try writer.flush(snapshot("Cannot flush"))
            preconditionFailure("Synchronous flush must propagate its write failure")
        } catch {}
        do {
            try await writer.waitForPendingWrites()
            preconditionFailure("A failed flush must also be visible to the async barrier")
        } catch {}
        try FileManager.default.removeItem(at: file)
        try writer.flush(snapshot("Flushed"))
        try await writer.waitForPendingWrites()
        let flushed = try store.load()
        precondition(flushed.courses.first?.name == "Flushed")
        print("PASS: library writer coalescing, durability barrier, write failures and recovery")
    }
}
