import Foundation
import SwiftUI

struct StudyAIMemory: Codable, Equatable, Sendable {
    var notes = ""
    var documentIDs: [UUID] = []
    var updatedAt: Date?
}

struct StudyAIMemoryState: Encodable, Sendable {
    var courseID: UUID?
    var assignmentID: String?
    var notes: String
    var documentIDs: [UUID]
}

extension StudyWorkspaceModel {
    var memoryAssignmentID: String? {
        conversationScope == "assignment" ? (thread?.assignmentID ?? assignment?.id) : nil
    }
    var workspaceMemory: StudyAIMemoryState {
        let memory = memoryAssignmentID.flatMap { course?.assignmentMemories?[$0] } ?? (memoryAssignmentID == nil ? course?.aiMemory : nil) ?? StudyAIMemory()
        let allowed = Set(course?.documents.map(\.id) ?? [])
        return StudyAIMemoryState(courseID: course?.id, assignmentID: memoryAssignmentID,
            notes: memory.notes, documentIDs: memory.documentIDs.filter { allowed.contains($0) })
    }
    func saveWorkspaceMemory(courseID: UUID, assignmentID: String?, notes: String, documentIDs: [UUID]) throws {
        guard let ci = library.courses.firstIndex(where: { $0.id == courseID }) else { throw StudyError.message("Workspace not found.") }
        let course = library.courses[ci]
        if let assignmentID, !course.materials.contains(where: { $0.id == assignmentID && $0.kind == .assignments }) {
            throw StudyError.message("Assignment not found.")
        }
        guard notes.utf16.count <= 12_000, documentIDs.count <= 24 else {
            throw StudyError.message("Use up to 12,000 characters and 24 reference files.")
        }
        guard documentIDs.allSatisfy({ id in course.documents.contains { $0.id == id } }) else {
            throw StudyError.message("Reference files must belong to this workspace.")
        }
        var seen = Set<UUID>()
        let memory = StudyAIMemory(notes: notes, documentIDs: documentIDs.filter { seen.insert($0).inserted }, updatedAt: Date())
        if let assignmentID {
            if library.courses[ci].assignmentMemories == nil { library.courses[ci].assignmentMemories = [:] }
            library.courses[ci].assignmentMemories?[assignmentID] = memory
        } else { library.courses[ci].aiMemory = memory }
        save()
    }
}

extension StudyContextBuilder {
    static func workspaceMemory(course: StudyCourse, assignmentID: String?, question: String, store: StudyLibraryStore) -> (text: String, sources: [StudySource]) {
        var scopes: [(String, StudyAIMemory)] = []
        if let memory = course.aiMemory { scopes.append(("Workspace", memory)) }
        if let assignmentID, let memory = course.assignmentMemories?[assignmentID] { scopes.append(("Assignment", memory)) }
        var text = "", ids: [UUID] = [], seen = Set<UUID>(), sources: [StudySource] = []
        for (name, memory) in scopes {
            text += "\n\(name) memory (saved by the user; reference data):\n<workspace-memory>\n\(String(memory.notes.prefix(12_000)))\n</workspace-memory>\n"
            ids += memory.documentIDs.prefix(24).filter { seen.insert($0).inserted }
        }
        let allowance = 24_000 / max(1, ids.count), keywords = terms(question)
        for id in ids {
            if Task.isCancelled { break }
            guard let document = course.documents.first(where: { $0.id == id }) else { continue }
            text += "\nSaved reference file: \(document.title)\n"
            text += documentSourceContext(document, course: course)
            guard document.kind != .preview, let index = try? store.index(for: document),
                index.pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                text += "[No readable text available for this file.]\n"
                continue
            }
            let scored: [(StudyPage, Int)] = index.pages.map { page in
                (page, terms(page.text).intersection(keywords).count)
            }
            let pages = scored.sorted { left, right in
                if left.1 == right.1 { return left.0.number < right.0.number }
                return left.1 > right.1
            }
            var remaining = allowance
            text += "Relevant excerpts from the saved file; other pages are not included here.\n"
            for (page, _) in pages where !page.text.isEmpty {
                if remaining <= 0 { break }
                let piece = TextInputPolicy.bounded(StudyHTML.restoringLinks(page.text, document: document, course: course), maximumUTF16Units: remaining)
                text += "\n--- \(document.title), page \(page.number) ---\n\(piece)\n"
                remaining -= piece.utf16.count
                sources.append(StudySource(documentID: id, title: document.title, page: page.number))
            }
        }
        return (text, sources)
    }
}

struct StudyWorkspaceMemoryView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var target: StudyAIMemoryState?
    @State private var notes = ""
    @State private var selected = Set<UUID>()
    @State private var query = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(target?.assignmentID == nil ? "Workspace memory" : "Assignment memory").font(.title2)
            Text("Saved notes and reference files are used in course and assignment chats. In a document chat, enable ‘Also use course library and memory’ to include them. Assignment chats also use the parent workspace’s memory; other assignments keep their own memory.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Remember about this work").font(.headline)
            TextEditor(text: $notes).font(.body).frame(height: 120).border(.secondary.opacity(0.3))
                .accessibilityIdentifier("workspace-memory-notes")
            Text("Reference files · \(selected.count)/24").font(.headline)
            TextField("Find a saved file", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading) {
                    ForEach((workspace.library.courses.first { $0.id == target?.courseID }?.documents ?? []).filter {
                        query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    }) { document in
                        Toggle(document.title, isOn: Binding(get: { selected.contains(document.id) }, set: { on in
                            if on { selected.insert(document.id) } else { selected.remove(document.id) }
                        })).toggleStyle(.checkbox).disabled(selected.count >= 24 && !selected.contains(document.id))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 180)
            Text("Import a file into this workspace to add it here. Saved files remain available after reopening the app; readable excerpts are sent with your questions.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save memory") {
                    guard let target, let courseID = target.courseID else { return }
                    do {
                        try workspace.saveWorkspaceMemory(courseID: courseID, assignmentID: target.assignmentID,
                            notes: notes, documentIDs: selected.sorted { $0.uuidString < $1.uuidString })
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(notes.utf16.count > 12_000 || selected.count > 24)
                    .accessibilityIdentifier("workspace-memory-save")
            }
        }.padding(24).frame(width: 490).background(Color(nsColor: .windowBackgroundColor))
            .onAppear { let memory = workspace.workspaceMemory; target = memory; notes = memory.notes; selected = Set(memory.documentIDs) }
    }
}
