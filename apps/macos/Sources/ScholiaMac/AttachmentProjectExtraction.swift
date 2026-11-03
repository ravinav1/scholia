import Foundation

/// Project containers are read as data only. Nothing is extracted to disk,
/// executed, or fetched through an external relationship.
enum AttachmentProjectExtraction {
    static let maximumMembers = 2_000
    static let maximumArchiveDepth = 3
    static let maximumFolderDepth = 12

    static func archive(data: Data, fileName: String, mimeType: String, depth: Int) throws -> MessageAttachment {
        guard depth < maximumArchiveDepth else {
            return MessageAttachmentIngestion.unavailable(fileName: fileName, mimeType: mimeType, byteCount: data.count,
                detail: "Nested archive exceeds the three-level reading limit. Attach the relevant inner file separately.")
        }
        let archive = try StudyOfficeArchive(data: data)
        let names = archive.names.filter { !$0.hasSuffix("/") }.sorted(by: projectOrder)
        var collected = Collection(title: "Contents of \(fileName)")
        for name in names.prefix(maximumMembers) {
            try Task.checkCancellation()
            if collected.hasRoomForContent {
                do {
                    let member = try MessageAttachmentIngestion.read(data: archive.read(name),
                        fileName: name, mimeType: nil, archiveDepth: depth + 1)
                    try collected.append(member, named: name)
                } catch is CancellationError { throw CancellationError() }
                catch { collected.unreadable(name, reason: error.localizedDescription) }
            } else { collected.omit(name, reason: "Full-text extraction resource limit reached") }
        }
        if names.count > maximumMembers {
            collected.omissions.append("\(names.count - maximumMembers) additional archive members were not inspected.")
        }
        let ext = (fileName as NSString).pathExtension.lowercased()
        let isModel = ["slx", "slxp", "sltx"].contains(ext)
        let explanation: String
        if isModel {
            explanation = "Simulink package XML, blocks, connections, parameters, and readable embedded sources are included below. This is static file evidence, not a simulation. External model references, libraries, MATLAB workspace values, and protected/binary parts are unavailable unless separately attached. Ask for missing dependencies before deriving project-specific results."
        } else if ["mlx", "mlapp"].contains(ext) {
            explanation = "MATLAB package source/XML is included. Code was not executed. Saved graphical outputs and binary workspace data may be unavailable."
        } else {
            explanation = "Archive members are listed with their reading status. Only the included extracted text is available; binary members and unlisted contents must not be inferred."
        }
        return collected.attachment(fileName: fileName, mimeType: mimeType, byteCount: data.count,
            detail: explanation, forcePartial: isModel || ["mlx", "mlapp"].contains(ext))
    }

