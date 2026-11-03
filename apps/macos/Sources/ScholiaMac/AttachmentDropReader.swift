@preconcurrency import AppKit
import SwiftUI

/// Resolves the native representations used by Finder, Spotlight, Mail, and Photos.
/// File representations are handled before images so PDFs are never flattened.
@MainActor
enum AttachmentDropReader {
    static let legacyFiles = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        let files: [NSPasteboard.PasteboardType] = [.fileURL, .URL, legacyFiles, .string, .pdf, .png, .tiff]
        return files + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard, allowPathStrings: Bool = false) -> [URL] {
        func unique(_ values: [URL]) -> [URL] {
            var seen = Set<String>()
            return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
        }
        // A drag often contains several representations of the SAME item. A
        // launcher may put the containing folder in its plain-text description.
        // Prefer actual file URLs; never merge that fallback into the selection.
        var urls = (pasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).filter(\.isFileURL)
        if !urls.isEmpty { return unique(urls) }
        if let paths = pasteboard.propertyList(forType: legacyFiles) as? [String] {
            urls += paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        }
        if !urls.isEmpty { return unique(urls) }
        // Spotlight and several search utilities expose a URL as a string.
        // Only explicit file URLs are interpreted here; ordinary pasted prose stays text.
        for item in pasteboard.pasteboardItems ?? [] {
            for type in [NSPasteboard.PasteboardType.fileURL, .URL, .string] {
                guard let value = item.string(forType: type) else { continue }
                let resolved: [URL] = value.components(separatedBy: .newlines).compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased().hasPrefix("file://"), let url = URL(string: trimmed),
                       url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { return url }
                    // Only an actual drag can turn plain path text into an attachment.
                    // Check existence so ordinary dragged prose is never interpreted as a file.
                    if allowPathStrings, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") {
                        let path = (trimmed as NSString).expandingTildeInPath
                        if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
                    }
                    return nil
                }
                if !resolved.isEmpty {
                    urls += resolved
                    break
                }
            }
        }
        return unique(urls)
    }

    static func canRead(_ pasteboard: NSPasteboard, allowPathStrings: Bool = false) -> Bool {
        pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || !fileURLs(from: pasteboard, allowPathStrings: allowPathStrings).isEmpty
            || pasteboard.availableType(from: [.pdf, .png, .tiff]) != nil
    }

    /// Receives promised files into persistent app storage: their source paths remain
    /// available for subsequent scoped reads and saved conversations.
    /// Call only synchronously inside an AppKit drag acceptance callback; AppKit
    /// raises an Objective-C exception when file promises are received on paste.
    @discardableResult
    static func receivePromises(from pasteboard: NSPasteboard, acceptingDrop: Bool = false,
                                receiving: @escaping @MainActor (Int) -> Void,
                                receive: @escaping @MainActor (URL?, String?) -> Void) -> Bool {
        guard acceptingDrop else { return false }
        guard let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
              !promises.isEmpty else { return false }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scholia/Received Attachments/\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { receive(nil, "The dropped files could not be received: \(error.localizedDescription)"); return true }
        receiving(promises.reduce(0) { $0 + max(1, $1.fileNames.count) })
        let queue = OperationQueue()
        queue.name = "Scholia attachment file promises"
        queue.maxConcurrentOperationCount = 1
        for promise in promises {
            promise.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                let failure = error.map { "\(url.lastPathComponent): \($0.localizedDescription)" }
                Task { @MainActor in receive(failure == nil ? url : nil, failure) }
            }
        }
        return true
    }
}

/// An AppKit ancestor is needed because SwiftUI URL drops do not receive file
/// promises and an NSTextView otherwise inserts a file's path into the question.
struct AttachmentDropContainer<Content: View>: NSViewRepresentable {
    var onDrop: (NSPasteboard) -> Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> AttachmentDropHostingView<Content> {
        let view = AttachmentDropHostingView(rootView: content())
        view.onDropAttachment = onDrop
        return view
    }
    func updateNSView(_ view: AttachmentDropHostingView<Content>, context: Context) {
        view.rootView = content()
        view.onDropAttachment = onDrop
    }
}

@MainActor
final class AttachmentDropHostingView<Content: View>: NSHostingView<Content> {
    var onDropAttachment: ((NSPasteboard) -> Bool)?
    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(AttachmentDropReader.draggedTypes)
        wantsLayer = true
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepted = AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true)
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = accepted ? 2 : 0
        return accepted ? .copy : []
    }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { layer?.borderWidth = 0 }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { layer?.borderWidth = 0 }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        AttachmentDropReader.canRead(sender.draggingPasteboard, allowPathStrings: true)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        return onDropAttachment?(sender.draggingPasteboard) == true
    }
}
