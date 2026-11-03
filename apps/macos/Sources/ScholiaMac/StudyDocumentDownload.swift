import Foundation

extension StudyDocument {
    /// The storage filename is an implementation detail, not the name of a saved copy.
    func downloadFileName(in course: StudyCourse? = nil) -> String {
        func clean(_ value: String) -> String {
            value.replacingOccurrences(of: #"[\x00-\x1F\x7F/\\:*?"<>|]+"#, with: "-", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        }
        func basename(_ value: String?) -> String {
            clean(((value ?? "").replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
        }
        func isStorageName(_ name: String) -> Bool {
            name.range(of: #"^original(?:\.[^.]+)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
        }
        let reference = sourceKey.flatMap { key in course?.materials.first { $0.id == key } }
        let sourceName = [originalFileName, reference?.fileName, fileName].map(basename)
            .first { !$0.isEmpty && !isStorageName($0) }
        var name: String
        if let sourceName {
            name = sourceName
        } else {
            let label = clean(course?.code ?? "")
            let courseName = label.isEmpty ? clean(course?.name ?? "") : label
            let title = clean(title)
            name = [courseName, title.isEmpty || isStorageName(title) ? "Document" : title]
                .filter { !$0.isEmpty }.joined(separator: " - ")
        }
        // Image imports are converted to JPEG, so use the saved format's extension.
        let suffix = kind == .pdf ? "pdf" : (basename(fileName) as NSString).pathExtension
        if !suffix.isEmpty && (sourceName == nil || kind == .pdf || kind == .image),
            !name.lowercased().hasSuffix("." + suffix.lowercased()) {
            if kind == .image && sourceName != nil { name = (name as NSString).deletingPathExtension }
            name += "." + suffix
        }
        return name
    }
}