    static func folder(at root: URL) throws -> MessageAttachment {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        var omitted: [String] = []
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles], errorHandler: { url, error in
                omitted.append("\(url.lastPathComponent): folder could not be listed (\(error.localizedDescription))")
                return true
            }) else {
            throw AttachmentReadError.unreadable("This folder could not be listed.")
        }
        var files: [(URL, String, Int)] = []
        var stopped = false
        var visited = 0
        let prefix = root.standardizedFileURL.path + "/"
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited > maximumMembers * 10 {
                omitted.append("Folder traversal stopped at \(maximumMembers * 10) items; additional directories were not inspected.")
                break
            }
            let relative = String(url.standardizedFileURL.path.dropFirst(prefix.count))
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                omitted.append("\(relative): inaccessible")
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                omitted.append("\(relative): symbolic link not followed")
                continue
            }
            if relative.split(separator: "/").count > maximumFolderDepth {
                enumerator.skipDescendants()
                omitted.append("\(relative): deeper than \(maximumFolderDepth) folders")
                continue
            }
            if values.isRegularFile == true {
                files.append((url, relative, values.fileSize ?? 0))
                if files.count >= maximumMembers { stopped = true; break }
            }
        }
        var collected = Collection(title: "Project folder: \(root.lastPathComponent)")
        collected.omissions = omitted
        for (url, relative, _) in files.sorted(by: { projectOrder($0.1, $1.1) }) {
            try Task.checkCancellation()
            if collected.hasRoomForContent {
                do { try collected.append(try MessageAttachmentIngestion.read(fileAt: url), named: relative) }
                catch is CancellationError { throw CancellationError() }
                catch { collected.unreadable(relative, reason: error.localizedDescription) }
            } else { collected.omit(relative, reason: "Full-text extraction resource limit reached") }
        }
        if stopped { collected.omissions.append("Folder listing stopped at \(maximumMembers) files; more files may exist.") }
        var result = collected.attachment(fileName: root.lastPathComponent, mimeType: "inode/directory",
            byteCount: files.reduce(0) { $0 + $1.2 },
            detail: "Visible project files were read recursively. Hidden files, symbolic links, and folders deeper than \(maximumFolderDepth) levels are excluded. Individual limitations are listed below. No source code was executed.",
            forcePartial: true)
        result.sourcePath = root.path
        return result
    }

    private static func projectOrder(_ lhs: String, _ rhs: String) -> Bool {
        func rank(_ name: String) -> Int {
            let lower = name.lowercased()
            let ext = (name as NSString).pathExtension.lowercased()
            if lower.hasPrefix("simulink/systems/") || lower == "simulink/blockdiagram.xml" { return 0 }
            if ["slx", "mdl", "m", "ssc"].contains(ext) { return 1 }
            if lower.contains("stateflow") || lower.contains("configset") || lower.hasPrefix("matlab/") { return 2 }
            if ["md", "txt", "pdf", "docx"].contains(ext) { return 3 }
            if MessageAttachmentIngestion.textFileExtensions.contains(ext) { return 4 }
            return 5
        }
        let left = rank(lhs), right = rank(rhs)
        return left == right ? lhs.localizedStandardCompare(rhs) == .orderedAscending : left < right
    }

    private struct Collection {
        var title: String
        var manifest: [String] = []
        var contents: [String] = []
        var omissions: [String] = []
        var contentUnits = 0
        var successfulReads = 0
        var completeReads = 0
        var partialReads = 0
        var unavailableReads = 0
        var omittedReads = 0
        var partial = false
        // Reserve space for all member names/statuses. This is a real memory
        // resource ceiling for the complete corpus, never the request budget.
        private var maximumContentUnits: Int { AttachmentTextCorpusStore.maximumUTF16Units - 1_000_000 }
        var hasRoomForContent: Bool { contentUnits < maximumContentUnits }

        mutating func append(_ original: MessageAttachment, named name: String) throws {
            try Task.checkCancellation()
            let attachment = original.isImage ? try MessageAttachmentIngestion.projectImageText(original) : original
            let label = MessageAttachmentIngestion.sanitizedFileName(name)
            let detail = attachment.readDetail.map { " — \($0)" } ?? ""
            if attachment.effectiveReadStatus == .unreadable {
                unreadable(label, reason: attachment.readDetail ?? "Contents could not be decoded")
                return
            }
            let text = try AttachmentTextCorpusStore.text(for: attachment)
            let remaining = max(0, maximumContentUnits - contentUnits)
            let block = "--- File: \(label) [\(attachment.effectiveReadStatus.rawValue)]\(detail) ---\n\(text)"
            let bounded = TextInputPolicy.boundedResult(block, maximumUTF16Units: remaining)
            manifest.append("\(label) — \(bounded.wasTruncated ? "partial (resource limit)" : attachment.effectiveReadStatus.rawValue)")
            if !bounded.value.isEmpty { contents.append(bounded.value); successfulReads += 1 }
            contentUnits += bounded.value.utf16.count + 2
            if bounded.wasTruncated { omissions.append("\(label): the full-text extraction resource limit was reached; later text is not indexed.") }
            if bounded.wasTruncated || attachment.effectiveReadStatus == .partial { partialReads += 1 }
            else { completeReads += 1 }
            partial = partial || bounded.wasTruncated || attachment.effectiveReadStatus != .complete
        }

        mutating func unreadable(_ name: String, reason: String) {
            manifest.append("\(MessageAttachmentIngestion.sanitizedFileName(name)) — UNREADABLE: \(reason)")
            unavailableReads += 1
            partial = true
        }

        mutating func omit(_ name: String, reason: String) {
            manifest.append("\(MessageAttachmentIngestion.sanitizedFileName(name)) — NOT READ: \(reason)")
            omittedReads += 1
            partial = true
        }

        func attachment(fileName: String, mimeType: String, byteCount: Int, detail: String, forcePartial: Bool) -> MessageAttachment {
            let listing = TextInputPolicy.boundedResult(manifest.joined(separator: "\n"), maximumUTF16Units: 900_000)
            let notices = TextInputPolicy.boundedResult(omissions.joined(separator: "\n"), maximumUTF16Units: 90_000)
            var text = title + "\n\nFILE MANIFEST\n" + listing.value
            if listing.wasTruncated { text += "\n[Manifest truncated; additional entries are not listed.]" }
            if !notices.value.isEmpty { text += "\n\nLIMITATIONS\n" + notices.value }
            if notices.wasTruncated { text += "\n[Additional omissions are not listed.]" }
            text += "\n\nEXTRACTED CONTENT\n" + contents.joined(separator: "\n\n")
            let status: AttachmentReadStatus = successfulReads == 0 ? .partial
                : (partial || forcePartial || !omissions.isEmpty || listing.wasTruncated ? .partial : .complete)
            var coverageParts: [String] = []
            if contentUnits >= maximumContentUnits { coverageParts.append("Extraction resource limit reached") }
            if completeReads > 0 { coverageParts.append("\(completeReads) file\(completeReads == 1 ? "" : "s") fully read") }
            if partialReads > 0 { coverageParts.append("\(partialReads) partly read") }
            if unavailableReads > 0 { coverageParts.append("\(unavailableReads) unavailable") }
            if omittedReads > 0 { coverageParts.append("\(omittedReads) not read") }
            if !omissions.isEmpty { coverageParts.append("Additional limitations listed in the manifest") }
            let coverage = coverageParts.isEmpty ? "No readable file contents found" : coverageParts.joined(separator: " · ")
            return MessageAttachmentIngestion.boundedAttachment(fileName: fileName, mimeType: mimeType,
                byteCount: byteCount, text: text, status: status,
                detail: "\(coverage). \(detail)")
        }
    }
}
