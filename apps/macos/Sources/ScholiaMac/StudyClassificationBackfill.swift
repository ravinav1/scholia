import Foundation

extension StudyWorkspaceModel {
    /// Existing libraries use their already-saved indexes; no OCR or network jobs are queued at startup.
    /// Small batches keep both disk work and published library changes away from the first frame.
    func backfillClassifications() {
        classificationTask?.cancel()
        let pending = library.courses.flatMap { course in
            course.documents.filter { $0.classification?.version != StudyMaterialClassifier.version }.map { (course.id, $0) }
        }
        guard !pending.isEmpty else { return }
        let store = store
        classificationTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(500))
                for start in stride(from: 0, to: pending.count, by: 8) {
                    try Task.checkCancellation()
                    let batch = Array(pending[start..<min(start + 8, pending.count)])
                    let job = Task.detached(priority: .utility) {
                        var results: [(UUID, StudyDocument, StudyMaterialClassification)] = []
                        for (courseID, document) in batch {
                            try Task.checkCancellation()
                            guard let index = try? store.index(for: document) else { continue }
                            let analysis = StudyMaterialClassifier.analyze(title: document.title,
                                fileName: document.originalFileName ?? document.fileName, kind: document.kind, pages: index.pages)
                            results.append((courseID, document, analysis))
                        }
                        return results
                    }
                    let results = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                    try Task.checkCancellation()
                    guard let self else { return }
                    var changed = false
                    for (courseID, original, analysis) in results {
                        guard let ci = self.library.courses.firstIndex(where: { $0.id == courseID }),
                              let di = self.library.courses[ci].documents.firstIndex(where: { $0.id == original.id }),
                              self.library.courses[ci].documents[di].contentHash == original.contentHash,
                              self.library.courses[ci].documents[di].title == original.title,
                              self.library.courses[ci].documents[di].classification?.version != StudyMaterialClassifier.version else { continue }
                        self.library.courses[ci].documents[di].classification = analysis
                        changed = true
                    }
                    if changed { self.save() }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch { /* Cancellation never interrupts reading or changes the original files. */ }
        }
    }
}
