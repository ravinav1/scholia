@preconcurrency import AppKit
import CoreGraphics
import Foundation

enum RegionCaptureError: LocalizedError {
    case permissionRequired
    case unavailable
    case regionTooSmall
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            "Allow Scholia in System Settings → Privacy & Security → Screen & System Audio Recording, then try again."
        case .unavailable:
            "Scholia could not capture the display."
        case .regionTooSmall:
            "Drag across a larger region to capture it."
        case .encodingFailed:
            "Scholia could not prepare the captured image."
        }
    }
}

@MainActor
final class RegionCaptureController {
    private struct Snapshot {
        var screen: NSScreen
        var image: CGImage
    }

    private var windows: [NSWindow] = []
    private var snapshots: [ObjectIdentifier: Snapshot] = [:]
    private var completion: ((Result<CapturedContent, Error>) -> Void)?

    var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func begin(completion: @escaping (Result<CapturedContent, Error>) -> Void) {
        cancel()
        guard CGPreflightScreenCaptureAccess() else {
            completion(.failure(RegionCaptureError.permissionRequired))
            return
        }

        var nextSnapshots: [ObjectIdentifier: Snapshot] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let image = CGDisplayCreateImage(CGDirectDisplayID(number.uint32Value)) else { continue }
            nextSnapshots[ObjectIdentifier(screen)] = Snapshot(screen: screen, image: image)
        }
        guard !nextSnapshots.isEmpty else {
            completion(.failure(RegionCaptureError.unavailable))
            return
        }

        self.completion = completion
        snapshots = nextSnapshots
        NSCursor.crosshair.push()
        windows = nextSnapshots.values.map { snapshot in
            let view = RegionSelectionView(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))
            view.onSelection = { [weak self, weak screen = snapshot.screen] rect in
                guard let self, let screen else { return }
                self.finish(screen: screen, localRect: rect)
            }
            view.onCancel = { [weak self] in self?.cancel() }
            let window = CaptureOverlayWindow(
                contentRect: snapshot.screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: snapshot.screen
            )
            window.setFrame(snapshot.screen.frame, display: true)
            window.contentView = view
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.orderFrontRegardless()
            return window
        }
        windows.first?.makeKey()
    }

    func cancel() {
        guard !windows.isEmpty || completion != nil else { return }
        dismissWindows()
        completion = nil
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func finish(screen: NSScreen, localRect: CGRect) {
        guard localRect.width >= 8, localRect.height >= 8 else {
            let callback = completion
            dismissWindows()
            completion = nil
            callback?(.failure(RegionCaptureError.regionTooSmall))
            return
        }
        guard let snapshot = snapshots[ObjectIdentifier(screen)] else {
            let callback = completion
            dismissWindows()
            completion = nil
            callback?(.failure(RegionCaptureError.unavailable))
            return
        }

        let image = snapshot.image
        let scaleX = CGFloat(image.width) / screen.frame.width
        let scaleY = CGFloat(image.height) / screen.frame.height
        var pixelRect = CGRect(
            x: localRect.minX * scaleX,
            y: (screen.frame.height - localRect.maxY) * scaleY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        ).integral
        pixelRect = pixelRect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let callback = completion
        dismissWindows()
        completion = nil
        guard let cropped = image.cropping(to: pixelRect),
              let data = ImageEncoding.jpegData(from: cropped, maximumDimension: 1_800) else {
            callback?(.failure(RegionCaptureError.encodingFailed))
            return
        }
        callback?(.success(CapturedContent(
            kind: .image,
            imageData: data,
            imageMimeType: "image/jpeg",
            applicationName: "Screen capture",
            selectionBounds: CGRect(
                x: screen.frame.minX + localRect.minX,
                y: screen.frame.minY + localRect.minY,
                width: localRect.width,
                height: localRect.height
            )
        )))
    }

    private func dismissWindows() {
        for window in windows { window.orderOut(nil) }
        if !windows.isEmpty { NSCursor.pop() }
        windows.removeAll()
        snapshots.removeAll()
    }

}

@MainActor
private final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class RegionSelectionView: NSView {
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    private var startPoint: NSPoint?
    private var selection = CGRect.zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(startPoint.x, current.x),
            y: min(startPoint.y, current.y),
            width: abs(current.x - startPoint.x),
            height: abs(current.y - startPoint.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        onSelection?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.28).setFill()
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd
        shade.fill()

        if !selection.isEmpty {
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(roundedRect: selection.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            border.lineWidth = 1.5
            border.stroke()
        }

        let text = "Drag to explain a region  ·  Esc to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let labelRect = CGRect(
            x: bounds.midX - size.width / 2 - 12,
            y: bounds.maxY - size.height - 38,
            width: size.width + 24,
            height: size.height + 12
        )
        NSColor.black.withAlphaComponent(0.68).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: labelRect.minX + 12, y: labelRect.minY + 6), withAttributes: attributes)
    }
}
