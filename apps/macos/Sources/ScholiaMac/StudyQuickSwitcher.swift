@preconcurrency import AppKit
import SwiftUI

enum StudyQuickAction: Hashable {
    case course(UUID), search, searchAll, dashboard, assignments, exams, review, materials, newChat, addDocuments, create
}

private struct StudyQuickEntry: Identifiable {
    let action: StudyQuickAction
    let title: String
    let detail: String
    let icon: String
    var keywords = ""
    var isWorkspace = false
    var id: StudyQuickAction { action }
}

struct StudyQuickSwitcher: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var onSelect: (StudyQuickAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var selected: StudyQuickAction?

    private var entries: [StudyQuickEntry] {
        let commandsOnly = query.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        let text = commandsOnly ? String(query.trimmingCharacters(in: .whitespaces).dropFirst()) : query
        let terms = text.split(whereSeparator: \.isWhitespace).map(String.init)
        func matches(_ entry: StudyQuickEntry) -> Bool {
            terms.allSatisfy { (entry.title + " " + entry.detail + " " + entry.keywords)
                .range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        func rank(_ entry: StudyQuickEntry) -> Int {
            terms.allSatisfy { entry.title.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil } ? 0 : 1
        }
        let activeCourse = workspace.isShowingLibrary ? nil : workspace.course
        let courses = workspace.library.courses.sorted {
            let a = $0.id == activeCourse?.id, b = $1.id == activeCourse?.id
            if a != b { return !a }
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }.map { course in
            StudyQuickEntry(action: .course(course.id), title: course.displayName,
                detail: [course.code, course.term ?? "", course.id == activeCourse?.id ? "Current workspace" : "Open workspace"]
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                icon: course.isFavorite ? "star.fill" : "books.vertical", isWorkspace: true)
        }.filter(matches)
        var actions: [StudyQuickEntry] = [
            .init(action: .search, title: "Search coursework", detail: activeCourse.map { "Files and contents in \($0.code.isEmpty ? $0.displayName : $0.code)" } ?? "Files and contents in all workspaces", icon: "magnifyingglass", keywords: "find readings materials notes assignments"),
            .init(action: .searchAll, title: "Search all coursework", detail: "Files and contents across your library", icon: "magnifyingglass", keywords: "find readings materials notes assignments"),
            .init(action: .dashboard, title: "Go to dashboard", detail: "Your workspaces and upcoming work", icon: "square.grid.2x2", keywords: "home courses library"),
            .init(action: .assignments, title: "Go to assignments", detail: "Upcoming and completed coursework", icon: "checklist", keywords: "homework deadlines tasks"),
            .init(action: .exams, title: "Go to exam dates", detail: "Exam schedule and study planning", icon: "calendar", keywords: "calendar planner"),
            .init(action: .review, title: "Review due", detail: "Practice questions ready to revisit", icon: "arrow.clockwise", keywords: "flashcards revision study")
        ]
        if let course = activeCourse {
            actions.append(.init(action: .materials, title: "Browse course materials", detail: course.displayName,
                icon: "doc.on.doc", keywords: "readings files coursework"))
            if !workspace.isStreaming {
                actions.append(.init(action: .newChat, title: "New chat", detail: "Start a conversation in this workspace", icon: "bubble.left", keywords: "tutor ask question conversation"))
            }
            if !workspace.isImporting {
                actions.append(.init(action: .addDocuments, title: "Add documents", detail: "Import readings into this workspace", icon: "plus", keywords: "upload files pdf"))
            }
        }
        actions.append(.init(action: .create, title: "New workspace", detail: "Create a space for a course", icon: "plus", keywords: "add course"))
        return (commandsOnly ? [] : terms.isEmpty ? Array(courses.prefix(6)) : courses)
            + actions.filter(matches).sorted { rank($0) < rank($1) }
    }

    var body: some View {
        let results = entries
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("QUICK JUMP").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Text("Switch workspace or take an action").font(.system(size: 24, design: .serif))
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            StudyQuickSearchField(text: $query, placeholder: "Type a workspace, course code, or action…",
                identifier: "workspace-shortcuts-query", onMove: moveSelection,
                onSubmit: openSelected, onCancel: { dismiss() }).frame(height: 32)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            if index == 0 || results[index - 1].isWorkspace != entry.isWorkspace {
                                Text(entry.isWorkspace
                                    ? "WORKSPACES\(query.isEmpty && workspace.library.courses.count > 6 ? " · type to find any workspace" : "")"
                                    : "QUICK ACTIONS")
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                    .padding(.top, 10).padding(.horizontal, 12).padding(.bottom, 4)
                            }
                            Button { onSelect(entry.action) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: entry.icon).foregroundStyle(Color.accentColor).frame(width: 24)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                                        Text(entry.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Text(entry.action == .search ? "⌘ K" : selected == entry.action ? "↵" : "")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background(selected == entry.action ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(entry.id)
                                .accessibilityAddTraits(selected == entry.action ? .isSelected : [])
                        }
                        if results.isEmpty {
                            Text("No matches. Try a course code or an action like “assignments”.")
                                .font(.callout).foregroundStyle(.secondary).padding(16)
                        }
                    }
                }
                .onChange(of: selected) { _, value in if let value { proxy.scrollTo(value) } }
            }
            HStack {
                Text("↑ ↓ move    ↵ open    esc close")
                Spacer()
                Text("Type > for actions")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(24).frame(width: 620, height: 580)
            .background(StudyPalette.paper(colorScheme == .dark))
            .tint(ScholiaVisualStyle.accentColor(for: colorScheme))
            .accentColor(ScholiaVisualStyle.accentColor(for: colorScheme))
            .onAppear { selected = results.first?.id }
            .onChange(of: query) { _, _ in selected = entries.first?.id }
    }

    private func moveSelection(_ delta: Int) {
        let results = entries
        guard !results.isEmpty else { selected = nil; return }
        let index = results.firstIndex { $0.id == selected } ?? 0
        selected = results[min(max(0, index + delta), results.count - 1)].id
    }
    private func openSelected() {
        if let entry = entries.first(where: { $0.id == selected }) ?? entries.first { onSelect(entry.action) }
    }
}

/// Keep text editing and IME behavior native while sending result-navigation keys
/// to the picker. A regular text field consumes these before SwiftUI onKeyPress.
struct StudyQuickSearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var identifier: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = FocusedSearchField()
        field.font = .systemFont(ofSize: 16)
        field.controlSize = .large
        field.delegate = context.coordinator
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.setAccessibilityIdentifier(identifier)
        if field.stringValue != text { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: StudyQuickSearchField
        init(_ parent: StudyQuickSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
    private final class FocusedSearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
