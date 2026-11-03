@preconcurrency import AppKit
import Foundation

@MainActor
extension StudyWorkspaceModel {
    func chooseDraftAttachment() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Add files or a project folder to this question. Scholia shows what it can read."
        let generation = attachmentDraftGeneration
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard response == .OK, let self, self.attachmentDraftGeneration == generation else { return }
                self.attachFiles(at: panel.urls)
            }
        }
    }

    func removeDraftAttachment(_ id: UUID) {
        draftAttachments.removeAll { $0.id == id }
        saveDraft()
    }

    /// Replaces only this draft's saved extraction. A failed or cancelled read
    /// leaves the existing evidence and question intact.
    func refreshDraftAttachment(_ id: UUID) {
        guard !isCurrentThreadStreaming, !isIngestingAttachment,
              let original = draftAttachments.first(where: { $0.id == id }),
              let path = original.sourcePath else { return }
        let generation = attachmentDraftGeneration
        let url = URL(fileURLWithPath: path)
        isIngestingAttachment = true
        attachmentStatus = "Reading all available content in \(original.fileName)…"
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            let worker = Task.detached(priority: .userInitiated) {
                Result { try MessageAttachmentIngestion.read(fileAt: url) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self.attachmentDraftGeneration == generation else { return }
            if let index = self.draftAttachments.firstIndex(where: { $0.id == id }) {
                switch result {
                case .success(var updated) where updated.effectiveReadStatus != .unreadable
                    && updated.readDetail?.localizedCaseInsensitiveContains("Full-text indexing failed") != true:
                    updated.id = id
                    updated.isEnabled = self.draftAttachments[index].isEnabled
                    self.draftAttachments[index] = updated
                    self.saveDraft()
                case .success(let unavailable):
                    self.error = "The saved attachment was kept. \(unavailable.readDetail ?? "The source could not be read again.")"
                case .failure(let failure):
                    self.error = "The saved attachment was kept. \(failure.localizedDescription)"
                }
            }
            self.attachmentTask = nil
            self.startAttachmentQueue()
        }
    }

    func attachFiles(at urls: [URL]) {
        guard course != nil else { error = "Open or create a workspace before adding files."; return }
        guard !isCurrentThreadStreaming else { error = "Wait for the response to finish before adding files."; return }
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        guard draftAttachments.count + attachmentQueuedURLs.count + files.count
                <= MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
            error = "Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) attachments can be added to a question. Add a project folder to keep its files together."
            return
        }
        attachmentQueuedURLs += files
        startAttachmentQueue()
    }

    private func startAttachmentQueue() {
        guard attachmentTask == nil else { return }
        guard !attachmentQueuedURLs.isEmpty else {
            isIngestingAttachment = attachmentPromiseCount > 0
            if !isIngestingAttachment { attachmentStatus = nil }
            return
        }
        isIngestingAttachment = true
        let generation = attachmentDraftGeneration
        attachmentTask = Task { [weak self] in
            guard let self else { return }
            while !self.attachmentQueuedURLs.isEmpty {
                guard !Task.isCancelled, self.attachmentDraftGeneration == generation else { return }
                let url = self.attachmentQueuedURLs.removeFirst()
                self.attachmentStatus = "Reading \(url.lastPathComponent)…"
                let worker = Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return Result { try MessageAttachmentIngestion.read(fileAt: url) }
                }
                let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.attachmentDraftGeneration == generation else { return }
                switch result {
                case .success(let attachment):
                    if self.draftAttachments.count < MessageAttachmentIngestion.maximumAttachmentsPerMessage {
                        self.draftAttachments.append(attachment)
                        self.saveDraft()
                    } else {
                        self.error = "\(url.lastPathComponent) was not added: the attachment limit has been reached."
                    }
                case .failure(let failure):
                    self.error = "\(url.lastPathComponent): \(failure.localizedDescription)"
                }
            }
            self.attachmentTask = nil
            self.isIngestingAttachment = self.attachmentPromiseCount > 0
            self.attachmentStatus = self.isIngestingAttachment ? "Receiving dropped files…" : nil
        }
    }

    func cancelAttachmentIngestion() {
        attachmentDraftGeneration = UUID()
        attachmentTask?.cancel()
        attachmentTask = nil
        attachmentQueuedURLs = []
        attachmentPromiseCount = 0
        isIngestingAttachment = false
        attachmentStatus = nil
    }

    @discardableResult
    func attachFromPasteboard(_ pasteboard: NSPasteboard = .general, acceptingDrop: Bool = false) -> Bool {
        guard AttachmentDropReader.canRead(pasteboard, allowPathStrings: acceptingDrop) else { return false }
        guard course != nil, !isCurrentThreadStreaming else {
            error = course == nil ? "Open or create a workspace before adding files."
                : "Wait for the response to finish before adding files."
            return true
        }
        let generation = attachmentDraftGeneration
        if acceptingDrop && AttachmentDropReader.receivePromises(from: pasteboard, acceptingDrop: true, receiving: { [weak self] count in
            guard let self else { return }
            self.attachmentPromiseCount += count
            self.isIngestingAttachment = true
            self.attachmentStatus = "Receiving dropped files…"
        }, receive: { [weak self] url, failure in
            guard let self, self.attachmentDraftGeneration == generation else { return }
            self.attachmentPromiseCount = max(0, self.attachmentPromiseCount - 1)
            if let failure { self.error = failure }
            if let url { self.attachFiles(at: [url]) }
            self.startAttachmentQueue()
        }) { return true }
        let urls = AttachmentDropReader.fileURLs(from: pasteboard, allowPathStrings: acceptingDrop)
        if !urls.isEmpty { attachFiles(at: urls); return true }
        if !acceptingDrop && pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            error = "This app supplied a drag-only attachment. Drag it into the chat, or save it and attach the file."
            return true
        }
        let data: Data
        let name: String
        if let pdf = pasteboard.data(forType: .pdf) {
            data = pdf
            name = "Pasted document.pdf"
        } else if let image = NSImage(pasteboard: pasteboard), let jpeg = ImageEncoding.jpegData(from: image) {
            data = jpeg
            name = "Pasted image.jpg"
        } else { return false }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Scholia/Received Attachments/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            attachFiles(at: [url])
        } catch { self.error = "The attachment could not be saved: \(error.localizedDescription)" }
        return true
    }
}
