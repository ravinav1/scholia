import AppKit
import SwiftUI

struct ChatAttachmentInspection: Identifiable {
    var attachment: MessageAttachment
    var member: String?
    var id: String { attachment.id.uuidString + ":" + (member ?? "") }

    static func excerpt(_ text: String, member: String?) -> String {
        var text = text
        if let member {
            let marker = "--- File: \(member) ["
            guard let start = text.range(of: marker) else {
                return "This member is listed in the saved attachment, but its extracted contents are unavailable."
            }
            let remaining = text[start.lowerBound...]
            let end = remaining.range(of: "\n--- File:")?.lowerBound ?? remaining.endIndex
            text = String(remaining[..<end])
        }
        let bounded = TextInputPolicy.boundedResult(text, maximumUTF16Units: 48_000)
        return bounded.value + (bounded.wasTruncated ? "\n\n[Preview shortened. The complete saved extraction remains available to chat.]" : "")
    }
}

struct ChatAttachmentInspector: View {
    let inspection: ChatAttachmentInspection
    @Environment(\.dismiss) private var dismiss
    @State private var excerpt: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(inspection.attachment.fileName).font(.headline)
                    if let member = inspection.member { Text(member).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(inspection.attachment.readingDetailsText).font(.caption).foregroundStyle(.secondary)
                .lineLimit(8).textSelection(.enabled)
            if let path = inspection.attachment.sourcePath {
                Button("Show original in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }.disabled(!FileManager.default.fileExists(atPath: path))
            }
            Divider()
            Text("Saved attachment evidence").font(.subheadline.weight(.semibold))
            if let excerpt {
                ScrollView {
                    Text(excerpt).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { ProgressView("Loading saved extraction…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.padding(22).frame(width: 680, height: 560)
            .task(id: inspection.id) {
                let attachment = inspection.attachment, member = inspection.member
                let job = Task.detached(priority: .userInitiated) {
                    do { return ChatAttachmentInspection.excerpt(try AttachmentTextCorpusStore.text(for: attachment), member: member) }
                    catch { return "Saved extraction unavailable: \(error.localizedDescription)" }
                }
                let loaded = await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
                if !Task.isCancelled { excerpt = loaded }
            }
    }
}
