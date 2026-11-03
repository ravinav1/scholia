@preconcurrency import AppKit
import SwiftUI
@testable import ScholiaMac

extension StudyWorkspaceSmoke {
    static func checkReferenceLinksAndShortcuts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-reference-shortcuts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("reference-shortcuts")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = StudyLibraryStore(root: root)
        let title = "Before and beyond trust: reliance in medical AI"
        let url = "https://doi.org/10.1136/medethics-2020-107095"
        var syllabus = try StudyDocumentImporter.read(data: Data(title.utf8), name: "Syllabus.txt", store: store)
        syllabus.sourceKey = "pages:syllabus"
        syllabus.sourceURL = "https://canvas.example/courses/1/pages/syllabus"
        var reference = CanvasMaterialReference(id: "files:paper", kind: .files, remoteID: "paper", title: title, sourceURL: url, version: "1")
        reference.linkedFromID = syllabus.sourceKey
        let course = StudyCourse(name: "Bioethics", documents: [syllabus], canvasMaterials: [reference])
        let pack = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1,
            question: "Suggest an essay reading about medical AI", selection: "", course: course, store: store, includeCourse: true)
        try courseUIRequire(pack.text.contains("[\(title)](\(url))"), "Legacy reading lists must retain the paper's own link")
        try courseUIRequire(pack.text.contains("Source URL (this document): \(syllabus.sourceURL!)"), "Syllabus source remains distinct from the paper URL")
        try courseUIRequire(pack.text.contains("not downloaded; contents unavailable; source URL: \(url)"), "A paper link must not imply its contents were read")
        try courseUIRequire(pack.sources.map(\.documentID) == [syllabus.id], "Only read sources belong in evidence")
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, showingCourseLibrary: false))
        let workspace = StudyWorkspaceModel(store: store)
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        controller.window.appearance = NSAppearance(named: .aqua)
        controller.show()
        defer { controller.window.close() }
        _ = try await courseUIWaitForElement("workspace-keyboard-shortcuts", in: controller.window)
        try await courseUIPress("workspace-keyboard-shortcuts", in: controller.window)
        let sheet = try courseUIUnwrap(controller.window.attachedSheet)
        _ = try await courseUIWaitForElement("keyboard-shortcuts-done", in: sheet)
        try snapshot(sheet, at: output.appendingPathComponent("shortcuts-light.png"))
        sheet.appearance = NSAppearance(named: .darkAqua)
        try await courseUISettle()
        try snapshot(sheet, at: output.appendingPathComponent("shortcuts-dark.png"))
        try await courseUIPress("keyboard-shortcuts-done", in: sheet)
        for _ in 0..<10 where controller.window.attachedSheet != nil { try await courseUISettle() }
        try courseUIRequire(controller.window.attachedSheet == nil, "Done closes the shortcut guide")
        print("PASS: native paper source links, legacy list recovery, evidence boundaries, subtle shortcut button and light/dark help sheet")
    }

    static func checkAIWorkspace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-ai-workspace-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ai-workspace")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let file = try StudyDocumentImporter.read(data: Data("Pinned motor torque constant: 0.042 Nm/A.".utf8), name: "KybintroKompendium.txt", store: store)
        let assignments = ["a", "b"].map { id in
            CanvasMaterialReference(id: id, kind: .assignments, remoteID: id, title: id, sourceURL: "https://example.com/\(id)", version: "1")
        }
        let course = StudyCourse(name: "Kybernetikk introduksjon", code: "TTK4100", documents: [file], canvasMaterials: assignments)
        try store.save(StudyLibrary(courses: [course], selectedCourseID: course.id, showingCourseLibrary: false, selectedAssignmentID: "a"))
        let workspace = StudyWorkspaceModel(store: store)
        try workspace.saveWorkspaceMemory(courseID: course.id, assignmentID: nil, notes: "Use SI units", documentIDs: [])
        try workspace.saveWorkspaceMemory(courseID: course.id, assignmentID: "a", notes: "Motor project", documentIDs: [file.id])
        try workspace.saveWorkspaceMemory(courseID: course.id, assignmentID: "b", notes: "Pendulum project", documentIDs: [])
        workspace.newThread(); workspace.flush()
        let saved = try store.load().courses[0]
        precondition(saved.assignmentMemories?["a"]?.documentIDs == [file.id])
        for (assignment, expected, excluded) in [(assignments[0], "Motor project", "Pendulum project"), (assignments[1], "Pendulum project", "Motor project")] {
            let pack = StudyContextBuilder.build(document: nil, index: nil, currentPage: 1, question: "what do we know?", selection: "", course: saved, store: store, includeCourse: false, assignment: assignment)
            precondition(pack.text.contains("Use SI units") && pack.text.contains(expected) && !pack.text.contains(excluded))
            precondition(pack.text.contains("0.042 Nm/A") == (assignment.id == "a"))
        }
        do {
            try workspace.saveWorkspaceMemory(courseID: course.id, assignmentID: "a", notes: "", documentIDs: [UUID()])
            throw StudyError.message("Accepted a foreign file")
        } catch { precondition(error.localizedDescription.contains("belong")) }
        for (old, expected) in [("Guide me", StudyTeachingMode.explain), ("Chat", .chat), ("General", .chat)] {
            let decoded = try JSONDecoder().decode(StudyTeachingMode.self, from: Data("\"\(old)\"".utf8))
            precondition(decoded == expected)
        }
        for mode in StudyTeachingMode.allCases {
            let prepared = PreparedConversation(language: "en", messages: [], teachingMode: mode)
            precondition(prepared.systemPrompt.contains(TutoringPolicy.learningBoundary) == (mode != .chat))
        }
        let search = StudyWorkspaceSearch()
        let found = try await search.search(courses: [saved], store: store, query: "ttk4100 kybtintro kompendium", mode: "files")
        precondition(found.results.first?.documentID == file.id.uuidString && found.results.first?.approximate == true)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("needle-v1.sqlite").path))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 390, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: StudyTutorPane(workspace: workspace).environmentObject(AppModel.shared))
        host.sizingOptions = []
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for width in [220, 280, 390] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await courseUISettle()
            let bounds = window.convertToScreen(NSRect(origin: .zero, size: window.contentLayoutRect.size))
            try snapshot(window, at: output.appendingPathComponent("assignment-\(width).png"))
            let elements = courseUIElements(in: window)
            for label in ["Message", "Send question", "Choose a model", "Workspace memory"] {
                guard let control = elements.first(where: { ($0.accessibilityLabel() == label || $0.accessibilityIdentifier() == label) && $0.accessibilityFrame().width > 0 }) else {
                    throw StudyError.message("Missing \(label). Labels: \(elements.compactMap { $0.accessibilityLabel() })")
                }
                let frame = control.accessibilityFrame()
                try courseUIRequire(frame.minX >= bounds.minX - 1 && frame.maxX <= bounds.maxX + 1, "\(label) overflows a \(width)px pane: \(frame) vs \(bounds)")
            }
        }
        try await courseUIPress("workspace-memory", in: window)
        for _ in 0..<20 where window.attachedSheet == nil { try await courseUISettle() }
        let sheet = try courseUIUnwrap(window.attachedSheet)
        _ = try await courseUIWaitForElement("workspace-memory-notes", in: sheet)
        try snapshot(sheet, at: output.appendingPathComponent("assignment-memory.png"))
        window.endSheet(sheet)
        try await checkRepairCenter(workspace: workspace, output: output, root: root)
        // Read the real catalog for performance evidence. Filename search never writes indexes.
        if CommandLine.arguments.contains("--real-catalog") {
            let realStore = StudyLibraryStore(), library = try realStore.load()
            let engine = StudyWorkspaceSearch()
            var timings: [Double] = []
            for _ in 0..<12 {
                let result = try await engine.search(courses: library.courses, store: realStore, query: "ttk4100 kybtintro kompendium", mode: "files")
                timings.append(result.totalMs)
                precondition(result.results.contains { $0.title == "KybintroKompendium.pdf" })
            }
            print("Native real catalog: cold \(timings[0])ms, warm median \(timings.dropFirst().sorted()[5])ms")
        }
        print("PASS: native workspace/assignment memory persistence, file isolation, legacy modes, unrestricted General prompts, filename search without indexes, narrow composer bounds, and memory editor")
    }

    private static func checkRepairCenter(workspace: StudyWorkspaceModel, output: URL, root: URL) async throws {
        let suite = "scholia-repair-smoke-\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let reports = root.appendingPathComponent("repairs"), repository = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent("apps/macos"), withIntermediateDirectories: true)
        try Data().write(to: repository.appendingPathComponent("apps/macos/Package.swift"))
        let fixture = root.appendingPathComponent("fixture-codex")
        try """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --model) shift; model="$1" ;;
            --config) shift; effort="$1" ;;
            --output-last-message) shift; result="$1" ;;
          esac
          shift
        done
        cat > "${result%/*}/received.txt"
        printf '%s' "$effort" > "${result%/*}/effort.txt"
        printf '{"type":"item.completed","item":{"text":"Fixture agent started"}}\\n'
        if [ "$model" = "fixture-wait" ]; then exec /bin/sleep 30; fi
        if [ "$model" = "fixture-fail" ]; then printf 'Fixture failure\\n' >&2; exit 7; fi
        printf 'Repaired with %s\\n' "$model" > "$result"
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        let center = ScholiaRepairCenter(root: reports, preferences: preferences)
        center.sourceRoot = repository.path; center.modelID = "fixture-model"
        center.reasoningEffort = "xhigh"
        center.capture(workspace: workspace, window: NSApp.keyWindow)
        center.note = "The PDF toolbar flickers when I scroll."
        center.screenshot = try Data(contentsOf: output.appendingPathComponent("assignment-390.png"))
        let id = try center.saveNote()
        let args = ScholiaRepairCenter.arguments(model: center.modelID, effort: center.reasoningEffort, sourceRoot: center.sourceRoot, folder: center.directory(id), hasScreenshot: true)
        precondition(args.contains("fixture-model") && args.contains("--image") && args.contains("workspace-write") && !args.contains("--dangerously-bypass-approvals-and-sandbox"))
        precondition(args.contains("model_reasoning_effort=\"xhigh\""))
        let defaultArgs = ScholiaRepairCenter.arguments(model: center.modelID, sourceRoot: center.sourceRoot, folder: center.directory(id), hasScreenshot: false)
        precondition(!defaultArgs.contains("--config"))
        let restored = ScholiaRepairCenter(root: reports, preferences: preferences)
        precondition(restored.reports.first?.note == center.note && restored.modelID == "fixture-model" && restored.reasoningEffort == "xhigh")
        restored.reasoningEffort = "low"
        restored.select(restored.reports[0])
        precondition(restored.reasoningEffort == "xhigh")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored.reports[0])) as! [String: Any]
        legacy.removeValue(forKey: "reasoningEffort")
        let legacyReport = try JSONDecoder().decode(ScholiaRepairReport.self, from: JSONSerialization.data(withJSONObject: legacy))
        restored.select(legacyReport)
        precondition(restored.reasoningEffort.isEmpty, "Older reports keep the CLI default")
        try center.launch(executable: fixture)
        for _ in 0..<100 where center.runningID != nil { try await Task.sleep(for: .milliseconds(30)) }
        precondition(center.runningID == nil && center.reports.first?.status == "Ready to review")
        precondition(center.output.contains("Repaired with fixture-model"))
        let received = try String(contentsOf: center.directory(id).appendingPathComponent("received.txt"), encoding: .utf8)
        precondition(received.contains(center.note) && received.contains("TTK4100") && received.contains("Chromium"))
        let forwardedEffort = try String(contentsOf: center.directory(id).appendingPathComponent("effort.txt"), encoding: .utf8)
        precondition(forwardedEffort == "model_reasoning_effort=\"xhigh\"", "The selected effort must reach the launched process")
        center.modelID = "fixture-fail"
        try center.launch(executable: fixture)
        for _ in 0..<100 where center.runningID != nil { try await Task.sleep(for: .milliseconds(30)) }
        precondition(center.reports.first?.status == "Failed (7)" && center.output.contains("Fixture failure") && !center.output.contains("Repaired with"))
        center.modelID = "fixture-wait"
        try center.launch(executable: fixture)
        try await Task.sleep(for: .milliseconds(100))
        center.stop()
        for _ in 0..<100 where center.runningID != nil { try await Task.sleep(for: .milliseconds(30)) }
        precondition(center.runningID == nil && center.reports.first?.status == "Stopped")
        center.screenshot = nil; _ = try center.saveNote()
        precondition(!FileManager.default.fileExists(atPath: center.directory(id).appendingPathComponent("screen.png").path))
        center.reasoningEffort = "ultra"
        center.normalizeEffort(supported: ["low", "medium", "high"])
        precondition(center.reasoningEffort.isEmpty, "Unsupported effort resets when changing models")
        center.modelID = "gpt-5.6-sol"; center.reasoningEffort = "high"
        center.normalizeEffort(supported: ["low", "medium", "high"])
        precondition(center.reasoningEffort == "high")
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 920, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScholiaRepairView(center: center).environmentObject(AppModel.shared))
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await courseUISettle()
        for identifier in ["repair-note", "repair-model", "repair-effort", "repair-launch"] {
            _ = try await courseUIWaitForElement(identifier, in: window)
        }
        try snapshot(window, at: output.appendingPathComponent("report-and-fix.png"))
        window.setContentSize(NSSize(width: 760, height: 580))
        try await courseUISettle()
        let bounds = window.convertToScreen(NSRect(origin: .zero, size: window.contentLayoutRect.size))
        for identifier in ["repair-model", "repair-effort"] {
            let frame = try courseUIElement(identifier, in: window).accessibilityFrame()
            try courseUIRequire(frame.minX >= bounds.minX && frame.maxX <= bounds.maxX, "Repair settings fit at minimum width")
        }
        try snapshot(window, at: output.appendingPathComponent("report-and-fix-compact.png"))
        print("PASS: native repair report persistence, model/effort selection and CLI forwarding, legacy reports, screenshot removal, prompt delivery, streamed output, success, failure, cancellation and repair panel rendering (fixture CLI)")
    }

    static func checkSyncStatusUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-sync-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("sync-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let workspace = StudyWorkspaceModel(store: StudyLibraryStore(root: root))
        workspace.canvasBusy = true
        workspace.canvasStatus = "Math wiki: downloading 6 materials…"
        workspace.canvasWarnings = ["One Canvas file needs another download attempt."]
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        let window = controller.window
        window.appearance = NSAppearance(named: .aqua)
        controller.show()
        defer { window.close() }
        let icon = try await courseUIWaitForElement("workspace-sync-status", in: window)
        try courseUIRequire(icon.accessibilityValue() as? String == "In progress", "Active sync is announced by the toolbar icon")
        try courseUIRequire(icon.accessibilityFrame().midY > window.frame.maxY - 130, "Sync activity belongs in the top toolbar")
        try snapshot(window, at: output.appendingPathComponent("toolbar-active.png"))
        try await courseUIPress("workspace-sync-status", in: window)
        var popup: NSWindow?
        for _ in 0..<20 where popup == nil {
            popup = NSApp.windows.first { candidate in
                courseUIElements(in: candidate).contains { $0.accessibilityIdentifier() == "workspace-sync-details" }
            }
            if popup == nil { try await courseUISettle() }
        }
        let panel = try courseUIUnwrap(popup)
        try courseUIRequire(courseUIElements(in: panel).contains { $0.accessibilityLabel() == "Stop" }, "Stop remains available in sync details")
        try snapshot(panel, at: output.appendingPathComponent("details-light.png"))
        window.appearance = NSAppearance(named: .darkAqua)
        panel.appearance = NSAppearance(named: .darkAqua)
        try await courseUISettle()
        try snapshot(panel, at: output.appendingPathComponent("details-dark.png"))
        try await courseUIPress("workspace-sync-status", in: window)
        workspace.canvasBusy = false
        workspace.canvasStatus = "Math wiki: 6 materials downloaded or updated."
        workspace.canvasWarnings = []
        try await courseUISettle()
        let idle = try await courseUIWaitForElement("workspace-sync-status", in: window)
        try courseUIRequire(idle.accessibilityValue() as? String == "Idle" && !workspace.syncActivity.active, "The sync indicator stops when work finishes")
        print("PASS: native top-toolbar sync icon, active/idle transitions, opening details, Stop action, and light/dark popover rendering")
    }

    /// Exercise the real SwiftUI accessibility actions with an isolated library.
    /// No Canvas session, provider request, or user document is needed.
    static func checkCourseUI() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("scholia-course-ui-\(UUID())")
        let store = StudyLibraryStore(root: root)
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("course-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let preferences = ["study.automaticallyUpdateCanvasContent", "study.automaticallyUpdateMathWiki", "study.materialsExpanded"]
        let previous = preferences.map { UserDefaults.standard.object(forKey: $0) }
        UserDefaults.standard.set(false, forKey: preferences[0])
        UserDefaults.standard.set(false, forKey: preferences[1])
        UserDefaults.standard.set(true, forKey: preferences[2])
        defer {
            for (key, value) in zip(preferences, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let date = Date(timeIntervalSince1970: 1_791_283_500)
        var documents: [StudyDocument] = []
        var materials: [CanvasMaterialReference] = []
        let names = [
            "Intro_til_Simulink_og_blokkdiagram_med_lange_filnavn_og_mange_detaljer.pdf",
            "Eksamen_TTK4100_2024_bokmål_oppgaver_og_vedlegg.pdf",
            "LF_TTK4100_2023_komplett_løsningsforslag.pdf",
            "Om emnerommet og praktisk informasjon.md"
        ]
        for (offset, name) in names.enumerated() {
            var document = try StudyDocumentImporter.read(data: offset < 3 ? fixturePDF() : Data("Course information and practical reading guidance.".utf8),
                name: name, store: store)
            document.title = name
            document.sourceKey = "files:\(offset + 10)"
            document.sourceURL = "https://canvas.example/courses/4100/files/\(offset + 10)"
            document.sourceVersion = "1"
            if offset == 0 { document.lastOpenedAt = date; document.lastPage = 2 }
            documents.append(document)
            materials.append(CanvasMaterialReference(id: document.sourceKey!, kind: .files, remoteID: "\(offset + 10)",
                title: name, fileName: name, sourceURL: document.sourceURL!, version: "1",
                moduleID: offset == 3 ? 2 : 1, moduleTitle: offset == 3 ? "LES HER / READ ME" : "Tidligere eksamensoppgaver og løsningsforslag",
                modulePosition: offset == 3 ? 1 : 2, moduleItemPosition: offset))
        }
        for index in 0..<10 {
            materials.append(CanvasMaterialReference(id: "files:\(100 + index)", kind: .files, remoteID: "\(100 + index)",
                title: "Forelesning_\(index + 1)_reguleringsteknikk_tilstandsrom_modellering_og_simulering.pdf",
                fileName: "lecture-\(index + 1).pdf", sourceURL: "https://canvas.example/courses/4100/files/\(100 + index)", version: "1",
                moduleID: 3, moduleTitle: "Forelesninger og ekstra materialer", modulePosition: 3, moduleItemPosition: index))
        }
        let warnings = ["Pages: Canvas returned HTTP 404.", "Files: Canvas has not granted access to this resource."]
        let answer = (1...12).map { index in
            "**Topic \(index): Feedback and modelling.** Connect the physical system to its mathematical model, identify the input and output, then use a simple example to test your understanding. Saved course information should be checked against Canvas when a collection is unavailable."
        }.joined(separator: "\n\n")
        let draft = "Keep this unsent question about feedback and stability."
        let thread = StudyThread(title: "What should I study next?", messages: [
            ConversationMessage(role: .user, content: "Help me plan my studying for this course."),
            ConversationMessage(role: .assistant, content: answer)
        ], draft: draft)
        let course = StudyCourse(name: "Kybernetikk, introduksjon", code: "TTK4100", documents: documents,
            threads: [thread], canvasID: 4100, canvasOrigin: "https://canvas.example", canvasMaterials: materials,
            catalogUpdatedAt: date, catalogWarnings: warnings, term: "2026 HØST",
            canvasFileSync: CanvasCourseFileSync(knownFileIDs: materials.map(\.id), checkedAt: date,
                error: warnings.joined(separator: "\n"), summary: "No new files to download."))
        let second = StudyCourse(name: "A second course for navigation and search isolation", code: "TMA4115",
            documents: [documents[0]])
        let empty = StudyCourse(name: "A course waiting for its first index", code: "EMPTY", canvasID: 4200,
            canvasOrigin: "https://canvas.example")
        try store.save(StudyLibrary(courses: [course, second, empty], selectedCourseID: course.id,
            selectedThreadID: thread.id, showingCourseLibrary: false))
        let workspace = StudyWorkspaceModel(store: store, canvasClientFactory: { _, _, _ in
            throw StudyError.message("This UI fixture never connects to Canvas.")
        })
        let controller = StudyWindowController(app: AppModel.shared, workspace: workspace, autosave: false)
        let window = controller.window
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1_680, height: 1_000))
        controller.show()
        defer { window.close() }
        let toggle: CourseUIAccessibility
        do {
            toggle = try await courseUIWaitForElement("course-chat-toggle", in: window)
        } catch {
            try snapshot(window, at: output.appendingPathComponent("course-mount-failure.png"))
            throw error
        }
        try snapshot(window, at: output.appendingPathComponent("course-initial.png"))
        try courseUIRequire(toggle.accessibilityValue() as? String == "Collapsed", "Course chat must begin collapsed")
        try courseUIRequire(!courseUIElements(in: window).contains { $0.accessibilityIdentifier() == "course-sync-details" },
            "Raw sync diagnostics must begin collapsed")
        let titles = courseUIElements(in: window).compactMap { $0.accessibilityLabel() }
        try courseUIRequire(titles.contains("Open original source for \(names[3])"), "Source links must have a useful accessible name")
        try await courseUIPress("course-sync-toggle", in: window)
        try courseUIRequire(try courseUIElement("course-sync-toggle", in: window).accessibilityValue() as? String == "Expanded",
            "Details must expose its expanded state")
        try courseUIRequire(courseUIElements(in: window).contains { $0.accessibilityIdentifier() == "course-sync-details" },
            "Details must reveal diagnostic content")
        try snapshot(window, at: output.appendingPathComponent("sync-details.png"))
        try await courseUIPress("course-sync-toggle", in: window)
        try await courseUIPress("course-chat-toggle", in: window)
        try courseUIRequire(workspace.draft == draft, "Opening chat must preserve an existing draft")
        try courseUIRequire(window.firstResponder is BoundedComposerTextView, "Opening chat must focus its composer")
        let openedFrame = window.frame
        for _ in 0..<3 {
            try await courseUIPress("course-chat-toggle", in: window)
            try courseUIRequire(workspace.draft == draft, "Collapsing chat must preserve the draft")
            try await courseUIPress("course-chat-toggle", in: window)
            try courseUIRequire(workspace.draft == draft && workspace.messages.count == 2,
                "Reopening chat must preserve draft and transcript")
        }
        try courseUIRequire(window.frame == openedFrame, "Repeated chat toggles must not resize the window")

        for (name, size, appearance) in [
            ("wide", NSSize(width: 1_680, height: 1_000), NSAppearance.Name.aqua),
            ("standard", NSSize(width: 1_280, height: 800), .aqua),
            ("compact", NSSize(width: 1_040, height: 700), .aqua),
            ("dark", NSSize(width: 1_280, height: 800), .darkAqua)
        ] {
            window.setContentSize(size)
            window.appearance = NSAppearance(named: appearance)
            let frame = window.frame
            try await courseUISettle()
            try courseUIRequire(window.frame == frame, "\(name): content must not grow the window")
            let chat = try courseUIElement("course-chat-panel", in: window).accessibilityFrame()
            try courseUIRequire(chat.width > 450 && chat.height >= 480 && chat.height <= 780,
                "\(name): chat must remain bounded and usable (actual \(chat))")
            let content = window.convertToScreen(try courseUIUnwrap(window.contentView).bounds)
            try courseUIRequire(chat.minX >= content.minX - 2 && chat.maxX <= content.maxX + 2,
                "\(name): chat must not overflow the window horizontally")
            // Include the space reserved for a non-overlay macOS scrollbar.
            try courseUIRequire(content.maxX - chat.maxX <= 48,
                "\(name): the course must stretch to the right edge (gap \(content.maxX - chat.maxX))")
            if name == "wide" {
                try courseUIRequire(chat.width > 1_100,
                    "Wide course content must expand beyond the old centered width cap")
            }
            let editor = try courseUIUnwrap(find(BoundedComposerTextView.self, in: try courseUIUnwrap(window.contentView)))
            try courseUIRequire(editor.bounds.height >= 32 && editor.string == draft,
                "\(name): composer must keep its text and useful editing height")
            try snapshot(window, at: output.appendingPathComponent("course-\(name).png"))
        }
        workspace.mode = .chat
        workspace.saveDraft()
        try await courseUISettle()
        try courseUIRequire(workspace.thread?.mode == .chat && workspace.draft == draft && workspace.messages.count == 2,
            "General Chat mode must persist without losing the conversation")
        _ = try courseUIElement("course-chat-mode", in: window)
        try courseUIRequire(PromptBuilder.systemPrompt(language: "en", mode: .chat).contains("conversational assistant"),
            "Chat mode must use general conversation guidance")
        try snapshot(window, at: output.appendingPathComponent("course-general-chat.png"))
        workspace.mode = .explain
        workspace.saveDraft()
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(NSSize(width: 1_280, height: 800))
        try await courseUIPress("course-chat-toggle", in: window)
        try await courseUIEditTextField("course-material-search", value: "zz-no-matching-material-zz", in: window)
        try await courseUISettle()
        try courseUIRequire(try courseUIElement("course-material-search", in: window).accessibilityValue() as? String == "zz-no-matching-material-zz",
            "Material search must accept native text editing")
        try snapshot(window, at: output.appendingPathComponent("search-empty.png"))
        try courseUIRequire(courseUIElements(in: window).contains {
            $0.accessibilityLabel() == "No matching materials" || $0.accessibilityValue() as? String == "No matching materials"
        },
            "Filtering to zero matches must expose an empty result state")
        try courseUIRequire(workspace.draft == draft, "Searching materials must preserve the course draft")
        workspace.selectCourse(second.id)
        try await courseUISettle()
        try courseUIRequire(try courseUIElement("course-material-search", in: window).accessibilityValue() as? String == "",
            "A different course must start with an unfiltered materials list")
        workspace.selectCourse(course.id)
        try await courseUISettle()
        try courseUIRequire(try courseUIElement("course-material-search", in: window).accessibilityValue() as? String == "",
            "Returning to a course must not leave an invisible stale filter")
        try await courseUIPress("course-chat-toggle", in: window)
        try courseUIRequire(workspace.draft == draft, "Cross-course navigation must preserve the saved course draft")

        workspace.error = "Fixture provider unavailable. This deliberately long error checks that errors wrap without squeezing the message history or the composer."
        workspace.selectedText = "A long selected passage about feedback loops, modelling assumptions, transfer functions, and their effect on system stability."
        workspace.draftImage = try courseUIAttachment()
        try await courseUISettle()
        let expanded = try courseUIElement("course-chat-panel", in: window).accessibilityFrame()
        try courseUIRequire(expanded.height >= 700 && expanded.height <= 1_040,
            "Image, quote, and error must leave usable space for the conversation (actual \(expanded))")
        try snapshot(window, at: output.appendingPathComponent("chat-attachment-error.png"))
        workspace.error = nil; workspace.selectedText = ""; workspace.draftImage = nil
        workspace.selectCourse(empty.id)
        try await courseUISettle()
        try courseUIRequire(!courseUIElements(in: window).contains { $0.accessibilityIdentifier() == "course-material-search" },
            "An empty unindexed course must not show a useless search field")
        try snapshot(window, at: output.appendingPathComponent("course-empty.png"))
        if !CommandLine.arguments.contains("--course-layout-only") {
            try await checkQuickSwitcherUI(window: window, workspace: workspace, first: course, second: second, output: output)
        }
        workspace.flush()
        print("PASS: native course UI, accessible controls, sync disclosure, draft preservation, filtering, cross-course reset, bounded layouts, and attachment/error resilience")
    }

    private static func checkQuickSwitcherUI(window: NSWindow, workspace: StudyWorkspaceModel,
        first: StudyCourse, second: StudyCourse, output: URL) async throws {
        window.setContentSize(NSSize(width: 1_280, height: 800))
        window.appearance = NSAppearance(named: .aqua)
        workspace.selectCourse(first.id)
        workspace.draft = "Keep this draft when jumping between courses."
        workspace.saveDraft()
        try await courseUISettle()
        func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [], in target: NSWindow) throws -> NSEvent {
            // Let AppKit translate Command/Shift and the active keyboard layout
            // instead of inventing inconsistent character/modifier combinations.
            let keyboard = try courseUIUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            keyboard.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
            let translated = try courseUIUnwrap(NSEvent(cgEvent: keyboard))
            return try courseUIUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: translated.characters ?? characters,
                charactersIgnoringModifiers: translated.charactersIgnoringModifiers ?? characters,
                isARepeat: false, keyCode: code))
        }
        func openQuick() async throws -> NSWindow {
            let handled = window.performKeyEquivalent(with: try key("K", code: 40, modifiers: [.command, .shift], in: window))
            try courseUIRequire(handled, "Command-Shift-K must be handled by the workspace")
            // AppKit may still report the departing search sheet during its
            // dismissal animation. Wait for the new presentation, not that window.
            for _ in 0..<30 {
                if let sheet = window.attachedSheet,
                    let field = try? courseUIElement("workspace-shortcuts-query", in: sheet),
                    field.accessibilityFrame().width > 0, sheet.firstResponder is NSTextView {
                    return sheet
                }
                try await courseUISettle()
            }
            if let sheet = window.attachedSheet {
                try snapshot(sheet, at: output.appendingPathComponent("quick-jump-open-failure.png"))
            }
            throw StudyError.message("Quick jump must open and focus its search field")
        }
        func choose(_ text: String) async throws {
            print("Quick jump: \(text)")
            let sheet = try await openQuick()
            try await courseUIEditTextField("workspace-shortcuts-query", value: text, in: sheet)
            try await courseUISettle()
            sheet.sendEvent(try key("\r", code: 36, in: sheet))
            for _ in 0..<30 where window.attachedSheet === sheet { try await courseUISettle() }
        }
        let sheet = try await openQuick()
        try snapshot(sheet, at: output.appendingPathComponent("quick-jump.png"))
        sheet.sendEvent(try key("\u{f701}", code: 125, in: sheet))
        sheet.sendEvent(try key("\u{f700}", code: 126, in: sheet))
        try await courseUIEditTextField("workspace-shortcuts-query", value: "no such workspace", in: sheet)
        try await courseUISettle()
        sheet.sendEvent(try key("\r", code: 36, in: sheet))
        try courseUIRequire(window.attachedSheet === sheet, "Enter with no matches must leave quick jump open")
        sheet.sendEvent(try key("\u{1b}", code: 53, in: sheet))
        for _ in 0..<30 where window.attachedSheet === sheet { try await courseUISettle() }
        try courseUIRequire(window.attachedSheet == nil, "Escape must close quick jump")
        try await choose(second.code)
        try courseUIRequire(workspace.course?.id == second.id, "A course code must switch workspace")
        try await choose(first.code)
        try courseUIRequire(workspace.course?.id == first.id && workspace.draft == "Keep this draft when jumping between courses.",
            "Switching workspace must preserve and restore the draft")
        try await choose("> assignments")
        try courseUIRequire(workspace.isShowingAssignments, "Quick actions must open assignments")
        try await choose("> search all")
        for _ in 0..<30 where window.attachedSheet == nil { try await courseUISettle() }
        let search = try courseUIUnwrap(window.attachedSheet)
        _ = try await courseUIWaitForElement("workspace-search-query", in: search)
        let hits = try await workspace.fileSearch.search(courses: workspace.library.courses,
            store: workspace.store, query: first.code)
        try courseUIRequire(hits.results.count >= 2 && hits.results[1].documentID != nil, "Search fixture needs two saved results")
        let expected = hits.results[1]
        try await courseUIEditTextField("workspace-search-query", value: first.code, in: search)
        _ = try await courseUIWaitForElement("workspace-search-hit-\(expected.id)", in: search)
        search.sendEvent(try key("\u{f701}", code: 125, in: search))
        try await courseUISettle()
        search.sendEvent(try key("\r", code: 36, in: search))
        for _ in 0..<30 where window.attachedSheet === search { try await courseUISettle() }
        try courseUIRequire(window.attachedSheet == nil, "Opening a search result must dismiss library search")
        try courseUIRequire(workspace.document?.id.uuidString == expected.documentID,
            "Arrow keys and Enter must open the selected coursework search result")
        // AppKit detaches a sheet before its closing animation and responder
        // handoff finish. Send the next shortcut after that handoff, as a real
        // key event would be routed, rather than directly to the parent early.
        for _ in 0..<30 where search.isVisible || !window.isKeyWindow { try await courseUISettle() }
        try courseUIRequire(!search.isVisible && window.isKeyWindow, "Search must finish closing before the next shortcut")
        try await choose("> new workspace")
        for _ in 0..<30 where window.attachedSheet == nil { try await courseUISettle() }
        let create = try courseUIUnwrap(window.attachedSheet)
        try courseUIRequire(courseUIElements(in: create).contains { $0.accessibilityLabel() == "Create workspace" },
            "New workspace must open its form after quick jump closes")
        create.sendEvent(try key("\u{1b}", code: 53, in: create))
        for _ in 0..<30 where window.attachedSheet === create { try await courseUISettle() }
        print("PASS: native quick-jump shortcut, typing, Enter/Escape, workspace navigation, draft preservation, coursework search arrows, and action sheets")
    }

    private struct CourseUIAccessibility {
        let object: AnyObject
        func accessibilityIdentifier() -> String? { object.accessibilityIdentifier?() ?? nil }
        func accessibilityLabel() -> String? { object.accessibilityLabel?() ?? nil }
        func accessibilityValue() -> Any? { object.accessibilityValue?() ?? nil }
        func accessibilityFrame() -> NSRect { object.accessibilityFrame?() ?? .zero }
        func accessibilityPerformPress() -> Bool { object.accessibilityPerformPress?() ?? false }
        var children: [Any] { (object.accessibilityChildren?() ?? nil) ?? [] }
    }

    private static func courseUIElements(in root: Any) -> [CourseUIAccessibility] {
        var stack: [Any] = [root], seen = Set<ObjectIdentifier>(), result: [CourseUIAccessibility] = []
        while let next = stack.popLast(), seen.count < 20_000 {
            let object = next as AnyObject
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            // SwiftUI accessibility proxies implement these selectors without
            // declaring conformance to AppKit's full NSAccessibilityProtocol.
            let element = CourseUIAccessibility(object: object)
            result.append(element)
            stack.append(contentsOf: element.children)
            if let window = next as? NSWindow, let content = window.contentView { stack.append(content) }
            if let view = next as? NSView { stack.append(contentsOf: view.subviews) }
        }
        return result
    }

    private static func courseUIElement(_ id: String, in window: NSWindow) throws -> CourseUIAccessibility {
        let matches = courseUIElements(in: window).filter { $0.accessibilityIdentifier() == id }
        if let match = matches.max(by: { $0.accessibilityFrame().height < $1.accessibilityFrame().height }) { return match }
        let identifiers = courseUIElements(in: window).compactMap { $0.accessibilityIdentifier() }
        throw StudyError.message("Missing accessibility element \(id). Found: \(identifiers)")
    }

    static func courseUIPress(_ id: String, in window: NSWindow) async throws {
        let element = try await courseUIWaitForElement(id, in: window)
        try courseUIRequire(element.accessibilityPerformPress(), "Could not activate \(id)")
        try await courseUISettle()
    }

    private static func courseUIWaitForElement(_ id: String, in window: NSWindow) async throws -> CourseUIAccessibility {
        // SwiftUI accessibility proxies appear after the hosted split views have
        // completed their first layout. Package builds can make that slower.
        for _ in 0..<50 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if let element = try? courseUIElement(id, in: window), element.accessibilityFrame().width > 0 { return element }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try courseUIElement(id, in: window)
    }

    private static func courseUIEditTextField(_ id: String, value: String, in window: NSWindow) async throws {
        let fields = courseUIElements(in: window).compactMap { $0.object as? NSTextField }
        guard let field = fields.first(where: { $0.accessibilityIdentifier() == id })
            ?? fields.first(where: { $0.placeholderString == "Search materials" }) else {
            throw StudyError.message("Missing native search field \(id). Fields: \(fields.map { $0.accessibilityIdentifier() + ":" + ($0.placeholderString ?? "") })")
        }
        try courseUIRequire(window.makeFirstResponder(field), "Could not focus \(id)")
        field.selectText(nil)
        for _ in 0..<30 {
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectAll(nil)
                editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw StudyError.message("Native search field \(id) never acquired a text editor; first responder: \(String(describing: window.firstResponder))")
    }

    private static func courseUISettle() async throws { try await Task.sleep(for: .milliseconds(250)) }
    private static func courseUIRequire(_ condition: Bool, _ message: String) throws {
        if !condition { throw StudyError.message(message) }
    }
    private static func courseUIUnwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw StudyError.message("Missing native UI fixture value") }; return value
    }
    private static func courseUIAttachment() throws -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 100))
        image.lockFocus()
        NSColor.systemGreen.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: 0, width: 240, height: 100).fill()
        ("Feedback → System → Output" as NSString).draw(at: NSPoint(x: 20, y: 42),
            withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        image.unlockFocus()
        let bitmap = try courseUIUnwrap(NSBitmapImageRep(data: try courseUIUnwrap(image.tiffRepresentation)))
        return try courseUIUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
