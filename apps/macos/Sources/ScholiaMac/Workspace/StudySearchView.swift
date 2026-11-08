import SwiftUI

struct StudySearchView: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    var allWorkspaces = true
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var scope = ""
    @State private var mode = "files"
    @State private var response: StudySearchResponse?
    @State private var searching = false
    @State private var error: String?
    @State private var selectedHitID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEEDLE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                    Text("Find it in your library").font(.system(size: 25, design: .serif))
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            StudyQuickSearchField(text: $query, placeholder: mode == "semantic" ? "Describe what you want to find…" : "Try TTK4100 kybintro kompendium",
                identifier: "workspace-search-query", onMove: moveSelection,
                onSubmit: {
                    if let hit = response?.results.first(where: { $0.id == selectedHitID }) ?? response?.results.first { open(hit) }
                }, onCancel: { dismiss() }).frame(height: 32)
            HStack {
                Picker("Search in", selection: $scope) {
                    Text("All workspaces").tag("")
                    ForEach(workspace.library.courses) { course in
                        Text(course.code.isEmpty ? course.name : "\(course.code) · \(course.name)").tag(course.id.uuidString)
                    }
                }
                Picker("Look for", selection: $mode) {
                    Text("Names & contents").tag("all")
                    Text("File names").tag("files")
                    Text("Contents").tag("content")
                    Text("Semantic · by meaning").tag("semantic")
                }.frame(width: 230)
            }.font(.caption)
            if searching {
                HStack { ProgressView().controlSize(.small); Text("Searching… Preparing new files on the first search.") }
                    .font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let response {
                Text((mode == "semantic" ? "Top \(response.results.count) related files" : "\(response.total) matching files") + " · \(Int(response.totalMs)) ms" + (response.strategy == "names" ? " · \(response.coverage["files", default: 0]) file names searched" : " · \(response.coverage["contentFiles", default: 0]) files have searchable text"))
                    .font(.caption).foregroundStyle(.secondary)
                if let semantic = response.semantic {
                    HStack {
                        if semantic.preparing { ProgressView().controlSize(.small) }
                        Text(semantic.description)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if response.coverage["remoteFiles", default: 0] > 0 || response.coverage["unavailableFiles", default: 0] > 0 {
                    Text("Cloud materials are searchable by name. Download them to search inside. Saved files without readable text are searchable by name only.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if response.total > response.results.count {
                    Text("Showing the first \(response.results.count) files. Add another term to narrow the results.").font(.caption)
                }
            } else { Text("Search one workspace or your entire library.").font(.caption).foregroundStyle(.secondary) }
            ScrollViewReader { proxy in
              ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(response?.results ?? []) { hit in
                        Button { open(hit) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(hit.title).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Text(hit.approximate == true ? "Similar name" : hit.page > 0 ? "\(hit.kind == "notebook" ? "Cell" : ["code", "office"].contains(hit.kind) ? "Section" : "Page") \(hit.page)" : hit.documentID == nil ? "Cloud material" : "File name")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(hit.courseName).font(.caption).foregroundStyle(.secondary)
                                Text(hit.snippet).font(.system(size: 12)).lineLimit(4)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .background(selectedHitID == hit.id ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).id(hit.id)
                            .accessibilityIdentifier("workspace-search-hit-\(hit.id)")
                            .accessibilityAddTraits(selectedHitID == hit.id ? .isSelected : [])
                    }
                }
              }.frame(maxHeight: .infinity)
              .onChange(of: selectedHitID) { _, value in if let value { proxy.scrollTo(value) } }
            }
            Text(mode == "semantic" ? "Find related ideas in your own words. Results are ranked by meaning. Files are prepared once in the background; text stays on this Mac." : "Find files by title, name, or course code. File names tolerate a small typo. Contents search matches literal words on the same page.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(26).frame(width: 710, height: 610)
            .onAppear { scope = allWorkspaces || workspace.isShowingLibrary ? "" : workspace.course?.id.uuidString ?? "" }
            .task(id: [query, scope, mode]) {
                response = nil; error = nil; selectedHitID = nil
                guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { searching = false; return }
                searching = true
                do {
                    try await Task.sleep(for: .milliseconds(35))
                    repeat {
                        let result = try await workspace.fileSearch.search(courses: workspace.library.courses,
                            store: workspace.store, query: query, courseID: scope, mode: mode)
                        try Task.checkCancellation()
                        response = result; searching = false
                        if !result.results.contains(where: { $0.id == selectedHitID }) { selectedHitID = result.results.first?.id }
                        guard result.semantic?.preparing == true else { break }
                        try await Task.sleep(for: .milliseconds(700))
                    } while !Task.isCancelled
                } catch is CancellationError { }
                catch { if !Task.isCancelled { self.error = error.localizedDescription; searching = false } }
            }
    }

    private func moveSelection(_ delta: Int) {
        guard let results = response?.results, !results.isEmpty else { return }
        let index = results.firstIndex { $0.id == selectedHitID } ?? 0
        selectedHitID = results[min(max(0, index + delta), results.count - 1)].id
    }

    private func open(_ hit: StudySearchHit) {
        guard let courseID = UUID(uuidString: hit.courseID),
              let course = workspace.library.courses.first(where: { $0.id == courseID }) else { return }
        if let id = hit.documentID.flatMap(UUID.init(uuidString:)), course.documents.contains(where: { $0.id == id }) {
            workspace.openReading(id, courseID: courseID, page: max(1, hit.page))
        } else if let material = course.materials.first(where: { $0.id == hit.materialID }) {
            if material.kind == .assignments { workspace.openAssignment(material, courseID: courseID) }
            else { workspace.openCanvasMaterial(material, courseID: courseID) }
        }
        dismiss()
    }
}
