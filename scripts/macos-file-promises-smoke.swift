@preconcurrency import AppKit
import SwiftUI
import Foundation

final class LivePromiseFixture: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { "Promised parameters.m" }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping ((any Error)?) -> Void) {
        do { try Data("Kp = 42;\nKi = 7;\n".utf8).write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { OperationQueue() }
}
@MainActor
final class DragSourceView: NSView, NSDraggingSource {
    let fixture = LivePromiseFixture()
    var started = false
    var ended = false
    override func draw(_ rect: NSRect) {
        NSColor.systemOrange.setFill(); bounds.fill()
        ("DRAG TEST FILE" as NSString).draw(at: NSPoint(x: 20, y: 50), withAttributes: [.foregroundColor: NSColor.black])
    }
    override func mouseDown(with event: NSEvent) {
        started = true
        let provider = NSFilePromiseProvider(fileType: "public.plain-text", delegate: fixture)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!
        item.setDraggingFrame(NSRect(x: 20, y: 35, width: 40, height: 40), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { ended = true }
}
@MainActor
final class LiveResult { var done = false; var failure: String?; var content: String?; var count = 0; var accepted = false }

@main
struct LiveSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let temporaryFile = FileManager.default.temporaryDirectory.appendingPathComponent("Launcher file \(UUID().uuidString).txt")
        try Data("launcher fixture".utf8).write(to: temporaryFile)
        defer { try? FileManager.default.removeItem(at: temporaryFile) }
        board.setString(temporaryFile.path, forType: .string)
        guard !AttachmentDropReader.canRead(board),
              AttachmentDropReader.fileURLs(from: board, allowPathStrings: true) == [temporaryFile] else {
            fatalError("Plain path must only resolve during an actual drop")
        }
        board.clearContents()
        board.setString(temporaryFile.path + ".missing", forType: .string)
        guard !AttachmentDropReader.canRead(board, allowPathStrings: true) else { fatalError("Nonexistent path accepted") }
        board.clearContents()
        board.setString("Explain " + temporaryFile.path, forType: .string)
        guard !AttachmentDropReader.canRead(board, allowPathStrings: true) else { fatalError("Prose accepted as a file") }
        board.clearContents()
        board.setString("~/", forType: .string)
        guard AttachmentDropReader.fileURLs(from: board, allowPathStrings: true).first?.path == NSHomeDirectory() else {
            fatalError("Home-relative launcher path not resolved")
        }
        board.clearContents()
        let copiedDelegate = LivePromiseFixture()
        board.writeObjects([NSFilePromiseProvider(fileType: "public.plain-text", delegate: copiedDelegate)])
        guard AttachmentDropReader.canRead(board), !AttachmentDropReader.receivePromises(from: board,
            receiving: { _ in fatalError("Paste invoked a drop-only API") },
            receive: { _, _ in fatalError("Paste invoked a drop-only API") }) else { fatalError("Promise paste guard failed") }
        withExtendedLifetime(copiedDelegate) {}
        NSApp.setActivationPolicy(.regular)
        let frame = NSRect(x: 150, y: 250, width: 680, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Scholia native file-promise verification"
        window.isReleasedWhenClosed = false
        window.level = .floating
        let source = DragSourceView(frame: NSRect(x: 20, y: 40, width: 200, height: 140))
        let output = LiveResult()
        let target = AttachmentDropHostingView(rootView: Text("DROP TEST ATTACHMENT HERE").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.blue.opacity(0.2)))
        target.frame = NSRect(x: 320, y: 40, width: 320, height: 140)
        target.onDropAttachment = { board in
            output.accepted = true
            return AttachmentDropReader.receivePromises(from: board, acceptingDrop: true, receiving: { output.count += $0 }, receive: { url, failure in
                output.failure = failure
                if let url {
                    output.content = try? String(contentsOf: url, encoding: .utf8)
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                }
                output.done = true
            })
        }
        window.contentView!.addSubview(source); window.contentView!.addSubview(target)
        window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        let screenHeight = NSScreen.screens[0].frame.height
        func point(_ view: NSView) -> CGPoint {
            let p = window.convertPoint(toScreen: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
            return CGPoint(x: p.x, y: screenHeight - p.y)
        }
        let start = point(source), end = point(target)
        print("PostEvent access: \(CGPreflightPostEventAccess())")
        DispatchQueue.global(qos: .userInitiated).async {
            func post(_ type: CGEventType, _ point: CGPoint) {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            Thread.sleep(forTimeInterval: 1.0)
            post(.mouseMoved, start)
            post(.leftMouseDown, start)
            for step in 1...16 {
                Thread.sleep(forTimeInterval: 0.05)
                let t = Double(step) / 16
                post(.leftMouseDragged, CGPoint(x: start.x + (end.x-start.x)*t, y: start.y + (end.y-start.y)*t))
            }
            Thread.sleep(forTimeInterval: 0.15)
            post(.leftMouseUp, end)
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            MainActor.assumeIsolated {
                if output.done { timer.invalidate(); NSApp.stop(nil) }
            }
        }
        Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.stop(nil) }
        }
        NSApp.run()
        print("Drag state: sourceStarted=\(source.started) sourceEnded=\(source.ended) targetAccepted=\(output.accepted) received=\(output.done) count=\(output.count)")
        guard output.done, output.failure == nil, output.content == "Kp = 42;\nKi = 7;\n", output.count == 1 else {
            print("FAILED: \(output.failure ?? "Real drag did not complete")"); exit(1)
        }
        print("PASS: real native drag lifecycle from NSFilePromiseProvider through production drop host and receiver delivers exact file contents")
    }
}
