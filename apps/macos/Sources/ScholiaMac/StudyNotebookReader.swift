import SwiftUI

/// A notebook is one reading surface. Cells remain separately addressable for
/// search, citations and the tutor's current context without paginating the UI.
struct StudyNotebookReader: View {
    @ObservedObject var workspace: StudyWorkspaceModel
    let document: StudyDocument
    let cells: [StudyPage]
    @Environment(\.colorScheme) private var colorScheme
    @State private var readingCell = 1
    @State private var tracking = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cells, id: \.number) { cell in
                        VStack(alignment: .leading, spacing: 18) {
                            RichMarkdownView(
                                source: cell.text,
                                registerSelectionView: {
                                    $0.identifier = NSUserInterfaceItemIdentifier("ScholiaStudyDocument")
                                }, onOpenLink: workspace.openCourseLink)
                            ForEach(cell.images ?? [], id: \.self) { name in
                                if let image = NSImage(
                                    contentsOf: workspace.store.directory(for: document.id).appendingPathComponent(name)
                                ) {
                                    Image(nsImage: image).resizable().scaledToFit().accessibilityLabel(
                                        "Saved output from cell \(cell.number)")
                                    Button("Ask about this output") {
                                        readingCell = cell.number
                                        workspace.setPage(cell.number)
                                        workspace.attachImage(image)
                                    }.controlSize(.small)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(30)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: NotebookCellFrames.self,
                                    value: [cell.number: geometry.frame(in: .named("notebook-scroll"))])
                            }
                        )
                        .id(cell.number)
                        if cell.number != cells.last?.number { Divider().padding(.horizontal, 30) }
                    }
                }
                .frame(maxWidth: 920, alignment: .leading)
                .background(StudyPalette.paper(colorScheme == .dark), in: RoundedRectangle(cornerRadius: 8))
                .padding(28)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "notebook-scroll")
            .onAppear {
                readingCell = workspace.currentPage
                DispatchQueue.main.async {
                    proxy.scrollTo(readingCell, anchor: .top)
                    tracking = true
                }
            }
            .onPreferenceChange(NotebookCellFrames.self) { frames in
                guard tracking,
                    let cell = frames.filter({ $0.value.maxY > 30 })
                        .min(by: { $0.value.minY < $1.value.minY })?.key
                else { return }
                readingCell = cell
                if workspace.currentPage != cell { workspace.setPage(cell) }
            }
            .onChange(of: workspace.currentPage) { _, cell in
                if tracking, cell != readingCell {
                    readingCell = cell
                    proxy.scrollTo(cell, anchor: .top)
                }
            }
            .onDisappear { tracking = false }
        }
    }
}

private struct NotebookCellFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
