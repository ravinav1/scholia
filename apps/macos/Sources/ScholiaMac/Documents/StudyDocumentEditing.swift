@preconcurrency import AppKit
import CryptoKit
import SwiftUI

struct StudyEditableCell: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var kind: String
    var source: String
}

struct StudyEditDraft: Codable, Equatable, Sendable {
    var documentID: UUID
    var revision: String
    var source: String?
    var cells: [StudyEditableCell]
}

enum StudyDocumentEditing {
    static func supports(_ document: StudyDocument) -> Bool { [.text, .code, .notebook].contains(document.kind) }
    static func revision(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func source(_ value: Any?) -> String { value as? String ?? (value as? [String])?.joined() ?? "" }

    static func read(_ document: StudyDocument, store: StudyLibraryStore) throws -> StudyEditDraft {
        guard supports(document) else {
            throw StudyError.message("Editing is available for notebooks, text and code files.")
        }
        let data = try Data(contentsOf: store.file(for: document))
        if document.kind == .notebook {
            guard let book = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let cells = book["cells"] as? [[String: Any]]
            else { throw StudyError.message("This notebook could not be opened for editing.") }
            return StudyEditDraft(
                documentID: document.id, revision: revision(data),
                cells: cells.enumerated().map {
                    StudyEditableCell(
                        id: $0.offset, kind: $0.element["cell_type"] as? String ?? "raw",
                        source: source($0.element["source"]))
                })
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw StudyError.message("This file is not UTF-8 text.")
        }
        return StudyEditDraft(documentID: document.id, revision: revision(data), source: text, cells: [])
    }

    static func applying(_ draft: StudyEditDraft, to data: Data, document: StudyDocument) throws -> Data {
        guard supports(document), draft.documentID == document.id, draft.revision == revision(data) else {
            throw StudyError.message(
                "This file changed in another window. Your draft is preserved; copy your changes, then cancel and reopen Edit to load the latest version."
            )
        }
        if document.kind != .notebook {
            guard let text = draft.source, text.utf16.count <= StudyDocumentImporter.maximumCharacters,
                !text.contains("\0")
            else { throw StudyError.message("Keep the file below 8 million text characters.") }
            return Data(text.utf8)
        }
        guard var book = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var cells = book["cells"] as? [[String: Any]], cells.count == draft.cells.count,
            draft.cells.map(\.id) == Array(cells.indices),
            draft.cells.reduce(0, { $0 + $1.source.utf16.count }) <= StudyDocumentImporter.maximumCharacters
        else {
            throw StudyError.message(
                "The notebook cells no longer match this draft, or their contents exceed 8 million characters.")
        }
        var changed = false
        for cell in draft.cells {
            guard cell.kind == cells[cell.id]["cell_type"] as? String else {
                throw StudyError.message("A notebook cell's type changed. Reopen the editor.")
            }
            guard cell.source != source(cells[cell.id]["source"]) else { continue }
            changed = true
            cells[cell.id]["source"] = cell.source
            if cell.kind == "code", let outputs = cells[cell.id]["outputs"] as? [Any], !outputs.isEmpty {
                var metadata = cells[cell.id]["metadata"] as? [String: Any] ?? [:]
                var scholia = metadata["scholia"] as? [String: Any] ?? [:]
                scholia["outputsFromEarlierSource"] = true
                metadata["scholia"] = scholia
                cells[cell.id]["metadata"] = metadata
            }
        }
        guard changed else { return data }
        book["cells"] = cells
        return try JSONSerialization.data(
            withJSONObject: book, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func save(_ draft: StudyEditDraft, document: StudyDocument, store: StudyLibraryStore) throws -> StudyDocument
    {
        let original = try Data(contentsOf: store.file(for: document))
        let data = try applying(draft, to: original, document: document)
        guard data != original else { return document }
        let staging = StudyDocumentStaging(destination: store)
        defer { staging.discard() }
        // Fully parse and index the replacement before touching the saved file.
        var saved = try StudyDocumentImporter.read(
            data: data.isEmpty ? Data("\n".utf8) : data, name: document.fileName, store: staging.store, id: document.id, displayTitle: document.title)
        // An empty text file is valid; the importer uses a blank reading section.
        if data.isEmpty {
            try data.write(to: staging.store.file(for: saved), options: .atomic)
            saved.contentHash = revision(data)
        }
        saved.title = document.title
        saved.sourceURL = document.sourceURL
        saved.sourceKey = document.sourceKey
        saved.sourceVersion = document.sourceVersion
        saved.lastPage = min(document.lastPage, saved.pageCount)
        saved.locallyEditedAt = Date()
        saved.lastOpenedAt = document.lastOpenedAt
        saved.originalFileName = document.originalFileName
        saved.addedAt = document.addedAt
        guard try Data(contentsOf: store.file(for: document)) == original else {
            throw StudyError.message("The original changed while saving. Your edit draft is preserved.")
        }
        try staging.commit(saved, to: store)
        saved.contentBytes = data.count
        saved.contentCheckedAt = Date()
        saved.contentIntegrity = .verified
        return saved
    }
}

@MainActor
final class StudyEditingState: ObservableObject {
    @Published var drafts: [UUID: StudyEditDraft] = [:]
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var documentErrors: [UUID: String] = [:]
    private var saveErrors: [UUID: String] = [:]
    private var persistenceErrors: [UUID: String] = [:]
    private let store: StudyLibraryStore
    private let writer: StudyEditDraftWriter
    private var persistTask: Task<Void, Never>?
    private var dirty = Set<UUID>()
    private var tickets: [UUID: UUID] = [:]
    private var writeTickets: [UUID: UUID] = [:]
    private var busyDocuments = Set<UUID>()
    init(store: StudyLibraryStore) {
        self.store = store
        writer = StudyEditDraftWriter(root: store.root)
    }
    func isBusy(_ id: UUID) -> Bool { busyDocuments.contains(id) }
    private func setBusy(_ id: UUID, _ value: Bool) {
        if value { busyDocuments.insert(id) } else { busyDocuments.remove(id) }
        busy = !busyDocuments.isEmpty
    }
    func begin(_ document: StudyDocument) {
        guard !isBusy(document.id), drafts[document.id] == nil else { return }
        let ticket = UUID()
        tickets[document.id] = ticket
        setBusy(document.id, true)
        saveErrors[document.id] = nil
        documentErrors[document.id] = persistenceErrors[document.id]
        error = documentErrors.values.sorted().first
        Task {
            defer { if tickets[document.id] == ticket { setBusy(document.id, false) } }
            do {
                let recovered = try await writer.recover(document, store: store)
                guard tickets[document.id] == ticket else { return }
                drafts[document.id] = recovered
            } catch {
                guard tickets[document.id] == ticket else { return }
                saveErrors[document.id] = error.localizedDescription
                documentErrors[document.id] = error.localizedDescription
                self.error = error.localizedDescription
            }
        }
    }
    func setSource(_ text: String, documentID: UUID, cell: Int? = nil) {
        guard drafts[documentID] != nil else { return }
        if let cell {
            guard drafts[documentID]?.cells.indices.contains(cell) == true else { return }
            drafts[documentID]?.cells[cell].source = text
        } else { drafts[documentID]?.source = text }
        dirty.insert(documentID)
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if !Task.isCancelled { flush() }
        }
    }
    private func completion(_ id: UUID, _ message: String?) {
        persistenceErrors[id] = message.map { "Could not preserve the edit draft: \($0)" }
        documentErrors[id] = saveErrors[id] ?? persistenceErrors[id]
        error = documentErrors.values.sorted().first
    }
    /// Navigation enqueues work; only termination waits for the durability barrier.
    func flush() {
        persistTask?.cancel()
        persistTask = nil
        for id in dirty {
            if let draft = drafts[id] {
                let ticket = UUID()
                writeTickets[id] = ticket
                writer.save(draft) { [weak self] id, message in
                    Task { @MainActor in
                        guard let self, self.writeTickets[id] == ticket else { return }
                        self.completion(id, message)
                    }
                }
            }
        }
        dirty.removeAll()
        writer.retry()
    }
    func flushAndWait() {
        flush()
        do { try writer.flush() }
        catch { self.error = "Could not preserve edit drafts: \(error.localizedDescription)" }
    }
    func cancel(_ id: UUID) {
        tickets[id] = nil
        setBusy(id, false)
        drafts.removeValue(forKey: id)
        dirty.remove(id)
        let ticket = UUID()
        writeTickets[id] = ticket
        writer.remove(id) { [weak self] id, message in
            Task { @MainActor in
                guard let self, self.writeTickets[id] == ticket else { return }
                self.completion(id, message)
            }
        }
        documentErrors[id] = nil
        saveErrors[id] = nil
        error = documentErrors.values.sorted().first
    }
    func save(_ id: UUID, workspace: StudyWorkspaceModel) {
        guard let draft = drafts[id], !isBusy(id) else { return }
        let ticket = UUID()
        tickets[id] = ticket
        setBusy(id, true)
        saveErrors[id] = nil
        documentErrors[id] = persistenceErrors[id]
        error = documentErrors.values.sorted().first
        Task {
            defer { if tickets[id] == ticket { setBusy(id, false) } }
            do {
                try await workspace.saveDocumentEdits(draft)
                if tickets[id] == ticket { cancel(id) }
            } catch {
                guard tickets[id] == ticket else { return }
                saveErrors[id] = error.localizedDescription
                documentErrors[id] = error.localizedDescription
                self.error = error.localizedDescription
                dirty.insert(id)
                flush()
            }
        }
    }
}

struct StudySourceEditor: NSViewRepresentable {
    @Binding var text: String
    var label: String
    var enabled = true
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = enabled
        view.setAccessibilityLabel(label)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StudySourceEditor
        init(_ parent: StudySourceEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
    }
}

struct StudyDocumentEditorView: View {
    @ObservedObject var editing: StudyEditingState
    let document: StudyDocument
    var body: some View {
        if let draft = editing.drafts[document.id] {
            if document.kind == .notebook {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        ForEach(draft.cells) { cell in
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Cell \(cell.id + 1) · \(cell.kind)").font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                StudySourceEditor(
                                    text: Binding(
                                        get: { editing.drafts[document.id]?.cells[cell.id].source ?? "" },
                                        set: { editing.setSource($0, documentID: document.id, cell: cell.id) }),
                                    label: "Edit cell \(cell.id + 1)", enabled: !editing.isBusy(document.id)
                                )
                                .frame(
                                    height: min(
                                        800, max(100, CGFloat(cell.source.components(separatedBy: "\n").count + 2) * 18)
                                    )
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }.id(cell.id)
                        }
                    }.padding(28).frame(maxWidth: 1000).frame(maxWidth: .infinity)
                }
            } else {
                StudySourceEditor(
                    text: Binding(
                        get: { editing.drafts[document.id]?.source ?? "" },
                        set: { editing.setSource($0, documentID: document.id) }), label: "Edit \(document.title)",
                    enabled: !editing.isBusy(document.id)
                ).padding(16)
            }
        }
    }
}
