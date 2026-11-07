@preconcurrency import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

typealias StudyCompletion =
    @MainActor (
        [ConversationMessage], ProviderConfiguration, @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CompletionResult

@MainActor
final class StudyWorkspaceModel: ObservableObject {
    @Published var library: StudyLibrary
    @Published private(set) var documentIndex: StudyDocumentIndex?
    @Published private(set) var documentOCRProgress: String?
    @Published var currentPage = 1
    @Published var selectedText = ""
    @Published var draftImage: Data?
    @Published var draftAttachments: [MessageAttachment] = []
    @Published var isIngestingAttachment = false
    @Published var attachmentStatus: String?
    var attachmentTask: Task<Void, Never>?
    var attachmentQueuedURLs: [URL] = []
    var attachmentPromiseCount = 0
    var attachmentDraftGeneration = UUID()
    @Published var selectingFigure = false
    @Published var includeCourseContext = false
    @Published var automaticContextEnabled = true
    @Published var error: String?
    @Published var activity: String?
    @Published private(set) var isImporting = false
    @Published private(set) var streamingThreadID: UUID?
    @Published private(set) var answerStartedAt: Date?
    @Published private(set) var contextSummary = ""
    @Published private(set) var tutorFocusRequest = 0
    @Published var canvasPresented = false
    @Published var canvasSigningIn = false
    @Published private(set) var canvasConnectionStatus = "Checking saved connection…"
    @Published private(set) var canvasChecking = false
    private var canvasConnectionCheckID = UUID()
    @Published var canvasAddress = "https://canvas.ntnu.no"
    @Published var canvasCourses: [CanvasCourseSummary] = []
    @Published var canvasStatus: String?
    @Published var canvasWarnings: [String] = []
    @Published var canvasBusy = false
    @Published private(set) var canvasFileSyncRunning = false
    @Published private(set) var canvasContentSyncRunning = false
    @Published private(set) var queuedCanvasCourseUpdateIDs: [UUID] = []
    @Published private(set) var manualCanvasCourseUpdateID: UUID?
    private var queuedCanvasCourseUpdateAccount: (origin: String, userID: Int)?
    private var automaticCanvasContentSyncRunning = false
    private let mathWikiClient: MathWikiClient
    private let mathWikiMaterials: CanvasClient
    private var automaticMathWikiSyncRunning = false
    @Published var automaticallyUpdateMathWiki =
        UserDefaults.standard.object(forKey: "study.automaticallyUpdateMathWiki") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(automaticallyUpdateMathWiki, forKey: "study.automaticallyUpdateMathWiki")
            if !automaticallyUpdateMathWiki && automaticMathWikiSyncRunning { canvasTask?.cancel() }
        }
    }
    @Published var automaticallyUpdateCanvasContent =
        UserDefaults.standard.bool(forKey: "study.automaticallyUpdateCanvasContent") {
        didSet {
            UserDefaults.standard.set(automaticallyUpdateCanvasContent, forKey: "study.automaticallyUpdateCanvasContent")
            if !automaticallyUpdateCanvasContent && automaticCanvasContentSyncRunning { canvasTask?.cancel() }
        }
    }
    @Published var automaticallyDownloadNewCanvasFiles =
        UserDefaults.standard.object(forKey: "study.automaticallyDownloadNewCanvasFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automaticallyDownloadNewCanvasFiles, forKey: "study.automaticallyDownloadNewCanvasFiles") }
    }
    @Published var canvasDownloadPriority: CanvasDownloadPriority = .background {
        didSet {
            canvasDownloadTaskPriority.update(canvasDownloadPriority)
            if canvasDownloadPriority == .prioritized { cancelPreloading() }
        }
    }
    private let canvasDownloadTaskPriority = CanvasDownloadTaskPriority(.background)
    @Published private(set) var canvasDownloadPendingCount = 0
    private var canvasDownloadProgress: CanvasDownloadProgress?
    private let canvasDownloadProgressStore: CanvasDownloadProgressStore
    private var canvasMaterialTransfers: [String: CanvasMaterialTransfer] = [:]
    private var canvasHTMLUpgradeAttempts = Set<UUID>()
    @Published private(set) var canvasVerifyingDownloads = false
    @Published private(set) var canvasVerificationStatus: String?
    private var canvasVerificationTask: Task<Void, Never>?
    @Published private(set) var fetchingMaterialID: String?
    @Published private(set) var canvasActivityCourseID: UUID?
    @Published var mode: StudyTeachingMode = .explain
    @Published var includeEntirePDF = false
    let composerDraft = StudyComposerDraft()
    var draft: String {
        get { composerDraft.text }
        set { composerDraft.text = newValue }
    }
    private var draftSaveTask: Task<Void, Never>?
    @Published var practicePresented = false
    @Published var examPlannerPresented = false {
        didSet { if examPlannerPresented { exitDocumentFocusIfIneligible() } }
    }
    @Published var examRecommendationBusy = false
    @Published var studentwebImportRequested = false
    // Deliberately outside StudyLibrary and every web/provider serialization.
    @Published var courseCompletions: [StudyCourseCompletion] = []
    @Published var courseCompletionsBusy = false
    @Published var courseCompletionsError: String?
    var courseCompletionsLoaded = false
    let completionStore: StudyCourseCompletionStore
    lazy var studentwebResultsConnection = StudentwebResultsConnection()
    @Published var practiceScreen = "setup"
    @Published var practiceSourceScope = "reading"
    let learning: StudyLearningModel
    var practiceTask: Task<Void, Never>?
    var practiceTicket: UUID?
    @Published private(set) var editingMessageID: UUID?
    @Published private(set) var assignmentText = ""
    @Published private(set) var assignmentNotice: String?
    @Published private(set) var assignmentFileNotices: [String: String] = [:]
    @Published private(set) var assignmentPreparing = false
    @Published var assignmentPDFFocused = true
    /// Document focus hides the sidebar and top bar and pairs with native full
    /// screen; the study window mirrors it. Transient, never persisted.
    @Published var documentFocused = false
    @Published private(set) var assignmentPreparingFileID: String?
    @Published private(set) var assignmentActivity: [ConversationActivity] = []
    @Published private(set) var feedbackRefreshing: Set<String> = []
    @Published private(set) var feedbackErrors: [String: String] = [:]
    private var feedbackCheckedAt: [String: Date] = [:]
    private var assignmentPreparationTask: Task<Void, Never>?
    private var assignmentPreparationID: UUID?

    let store: StudyLibraryStore
    // The sidebar, overview and local web server share the active catalog.
    let materialListCache = StudyMaterialListCache()
    let fileSearch = StudyWorkspaceSearch()
    let documentEditing: StudyEditingState
    private var canSave = true
    private var answerTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var savingDocumentID: UUID?
    private var indexTask: Task<Void, Never>?
    private var indexLoadID = UUID()
    private var indexedDocument: DocumentContentIdentity?
    private struct DocumentContentIdentity: Equatable {
        var id: UUID
        var fileName: String
        var contentHash: String?
        var sourceVersion: String?
        var addedAt: Date
        var locallyEditedAt: Date?
        init(_ document: StudyDocument) {
            id = document.id
            fileName = document.fileName
            contentHash = document.contentHash
            sourceVersion = document.sourceVersion
            addedAt = document.addedAt
            locallyEditedAt = document.locallyEditedAt
        }
    }
    var classificationTask: Task<Void, Never>?
    private var canvasTask: Task<Void, Never>?
    @Published private(set) var assignmentRefreshBusy = false
    private var assignmentRefreshAttempt: Date?
    private var activeAnswerID: UUID?
    private var canvasClient: CanvasClient?
    private var canvasAccount: CanvasAccount?
    private var connectedOrigin: URL?
    private let canvasClientFactory: @MainActor (URL, Bool, Bool) async throws -> CanvasClient
    private var saveTask: Task<Void, Never>?
    private let libraryWriter: StudyLibraryWriter
    @Published private var backRoutes: [StudyNavigation] = []
    @Published private var forwardRoutes: [StudyNavigation] = []
    @Published var preloadFrequentCourses =
        UserDefaults.standard.object(forKey: "study.preloadFrequentCourses") as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(preloadFrequentCourses, forKey: "study.preloadFrequentCourses")
            if !preloadFrequentCourses { cancelPreloading() }
        }
    }
    @Published private(set) var preloadStatus: String?
    private var preloadTask: Task<Void, Never>?
    private var preloadTicket: UUID?
    private var restoringNavigation = false
    var canGoBack: Bool { !backRoutes.isEmpty }
    var canGoForward: Bool { !forwardRoutes.isEmpty }
    private var navigation: StudyNavigation {
        StudyNavigation(
            library: isShowingLibrary, course: course?.id, document: document?.id, assignment: assignment?.id,
            assignmentFile: library.selectedAssignmentFileID, thread: thread?.id, page: currentPage,
            libraryView: courseLibraryView)
    }
    private func recordNavigation() {
        guard !restoringNavigation else { return }
        saveDraft()
        if backRoutes.last != navigation { backRoutes.append(navigation) }
        if backRoutes.count > 80 { backRoutes.removeFirst() }
        forwardRoutes.removeAll()
    }
    func goBack() {
        saveDraft()
        guard let target = backRoutes.popLast() else { return }
        forwardRoutes.append(navigation)
        restoreNavigation(target)
    }
    func goForward() {
        saveDraft()
        guard let target = forwardRoutes.popLast() else { return }
        backRoutes.append(navigation)
        restoreNavigation(target)
    }
    private func restoreNavigation(_ target: StudyNavigation) {
        cancelAssignmentPreparation()
        restoringNavigation = true
        defer { restoringNavigation = false }
        saveBeforeNavigating()
        cancelPracticePreparation()
        cancelPreloading()
        let course = library.courses.first { $0.id == target.course }
        library.selectedCourseID = course?.id
        library.showingCourseLibrary = target.library || course == nil
        library.courseLibraryView = target.libraryView
        library.selectedDocumentID = course?.documents.first { $0.id == target.document }?.id
        library.selectedAssignmentID = course?.materials.first { $0.id == target.assignment }?.id
        library.selectedAssignmentFileID = target.assignmentFile
        library.selectedThreadID = course?.threads.first { $0.id == target.thread }?.id
        restoreThread()
        loadSelectedDocument()
        loadAssignmentText()
        setPage(target.page)
        exitDocumentFocusIfIneligible()
        save()
    }
    private func saveBeforeNavigating() {
        examPlannerPresented = false
        saveDraft()
        saveTask?.cancel()
        documentEditing.flush()
        save()
    }
    private func cancelPreloading() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadTicket = nil
        preloadStatus = nil
    }

    private func visitedCourse() {
        cancelPreloading()
        guard let ci = courseIndex(), !isShowingLibrary else { return }
        let last = library.courses[ci].lastVisitedAt ?? .distantPast
        if Date().timeIntervalSince(last) > 60 {
            library.courses[ci].visitCount = (library.courses[ci].visitCount ?? 0) + 1
            library.courses[ci].lastVisitedAt = Date()
        }
        guard preloadFrequentCourses, let course, !StudyCoursePreloading.candidates(in: course).isEmpty else { return }
        let ticket = UUID()
        preloadTicket = ticket
        preloadTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
                guard let self else { return }
                defer {
                    // A cancelled task can finish after a new visit has scheduled another.
                    if preloadTicket == ticket {
                        preloadStatus = nil
                        preloadTask = nil
                        preloadTicket = nil
                    }
                }
                guard canPreload(courseID: course.id, ticket: ticket) else { return }
                let client = try await connectedClient(for: course)
                for item in StudyCoursePreloading.candidates(in: course) {
                    try Task.checkCancellation()
                    guard canPreload(courseID: course.id, ticket: ticket) else { return }
                    preloadStatus = "Saving \(item.title) for offline use…"
                    _ = try await fetchMaterial(item, courseID: course.id, client: client, background: true)
                }
            } catch {
                // Expired sign-in or failed background transfers must not interrupt reading.
                if let self, preloadTicket == ticket {
                    preloadStatus = nil
                    preloadTask = nil
                    preloadTicket = nil
                }
            }
        }
    }

    private func canPreload(courseID: UUID, ticket: UUID) -> Bool {
        preloadTicket == ticket && preloadFrequentCourses && !isShowingLibrary
            && !canvasBusy && !assignmentPreparing && !isImporting && !isStreaming && course?.id == courseID
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue
    }

    private struct SemesterInput: Equatable {
        var id: UUID
        var name: String
        var code: String
        var term: String?
        var favorite: Bool
        init(_ course: StudyCourse) {
            id = course.id
            name = course.name
            code = course.code
            term = course.term
            favorite = course.isFavorite
        }
    }
    private var semesterCache: (input: [SemesterInput], current: StudySemester, groups: [StudySemesterGroup])?

    init(store: StudyLibraryStore = StudyLibraryStore(),
        completionStore: StudyCourseCompletionStore? = nil,
        mathWikiSession: URLSession? = nil,
        canvasClientFactory: @escaping @MainActor (URL, Bool, Bool) async throws -> CanvasClient = {
            try await CanvasSession.client(origin: $0, useBrowserSession: $1, allowKeychainInteraction: $2)
        }) {
        self.store = store
        self.completionStore = completionStore ?? .keychain(root: store.root)
        mathWikiClient = MathWikiClient(session: mathWikiSession)
        mathWikiMaterials = CanvasClient(origin: MathWikiAddress.origin, session: mathWikiSession, mathWikiClient: mathWikiClient)
        canvasDownloadProgressStore = CanvasDownloadProgressStore(root: store.root)
        canvasDownloadProgress = try? CanvasDownloadProgressStore.load(root: store.root)
        canvasDownloadPendingCount = canvasDownloadProgress?.remainingCourseIDs.count ?? 0
        self.canvasClientFactory = canvasClientFactory
        libraryWriter = StudyLibraryWriter(store: store)
        learning = StudyLearningModel(root: store.root)
        documentEditing = StudyEditingState(store: store)
        do { library = try store.load() } catch {
            library = StudyLibrary()
            canSave = false
            self.error =
                "Could not open your study library: \(error.localizedDescription) The original library has been preserved."
        }
        canvasAddress = library.canvasOrigin
        canvasStatus = library.canvasRefreshSummary
        canvasWarnings = library.courses.flatMap { course in
            (course.catalogWarnings ?? []).map { "\(course.code.isEmpty ? course.name : course.code): \($0)" }
        }
        if let course = library.courses.first(where: { $0.id == library.selectedCourseID }) {
            if let thread = course.threads.first(where: { $0.id == library.selectedThreadID }) {
                draft = thread.draft
                draftImage = thread.draftImage
                draftAttachments = thread.draftAttachments ?? []
                mode = thread.mode
                includeEntirePDF = thread.entirePDF == true
                automaticContextEnabled = thread.automaticContextEnabled ?? true
                includeCourseContext = thread.includeCourseContext ?? false
            }
        } else {
            library.selectedCourseID = library.courses.first?.id
            library.selectedDocumentID = nil
            library.selectedThreadID = nil
        }
        loadSelectedDocument()
        loadAssignmentText()
        composerDraft.onChange = { [weak self] in self?.scheduleDraftSave() }
        if canSave { backfillClassifications() }
    }

    var isShowingLibrary: Bool { library.showingCourseLibrary ?? (library.selectedCourseID == nil) }
    var isShowingAssignments: Bool { isShowingLibrary && courseLibraryView == .assignments }
    var courseLibraryView: StudyCourseLibraryViewMode { library.courseLibraryView ?? .all }
    var semesterGroups: [StudySemesterGroup] {
        let input = library.courses.map(SemesterInput.init)
        let current = StudySemester.current()
        if let cache = semesterCache, cache.input == input, cache.current == current { return cache.groups }
        let groups = StudySemesterGroup.make(courses: sortedCourses)
        semesterCache = (input, current, groups)
        return groups
    }
    var selectedSemesterID: String {
        let id = library.selectedSemesterID ?? "all"
        return id == "all" || semesterGroups.contains(where: { $0.id == id }) ? id : "all"
    }
    func setCourseLibraryView(_ mode: StudyCourseLibraryViewMode) {
        library.courseLibraryView = mode
        save()
    }
    func selectSemester(_ id: String) {
        guard id == "all" || semesterGroups.contains(where: { $0.id == id }) else { return }
        library.selectedSemesterID = id
        save()
    }
    var sortedCourses: [StudyCourse] {
        library.courses.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    var recentReadings: [StudyRecentReading] { StudyRecentReading.inCourses(library.courses) }
    func resumeReading(_ documentID: UUID) {
        guard let target = library.courses.first(where: { $0.documents.contains(where: { $0.id == documentID }) })
        else { return }
        recordNavigation()
        if course?.id != target.id { selectCourse(target.id, recordHistory: false) }
        selectDocument(documentID, recordHistory: false)
    }
    func prepareStudyPrompt(_ teachingMode: StudyTeachingMode) {
        if teachingMode == .practice {
            mode = .practice
            saveDraft()
            practiceScreen = "setup"
            practicePresented = true
            return
        }
        let prompt = teachingMode.starter(document: document)
        mode = teachingMode
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = prompt
        } else if !draft.contains(prompt) {
            draft += "\n\n" + prompt
        }
        saveDraft()
    }
    func sidebarCourses(matching query: String) -> [StudyCourse] {
        if !query.isEmpty {
            return sortedCourses.filter { ($0.name + " " + $0.code).localizedCaseInsensitiveContains(query) }
        }
        var visible = Array(sortedCourses.prefix(7))
        if let course, !visible.contains(where: { $0.id == course.id }) { visible.append(course) }
        return visible
    }
    func showCourseLibrary() {
        cancelAssignmentPreparation()
        recordNavigation()
        cancelPreloading()
        cancelPracticePreparation()
        saveBeforeNavigating()
        library.showingCourseLibrary = true
        if courseLibraryView == .assignments { library.courseLibraryView = .all }
        library.selectedAssignmentID = nil
        exitDocumentFocusIfIneligible()
        save()
    }
    func showAssignments() {
        cancelAssignmentPreparation()
        recordNavigation()
        cancelPreloading()
        cancelPracticePreparation()
        saveBeforeNavigating()
        library.showingCourseLibrary = true
        library.courseLibraryView = .assignments
        library.selectedAssignmentID = nil
        exitDocumentFocusIfIneligible()
        save()
        Task { await self.refreshCanvasAssignmentsIfNeeded() }
    }
    func showCourseMaterials() {
        cancelAssignmentPreparation()
        recordNavigation()
        cancelPracticePreparation()
        saveBeforeNavigating()
        library.showingCourseLibrary = false
        library.selectedDocumentID = nil
        library.selectedAssignmentID = nil
        library.selectedAssignmentFileID = nil
        library.selectedThreadID = course?.threads.last(where: { $0.documentID == nil && $0.assignmentID == nil })?.id
        restoreThread()
        loadSelectedDocument()
        exitDocumentFocusIfIneligible()
        save()
    }
    func askAboutCourse(question: String? = nil) {
        guard course != nil else { return }
        showCourseMaterials()
        if let question {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft = question
            } else if !draft.contains(question) {
                draft += "\n\n" + question
            }
            saveDraft()
        }
        focusTutor()
    }
    func focusTutor() { tutorFocusRequest += 1 }
    static func canFocusDocument(hasDocument: Bool, showingLibrary: Bool, examPlannerPresented: Bool) -> Bool {
        hasDocument && !showingLibrary && !examPlannerPresented
    }
    var canFocusDocument: Bool {
        Self.canFocusDocument(hasDocument: document != nil, showingLibrary: isShowingLibrary,
            examPlannerPresented: examPlannerPresented)
    }
    func toggleDocumentFocus() {
        if documentFocused { documentFocused = false } else if canFocusDocument { documentFocused = true }
    }
    func exitDocumentFocus() {
        if documentFocused { documentFocused = false }
    }
    private func exitDocumentFocusIfIneligible() {
        if documentFocused && !canFocusDocument { documentFocused = false }
    }
    /// Citation browsing can leave a course conversation beside an open reading.
    /// Explicit reader actions return to that reading's own saved conversation.
    func useOpenDocumentConversation() {
        guard isCourseConversation, let document else { return }
        let page = currentPage
        selectDocument(document.id)
        setPage(page)
    }
    func askAboutOpenDocument() {
        guard !isStreaming, !isIngestingAttachment else { return }
        guard isCourseConversation, document != nil else { focusTutor(); return }
        let question = draft
        let image = draftImage
        let attachments = draftAttachments
        let selection = selectedText
        let hasQuestion = !question.isEmpty || image != nil || !attachments.isEmpty || !selection.isEmpty
        useOpenDocumentConversation()
        if hasQuestion {
            let hasExistingDraft = !draft.isEmpty || draftImage != nil || !draftAttachments.isEmpty
            if hasExistingDraft && (draft != question || draftImage != image || draftAttachments != attachments) {
                newThread()
            }
            draft = question
            draftImage = image
            draftAttachments = attachments
            selectedText = selection
        }
        automaticContextEnabled = true
        saveDraft()
        focusTutor()
    }
    func openSelectionInChat(_ text: String, question: String = "") {
        useOpenDocumentConversation()
        selectedText = String(text.prefix(16_000))
        let comment = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !comment.isEmpty { draft = [draft, comment].filter { !$0.isEmpty }.joined(separator: "\n\n") }
        saveDraft()
        focusTutor()
    }
    /// Where the reader's explanation popover reads its answer from.
    struct SelectionResponseTarget: Equatable {
        var threadID: UUID
        var answerID: UUID
        var inChat: Bool
    }
    @Published private(set) var selectionResponseTarget: SelectionResponseTarget?

    /// The hidden one-shot thread that answers passage explanations for the
    /// open document. Emptied before each use so the popover shows one answer.
    private func selectionScratchThreadID() -> UUID? {
        guard let ci = courseIndex(), let document else { return nil }
        if let index = library.courses[ci].threads.firstIndex(where: { $0.isSelectionScratch == true && $0.documentID == document.id }) {
            library.courses[ci].threads[index].messages = []
            library.courses[ci].threads[index].sources = [:]
            return library.courses[ci].threads[index].id
        }
        var thread = StudyThread(documentID: document.id, mode: mode, automaticContextEnabled: automaticContextEnabled,
            includeCourseContext: includeCourseContext)
        thread.isSelectionScratch = true
        thread.title = "Selected passage"
        library.courses[ci].threads.append(thread)
        return thread.id
    }
    /// Moves the popover's explanation into the document conversation.
    func keepSelectionExplanationInChat() {
        guard let target = selectionResponseTarget, let ci = courseIndex(),
            let si = library.courses[ci].threads.firstIndex(where: { $0.id == target.threadID }),
            library.courses[ci].threads[si].isSelectionScratch == true,
            !library.courses[ci].threads[si].messages.isEmpty else {
            // Already in the conversation (or nothing to move): just go there.
            focusTutor()
            return
        }
        guard !isStreaming else { return }
        let scratch = library.courses[ci].threads[si]
        useOpenDocumentConversation()
        if threadIndex(in: ci) == nil {
            let thread = StudyThread(documentID: document?.id, assignmentID: assignment?.id, mode: mode)
            library.courses[ci].threads.append(thread)
            library.selectedThreadID = thread.id
        }
        guard let ti = threadIndex(in: ci) else { return }
        if library.courses[ci].threads[ti].messages.isEmpty, let first = scratch.messages.first {
            library.courses[ci].threads[ti].title = String(first.content.prefix(70))
        }
        library.courses[ci].threads[ti].messages.append(contentsOf: scratch.messages)
        library.courses[ci].threads[ti].sources.merge(scratch.sources) { _, new in new }
        library.courses[ci].threads[ti].updatedAt = Date()
        library.courses[ci].threads[si].messages = []
        library.courses[ci].threads[si].sources = [:]
        selectionResponseTarget = SelectionResponseTarget(threadID: library.courses[ci].threads[ti].id, answerID: target.answerID, inChat: true)
        save()
        focusTutor()
    }
    @discardableResult
    func sendReaderSelection(_ text: String, question: String = "", inChat: Bool = false, send: () -> Void) -> Bool {
        guard !isStreaming, !isIngestingAttachment,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let previousThreadID = library.selectedThreadID
        if inChat { useOpenDocumentConversation() }
        let savedDraft = draft
        let savedImage = draftImage
        let savedAttachments = draftAttachments
        let savedEditingMessageID = editingMessageID
        draft = question.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedText = String(text.prefix(16_000))
        draftImage = nil
        draftAttachments = []
        editingMessageID = nil
        if !inChat, let scratch = selectionScratchThreadID() { library.selectedThreadID = scratch }
        send()
        let sent = isStreaming || error != nil
        if let threadID = library.selectedThreadID, let answerID = thread?.messages.last?.id, sent {
            selectionResponseTarget = SelectionResponseTarget(threadID: threadID, answerID: answerID, inChat: inChat)
        } else {
            selectionResponseTarget = nil
        }
        // The popover follows the scratch thread by ID; the chat column keeps its own conversation.
        if !inChat { library.selectedThreadID = previousThreadID }
        draft = savedDraft
        draftImage = savedImage
        draftAttachments = savedAttachments
        editingMessageID = savedEditingMessageID
        saveDraft()
        return sent
    }
    func setAssignmentHidden(_ id: String, courseID: UUID, hidden: Bool) {
        guard let index = library.courses.firstIndex(where: { $0.id == courseID }),
            library.courses[index].materials.contains(where: { $0.id == id && $0.kind == .assignments })
        else { return }
        var ids = Set(library.courses[index].hiddenAssignmentIDs ?? [])
        if hidden { ids.insert(id) } else { ids.remove(id) }
        library.courses[index].hiddenAssignmentIDs = ids.sorted()
        save()
    }

    func setAssignmentProgress(_ progress: StudyAssignmentProgress?, id: String, courseID: UUID) {
        guard let index = library.courses.firstIndex(where: { $0.id == courseID }),
            library.courses[index].materials.contains(where: { $0.id == id && $0.assignment != nil })
        else { return }
        var values = library.courses[index].assignmentProgress ?? [:]
        values[id] = progress
        library.courses[index].assignmentProgress = values.isEmpty ? nil : values
        save()
    }

    func toggleFavorite(_ id: UUID) {
        guard let ci = library.courses.firstIndex(where: { $0.id == id }) else { return }
        library.courses[ci].favorite = !library.courses[ci].isFavorite
        library.courses[ci].examFavorite = false
        save()
    }

    var course: StudyCourse? { library.courses.first { $0.id == library.selectedCourseID } }
    var document: StudyDocument? { course?.documents.first { $0.id == library.selectedDocumentID } }
    var assignment: CanvasMaterialReference? {
        course?.materials.first { $0.id == library.selectedAssignmentID && $0.kind == .assignments }
    }
    var assignmentFiles: [CanvasMaterialReference] {
        guard let course, let assignment else { return [] }
        return (assignment.assignment?.linkedFileIDs ?? []).map { id in
            course.materials.first(where: { $0.id == "files:\(id)" })
                ?? CanvasMaterialReference(
                    id: "files:\(id)", kind: .files, remoteID: id, title: "Canvas file \(id)",
                    sourceURL: "\(course.canvasOrigin ?? "")/courses/\(course.canvasID ?? 0)/files/\(id)", version: "")
        }
    }
    var assignmentPDFs: [CanvasMaterialReference] {
        assignmentFiles.filter { file in
            (file.fileName ?? file.title).lowercased().hasSuffix(".pdf")
                || course?.documents.contains(where: { $0.sourceKey == file.id && $0.kind == .pdf }) == true
        }
    }
    var assignmentFeedbackFiles: [CanvasMaterialReference] {
        guard let course, let assignment else { return [] }
        return (assignment.assignment?.feedback?.attachments ?? []).map { file in
            course.materials.first { $0.id == file.materialID }
                ?? CanvasMaterialReference(id: file.materialID, kind: .files, remoteID: file.id, title: file.name,
                    fileName: file.name, sourceURL: "\(course.canvasOrigin ?? "")/files/\(file.id)",
                    version: "", byteCount: file.byteCount)
        }
    }
    private var assignmentReadableFiles: [CanvasMaterialReference] {
        let instructions = assignmentFiles
        let ids = Set(instructions.map(\.id))
        return instructions + assignmentFeedbackFiles.filter { !ids.contains($0.id) }
    }

    func feedbackKey(courseID: UUID, assignmentID: String) -> String { "\(courseID):\(assignmentID)" }

    func refreshAssignmentFeedback(courseID: UUID, assignmentID: String, force: Bool = false,
        clientOverride: CanvasClient? = nil) async {
        let key = feedbackKey(courseID: courseID, assignmentID: assignmentID)
        guard !feedbackRefreshing.contains(key),
            force || Date().timeIntervalSince(feedbackCheckedAt[key] ?? .distantPast) >= 120,
            let course = library.courses.first(where: { $0.id == courseID }), let remoteID = course.canvasID,
            let reference = course.materials.first(where: { $0.id == assignmentID && $0.kind == .assignments })
        else { return }
        feedbackRefreshing.insert(key)
        feedbackErrors[key] = nil
        let accountID = library.canvasUserID
        let accountOrigin = library.canvasOrigin
        defer { feedbackRefreshing.remove(key) }
        do {
            let client: CanvasClient
            if let clientOverride { client = clientOverride }
            else { client = try await connectedClient(for: course) }
            let details = try await client.assignmentDetails(courseID: remoteID, id: reference.remoteID)
            try Task.checkCancellation()
            guard library.canvasUserID == accountID, library.canvasOrigin == accountOrigin,
                let ci = library.courses.firstIndex(where: { $0.id == courseID
                && $0.canvasOrigin == course.canvasOrigin && $0.canvasUserID == course.canvasUserID }),
                let mi = library.courses[ci].canvasMaterials?.firstIndex(where: { $0.id == assignmentID }) else { return }
            let previous = library.courses[ci].canvasMaterials?[mi].assignment
            library.courses[ci].canvasMaterials?[mi].assignment = details.retainingFeedback(from: previous)
            feedbackCheckedAt[key] = Date()
            if details.feedback == nil {
                feedbackErrors[key] = previous?.feedback == nil ? "Canvas did not return feedback for this assignment."
                    : "Canvas did not return feedback. Your saved feedback is still available."
            }
            save()
        } catch is CancellationError { }
        catch {
            feedbackErrors[key] = "Could not refresh feedback. \(error.localizedDescription)"
            recordCanvasConnectionError(error)
        }
    }
    func assignmentFileStatus(_ file: CanvasMaterialReference) -> String {
        if assignmentPreparingFileID == file.id { return "Preparing…" }
        if let notice = assignmentFileNotices[file.id] { return notice }
        if let saved = course?.documents.first(where: { $0.sourceKey == file.id }),
            FileManager.default.fileExists(atPath: store.file(for: saved).path)
        {
            let availability =
                saved.kind == .preview || saved.unreadablePages == saved.pageCount
                ? "Saved · no readable text for companion" : "Ready for companion"
            return document?.id == saved.id ? "Open · \(availability)" : availability
        }
        return file.unavailableReason ?? "Not downloaded"
    }
    var thread: StudyThread? { course?.threads.first { $0.id == library.selectedThreadID } }
    var conversationScope: String {
        if let thread {
            if thread.assignmentID != nil { return "assignment" }
            return thread.documentID == nil ? "course" : "document"
        }
        return assignment != nil ? "assignment" : document != nil ? "document" : "course"
    }
    var isCourseConversation: Bool { course != nil && conversationScope == "course" }
    var messages: [ConversationMessage] { thread?.messages ?? [] }
    var isStreaming: Bool { streamingThreadID != nil }
    var isCurrentThreadStreaming: Bool { streamingThreadID != nil && streamingThreadID == library.selectedThreadID }
    var currentPageText: String { documentIndex?.pages.first { $0.number == currentPage }?.text ?? "" }
    var canSend: Bool {
        course != nil && (!automaticContextEnabled || isCourseConversation || document == nil || documentIndex != nil) && !isStreaming && !isIngestingAttachment
            && (!automaticContextEnabled || assignment == nil || !assignmentPreparing)
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftImage != nil || draftAttachments.contains(where: \.includedInContext)
                || !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func save() {
        guard canSave else { return }
        libraryWriter.save(library) { [weak self] message in
            Task { @MainActor in self?.error = "Could not save your workspace: \(message)" }
        }
    }
    func saveDraft() {
        draftSaveTask?.cancel()
        draftSaveTask = nil
        if let ci = courseIndex() {
            if threadIndex(in: ci) == nil && (!draft.isEmpty || draftImage != nil || !draftAttachments.isEmpty || includeEntirePDF) {
                let thread = StudyThread(documentID: document?.id, assignmentID: assignment?.id, mode: mode)
                library.courses[ci].threads.append(thread)
                library.selectedThreadID = thread.id
            }
            if let ti = threadIndex(in: ci) {
                var savedThread = library.courses[ci].threads[ti]
                if savedThread.draft != draft || savedThread.draftImage != draftImage
                    || (savedThread.draftAttachments ?? []) != draftAttachments || savedThread.mode != mode
                    || (savedThread.entirePDF == true) != includeEntirePDF
                    || savedThread.automaticContextEnabled != automaticContextEnabled
                    || savedThread.includeCourseContext != includeCourseContext {
                    savedThread.draft = draft
                    savedThread.draftImage = draftImage
                    savedThread.draftAttachments = draftAttachments.isEmpty ? nil : draftAttachments
                    savedThread.mode = mode
                    savedThread.entirePDF = includeEntirePDF
                    savedThread.automaticContextEnabled = automaticContextEnabled
                    savedThread.includeCourseContext = includeCourseContext
                    library.courses[ci].threads[ti] = savedThread
                }
            }
        }
        scheduleSave()
    }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.saveDraft()
        }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func flush() {
        saveDraft()
        saveTask?.cancel()
        documentEditing.flush()
        guard canSave else { return }
        do { try libraryWriter.flush(library) } catch {
            self.error = "Could not save your workspace: \(error.localizedDescription)"
        }
    }

    func createCourse(name: String, code: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, canSave else { return }
        let course = StudyCourse(name: String(name.prefix(180)), code: String(code.prefix(40)))
        library.courses.append(course)
        selectCourse(course.id)
    }
    func renameCourse(name: String, code: String) {
        guard let ci = courseIndex(), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        library.courses[ci].name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        library.courses[ci].code = String(code.prefix(40))
        save()
    }
    func removeCourse(_ id: UUID) {
        guard !isStreaming, !isImporting, !canvasBusy else { return }
        library.courses.removeAll { $0.id == id }
        if library.selectedCourseID == id { selectCourse(library.courses.first?.id) }
        save()
    }
    func selectCourse(_ id: UUID?, recordHistory: Bool = true) {
        cancelAssignmentPreparation()
        if recordHistory { recordNavigation() }
        cancelPracticePreparation()
        saveBeforeNavigating()
        library.selectedAssignmentID = nil
        library.selectedCourseID = id
        library.showingCourseLibrary = id == nil
        library.selectedDocumentID = nil
        library.selectedThreadID = course?.threads.last(where: { $0.documentID == nil && $0.assignmentID == nil })?.id
        restoreThread()
        loadSelectedDocument()
        visitedCourse()
        exitDocumentFocusIfIneligible()
        save()
    }
    func selectDocument(
        _ id: UUID, assignmentID: String? = nil, recordHistory: Bool = true, preservingConversation: Bool = false
    ) {
        if assignmentID != library.selectedAssignmentID { cancelAssignmentPreparation() }
        if recordHistory { recordNavigation() }
        cancelPracticePreparation()
        saveBeforeNavigating()
        library.selectedAssignmentID = assignmentID
        library.showingCourseLibrary = false
        library.selectedDocumentID = id
        if !preservingConversation {
            library.selectedThreadID = course?.threads.last(where: { $0.documentID == id && $0.assignmentID == assignmentID && $0.isSelectionScratch != true })?.id
        }
        restoreThread()
        loadSelectedDocument()
        exitDocumentFocusIfIneligible()
        save()
        if let document, document.needsCanvasHTMLUpgrade, !canvasBusy,
            let course, let ref = course.materials.first(where: { $0.id == document.sourceKey }),
            canvasHTMLUpgradeAttempts.insert(document.id).inserted {
            openCanvasMaterial(ref, courseID: course.id)
        }
    }
    func removeDocument(_ id: UUID) {
        guard !isStreaming, !isImporting, !canvasBusy, let ci = courseIndex() else { return }
        library.courses[ci].documents.removeAll { $0.id == id }
        if library.selectedDocumentID == id {
            library.selectedDocumentID = nil
            library.selectedThreadID = nil
            restoreThread()
            loadSelectedDocument()
            exitDocumentFocusIfIneligible()
        }
        save()
    }
    func selectThread(_ id: UUID) {
        recordNavigation()
        saveBeforeNavigating()
        guard let thread = course?.threads.first(where: { $0.id == id }) else { return }
        library.selectedAssignmentID = thread.assignmentID
        library.selectedAssignmentFileID = nil
        library.showingCourseLibrary = false
        library.selectedThreadID = id
        library.selectedDocumentID = thread.documentID
        restoreThread()
        loadSelectedDocument()
        loadAssignmentText()
        save()
    }
    func newThread() {
        guard let ci = courseIndex() else { return }
        flush()
        let thread = StudyThread(
            documentID: isCourseConversation ? nil : document?.id,
            assignmentID: isCourseConversation ? nil : (self.thread?.assignmentID ?? assignment?.id), mode: mode,
            automaticContextEnabled: automaticContextEnabled, includeCourseContext: includeCourseContext)
        library.courses[ci].threads.append(thread)
        library.selectedThreadID = thread.id
        cancelAttachmentIngestion()
        draftAttachments = []
        draft = ""
        includeEntirePDF = false
        draftImage = nil
        selectedText = ""
        error = nil
        contextSummary = ""
        editingMessageID = nil
        save()
    }
    func removeThread(_ id: UUID) {
        guard id != streamingThreadID, let ci = courseIndex() else { return }
        library.courses[ci].threads.removeAll { $0.id == id }
        if library.selectedThreadID == id {
            library.selectedThreadID = nil
            restoreThread()
        }
        save()
    }
    private func restoreThread() {
        cancelAttachmentIngestion()
        draftAttachments = thread?.draftAttachments ?? []
        draft = thread?.draft ?? ""
        mode = thread?.mode ?? .explain
        includeEntirePDF = thread?.entirePDF == true
        automaticContextEnabled = thread?.automaticContextEnabled ?? true
        includeCourseContext = thread?.includeCourseContext ?? false
        draftImage = thread?.draftImage
        selectedText = ""
        contextSummary = ""
        error = nil
        editingMessageID = nil
    }
    func setPage(_ page: Int) {
        guard let document else { return }
        let nextPage = min(max(1, page), max(1, document.pageCount))
        guard nextPage != currentPage else { return }
        cancelPracticePreparation()
        currentPage = nextPage
        selectedText = ""
        if let ci = courseIndex(), let di = library.courses[ci].documents.firstIndex(where: { $0.id == document.id }) {
            library.courses[ci].documents[di].lastPage = currentPage
            library.courses[ci].documents[di].lastOpenedAt = Date()
        }
        scheduleSave()
    }
    func navigate(to source: StudySource) {
        guard course?.documents.contains(where: { $0.id == source.documentID }) == true else { return }
        recordNavigation()
        // Keep the conversation and assignment context when following an included-file citation.
        let target = course?.documents.first { $0.id == source.documentID }
        let linkedKeys = Set(assignmentReadableFiles.map(\.id))
        if let key = target?.sourceKey, key == assignment?.id || linkedKeys.contains(key) {
            library.selectedAssignmentFileID = linkedKeys.contains(key) ? key : nil
        } else {
            cancelAssignmentPreparation()
            library.selectedAssignmentID = nil
            library.selectedAssignmentFileID = nil
        }
        library.selectedDocumentID = source.documentID
        loadSelectedDocument()
        setPage(source.page)
    }
    private func loadSelectedDocument() {
        cancelPracticePreparation()
        selectedText = ""
        selectingFigure = false
        let identity = document.map(DocumentContentIdentity.init)
        // Conversation navigation often keeps the same reading open. Preserve
        // its ready index (and any ongoing OCR) instead of showing a new load.
        if identity != nil, indexedDocument == identity, documentIndex != nil || indexTask != nil { return }
        indexTask?.cancel()
        indexTask = nil
        indexedDocument = identity
        let loadID = UUID()
        indexLoadID = loadID
        documentOCRProgress = nil
        documentIndex = nil
        currentPage = document?.lastPage ?? 1
        guard let document else { return }
        if !isShowingLibrary, let ci = courseIndex(),
            let di = library.courses[ci].documents.firstIndex(where: { $0.id == document.id })
        {
            library.courses[ci].documents[di].lastOpenedAt = Date()
            scheduleSave()
        }
        let store = store
        indexTask = Task { [weak self] in
            defer {
                if self?.indexLoadID == loadID { self?.indexTask = nil }
            }
            let job = Task.detached(priority: .userInitiated) { Result { try store.index(for: document) } }
            let result = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
            guard let self, !Task.isCancelled, self.document?.id == document.id,
                  self.document?.contentHash == document.contentHash else { return }
            let cached: StudyDocumentIndex
            switch result {
            case .success(let index):
                self.documentIndex = index // The reader and tutor are usable before any legacy OCR starts.
                cached = index
                // Practice or another reader can have completed the sidecar.
                // Reconcile coverage even when no new OCR job is necessary.
                if let ci = self.courseIndex(), let di = self.library.courses[ci].documents.firstIndex(where: { $0.id == document.id }) {
                    let unreadable = index.pages.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                    let notice = index.extractionNotice ?? document.contentNotice
                    var saved = self.library.courses[ci].documents[di]
                    if saved.unreadablePages != unreadable || saved.contentNotice != notice {
                        saved.unreadablePages = unreadable
                        saved.contentNotice = notice
                        self.library.courses[ci].documents[di] = saved
                        self.scheduleSave()
                    }
                }
            case .failure(let error):
                self.error = "Could not load \(document.title): \(error.localizedDescription)"
                return
            }
            let needsOCR = cached.extractionVersion != StudyOCRIndexing.version
                && [.pdf, .image].contains(document.kind) && document.contentHash != nil
            guard needsOCR || document.classification?.version != StudyMaterialClassifier.version else { return }
            if needsOCR { self.documentOCRProgress = "Recognizing document text…" }
            let upgrade = Task.detached(priority: .utility) {
                Result {
                    let index = needsOCR ? try store.readingIndex(for: document) { [weak self] completed, total in
                        Task { @MainActor [weak self] in
                            guard let self, self.indexLoadID == loadID, self.documentOCRProgress != nil else { return }
                            self.documentOCRProgress = "Recognizing text · \(completed) / \(total) pages"
                        }
                    } : cached
                    let analysis = StudyMaterialClassifier.analyze(title: document.title,
                        fileName: document.originalFileName ?? document.fileName, kind: document.kind, pages: index.pages)
                    return (index, analysis)
                }
            }
            let upgraded = await withTaskCancellationHandler(operation: { await upgrade.value }, onCancel: { upgrade.cancel() })
            guard !Task.isCancelled, self.document?.id == document.id,
                  self.document?.contentHash == document.contentHash else { return }
            self.documentOCRProgress = nil
            if case .success(let (index, analysis)) = upgraded {
                self.documentIndex = index
                if let ci = self.courseIndex(), let di = self.library.courses[ci].documents.firstIndex(where: { $0.id == document.id }) {
                    self.library.courses[ci].documents[di].classification = analysis
                    self.library.courses[ci].documents[di].unreadablePages = index.pages.filter { $0.text.isEmpty }.count
                    self.library.courses[ci].documents[di].contentNotice = index.extractionNotice
                    self.scheduleSave()
                }
            } else if case .failure(let error) = upgraded, !(error is CancellationError) {
                self.error = "Could not finish text recognition for \(document.title): \(error.localizedDescription)"
            }
        }
    }
    func chooseDocuments() {
        guard course != nil, !isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.item]
        panel.prompt = "Add to course"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.importDocuments(panel.urls) }
        }
    }
    func importDocuments(_ urls: [URL]) {
        guard let courseID = course?.id, !isImporting, canSave else { return }
        isImporting = true
        error = nil
        let store = store
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                activity = nil
            }
            for url in urls {
                if Task.isCancelled { break }
                activity = "Reading \(url.lastPathComponent)…"
                do {
                    let job = Task.detached(priority: .userInitiated) {
                        try StudyDocumentImporter.read(url: url, store: store)
                    }
                    let document = try await withTaskCancellationHandler(
                        operation: { try await job.value }, onCancel: { job.cancel() })
                    guard let ci = library.courses.firstIndex(where: { $0.id == courseID }) else { break }
                    library.courses[ci].documents.append(document)
                    if library.selectedCourseID == courseID { selectDocument(document.id) }
                    save()
                } catch is CancellationError { break } catch {
                    self.error = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }
    func cancelImport() { importTask?.cancel() }
    func importBrowserDocument(data: Data, name: String) {
        guard let courseID = course?.id, !isImporting, canSave else { return }
        isImporting = true
        error = nil
        activity = "Reading \(name)…"
        let store = store
        importTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isImporting = false
                activity = nil
            }
            do {
                let job = Task.detached { try StudyDocumentImporter.read(data: data, name: name, store: store) }
                let document = try await withTaskCancellationHandler(
                    operation: { try await job.value }, onCancel: { job.cancel() })
                guard let ci = library.courses.firstIndex(where: { $0.id == courseID }) else { return }
                library.courses[ci].documents.append(document)
                if library.selectedCourseID == courseID { selectDocument(document.id) }
                save()
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func saveDocumentEdits(_ draft: StudyEditDraft) async throws {
        guard canSave, !isImporting, !canvasBusy, !isStreaming else {
            throw StudyError.message(
                "Wait for the current import, Canvas check or answer to finish before saving changes.")
        }
        guard
            let courseID = library.courses.first(where: { $0.documents.contains(where: { $0.id == draft.documentID }) }
            )?.id,
            let document = library.courses.first(where: { $0.id == courseID })?.documents.first(where: {
                $0.id == draft.documentID
            })
        else { throw StudyError.message("This document is no longer in the library.") }
        if let sourceKey = document.sourceKey {
            let transfer = canvasMaterialTransfers[courseID.uuidString + ":" + sourceKey]
            let preparingThisFile = assignmentPreparing && self.course?.id == courseID
                && (assignmentPreparingFileID == sourceKey || (assignmentPreparingFileID == nil && assignment?.id == sourceKey))
            guard transfer == nil || transfer?.finished == true, !preparingThisFile else {
                throw StudyError.message("This file is being prepared from Canvas. Your draft is kept; wait for this file to finish before saving.")
            }
        }
        isImporting = true
        savingDocumentID = document.id
        activity = "Saving local changes…"
        error = nil
        defer {
            isImporting = false
            savingDocumentID = nil
            activity = nil
        }
        let store = store
        let saved = try await Task.detached(priority: .userInitiated) {
            try StudyDocumentEditing.save(draft, document: document, store: store)
        }.value
        guard let ci = library.courses.firstIndex(where: { $0.id == courseID }),
            let di = library.courses[ci].documents.firstIndex(where: { $0.id == saved.id })
        else { return }
        library.courses[ci].documents[di] = saved
        if self.document?.id == saved.id { loadSelectedDocument() }
        save()
    }

    func attachImage(_ image: NSImage) {
        guard let data = ImageEncoding.jpegData(from: image) else {
            error = "The image could not be read."
            return
        }
        draftImage = data
    }
    func chooseQuestionImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let data = ImageEncoding.jpegData(fileAt: url) else {
                    self?.error = "The image could not be read or exceeds 25 MB."
                    return
                }
                self?.draftImage = data
            }
        }
    }

    func sendEntirePDF(using app: AppModel) {
        guard document?.kind == .pdf, !isStreaming, !isIngestingAttachment else { return }
        askAboutOpenDocument()
        automaticContextEnabled = true
        includeEntirePDF = true
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draft = "Read the entire PDF and explain its main ideas, structure, and conclusions, with page references."
        }
        saveDraft()
        send(using: app)
    }

    func send(using app: AppModel, question: String? = nil) {
        if let question { draft = question }
        guard canSend else { return }
        let configuration: ProviderConfiguration
        do { configuration = try app.studyProviderConfiguration(allowLocalFiles: true) } catch {
            self.error = error.localizedDescription
            return
        }
        submit(configuration: configuration, routingMode: app.activeStudyModelMode,
            routingModels: app.verifiedModels(for: configuration.provider)) { [weak self] messages, configuration, onToken in
            let answerID = self?.activeAnswerID
            return try await app.completeStudy(messages: messages, configuration: configuration,
                onProgress: { [weak self] progress in
                    guard let self, self.activeAnswerID == answerID else { return }
                    self.updateAnswerProgress(progress)
                }, onToken: onToken)
        }
    }

    private func updateAnswerProgress(_ progress: String) {
        guard let messageID = activeAnswerID, let threadID = streamingThreadID,
            let course = library.courses.first(where: { $0.threads.contains(where: { $0.id == threadID }) })
        else { return }
        updateMessage(courseID: course.id, threadID: threadID, messageID: messageID) {
            $0.metadata = progress
            $0.recordActivity(progress)
        }
    }

    func submit(
        configuration: ProviderConfiguration, routingMode: StudyModelMode = .manual,
        routingModels: [ModelDefinition] = [], complete: @escaping StudyCompletion
    ) {
        var requestConfiguration = configuration
        requestConfiguration.teachingMode = mode
        let baseConfiguration = requestConfiguration
        guard canSend, let course else { return }
        let question =
            draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (!selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Explain this passage in its document context:\n\n> " + selectedText.replacingOccurrences(of: "\n", with: "\n> ")
                : !draftAttachments.isEmpty
                    ? "Read the attached files, explain what they contain and how they relate, and ask me for anything essential that is missing."
                    : "Explain this image in the context of the \(isCourseConversation ? "course" : "document").")
            : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let precedingMessages = Array(messages.prefix { $0.id != editingMessageID })
        let previousQuestions = precedingMessages.filter { $0.role == .user }.suffix(4).map(\.content)
        let conversationHasImages = draftImage != nil || draftAttachments.contains { $0.isImage && $0.includedInContext } || precedingMessages.contains {
            $0.imageData != nil || $0.attachments?.contains { $0.isImage && $0.includedInContext } == true
        }
        func routedConfiguration(_ route: StudyModelRoute) -> ProviderConfiguration {
            var value = baseConfiguration
            value.model = route.modelID
            value.reasoningEffort = route.reasoningEffort
            if route.modelID != baseConfiguration.model {
                value.modelSupportsImages = routingModels.first { $0.id == route.modelID }?.supportsImages ?? true
            }
            return value
        }
        let initialRoute = StudyModelRouter.route(
            mode: routingMode, providerID: baseConfiguration.provider.id, selectedModel: baseConfiguration.model,
            reasoningEffort: baseConfiguration.reasoningEffort, availableModels: routingModels,
            question: question, previousQuestions: previousQuestions, hasImages: conversationHasImages)
        let configuration = routedConfiguration(initialRoute)
        if conversationHasImages && !configuration.studyImageInputAllowed {
            error = "This model cannot read images. Choose a vision model from the model picker."
            return
        }
        guard let ci = courseIndex() else { return }
        // A highlighted passage is a complete first question even when there
        // is no composer draft. Draft saving deliberately skips empty drafts.
        if threadIndex(in: ci) == nil {
            let thread = StudyThread(documentID: document?.id, assignmentID: assignment?.id, mode: mode)
            library.courses[ci].threads.append(thread)
            library.selectedThreadID = thread.id
        }
        guard let ti = threadIndex(in: ci) else { return }
        if let editingMessageID,
            let position = library.courses[ci].threads[ti].messages.firstIndex(where: { $0.id == editingMessageID })
        {
            library.courses[ci].threads[ti].messages.removeSubrange(position...)
        }
        editingMessageID = nil
        let user = ConversationMessage(
            role: .user, content: question, imageData: draftImage, imageMimeType: draftImage == nil ? nil : "image/jpeg",
            attachments: draftAttachments.isEmpty ? nil : draftAttachments
        )
        library.courses[ci].threads[ti].messages.append(user)
        if library.courses[ci].threads[ti].messages.count == 1 {
            library.courses[ci].threads[ti].title = String(question.prefix(70))
        }
        library.courses[ci].threads[ti].mode = mode
        library.courses[ci].threads[ti].entirePDF = includeEntirePDF
        library.courses[ci].threads[ti].automaticContextEnabled = automaticContextEnabled
        library.courses[ci].threads[ti].includeCourseContext = includeCourseContext
        library.courses[ci].threads[ti].draft = ""
        library.courses[ci].threads[ti].draftImage = nil
        library.courses[ci].threads[ti].draftAttachments = nil
        library.courses[ci].threads[ti].updatedAt = Date()
        let requestMessages = library.courses[ci].threads[ti].messages
        let threadID = library.courses[ci].threads[ti].id
        let assistantID = UUID()
        library.courses[ci].threads[ti].messages.append(
            ConversationMessage(id: assistantID, role: .assistant, content: "", isStreaming: true,
                activity: isCourseConversation || self.assignment == nil ? nil : assignmentActivity))
        streamingThreadID = threadID
        activeAnswerID = assistantID
        answerStartedAt = Date()
        let responseStartedAt = Date()
        draft = ""
        draftImage = nil
        error = nil
        draftAttachments = []
        let automaticContext = automaticContextEnabled
        let courseScope = isCourseConversation
        let doc = courseScope ? nil : document
        let index = courseScope ? nil : documentIndex
        let entirePDF = includeEntirePDF && doc != nil
        let page = currentPage
        let selection = selectedText
        selectedText = ""
        let selectionSource = courseScope ? document.map {
            StudySource(documentID: $0.id, title: $0.title, page: currentPage)
        } : nil
        let store = store
        let includeCourse = courseScope || includeCourseContext
        let assignment = courseScope ? nil : course.materials.first {
            $0.id == (thread?.assignmentID ?? library.selectedAssignmentID) && $0.kind == .assignments
        }
        let assignmentFileNotices = assignmentFileNotices
        let mode = mode
        contextSummary = automaticContext ? "Finding relevant passages…" : "Saved sources off"
        updateAnswerProgress(automaticContext ? "Finding relevant passages…" : "Preparing explicit attachments…")
        save()
        answerTask = Task { [weak self] in
            guard let self else { return }
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    let retrieval = AttachmentContextRetrieval.prepare(messages: requestMessages, question: question)
                    guard automaticContext else {
                        return (StudyContextBuilder.explicitOnly(selection: selection), [MessageAttachment](), retrieval)
                    }
                    let reading = try doc.map { try store.readingIndex(for: $0) } ?? index
                    let pack = try entirePDF
                        ? StudyContextBuilder.entireDocument(document: doc, index: reading, selection: selection)
                        : StudyContextBuilder.build(
                        document: doc, index: reading, currentPage: page, question: question,
                        selection: selection, course: course, store: store, includeCourse: includeCourse,
                        assignment: assignment, assignmentFileNotices: assignmentFileNotices,
                        selectionSource: selectionSource, budget: StudyContextBuilder.requestBudget(question), previousQuestions: previousQuestions)
                    let images =
                        configuration.studyImageInputAllowed
                        ? doc.map { StudyContextBuilder.pageImages(document: $0, pages: pack.imagePages, store: store) }
                            ?? [] : []
                    return (pack, images, retrieval)
                }
                let prepared = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                contextSummary =
                    prepared.0.summary
                    + (prepared.1.isEmpty
                        ? " · Text context" : " · \(prepared.1.count) page image\(prepared.1.count == 1 ? "" : "s")")
                let attachedFiles = requestMessages.flatMap { $0.attachments ?? [] }.filter(\.includedInContext)
                if !attachedFiles.isEmpty {
                    let incomplete = attachedFiles.filter { $0.effectiveReadStatus != .complete }.count
                    contextSummary += " · \(attachedFiles.count) attached file\(attachedFiles.count == 1 ? "" : "s")"
                        + (incomplete == 0 ? "" : " (\(incomplete) with reading limits)")
                }
                if let retrievalSummary = prepared.2.summary { contextSummary += " · " + retrievalSummary }
                mutateThread(courseID: course.id, threadID: threadID) {
                    $0.sources[assistantID.uuidString] = prepared.0.sources
                }
                updateMessage(courseID: course.id, threadID: threadID, messageID: assistantID) {
                    for file in user.attachments ?? [] where file.includedInContext {
                        $0.recordActivity(file.readStatusLabel, detail: file.fileName + (file.readDetail.map { " · " + $0 } ?? ""))
                    }
                    for source in prepared.0.sources {
                        $0.recordActivity("Read saved file", detail: "\(source.title) · page \(source.page)")
                    }
                    if !prepared.1.isEmpty { $0.recordActivity("Prepared page images", detail: "\(prepared.1.count) images included") }
                    if let retrievalSummary = prepared.2.summary { $0.recordActivity("Selected relevant attachment passages", detail: retrievalSummary) }
                }
                let route = StudyModelRouter.route(
                    mode: routingMode, providerID: baseConfiguration.provider.id, selectedModel: baseConfiguration.model,
                    reasoningEffort: baseConfiguration.reasoningEffort, availableModels: routingModels,
                    question: question, previousQuestions: previousQuestions,
                    contextCharacters: prepared.0.text.count + prepared.2.includedCharacters + requestMessages.reduce(0) { $0 + $1.content.count },
                    hasImages: conversationHasImages || !prepared.1.isEmpty)
                let answerConfiguration = routedConfiguration(route)
                if routingMode != .manual {
                    updateMessage(courseID: course.id, threadID: threadID, messageID: assistantID) {
                        $0.modelRouting = route
                        $0.recordActivity("\(routingMode.label) selected \(route.modelID)", detail: route.reason)
                    }
                }
                updateAnswerProgress("Sources ready · Waiting for \(answerConfiguration.model)…")
                let result = try await complete(
                    StudyContextBuilder.requestMessages(
                        prepared.2.messages, pack: prepared.0, mode: mode, images: prepared.1),
                    answerConfiguration
                ) { [weak self] token in
                    guard let self, self.activeAnswerID == assistantID else { return }
                    self.updateMessage(courseID: course.id, threadID: threadID, messageID: assistantID) {
                        $0.content += token
                        $0.metadata = "Writing answer…"
                        $0.recordActivity("Writing answer…")
                    }
                }
                try Task.checkCancellation()
                guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw StudyError.message("The model returned no answer. Try again or choose another model.")
                }
                guard activeAnswerID == assistantID else { return }
                updateMessage(courseID: course.id, threadID: threadID, messageID: assistantID) {
                    $0.content = result.text
                    $0.reasoning = result.reasoning
                    $0.usage = result.usage
                    $0.responseDurationSeconds = Date().timeIntervalSince(responseStartedAt)
                    $0.isStreaming = false
                    $0.metadata = routingMode == .manual
                        ? "\(result.model) · \(prepared.0.summary)"
                        : "\(routingMode.label) · \(result.model) · \(route.reason)"
                    $0.recordActivity("Answer complete", detail: result.model)
                }
            } catch {
                guard activeAnswerID == assistantID else { return }
                if !(error is CancellationError) { self.error = error.localizedDescription }
                updateMessage(courseID: course.id, threadID: threadID, messageID: assistantID) {
                    $0.isStreaming = false
                    $0.metadata = error is CancellationError ? "Stopped" : "Response interrupted"
                    $0.recordActivity(error is CancellationError ? "Stopped" : "Response interrupted")
                }
                mutateThread(courseID: course.id, threadID: threadID) {
                    $0.messages.removeAll { $0.id == assistantID && $0.content.isEmpty && $0.activity?.isEmpty != false }
                }
            }
            guard activeAnswerID == assistantID else { return }
            streamingThreadID = nil
            activeAnswerID = nil
            answerStartedAt = nil
            save()
        }
    }
    func stopAnswer() { answerTask?.cancel() }
    func setAttachmentIncluded(_ id: UUID, included: Bool) {
        guard !isStreaming else { return }
        if let index = draftAttachments.firstIndex(where: { $0.id == id }) {
            draftAttachments[index].isEnabled = included
            saveDraft()
        }
        if let ci = courseIndex(), let ti = threadIndex(in: ci) {
            for mi in library.courses[ci].threads[ti].messages.indices {
                if let fi = library.courses[ci].threads[ti].messages[mi].attachments?.firstIndex(where: { $0.id == id }) {
                    library.courses[ci].threads[ti].messages[mi].attachments?[fi].isEnabled = included
                }
            }
            save()
        }
    }
    func retry(using app: AppModel) {
        guard !isStreaming, let ci = courseIndex(), let ti = threadIndex(in: ci),
            let ui = library.courses[ci].threads[ti].messages.lastIndex(where: { $0.role == .user })
        else { return }
        cancelAttachmentIngestion()
        let user = library.courses[ci].threads[ti].messages[ui]
        library.courses[ci].threads[ti].messages.removeSubrange(ui...)
        draft = user.content
        draftImage = user.imageData
        draftAttachments = user.attachments ?? []
        send(using: app)
    }
    func edit(_ message: ConversationMessage) {
        guard !isStreaming, messages.contains(where: { $0.id == message.id }) else { return }
        cancelAttachmentIngestion()
        draft = message.content
        draftImage = message.imageData
        draftAttachments = message.attachments ?? []
        editingMessageID = message.id
        saveDraft()
    }
    func cancelEdit() {
        cancelAttachmentIngestion()
        editingMessageID = nil
        draft = ""
        draftImage = nil
        draftAttachments = []
        saveDraft()
    }

    func importConversation(_ conversation: StoredConversation) {
        guard let ci = courseIndex() else { return }
        var thread = StudyThread(
            title: conversation.title, documentID: isCourseConversation ? nil : document?.id,
            assignmentID: isCourseConversation ? nil : assignment?.id)
        thread.messages = conversation.messages
        library.courses[ci].threads.append(thread)
        selectThread(thread.id)
    }

    /// Connecting indexes every course first. Downloading bodies/files is a separate opt-in.
    func loadCanvasCourses(token: String? = nil, downloadAll: Bool = false, clientOverride: CanvasClient? = nil) {
        guard !canvasBusy, canSave else { return }
        cancelPreloading()
        canvasConnectionCheckID = UUID(); canvasChecking = false
        canvasBusy = true
        canvasStatus = "Finding your Canvas courses…"
        canvasWarnings = []
        canvasTask = Task(priority: canvasDownloadPriority.taskPriority) { [weak self] in
            guard let self else { return }
            defer {
                canvasBusy = false
                canvasActivityCourseID = nil
                fetchingMaterialID = nil
                save()
                startNextCanvasCourseUpdate()
            }
            do {
                let origin = try CanvasAddress.origin(canvasAddress)
                let client: CanvasClient
                if let clientOverride {
                    client = clientOverride
                } else if let token, !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    client = CanvasClient(origin: origin, token: token.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    client = try await canvasClientFactory(origin, false, false)
                }
                let account = try await client.account()
                if let previous = canvasClient, connectedOrigin == origin, canvasAccount?.id == account.id {
                    await client.reuseMetadata(from: previous)
                }
                let courses = try await client.courses()
                try Task.checkCancellation()
                if clientOverride == nil, let token, !token.isEmpty {
                    try await CanvasSession.saveToken(token.trimmingCharacters(in: .whitespacesAndNewlines), origin: origin)
                }
                canvasClient = client
                canvasAccount = account
                canvasConnectionStatus = "Connected as \(account.name)"
                canvasNeedsSignIn = false
                canvasNeedsKeychainAccess = false
                connectedOrigin = origin
                canvasCourses = courses
                let firstConnection = library.canvasUserID == nil
                library.canvasOrigin = origin.absoluteString
                library.canvasUserID = account.id
                library.canvasUserName = account.name
                canvasAddress = origin.absoluteString
                canvasSigningIn = false
                var ids: [UUID] = []
                var newCourses = 0
                var changedCourses = 0
                var unavailableCourses = 0
                for remote in courses {
                    if let ci = library.courses.firstIndex(where: {
                        $0.canvasID == remote.id && $0.canvasOrigin == origin.absoluteString
                            && $0.canvasUserID == account.id
                    }) {
                        if let favorite = remote.favorite { library.courses[ci].canvasFavorite = favorite }
                        if library.courses[ci].name != remote.name || library.courses[ci].code != remote.code
                            || library.courses[ci].term != remote.term || library.courses[ci].canvasAvailable == false
                        {
                            changedCourses += 1
                            library.courses[ci].name = remote.name
                            library.courses[ci].code = remote.code
                            library.courses[ci].term = remote.term
                        }
                        if library.courses[ci].canvasAvailable != true { library.courses[ci].canvasAvailable = true }
                        ids.append(library.courses[ci].id)
                    } else {
                        let course = StudyCourse(
                            name: remote.name, code: remote.code, canvasID: remote.id,
                            canvasOrigin: origin.absoluteString, canvasUserID: account.id,
                            canvasFavorite: remote.favorite, term: remote.term, canvasAvailable: true)
                        library.courses.append(course)
                        ids.append(course.id)
                        newCourses += 1
                    }
                }
                let present = Set(ids)
                for ci in library.courses.indices
                where library.courses[ci].canvasOrigin == origin.absoluteString
                    && library.courses[ci].canvasUserID == account.id && !present.contains(library.courses[ci].id)
                {
                    if library.courses[ci].canvasAvailable != false {
                        unavailableCourses += 1
                        library.courses[ci].canvasAvailable = false
                    }
                }
                if firstConnection { showCourseLibrary() } else { save() }
                let courseChanges = [
                    (newCourses, "new courses"), (changedCourses, "course details updated"),
                    (unavailableCourses, "courses no longer listed"),
                ]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
                try await syncCatalogs(ids, client: client, downloadAll: downloadAll, courseChanges: courseChanges)
            } catch is CancellationError {
                canvasStatus = "Stopped. Course cards and completed downloads are saved."
            } catch { reportCanvasError(error) }
        }
    }

    func syncCanvasCourses(courseIDs: [UUID], downloadAll: Bool = false) {
        _ = startCanvasCourseSync(courseIDs: courseIDs, downloadAll: downloadAll)
    }

    func updateCanvasCourseContent(courseIDs: [UUID]) {
        let ids = courseIDs.filter { canUpdateCanvasCourseContent($0) }
        guard !ids.isEmpty, let userID = library.canvasUserID else { return }
        queuedCanvasCourseUpdateAccount = (library.canvasOrigin, userID)
        for id in ids where !queuedCanvasCourseUpdateIDs.contains(id) { queuedCanvasCourseUpdateIDs.append(id) }
        startNextCanvasCourseUpdate()
    }

    var canvasUpdatableCourses: [StudyCourse] {
        library.courses.filter {
            $0.canvasID != nil && $0.canvasOrigin == library.canvasOrigin && $0.canvasUserID == library.canvasUserID
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func canUpdateCanvasCourseContent(_ id: UUID) -> Bool {
        guard let course = library.courses.first(where: { $0.id == id }) else { return false }
        return canUpdateCanvasCourseContent(course)
    }

    /// Cards already have the course. Eligibility must not sort the full catalog
    /// twice per card (including its eagerly constructed context menu).
    func canUpdateCanvasCourseContent(_ course: StudyCourse) -> Bool {
        canSave && library.canvasUserID != nil && !canvasChecking && !canvasSigningIn && !canvasNeedsAuthentication
            && !queuedCanvasCourseUpdateIDs.contains(course.id) && !isUpdatingCanvasCourseContent(course.id)
            && course.canvasID != nil && course.canvasOrigin == library.canvasOrigin && course.canvasUserID == library.canvasUserID
    }

    private func isUpdatingCanvasCourseContent(_ id: UUID) -> Bool {
        manualCanvasCourseUpdateID == id || (canvasContentSyncRunning && canvasActivityCourseID == id)
    }

    func canvasCourseUpdateTitle(_ id: UUID) -> String {
        if isUpdatingCanvasCourseContent(id) { return "Updating…" }
        if queuedCanvasCourseUpdateIDs.contains(id) { return "Queued" }
        return canvasBusy ? "Queue update" : "Update now"
    }

    /// Manual requests share the existing download worker and its priority and checkpoints.
    private func startNextCanvasCourseUpdate() {
        guard !canvasBusy else { return }
        guard let account = queuedCanvasCourseUpdateAccount,
            account.origin == library.canvasOrigin, account.userID == library.canvasUserID,
            !canvasNeedsAuthentication else {
            queuedCanvasCourseUpdateIDs.removeAll()
            queuedCanvasCourseUpdateAccount = nil
            return
        }
        while !queuedCanvasCourseUpdateIDs.isEmpty {
            let id = queuedCanvasCourseUpdateIDs.removeFirst()
            guard canUpdateCanvasCourseContent(id) else { continue }
            if startCanvasCourseSync(courseIDs: [id], downloadAll: true) != nil {
                manualCanvasCourseUpdateID = id
                return
            }
        }
        queuedCanvasCourseUpdateAccount = nil
    }

    private var contentPollingExtras: [Double] {
        library.courses.flatMap { ($0.canvasPolling?.extraChecks ?? []) + ($0.mathWikiPolling?.extraChecks ?? []) }
    }

    private func contentPollingReason(_ course: StudyCourse, source: ContentPollSource, now: Date,
        extras: [Double]? = nil) -> ContentPollingModel.Reason? {
        course[polling: source].decision(at: now, interval: source.interval,
            lastRegular: source == .canvas ? course.contentUpdateAttemptedAt : course.mathWikiUpdateAttemptedAt,
            workspaceExtras: extras ?? contentPollingExtras)
    }

    func refreshMathWikiIfNeeded(now: Date = Date()) async {
        guard automaticallyUpdateMathWiki, canSave, !canvasBusy, !assignmentRefreshBusy,
            !assignmentPreparing, !isImporting, !isStreaming else { return }
        let courses = automaticCanvasFileCourses(at: now).filter {
            MathWikiScope.course($0)?.terms.isEmpty == false &&
                contentPollingReason($0, source: .mathWiki, now: now) != nil
        }
        guard !courses.isEmpty else { return }
        let origin = library.canvasOrigin, userID = library.canvasUserID, previousStatus = canvasStatus
        cancelPreloading()
        canvasBusy = true
        automaticMathWikiSyncRunning = true
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                canvasBusy = false
                automaticMathWikiSyncRunning = false
                canvasActivityCourseID = nil
                saveTask?.cancel()
                saveTask = nil
                save()
                startNextCanvasCourseUpdate()
            }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard automaticallyUpdateMathWiki, library.canvasOrigin == origin, library.canvasUserID == userID else { throw CancellationError() }
            }
            var downloaded = 0
            do {
                for target in courses {
                    try check()
                    guard let ci = library.courses.firstIndex(where: { $0.id == target.id }) else { continue }
                    guard let reason = contentPollingReason(library.courses[ci], source: .mathWiki, now: now) else { continue }
                    var attemptedCourse = library.courses[ci]
                    attemptedCourse[polling: .mathWiki].attempt(at: now, reason: reason)
                    if reason == .regular { attemptedCourse.mathWikiUpdateAttemptedAt = now }
                    library.courses[ci] = attemptedCourse
                    scheduleSave()
                    let course = library.courses[ci]
                    canvasActivityCourseID = target.id
                    let result: MathWikiClient.Catalog
                    do { result = try await mathWikiClient.catalog(course: course, fileRecheckInterval: MathWikiClient.fileCheckInterval) }
                    catch {
                        try check()
                        if let ci = library.courses.firstIndex(where: { $0.id == target.id }) {
                            library.courses[ci][polling: .mathWiki].observe(at: now, signature: "", complete: false, interval: MathWikiClient.checkInterval)
                        }
                        throw error
                    }
                    try check()
                    guard let ci = library.courses.firstIndex(where: { $0.id == target.id }) else { continue }
                    var refreshedCourse = library.courses[ci]
                    refreshedCourse[polling: .mathWiki].observe(at: now,
                        signature: ContentPollingModel.signature(result.items, source: .mathWiki),
                        complete: result.complete, interval: MathWikiClient.checkInterval)
                    let catalog = CanvasMaterialCatalog(items: result.items, warnings: result.warnings, mathWikiComplete: result.complete)
                    let merged = CanvasCatalogChanges.reconcile(previous: refreshedCourse.canvasMaterials, catalog: catalog)
                    if refreshedCourse.canvasMaterials != merged.items { refreshedCourse.canvasMaterials = merged.items }
                    if merged.changes.count > 0 {
                        refreshedCourse.catalogChanges = merged.changes
                        refreshedCourse.catalogChangedAt = now
                    }
                    if result.complete { refreshedCourse.mathWikiCheckedAt = now }
                    library.courses[ci] = refreshedCourse
                    var warnings = result.warnings
                    for ref in result.items where ref.unavailableReason == nil && (ref.byteCount ?? 0) <= StudyDocumentImporter.maximumBytes {
                        try check()
                        guard let current = library.courses.first(where: { $0.id == target.id }) else { break }
                        if let saved = current.documents.first(where: { $0.sourceKey == ref.id }),
                            saved.sourceVersion == ref.version, !ref.version.isEmpty,
                            FileManager.default.fileExists(atPath: store.file(for: saved).path) { continue }
                        do {
                            _ = try await fetchMaterial(ref, courseID: target.id, client: mathWikiMaterials, bulk: true)
                            downloaded += 1
                        } catch {
                            try check()
                            warnings.append("Math wiki \(ref.title): \(error.localizedDescription)")
                        }
                    }
                    if let ci = library.courses.firstIndex(where: { $0.id == target.id }) {
                        let previous = Set(library.courses[ci].mathWikiWarnings ?? [])
                        let catalogWarnings = (library.courses[ci].catalogWarnings ?? []).filter { !previous.contains($0) } + warnings
                        if library.courses[ci].catalogWarnings != catalogWarnings || library.courses[ci].mathWikiWarnings != warnings {
                            var warnedCourse = library.courses[ci]
                            warnedCourse.catalogWarnings = catalogWarnings
                            warnedCourse.mathWikiWarnings = warnings
                            library.courses[ci] = warnedCourse
                        }
                    }
                    scheduleSave()
                }
                canvasStatus = downloaded > 0 ? "Math wiki: \(downloaded) materials downloaded or updated." : previousStatus
            } catch is CancellationError {
                canvasStatus = previousStatus
            } catch {
                canvasStatus = "Math wiki check: \(error.localizedDescription)"
            }
        }
        canvasTask = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    func refreshCanvasContentIfNeeded(now: Date = Date()) async {
        guard automaticallyUpdateCanvasContent, !canvasNeedsAuthentication,
            !assignmentRefreshBusy, !assignmentPreparing, !isImporting, !isStreaming else { return }
        var extras = contentPollingExtras, ids: [UUID] = [], predicted = Set<UUID>()
        for course in automaticCanvasFileCourses(at: now) {
            guard let reason = contentPollingReason(course, source: .canvas, now: now, extras: extras) else { continue }
            ids.append(course.id)
            if reason == .predicted { predicted.insert(course.id); extras.append(now.timeIntervalSince1970) }
        }
        guard let task = startCanvasCourseSync(courseIDs: ids, downloadAll: true, automatic: true, now: now,
            predictedCourseIDs: predicted) else { return }
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func startCanvasCourseSync(courseIDs: [UUID], downloadAll: Bool, automatic: Bool = false,
        now: Date = Date(), predictedCourseIDs: Set<UUID> = []) -> Task<Void, Never>? {
        guard !canvasBusy, !canvasChecking, !canvasSigningIn, canSave, library.canvasUserID != nil else { return nil }
        var seen = Set<UUID>()
        let courseIDs = courseIDs.filter { id in
            guard seen.insert(id).inserted else { return false }
            // Keep removed IDs in a download queue long enough for syncCatalogs
            // to retire their checkpoints when resuming the remaining courses.
            guard let course = library.courses.first(where: { $0.id == id }) else { return downloadAll }
            return course.canvasID != nil && course.canvasOrigin == library.canvasOrigin
                && course.canvasUserID == library.canvasUserID
        }
        guard !courseIDs.isEmpty else { return nil }
        cancelPreloading()
        canvasBusy = true
        canvasContentSyncRunning = downloadAll
        automaticCanvasContentSyncRunning = automatic
        canvasWarnings = []
        canvasStatus = "Connecting to Canvas…"
        let task = Task(priority: canvasDownloadPriority.taskPriority) { [weak self] in
            guard let self else { return }
            defer {
                canvasBusy = false
                canvasContentSyncRunning = false
                automaticCanvasContentSyncRunning = false
                canvasActivityCourseID = nil
                fetchingMaterialID = nil
                manualCanvasCourseUpdateID = nil
                save()
                startNextCanvasCourseUpdate()
            }
            var connected = false
            do {
                guard let course = courseIDs.compactMap({ id in library.courses.first(where: { $0.id == id }) }).first else {
                    if downloadAll {
                        for id in courseIDs { try await updateCanvasDownloadProgress(courseID: id, pending: nil) }
                        canvasStatus = "The courses in this download queue were removed."
                    }
                    return
                }
                for id in courseIDs {
                    if downloadAll, let ci = library.courses.firstIndex(where: { $0.id == id }) {
                        let reason: ContentPollingModel.Reason = predictedCourseIDs.contains(id) ? .predicted : .regular
                        library.courses[ci][polling: .canvas].attempt(at: now, reason: reason)
                        if reason == .regular { library.courses[ci].contentUpdateAttemptedAt = now }
                    }
                }
                save()
                let client = try await connectedClient(for: course)
                connected = true
                try await syncCatalogs(courseIDs, client: client, downloadAll: downloadAll, automatic: automatic,
                    now: now, predictedCourseIDs: predictedCourseIDs)
            } catch is CancellationError { canvasStatus = "Stopped. Completed work is saved." } catch {
                if !connected {
                    for id in courseIDs {
                        if let ci = library.courses.firstIndex(where: { $0.id == id }) {
                            library.courses[ci][polling: .canvas].observe(at: now, signature: "", complete: false,
                                interval: CanvasCourseFileSync.checkInterval)
                        }
                    }
                }
                reportCanvasError(error)
            }
        }
        canvasTask = task
        return task
    }

    func resumeCanvasDownloads() {
        guard !canvasBusy, let progress = canvasDownloadProgress else { return }
        guard progress.origin == library.canvasOrigin, progress.userID == library.canvasUserID else {
            canvasStatus = "Reconnect the Canvas account that started these downloads before resuming."
            return
        }
        syncCanvasCourses(courseIDs: progress.remainingCourseIDs, downloadAll: true)
    }

    var coursesWithNewCanvasFiles: [StudyCourse] {
        library.courses.filter { $0.canvasOrigin == library.canvasOrigin && $0.canvasUserID == library.canvasUserID }
            .filter { $0.canvasFileSync?.pendingFileIDs.isEmpty == false }
    }
    var newCanvasFileCount: Int { coursesWithNewCanvasFiles.reduce(0) { $0 + ($1.canvasFileSync?.pendingFileIDs.count ?? 0) } }

    func checkForNewCanvasFiles(courseIDs: [UUID], download: Bool? = nil) {
        _ = startCanvasFileSync(courseIDs: courseIDs, download: download ?? automaticallyDownloadNewCanvasFiles,
            automatic: false, now: Date())
    }

    func automaticCanvasFileCourses(at now: Date = Date()) -> [StudyCourse] {
        let current = StudySemester.current(at: now)
        return library.courses.filter { course in
            course.canvasID != nil && course.canvasAvailable != false
                && course.canvasOrigin == library.canvasOrigin && course.canvasUserID == library.canvasUserID
                && (course.id == library.selectedCourseID || course.isFavorite
                    || StudySemester.memberships(term: course.term, code: course.code, name: course.name).contains(current))
        }.sorted { lhs, rhs in
            if (lhs.id == library.selectedCourseID) != (rhs.id == library.selectedCourseID) {
                return lhs.id == library.selectedCourseID
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    func refreshCanvasFilesIfNeeded(now: Date = Date()) async {
        guard !automaticallyUpdateCanvasContent, !canvasNeedsAuthentication, !assignmentRefreshBusy,
            !assignmentPreparing, !isImporting, !isStreaming else { return }
        let ids = automaticCanvasFileCourses(at: now).filter {
            CanvasCourseFileSync.baseline(for: $0).needsCheck(at: now, downloadAutomatically: automaticallyDownloadNewCanvasFiles)
        }.map(\.id)
        guard let task = startCanvasFileSync(courseIDs: ids, download: automaticallyDownloadNewCanvasFiles,
            automatic: true, now: now) else { return }
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private func startCanvasFileSync(courseIDs: [UUID], download: Bool, automatic: Bool, now: Date) -> Task<Void, Never>? {
        guard canSave, !canvasBusy, !canvasChecking, !canvasSigningIn, library.canvasUserID != nil else { return nil }
        let origin = library.canvasOrigin, userID = library.canvasUserID
        var seen = Set<UUID>()
        let ids = courseIDs.filter { id in
            seen.insert(id).inserted && library.courses.contains {
                $0.id == id && $0.canvasID != nil && $0.canvasOrigin == origin && $0.canvasUserID == userID
            }
        }
        guard !ids.isEmpty else { return nil }
        cancelPreloading()
        canvasBusy = true
        canvasFileSyncRunning = true
        if !automatic { canvasStatus = "Checking for new Canvas files…"; canvasWarnings = [] }
        let task = Task(priority: canvasDownloadPriority.taskPriority) { [weak self] in
            guard let self else { return }
            defer {
                canvasBusy = false; canvasFileSyncRunning = false; canvasActivityCourseID = nil
                save()
                startNextCanvasCourseUpdate()
            }
            var downloaded = 0, checked = 0
            var warnings: [String] = []
            @MainActor func stillConnected(_ course: StudyCourse) -> Bool {
                library.canvasOrigin == origin && library.canvasUserID == userID
                    && library.courses.contains { $0.id == course.id && $0.canvasOrigin == origin && $0.canvasUserID == userID }
            }
            do {
                for id in ids {
                    try Task.checkCancellation()
                    guard let course = library.courses.first(where: { $0.id == id }), course.canvasID != nil,
                        stillConnected(course) else { throw CancellationError() }
                    canvasActivityCourseID = id
                    do {
                        let client = try await connectedClient(for: course)
                        let catalog = try await client.catalog(course: course, filesOnly: true)
                        try Task.checkCancellation()
                        guard stillConnected(course), let ci = library.courses.firstIndex(where: { $0.id == id }) else {
                            throw CancellationError()
                        }
                        var current = library.courses[ci]
                        let state = CanvasCourseFileSync.reconcile(course: current, catalog: catalog, now: now)
                        // Discovery is additive. A partial file check must not remove other course materials.
                        var additive = catalog
                        additive.completeKinds = []
                        let merged = CanvasCatalogChanges.reconcile(previous: current.canvasMaterials, catalog: additive)
                        current.canvasMaterials = merged.items
                        current.canvasFileSync = state
                        library.courses[ci] = current
                        checked += 1
                        warnings += catalog.warnings.map { "\(course.displayName): \($0)" }
                        save()
                        guard download else { continue }
                        let pending = Set(state.pendingFileIDs)
                        if !pending.isEmpty {
                            library.courses[ci].canvasFileSync?.downloadAttemptedAt = now
                            save()
                        }
                        let files = catalog.items.filter { $0.kind == .files && pending.contains($0.id) }
                        guard !files.isEmpty else { continue }
                        try await libraryWriter.waitForPendingWrites()
                        var courseDownloads = 0
                        var fileErrors: [String] = []
                        try await CanvasDownloadScheduling.run(count: files.count, priority: { self.canvasDownloadPriority },
                            operation: { [self] index -> CanvasBulkMaterialResult in
                                try Task.checkCancellation()
                                guard stillConnected(course) else { throw CancellationError() }
                                if automatic && !automaticallyDownloadNewCanvasFiles { throw CancellationError() }
                                let file = files[index]
                                if library.courses.first(where: { $0.id == id })?.documents.contains(where: { $0.sourceKey == file.id }) == true {
                                    return .cached
                                }
                                if let reason = file.unavailableReason { return .unavailable(reason) }
                                do {
                                    try await canvasDownloadCheckpoint()
                                    if automatic && !automaticallyDownloadNewCanvasFiles { throw CancellationError() }
                                    canvasStatus = "Downloading new file · \(file.title)"
                                    _ = try await fetchMaterial(file, courseID: id, client: client, bulk: true)
                                    return .downloaded
                                } catch {
                                    try Task.checkCancellation()
                                    if (error as? CanvasHTTPError)?.requiresSignIn == true
                                        || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                                    return .failed(error.localizedDescription)
                                }
                            }, completed: { [self] index, result in
                                guard stillConnected(course), let ci = library.courses.firstIndex(where: { $0.id == id }) else {
                                    throw CancellationError()
                                }
                                switch result {
                                case .downloaded:
                                    downloaded += 1; courseDownloads += 1
                                    library.courses[ci].canvasFileSync?.pendingFileIDs.removeAll { $0 == files[index].id }
                                case .cached:
                                    library.courses[ci].canvasFileSync?.pendingFileIDs.removeAll { $0 == files[index].id }
                                case .unavailable(let reason), .failed(let reason):
                                    fileErrors.append("\(files[index].title): \(reason)")
                                }
                                save()
                            })
                        if let ci = library.courses.firstIndex(where: { $0.id == id }) {
                            let remaining = library.courses[ci].canvasFileSync?.pendingFileIDs.count ?? 0
                            library.courses[ci].canvasFileSync?.summary = "\(courseDownloads) new \(courseDownloads == 1 ? "file" : "files") downloaded."
                                + (remaining == 0 ? "" : " \(remaining) waiting to retry.")
                            let errors = catalog.warnings + fileErrors
                            library.courses[ci].canvasFileSync?.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
                        }
                        warnings += fileErrors
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        guard stillConnected(course) else { throw CancellationError() }
                        if let ci = library.courses.firstIndex(where: { $0.id == id }) {
                            var state = CanvasCourseFileSync.baseline(for: library.courses[ci])
                            state.checkedAt = now; state.downloadAttemptedAt = now
                            state.error = error.localizedDescription
                            library.courses[ci].canvasFileSync = state
                        }
                        warnings.append("\(course.displayName): \(error.localizedDescription)")
                        recordCanvasConnectionError(error)
                        if canvasNeedsAuthentication { break }
                    }
                }
                if !automatic || downloaded > 0 || !warnings.isEmpty {
                    canvasWarnings = warnings
                    canvasStatus = "\(checked) \(checked == 1 ? "course" : "courses") checked. \(downloaded) new files downloaded."
                        + (warnings.isEmpty ? "" : " Some files could not be checked or downloaded.")
                }
            } catch is CancellationError {
                canvasStatus = "New-file downloads stopped. Completed files and the remaining queue are saved."
            } catch { reportCanvasError(error) }
        }
        canvasTask = task
        return task
    }

    var canvasDownloadInventory: [CanvasCourseDownloadInventory] {
        canvasUpdatableCourses.map(CanvasCourseDownloadInventory.make)
    }

    /// Rebuild the inventory from the actual originals and indexes, including files saved before this version.
    func verifyCanvasDownloads() {
        guard !canvasVerifyingDownloads, canSave else { return }
        let documents = library.courses.flatMap(\.documents).filter { $0.sourceKey != nil }
        guard !documents.isEmpty else { return }
        canvasVerifyingDownloads = true
        canvasVerificationStatus = "Checking \(documents.count) saved materials…"
        let store = store
        canvasVerificationTask = Task { [weak self] in
            guard let self else { return }
            defer { canvasVerifyingDownloads = false; canvasVerificationTask = nil }
            let worker = Task.detached(priority: .background) { try CanvasSavedFileCheck.run(documents, store: store) }
            do {
                let results = try await withTaskCancellationHandler(
                    operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.document.id, $0) })
                var updated = library
                var verified = 0, unverified = 0, repairs = 0
                for ci in updated.courses.indices {
                    for di in updated.courses[ci].documents.indices {
                        let current = updated.courses[ci].documents[di]
                        guard let check = byID[current.id], current.contentHash == check.document.contentHash,
                            current.sourceVersion == check.document.sourceVersion,
                            current.locallyEditedAt == check.document.locallyEditedAt else { continue }
                        updated.courses[ci].documents[di].contentBytes = check.bytes
                        updated.courses[ci].documents[di].contentCheckedAt = check.checkedAt
                        updated.courses[ci].documents[di].contentIntegrity = check.integrity
                        switch check.integrity {
                        case .verified: verified += 1
                        case .unverified: unverified += 1
                        case .needsRepair: repairs += 1
                        }
                    }
                }
                library = updated
                save()
                try await libraryWriter.waitForPendingWrites()
                canvasVerificationStatus = "\(verified) verified · \(unverified) need verification · \(repairs) need repair."
            } catch is CancellationError {
                canvasVerificationStatus = "Verification stopped. Previously saved results are kept."
            } catch { canvasVerificationStatus = "Verification could not be saved: \(error.localizedDescription)" }
        }
    }

    func cancelCanvasVerification() { canvasVerificationTask?.cancel() }

    private func canvasDownloadCheckpoint() async throws {
        try await CanvasDownloadScheduling.checkpoint(
            priority: { self.canvasDownloadPriority },
            foregroundBusy: { self.assignmentPreparing || self.isImporting || self.isStreaming },
            constrained: {
                ProcessInfo.processInfo.isLowPowerModeEnabled
                    || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
            })
    }

    private func saveCanvasDownloadProgress(_ progress: CanvasDownloadProgress?) async throws {
        try await canvasDownloadProgressStore.save(progress)
        canvasDownloadProgress = progress?.remainingCourseIDs.isEmpty == false ? progress : nil
        canvasDownloadPendingCount = canvasDownloadProgress?.remainingCourseIDs.count ?? 0
    }

    private func updateCanvasDownloadProgress(courseID: UUID, pending: [String]?) async throws {
        guard var progress = canvasDownloadProgress else { return }
        // A checkpoint can advance only after the library snapshot referencing the committed files is durable.
        save()
        try await libraryWriter.waitForPendingWrites()
        if let pending {
            progress.pendingMaterialIDs[courseID] = pending
        } else {
            progress.remainingCourseIDs.removeAll { $0 == courseID }
            progress.pendingMaterialIDs[courseID] = nil
        }
        try await saveCanvasDownloadProgress(progress)
    }

    func refreshCanvasAssignmentsIfNeeded(now: Date = Date(), force: Bool = false) async {
        guard !canvasBusy, !canvasChecking, !canvasSigningIn, !assignmentRefreshBusy,
            library.canvasUserID != nil,
            force || now.timeIntervalSince(assignmentRefreshAttempt ?? .distantPast) >= 120 else { return }
        let origin = library.canvasOrigin, userID = library.canvasUserID
        let targets = library.courses.filter {
            $0.canvasID != nil && $0.canvasAvailable != false
                && $0.canvasOrigin == origin && $0.canvasUserID == userID
        }
        guard !targets.isEmpty else { return }
        assignmentRefreshBusy = true
        assignmentRefreshAttempt = now
        defer { assignmentRefreshBusy = false }
        var failures = 0
        var needsSignIn = false
        var needsKeychainAccess = false
        var refreshedAssignments: [(courseID: UUID, updates: [CanvasMaterialReference])] = []
        for course in targets {
            if Task.isCancelled || canvasBusy || library.canvasOrigin != origin || library.canvasUserID != userID { return }
            do {
                let client = try await connectedClient(for: course)
                let updates = try await client.assignmentUpdates(courseID: course.canvasID!)
                try Task.checkCancellation()
                guard !canvasBusy, library.canvasOrigin == origin, library.canvasUserID == userID else { continue }
                refreshedAssignments.append((course.id, updates))
            } catch is CancellationError { return }
            catch {
                failures += 1
                let error = resolvedCanvasConnectionError(error)
                if (error as? KeychainStoreError)?.needsInteraction == true {
                    recordCanvasConnectionError(error)
                    needsKeychainAccess = true
                    break
                }
                if (error as? CanvasHTTPError)?.requiresSignIn == true {
                    recordCanvasConnectionError(error)
                    needsSignIn = true
                    break
                }
            }
        }
        guard !Task.isCancelled, !canvasBusy, library.canvasOrigin == origin, library.canvasUserID == userID else { return }
        // Merge into the current library after the network awaits, preserving any
        // edits made meanwhile. Publishing nested fields for every assignment
        // invalidated the whole workspace hundreds of times, even for equal data.
        var refreshedLibrary = library
        var changed = false
        var selectedCourseChanged = false
        for result in refreshedAssignments {
            guard let ci = refreshedLibrary.courses.firstIndex(where: {
                $0.id == result.courseID && $0.canvasOrigin == origin && $0.canvasUserID == userID
            }) else { continue }
            var materials = refreshedLibrary.courses[ci].canvasMaterials ?? []
            var indices: [String: Int] = [:]
            for index in materials.indices where indices[materials[index].id] == nil {
                indices[materials[index].id] = index
            }
            var courseChanged = false
            for update in result.updates {
                if let index = indices[update.id] {
                    var merged = materials[index]
                    merged.assignment = update.assignment?.retainingFeedback(from: merged.assignment)
                    merged.title = update.title
                    merged.version = update.version
                    guard merged != materials[index] else { continue }
                    materials[index] = merged
                } else {
                    indices[update.id] = materials.count
                    materials.append(update)
                }
                courseChanged = true
            }
            if courseChanged {
                refreshedLibrary.courses[ci].canvasMaterials = materials
                changed = true
                selectedCourseChanged = selectedCourseChanged || result.courseID == library.selectedCourseID
            }
        }
        if failures == 0, refreshedLibrary.canvasAssignmentsCheckedAt != now {
            refreshedLibrary.canvasAssignmentsCheckedAt = now
            changed = true
        }
        let refreshError: String? = needsKeychainAccess
            ? "The saved Canvas login needs Keychain access. Reconnect Canvas to refresh assignment status."
            : needsSignIn
            ? "Your Canvas sign-in has expired. Reconnect Canvas to refresh assignment status."
            : failures == 0 ? nil : "Some Canvas statuses could not be refreshed. Retrying automatically."
        if refreshedLibrary.canvasAssignmentsError != refreshError {
            refreshedLibrary.canvasAssignmentsError = refreshError
            changed = true
        }
        guard changed else { return }
        library = refreshedLibrary
        if selectedCourseChanged { loadAssignmentText() }
        // A refresh needs one durable snapshot, not one full-library encoding
        // for every course. The existing writer still coalesces unrelated saves.
        save()
    }

    private func connectedClient(for course: StudyCourse) async throws -> CanvasClient {
        guard let value = course.canvasOrigin, let userID = course.canvasUserID else {
            throw StudyError.message("Connect this course to Canvas first.")
        }
        let origin = try CanvasAddress.origin(value)
        if let canvasClient, connectedOrigin == origin, canvasAccount?.id == userID { return canvasClient }
        let ticket = canvasConnectionCheckID
        let client = try await canvasClientFactory(origin, false, false)
        let account = try await client.account()
        guard canvasConnectionCheckID == ticket else { throw CancellationError() }
        guard account.id == userID else {
            throw StudyError.message("Sign into the Canvas account that owns this course, then try again.")
        }
        if canvasNeedsAuthentication { canvasStatus = nil }
        canvasNeedsSignIn = false
        canvasNeedsKeychainAccess = false
        canvasClient = client
        canvasAccount = account
        connectedOrigin = origin
        return client
    }

    func beginCanvasSignIn() async {
        guard !canvasBusy, !canvasChecking else { return }
        let address = canvasAddress
        func reconnect(useBrowserSession: Bool = false) async -> Bool {
            if await checkCanvasConnection(useBrowserSession: useBrowserSession) { return true }
            if canvasNeedsKeychainAccess, !Task.isCancelled, canvasAddress == address {
                // Only an explicit Reconnect action may ask macOS for Keychain access.
                return await checkCanvasConnection(useBrowserSession: useBrowserSession, allowKeychainInteraction: true)
            }
            return false
        }
        // A valid saved token or browser session never needs a web view or a window.
        if await reconnect() { return }
        guard !Task.isCancelled, !canvasBusy, canvasAddress == address, canvasNeedsSignIn else { return }
        // An expired personal token must not force a window when the saved
        // browser session is still valid.
        if await reconnect(useBrowserSession: true) { return }
        guard !Task.isCancelled, !canvasBusy, canvasAddress == address, canvasNeedsSignIn else { return }
        do {
            canvasConnectionCheckID = UUID(); canvasChecking = false
            let origin = try CanvasAddress.origin(canvasAddress)
            canvasAddress = origin.absoluteString
            canvasClient = nil; canvasAccount = nil; connectedOrigin = nil
            canvasConnectionStatus = "Complete your Canvas sign-in below."
            canvasSigningIn = true
        } catch { canvasConnectionStatus = error.localizedDescription }
    }

    @Published private var canvasNeedsSignIn = false
    @Published private var canvasNeedsKeychainAccess = false

    var canvasNeedsAuthentication: Bool { canvasNeedsSignIn || canvasNeedsKeychainAccess }
    var canvasReconnectTitle: String { canvasNeedsKeychainAccess ? "Allow Keychain access" : "Sign in again" }

    private func recordCanvasConnectionError(_ error: Error) {
        let error = resolvedCanvasConnectionError(error)
        canvasNeedsSignIn = (error as? CanvasHTTPError)?.requiresSignIn == true
        canvasNeedsKeychainAccess = (error as? KeychainStoreError)?.needsInteraction == true
        if canvasNeedsAuthentication {
            canvasClient = nil; canvasAccount = nil; connectedOrigin = nil
        }
    }

    private func reportCanvasError(_ error: Error) {
        recordCanvasConnectionError(error)
        canvasStatus = resolvedCanvasConnectionError(error).localizedDescription
    }

    private func resolvedCanvasConnectionError(_ error: Error) -> Error {
        if (error as? CanvasHTTPError)?.requiresSignIn == true,
            let origin = try? CanvasAddress.origin(canvasAddress),
            let keychain = CanvasSession.keychainError(origin: origin) { return keychain }
        return error
    }

    func retryCanvasSignIn() async {
        guard !canvasBusy, !canvasChecking else { return }
        await beginCanvasSignIn()
        canvasStatus = canvasConnectionStatus
        if canvasSigningIn { canvasPresented = true }
    }

    func cancelCanvasSignIn() {
        guard canvasSigningIn else { return }
        canvasConnectionCheckID = UUID()
        canvasChecking = false
        canvasSigningIn = false
        canvasConnectionStatus = "Sign-in closed. Your saved connection will be checked on the next refresh."
    }

    func canvasSignInFailed(_ message: String) {
        canvasConnectionStatus = message
    }

    @discardableResult
    func checkCanvasConnection(useBrowserSession: Bool = false, allowKeychainInteraction: Bool = false) async -> Bool {
        guard !canvasBusy, !canvasChecking else { return false }
        canvasChecking = true
        canvasConnectionStatus = "Checking saved connection…"
        let ticket = UUID()
        canvasConnectionCheckID = ticket
        defer { if canvasConnectionCheckID == ticket { canvasChecking = false } }
        let address = canvasAddress
        do {
            let origin = try CanvasAddress.origin(address)
            let browserSignIn = useBrowserSession || canvasSigningIn
            let client = try await canvasClientFactory(origin, browserSignIn, allowKeychainInteraction)
            let account = try await client.account()
            guard !Task.isCancelled, canvasAddress == address, canvasConnectionCheckID == ticket else { return false }
            if browserSignIn { CanvasSession.preferBrowser(origin: origin) }
            canvasClient = client; canvasAccount = account; connectedOrigin = origin
            canvasConnectionStatus = "Connected as \(account.name)"
            if let warning = CanvasSession.persistenceWarning(origin: origin) {
                canvasConnectionStatus += ". " + warning
            }
            library.canvasOrigin = origin.absoluteString
            library.canvasUserID = account.id
            library.canvasUserName = account.name
            canvasSigningIn = false
            if canvasNeedsAuthentication { canvasStatus = nil }
            canvasNeedsSignIn = false
            canvasNeedsKeychainAccess = false
            assignmentRefreshAttempt = nil
            save()
            // Reconnect also unblocks browser-only status updates immediately.
            Task { await self.refreshCanvasAssignmentsIfNeeded(force: true) }
            return true
        } catch {
            guard canvasAddress == address, canvasConnectionCheckID == ticket else { return false }
            recordCanvasConnectionError(error)
            canvasConnectionStatus = resolvedCanvasConnectionError(error).localizedDescription
            return false
        }
    }

    private enum CanvasBulkMaterialResult: Sendable {
        case downloaded, cached, unavailable(String), failed(String)
    }

    private func syncCatalogs(_ ids: [UUID], client: CanvasClient, downloadAll: Bool, courseChanges: String = "",
        automatic: Bool = false, now: Date = Date(), predictedCourseIDs: Set<UUID> = [])
        async throws
    {
        var catalogCount = 0
        var downloadCount = 0
        var changes = CanvasCatalogChanges()
        let origin = library.canvasOrigin, userID = library.canvasUserID
        func checkConnection() throws {
            try Task.checkCancellation()
            guard library.canvasOrigin == origin, library.canvasUserID == userID,
                !automatic || automaticallyUpdateCanvasContent else { throw CancellationError() }
        }
        if downloadAll, let origin = connectedOrigin?.absoluteString, let userID = canvasAccount?.id {
            // The journal must never refer to newly discovered course IDs that only exist in memory.
            save()
            try await libraryWriter.waitForPendingWrites()
            let previous = canvasDownloadProgress.flatMap { $0.origin == origin && $0.userID == userID ? $0 : nil }
            var progress = previous ?? CanvasDownloadProgress(origin: origin, userID: userID, remainingCourseIDs: [])
            for id in ids where !progress.remainingCourseIDs.contains(id) { progress.remainingCourseIDs.append(id) }
            try await saveCanvasDownloadProgress(progress)
        }
        for (position, id) in ids.enumerated() {
            try checkConnection()
            try await canvasDownloadCheckpoint()
            guard var ci = library.courses.firstIndex(where: { $0.id == id }),
                library.courses[ci].canvasID != nil
            else {
                if downloadAll { try await updateCanvasDownloadProgress(courseID: id, pending: nil) }
                continue
            }
            let course = library.courses[ci]
            guard course.canvasOrigin == connectedOrigin?.absoluteString, course.canvasUserID == canvasAccount?.id
            else { continue }
            canvasActivityCourseID = id
            canvasStatus = "Checking \(position + 1)/\(ids.count) · \(course.displayName)…"
            if !automatic {
                library.courses[ci][polling: .canvas].attempt(at: now, reason: .regular)
                library.courses[ci].contentUpdateAttemptedAt = now
            }
            var observed = false
            do {
                let catalog = try await client.catalog(course: course, includePublic: !predictedCourseIDs.contains(id))
                try checkConnection()
                let reconcile = Task.detached(priority: canvasDownloadPriority.taskPriority) {
                    CanvasCatalogChanges.reconcile(previous: course.canvasMaterials, catalog: catalog)
                }
                let merged = await withTaskCancellationHandler(operation: { await reconcile.value }, onCancel: { reconcile.cancel() })
                try checkConnection()
                guard let currentIndex = library.courses.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
                ci = currentIndex
                var updated = library.courses[ci]
                updated.observeContent(catalog, at: now, includingWiki: !predictedCourseIDs.contains(id))
                observed = true
                updated.canvasFileSync = CanvasCourseFileSync.reconcile(course: updated, catalog: catalog, now: Date())
                updated.canvasMaterials = merged.items
                updated.catalogChanges = merged.changes
                if merged.changes.count > 0 { updated.catalogChangedAt = Date() }
                updated.catalogUpdatedAt = Date()
                updated.catalogWarnings = catalog.warnings
                library.courses[ci] = updated
                if self.course?.id == id { loadAssignmentText() }
                changes.added += merged.changes.added
                changes.updated += merged.changes.updated
                changes.removed += merged.changes.removed
                canvasWarnings += catalog.warnings.map { "\(course.code.isEmpty ? course.name : course.code): \($0)" }
                catalogCount += 1
                save()
                if downloadAll {
                    var pending = catalog.items.filter { $0.unavailableReason == nil }.map(\.id)
                    try await updateCanvasDownloadProgress(courseID: id, pending: pending)
                    var finished = 0
                    try await CanvasDownloadScheduling.run(count: catalog.items.count,
                        priority: { self.canvasDownloadPriority }, operation: { [self] i -> CanvasBulkMaterialResult in
                            try checkConnection()
                            let reference = catalog.items[i]
                            if let reason = reference.unavailableReason { return .unavailable(reason) }
                            if let cached = library.courses.first(where: { $0.id == id })?.documents.first(where: { $0.sourceKey == reference.id }),
                                !reference.version.isEmpty, cached.sourceVersion == reference.version,
                                await completeCanvasDocument(cached) { return .cached }
                            do {
                                try await canvasDownloadCheckpoint()
                                try checkConnection()
                                canvasStatus = "Downloading \(position + 1)/\(ids.count) courses · \(reference.title)"
                                _ = try await fetchMaterial(reference, courseID: id, client: client, bulk: true)
                                return .downloaded
                            } catch {
                                try checkConnection()
                                if (error as? CanvasHTTPError)?.requiresSignIn == true
                                    || (error as? KeychainStoreError)?.needsInteraction == true { throw error }
                                return .failed(error.localizedDescription)
                            }
                        }, completed: { [self] i, result in
                            try checkConnection()
                            let reference = catalog.items[i]
                            finished += 1
                            switch result {
                            case .downloaded:
                                downloadCount += 1
                                pending.removeAll { $0 == reference.id }
                                try await updateCanvasDownloadProgress(courseID: id, pending: pending)
                            case .cached:
                                pending.removeAll { $0 == reference.id }
                            case .unavailable(let reason), .failed(let reason):
                                canvasWarnings.append("\(reference.title): \(reason)")
                            }
                            canvasStatus = "Downloading \(position + 1)/\(ids.count) courses · \(finished)/\(catalog.items.count) materials checked"
                        })
                    let completeCatalog = catalog.completeKinds.isSuperset(of: [.syllabus, .pages, .files, .assignments])
                        && catalog.moduleOrderComplete && catalog.linkedContentComplete
                    if let currentIndex = library.courses.firstIndex(where: { $0.id == id }), pending.isEmpty && completeCatalog {
                        library.courses[currentIndex].syncedAt = Date()
                    }
                    try await updateCanvasDownloadProgress(courseID: id, pending: pending.isEmpty && completeCatalog ? nil : pending)
                }
            } catch {
                try checkConnection()
                if !observed, let ci = library.courses.firstIndex(where: { $0.id == id }) {
                    library.courses[ci][polling: .canvas].observe(at: now, signature: "", complete: false,
                        interval: CanvasCourseFileSync.checkInterval)
                }
                recordCanvasConnectionError(error)
                if canvasNeedsAuthentication { throw error }
                canvasWarnings.append("\(course.name): \(error.localizedDescription)")
            }
        }
        var summary = "\(catalogCount) courses checked. "
        if !courseChanges.isEmpty { summary += courseChanges + ". " }
        summary +=
            changes.summary.map { "Materials: \($0)." }
            ?? (canvasWarnings.isEmpty ? "No material changes." : "No changes in the available material metadata.")
        if downloadAll { summary += " \(downloadCount) materials downloaded or updated." }
        if downloadAll, canvasDownloadPendingCount > 0 { summary += " Resume downloads to retry unfinished courses." }
        if !canvasWarnings.isEmpty { summary += " Some Canvas sections could not be checked." }
        canvasStatus = summary
        library.canvasRefreshSummary = summary
        library.canvasCheckedAt = Date()
    }

    func openCanvasMaterial(_ reference: CanvasMaterialReference, courseID: UUID) {
        cancelPreloading()
        if reference.kind == .assignments {
            openAssignment(reference, courseID: courseID)
            return
        }
        guard let course = library.courses.first(where: { $0.id == courseID }) else { return }
        if let document = course.documents.first(where: { $0.sourceKey == reference.id }),
            !document.needsCanvasHTMLUpgrade,
            reference.version.isEmpty || document.sourceVersion == reference.version,
            FileManager.default.fileExists(atPath: store.file(for: document).path)
        {
            if self.course?.id != courseID { selectCourse(courseID) }
            selectDocument(document.id)
            return
        }
        guard !canvasBusy, canSave else { return }
        canvasBusy = true
        canvasWarnings = []
        canvasActivityCourseID = courseID
        canvasStatus = "Downloading \(reference.title)…"
        error = nil
        let openingDocumentID = library.selectedDocumentID
        let openingAssignmentID = library.selectedAssignmentID
        canvasTask = Task { [weak self] in
            guard let self else { return }
            defer {
                canvasBusy = false
                canvasActivityCourseID = nil
                fetchingMaterialID = nil
                save()
                startNextCanvasCourseUpdate()
            }
            do {
                let client = try await connectedClient(for: course)
                let document = try await fetchMaterial(reference, courseID: courseID, client: client)
                if self.course?.id == courseID, !isShowingLibrary,
                    library.selectedDocumentID == openingDocumentID, library.selectedAssignmentID == openingAssignmentID
                {
                    selectDocument(document.id)
                }
                canvasStatus = "\(document.title) is saved for offline reading and tutor context."
            } catch is CancellationError { canvasStatus = "Download stopped. Your library is saved." } catch {
                reportCanvasError(error)
                self.error = error.localizedDescription
            }
        }
    }

    private func loadAssignmentText() {
        assignmentText = ""
        guard let assignment, let document = course?.documents.first(where: { $0.sourceKey == assignment.id }),
            let index = try? store.index(for: document)
        else { return }
        assignmentText = CanvasAssignmentDetails.refreshingCachedDeadline(
            index.pages.map(\.text).joined(separator: "\n\n"),
            sourceVersion: document.sourceVersion, dueAt: assignment.assignment?.dueAt)
        let heading = "# \(assignment.title)\n"
        if assignmentText.hasPrefix(heading) { assignmentText.removeFirst(heading.count) }
        assignmentText = assignmentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelAssignmentPreparation() {
        assignmentPreparationTask?.cancel()
        assignmentPreparationTask = nil
        assignmentPreparationID = nil
        assignmentPreparing = false
        assignmentPreparingFileID = nil
    }

    /// Keep the assignment selected while its reader and companion files become available.
    func openAssignment(
        _ reference: CanvasMaterialReference, courseID: UUID, fileID: String? = nil, clientOverride: CanvasClient? = nil
    ) {
        guard reference.kind == .assignments, let target = library.courses.first(where: { $0.id == courseID }),
            let remoteID = target.canvasID
        else { return }
        if self.course?.id != courseID || assignment?.id != reference.id { assignmentActivity = [] }
        let requestedFileID =
            fileID
            ?? (self.course?.id == courseID && assignment?.id == reference.id ? library.selectedAssignmentFileID : nil)
        let preservesConversation = self.course?.id == courseID && assignment?.id == reference.id
            && assignmentFeedbackFiles.contains(where: { $0.id == requestedFileID })
        if preservesConversation { saveDraft() }
        let feedbackThreadID = preservesConversation ? library.selectedThreadID : nil
        recordNavigation()
        selectCourse(courseID, recordHistory: false)
        library.selectedAssignmentID = reference.id
        library.selectedAssignmentFileID = requestedFileID
        library.selectedThreadID = preservesConversation ? feedbackThreadID
            : course?.threads.last(where: { $0.documentID == nil && $0.assignmentID == reference.id })?.id
        restoreThread()
        assignmentNotice = nil
        assignmentFileNotices = [:]
        loadAssignmentText()
        save()
        let initial =
            requestedFileID.flatMap { id in assignmentReadableFiles.first { $0.id == id } }
            ?? assignmentPDFs.first ?? assignmentFiles.first
        if let initial, let cached = target.documents.first(where: { $0.sourceKey == initial.id }),
            FileManager.default.fileExists(atPath: store.file(for: cached).path)
        {
            library.selectedAssignmentFileID = initial.id
            selectDocument(cached.id, assignmentID: reference.id, recordHistory: false,
                preservingConversation: preservesConversation)
        }
        guard canSave else { return }
        cancelPreloading()
        let preparationID = UUID()
        assignmentPreparationID = preparationID
        assignmentPreparing = true
        error = nil
        let openingDocumentID = library.selectedDocumentID
        let openingFileID = library.selectedAssignmentFileID
        assignmentPreparationTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                if assignmentPreparationID == preparationID {
                    assignmentPreparing = false
                    assignmentPreparingFileID = nil
                    assignmentPreparationTask = nil
                    assignmentPreparationID = nil
                }
                save()
            }
            @MainActor func stillSelected() -> Bool {
                assignmentPreparationID == preparationID && !Task.isCancelled
                    && self.course?.id == courseID && library.selectedAssignmentID == reference.id && !isShowingLibrary
            }
            var resolvedClient = clientOverride
            @MainActor func client() async throws -> CanvasClient {
                if let resolvedClient { return resolvedClient }
                let connected = try await connectedClient(for: target)
                resolvedClient = connected
                return connected
            }
            @MainActor func cached(_ material: CanvasMaterialReference) -> StudyDocument? {
                guard
                    let document = library.courses.first(where: { $0.id == courseID })?.documents.first(where: {
                        $0.sourceKey == material.id
                    }), material.version.isEmpty || document.sourceVersion == material.version,
                    FileManager.default.fileExists(atPath: store.file(for: document).path)
                else { return nil }
                return document
            }
            do {
                var current = reference
                do {
                    // A saved PDF or description says nothing about whether the
                    // instructor has moved the deadline since it was downloaded.
                    let update = try await client().assignmentUpdate(courseID: remoteID, id: reference.remoteID)
                    try Task.checkCancellation()
                    guard stillSelected(), let ci = library.courses.firstIndex(where: { $0.id == courseID }),
                        let mi = library.courses[ci].canvasMaterials?.firstIndex(where: { $0.id == reference.id })
                    else { return }
                    current.assignment = update.assignment?.retainingFeedback(from: current.assignment)
                    current.title = update.title
                    current.version = update.version
                    library.courses[ci].canvasMaterials?[mi].assignment = current.assignment
                    library.courses[ci].canvasMaterials?[mi].title = current.title
                    library.courses[ci].canvasMaterials?[mi].version = current.version
                } catch {
                    try Task.checkCancellation()
                    guard stillSelected() else { return }
                    recordCanvasConnectionError(error)
                    assignmentNotice = "Deadline may be out of date. Could not refresh Canvas: \(error.localizedDescription)"
                }
                if let reason = current.unavailableReason {
                    assignmentNotice = [assignmentNotice, reason].compactMap { $0 }.joined(separator: " ")
                    return
                }
                if cached(current) == nil || current.assignment?.linkedFileIDs == nil {
                    recordAssignmentActivity("Fetching assignment instructions", detail: current.title)
                    _ = try await fetchMaterial(current, courseID: courseID, client: client())
                }
                try Task.checkCancellation()
                guard stillSelected() else { return }
                loadAssignmentText()
                recordAssignmentActivity("Assignment instructions ready", detail: reference.title)
                let linkedIDs = assignment?.assignment?.linkedFileIDs ?? []
                var resolveIDs = Array(linkedIDs.prefix(50))
                if let requestedFileID, let id = assignmentReadableFiles.first(where: { $0.id == requestedFileID })?.remoteID {
                    resolveIDs.removeAll { $0 == id }
                    resolveIDs.insert(id, at: 0)
                }
                for id in resolveIDs {
                    // An explicit file request goes directly to that file; resolve companions as they are prepared.
                    if let fileID, "files:\(id)" != fileID { continue }
                    try Task.checkCancellation()
                    guard stillSelected() else { return }
                    if course?.materials.first(where: { $0.id == "files:\(id)" })?.fileName != nil { continue }
                    do {
                        let file = try await client().fileReference(id: id, courseID: remoteID)
                        try Task.checkCancellation()
                        guard stillSelected() else { return }
                        guard let ci = library.courses.firstIndex(where: { $0.id == courseID }) else { return }
                        if let mi = library.courses[ci].canvasMaterials?.firstIndex(where: { $0.id == file.id }) {
                            library.courses[ci].canvasMaterials?[mi] = file
                        } else {
                            library.courses[ci].canvasMaterials = (library.courses[ci].canvasMaterials ?? []) + [file]
                        }
                    } catch {
                        try Task.checkCancellation()
                        if stillSelected() {
                            assignmentFileNotices["files:\(id)"] = "Unavailable: \(error.localizedDescription)"
                        }
                    }
                }
                guard stillSelected() else { return }
                var files = assignmentFiles
                if let requestedFileID, let feedback = assignmentFeedbackFiles.first(where: { $0.id == requestedFileID }),
                    !files.contains(where: { $0.id == feedback.id }) { files.insert(feedback, at: 0) }
                let selected =
                    requestedFileID.flatMap { id in files.first { $0.id == id } }
                    ?? assignmentPDFs.first ?? files.first
                var expectedFileID = openingFileID
                if library.selectedDocumentID == openingDocumentID && library.selectedAssignmentFileID == openingFileID
                {
                    library.selectedAssignmentFileID = selected?.id
                    expectedFileID = selected?.id
                }
                let automaticIDs = Set(files.prefix(50).map(\.id))
                let ordered = selected.map { [$0] } ?? []
                var automaticBytes = 0
                for var file in ordered + files.filter({ $0.id != selected?.id }) {
                    try Task.checkCancellation()
                    guard stillSelected() else { return }
                    assignmentPreparingFileID = file.id
                    let explicitlyOpened = file.id == fileID
                    if file.fileName == nil, assignmentFileNotices[file.id] == nil,
                        automaticIDs.contains(file.id) || explicitlyOpened
                    {
                        do {
                            file = try await client().fileReference(id: file.remoteID, courseID: remoteID)
                            try Task.checkCancellation()
                            guard stillSelected(), let ci = library.courses.firstIndex(where: { $0.id == courseID })
                            else { return }
                            if let mi = library.courses[ci].canvasMaterials?.firstIndex(where: { $0.id == file.id }) {
                                library.courses[ci].canvasMaterials?[mi] = file
                            } else {
                                library.courses[ci].canvasMaterials = (library.courses[ci].canvasMaterials ?? []) + [file]
                            }
                        } catch {
                            try Task.checkCancellation()
                            guard stillSelected() else { return }
                            assignmentFileNotices[file.id] = "Unavailable: \(error.localizedDescription)"
                            continue
                        }
                    }
                    let existing = cached(file)
                    if !explicitlyOpened && !automaticIDs.contains(file.id) {
                        if existing == nil {
                            assignmentFileNotices[file.id] =
                                "Not prepared: automatic limit is 50 files. Open to download."
                        }
                        continue
                    }
                    if existing == nil, !explicitlyOpened {
                        if let size = file.byteCount, size > 20_000_000 {
                            assignmentFileNotices[file.id] = "Not prepared: larger than 20 MB. Open to download."
                            continue
                        }
                        if automaticBytes >= 50_000_000 || (file.byteCount ?? 0) > 50_000_000 - automaticBytes {
                            assignmentFileNotices[file.id] =
                                "Not prepared: assignment download limit reached. Open to download."
                            continue
                        }
                    }
                    if let reason = file.unavailableReason {
                        assignmentFileNotices[file.id] = reason
                        continue
                    }
                    if file.fileName == nil, assignmentFileNotices[file.id] != nil { continue }
                    let limit =
                        explicitlyOpened
                        ? StudyDocumentImporter.maximumBytes : min(20_000_000, 50_000_000 - automaticBytes)
                    var received = 0
                    do {
                        let saved: StudyDocument
                        if let existing {
                            recordAssignmentActivity("Reading saved file", detail: file.title)
                            saved = try await indexCachedAssignmentText(existing, file: file, courseID: courseID)
                        } else {
                            recordAssignmentActivity("Downloading included file", detail: file.title)
                            saved = try await fetchMaterial(
                                file, courseID: courseID, client: client(), maximumBytes: limit
                            ) { received = $0 }
                        }
                        if !explicitlyOpened { automaticBytes += received }
                        guard stillSelected() else { return }
                        recordAssignmentActivity("File ready", detail: saved.title)
                        if file.id == selected?.id, library.selectedDocumentID == openingDocumentID,
                            library.selectedAssignmentFileID == expectedFileID
                        {
                            selectDocument(saved.id, assignmentID: reference.id, recordHistory: false,
                                preservingConversation: preservesConversation)
                        }
                    } catch {
                        try Task.checkCancellation()
                        if !explicitlyOpened { automaticBytes += received == 0 ? limit : received }
                        if stillSelected() {
                            recordAssignmentActivity("File unavailable", detail: file.title + ": " + error.localizedDescription)
                            assignmentFileNotices[file.id] = "Unavailable: \(error.localizedDescription)"
                        }
                    }
                }
                if stillSelected() {
                    if !assignmentFileNotices.isEmpty {
                        assignmentNotice = [assignmentNotice,
                            "Some included files are not ready for the companion. See each file's status."]
                            .compactMap { $0 }.joined(separator: " ")
                    }
                }
            } catch {
                if stillSelected() {
                    recordCanvasConnectionError(error)
                    loadAssignmentText()
                    assignmentNotice =
                        error is CancellationError
                        ? "Preparation stopped. Saved instructions and files are still available."
                        : "Could not prepare this assignment. \(error.localizedDescription)"
                }
            }
        }
    }

    func openAssignmentFile(_ id: String) {
        guard let assignment, let course, assignmentReadableFiles.contains(where: { $0.id == id }) else { return }
        openAssignment(assignment, courseID: course.id, fileID: id)
    }

    private func recordAssignmentActivity(_ title: String, detail: String) {
        guard assignmentActivity.last?.title != title || assignmentActivity.last?.detail != detail else { return }
        assignmentActivity = Array((assignmentActivity + [ConversationActivity(title: title, detail: String(detail.prefix(2_000)))]).suffix(80))
    }

    func openAssignmentPDF(_ id: String) { openAssignmentFile(id) }

    private func indexCachedAssignmentText(
        _ document: StudyDocument, file: CanvasMaterialReference, courseID: UUID
    ) async throws -> StudyDocument {
        guard document.kind == .preview else { return document }
        let store = store
        let name = file.fileName ?? document.originalFileName ?? document.fileName
        guard !StudyFileFormats.previewExtensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) else {
            return document
        }
        let staging = StudyDocumentStaging(destination: store)
        defer { staging.discard() }
        let job = Task.detached(priority: .utility) { () throws -> StudyDocumentStaging.PreparedDocument? in
            let data = try Data(contentsOf: store.file(for: document))
            guard StudyDocumentImporter.safePlainText(data) != nil else { return nil }
            let indexed = try StudyDocumentImporter.read(data: data, name: name, store: staging.store, id: document.id)
            return try staging.prepare(indexed)
        }
        guard
            let prepared = try await withTaskCancellationHandler(
                operation: { try await job.value }, onCancel: { job.cancel() })
        else {
            return document
        }
        try Task.checkCancellation()
        guard let ci = library.courses.firstIndex(where: { $0.id == courseID }),
            let di = library.courses[ci].documents.firstIndex(where: { $0.id == document.id })
        else { throw CancellationError() }
        let current = library.courses[ci].documents[di]
        guard savingDocumentID != document.id, current.contentHash == document.contentHash,
            current.locallyEditedAt == document.locallyEditedAt, current.sourceVersion == document.sourceVersion else {
            throw StudyError.message("This file changed while it was being prepared. Your saved changes were kept; reopen the file to retry.")
        }
        let indexed = prepared.document
        try staging.commit(prepared, to: store)
        var saved = document
        saved.kind = indexed.kind
        saved.fileName = indexed.fileName
        saved.pageCount = indexed.pageCount
        saved.unreadablePages = indexed.unreadablePages
        saved.contentHash = indexed.contentHash
        saved.contentBytes = indexed.contentBytes
        saved.contentCheckedAt = indexed.contentCheckedAt
        saved.contentIntegrity = indexed.contentIntegrity
        saved.contentNotice = indexed.contentNotice
        saved.originalFileName = name
        saved.classification = indexed.classification
        library.courses[ci].documents[di] = saved
        return saved
    }

    private func fetchMaterial(
        _ reference: CanvasMaterialReference, courseID: UUID, client: CanvasClient, background: Bool = false,
        bulk: Bool = false,
        maximumBytes: Int = StudyDocumentImporter.maximumBytes, onDownload: ((Int) -> Void)? = nil
    ) async throws -> StudyDocument {
        try Task.checkCancellation()
        let key = courseID.uuidString + ":" + reference.id
        let waiter = UUID()
        let limit = background ? min(10_000_000, maximumBytes) : maximumBytes
        let transfer: CanvasMaterialTransfer
        if let existing = canvasMaterialTransfers[key] {
            transfer = existing
        } else {
            let priority: TaskPriority = bulk ? canvasDownloadPriority.taskPriority : background ? .background : .userInitiated
            let task = Task(priority: priority) { [self] in
                try await performMaterialTransfer(reference, courseID: courseID, client: client,
                    background: background, bulk: bulk, maximumBytes: limit)
            }
            transfer = CanvasMaterialTransfer(maximumBytes: limit, task: task)
            canvasMaterialTransfers[key] = transfer
        }
        transfer.waiters.insert(waiter)
        defer { releaseCanvasMaterialTransfer(key, transfer: transfer, waiter: waiter) }
        let waiting = CanvasMaterialWaiter()
        // Awaiting at the caller's priority also promotes an in-flight background transfer when opened explicitly.
        Task(priority: bulk ? canvasDownloadPriority.taskPriority : background ? .background : .userInitiated) { [self] in
            let result: Result<(StudyDocument, Int), Error>
            do { result = .success(try await transfer.task.value) }
            catch { result = .failure(error) }
            transfer.finished = true
            waiting.complete(result)
            releaseCanvasMaterialTransfer(key, transfer: transfer, waiter: waiter)
        }
        do {
            let (document, count) = try await withTaskCancellationHandler(
                operation: { try await withCheckedThrowingContinuation { waiting.install($0) } },
                onCancel: { waiting.complete(.failure(CancellationError())) })
            try Task.checkCancellation()
            guard count <= limit else { throw StudyError.message("This material exceeds the download size limit.") }
            onDownload?(count)
            return document
        } catch {
            try Task.checkCancellation()
            // A stopped preloader or a stricter automatic file limit must not defeat a foreground request.
            if transfer.task.isCancelled || transfer.maximumBytes < limit {
                if canvasMaterialTransfers[key]?.id == transfer.id { canvasMaterialTransfers[key] = nil }
                return try await fetchMaterial(reference, courseID: courseID, client: client,
                    background: background, bulk: bulk, maximumBytes: maximumBytes, onDownload: onDownload)
            }
            throw error
        }
    }

    private func releaseCanvasMaterialTransfer(_ key: String, transfer: CanvasMaterialTransfer, waiter: UUID) {
        transfer.waiters.remove(waiter)
        guard transfer.waiters.isEmpty else { return }
        if transfer.finished {
            if canvasMaterialTransfers[key]?.id == transfer.id { canvasMaterialTransfers[key] = nil }
        } else {
            transfer.task.cancel()
        }
    }

    private func completeCanvasDocument(_ document: StudyDocument) async -> Bool {
        guard !document.needsCanvasHTMLUpgrade else { return false }
        let store = store
        let job = Task.detached(priority: canvasDownloadPriority.taskPriority) {
            try CanvasSavedFileCheck.run([document], store: store).first!
        }
        guard let check = try? await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() }),
            !Task.isCancelled else { return false }
        if let ci = library.courses.firstIndex(where: { $0.documents.contains(where: { $0.id == document.id }) }),
            let di = library.courses[ci].documents.firstIndex(where: { $0.id == document.id }),
            library.courses[ci].documents[di].contentHash == document.contentHash,
            library.courses[ci].documents[di].sourceVersion == document.sourceVersion {
            var course = library.courses[ci]
            course.documents[di].contentBytes = check.bytes
            course.documents[di].contentCheckedAt = check.checkedAt
            course.documents[di].contentIntegrity = check.integrity
            library.courses[ci] = course
        }
        return check.integrity == .verified
    }

    private func performMaterialTransfer(
        _ reference: CanvasMaterialReference, courseID: UUID, client: CanvasClient,
        background: Bool, bulk: Bool, maximumBytes: Int
    ) async throws -> (StudyDocument, Int) {
        guard var ci = library.courses.firstIndex(where: { $0.id == courseID }),
            let remoteID = library.courses[ci].canvasID
        else { throw StudyError.message("Course not found.") }
        if !background && !bulk { fetchingMaterialID = reference.id }
        defer { if fetchingMaterialID == reference.id { fetchingMaterialID = nil } }
        let item = try await client.material(reference, courseID: remoteID)
        try Task.checkCancellation()
        guard let currentIndex = library.courses.firstIndex(where: { $0.id == courseID }) else {
            throw CancellationError()
        }
        ci = currentIndex
        let previous = library.courses[ci].documents.first(where: { $0.sourceKey == reference.id })
        if let mi = library.courses[ci].canvasMaterials?.firstIndex(where: { $0.id == reference.id }) {
            if !item.version.isEmpty { library.courses[ci].canvasMaterials?[mi].version = item.version }
            if let details = item.assignment {
                library.courses[ci].canvasMaterials?[mi].assignment = details.retainingFeedback(
                    from: library.courses[ci].canvasMaterials?[mi].assignment)
            }
        }
        if let previous, !item.version.isEmpty, previous.sourceVersion == item.version,
            await completeCanvasDocument(previous)
        {
            return (previous, 0)
        }
        let data: Data
        if let text = item.text {
            data = Data(text.utf8)
        } else if let url = item.downloadURL {
            data = try await client.download(url, limit: maximumBytes,
                priority: bulk ? canvasDownloadTaskPriority : background ? CanvasDownloadTaskPriority(.background) : nil,
                mathWikiFile: reference.isMathWiki || reference.isCourseWebsite)
        } else {
            throw StudyError.message("This material is unavailable.")
        }
        try Task.checkCancellation()
        // Preserve local edits separately when a newer Canvas original arrives.
        let preserveLocal = previous?.locallyEditedAt != nil
        let documentID = preserveLocal ? UUID() : previous?.id ?? UUID()
        let staging = StudyDocumentStaging(destination: store)
        defer { Task.detached(priority: .background) { staging.discard() } }
        let priority: TaskPriority = bulk ? canvasDownloadPriority.taskPriority : background ? .background : .userInitiated
        let job = Task.detached(priority: priority) {
            let document = try StudyDocumentImporter.read(data: data, name: item.fileName, store: staging.store, id: documentID, displayTitle: item.title)
            return try staging.prepare(document)
        }
        let prepared = try await withTaskCancellationHandler(
            operation: { try await job.value }, onCancel: { job.cancel() })
        var document = prepared.document
        try Task.checkCancellation()
        guard let finalIndex = library.courses.firstIndex(where: { $0.id == courseID }) else {
            throw CancellationError()
        }
        ci = finalIndex
        let currentPrevious = library.courses[ci].documents.first(where: { $0.sourceKey == reference.id })
        guard savingDocumentID == nil || savingDocumentID != previous?.id,
            currentPrevious?.id == previous?.id, currentPrevious?.contentHash == previous?.contentHash,
            currentPrevious?.locallyEditedAt == previous?.locallyEditedAt,
            currentPrevious?.sourceVersion == previous?.sourceVersion else {
            throw StudyError.message("This file changed while Canvas was downloading. Your saved changes were kept; reopen the file to retry.")
        }
        // Validation already ran off-main. Keep the short atomic swap and library publication together.
        try staging.commit(prepared, to: store)
        document.title = item.title
        document.sourceKey = reference.id
        document.sourceURL = item.sourceURL
        document.sourceVersion = item.version
        document.lastPage = min(previous?.lastPage ?? 1, document.pageCount)
        if !preserveLocal { document.lastOpenedAt = previous?.lastOpenedAt }
        var updatedCourse = library.courses[ci]
        if preserveLocal, let previous,
            let di = updatedCourse.documents.firstIndex(where: { $0.id == previous.id })
        {
            updatedCourse.documents[di].sourceKey = nil
            updatedCourse.documents[di].title = previous.title + " (local edits)"
        }
        if let di = updatedCourse.documents.firstIndex(where: { $0.id == documentID }) {
            updatedCourse.documents[di] = document
        } else {
            updatedCourse.documents.append(document)
        }
        updatedCourse.canvasFileSync?.pendingFileIDs.removeAll { $0 == reference.id }
        library.courses[ci] = updatedCourse
        if self.document?.id == documentID { loadSelectedDocument() }
        save()
        return (document, data.count)
    }

    func cancelCanvas() {
        queuedCanvasCourseUpdateIDs.removeAll()
        queuedCanvasCourseUpdateAccount = nil
        if automaticCanvasContentSyncRunning { automaticallyUpdateCanvasContent = false }
        if canvasFileSyncRunning { automaticallyDownloadNewCanvasFiles = false }
        canvasTask?.cancel()
        cancelPreloading()
    }
    func disconnectCanvas() {
        cancelPreloading()
        guard !canvasBusy else { return }
        cancelAssignmentPreparation()
        canvasConnectionCheckID = UUID(); canvasChecking = false
        canvasSigningIn = false
        canvasBusy = true
        Task {
            defer {
                canvasBusy = false
                queuedCanvasCourseUpdateIDs.removeAll()
                queuedCanvasCourseUpdateAccount = nil
            }
            do {
                let origin = try CanvasAddress.origin(library.canvasOrigin)
                try await CanvasSession.disconnect(origin: origin)
                canvasClient = nil
                canvasAccount = nil
                connectedOrigin = nil
                canvasCourses = []
                canvasConnectionStatus = "Not connected"
                canvasNeedsSignIn = false
                canvasNeedsKeychainAccess = false
                library.canvasUserID = nil
                library.canvasUserName = nil
                canvasStatus = "Disconnected. Your course cards, favorites, and downloaded documents remain available."
                save()
            } catch { reportCanvasError(error) }
        }
    }
    private func courseIndex() -> Int? { library.courses.firstIndex { $0.id == library.selectedCourseID } }
    private func threadIndex(in ci: Int) -> Int? {
        library.courses[ci].threads.firstIndex { $0.id == library.selectedThreadID }
    }
    private func mutateThread(courseID: UUID, threadID: UUID, change: (inout StudyThread) -> Void) {
        guard let ci = library.courses.firstIndex(where: { $0.id == courseID }),
            let ti = library.courses[ci].threads.firstIndex(where: { $0.id == threadID })
        else { return }
        change(&library.courses[ci].threads[ti])
    }
    private func updateMessage(
        courseID: UUID, threadID: UUID, messageID: UUID, change: (inout ConversationMessage) -> Void
    ) {
        mutateThread(courseID: courseID, threadID: threadID) { thread in
            if let i = thread.messages.firstIndex(where: { $0.id == messageID }) { change(&thread.messages[i]) }
        }
    }
}
