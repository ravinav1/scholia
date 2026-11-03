@preconcurrency import AVFoundation
@preconcurrency import AppKit
import Combine
import CoreImage
import Foundation
import Vision

enum PaperCameraDeviceKind: Equatable, Sendable {
    case builtIn, iPhone, external, deskView

    init(deviceType: AVCaptureDevice.DeviceType, isContinuityCamera: Bool) {
        if deviceType == .deskViewCamera { self = .deskView }
        else if isContinuityCamera { self = .iPhone }
        else if deviceType == .builtInWideAngleCamera { self = .builtIn }
        else { self = .external }
    }

    var recoveryInstructions: String {
        switch self {
        case .builtIn:
            "Open your Mac’s lid and close other camera apps, then reconnect."
        case .iPhone:
            "Lock and mount your iPhone, then reconnect. If it disappeared after Disconnect, plug it into your Mac and refresh cameras."
        case .external:
            "Check the camera’s cable and privacy cover, close other camera apps, then reconnect."
        case .deskView:
            "Check the camera providing Desk View, then refresh cameras and reconnect."
        }
    }
}

struct PaperCameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: PaperCameraDeviceKind

    init(id: String, name: String, kind: PaperCameraDeviceKind = .external) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

enum PaperCameraTiming {
    /// Continuity Camera may need time to establish its first video stream.
    /// Once frames arrive, detect an interrupted stream more promptly.
    static func isFrameDeliveryOverdue(startedAt: Date, lastSampleAt: Date?, now: Date) -> Bool {
        if let lastSampleAt { return now.timeIntervalSince(lastSampleAt) > 6 }
        return now.timeIntervalSince(startedAt) > 15
    }
}

struct PaperCameraSourceGeometry: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// Source format changes can reinterpret a normalized crop. The first frame
/// establishes a baseline; subsequent changes need an explicit crop review.
struct PaperCameraGeometryGate: Sendable {
    private(set) var geometry: PaperCameraSourceGeometry?
    private(set) var requiresReview = false

    @discardableResult
    mutating func observe(_ next: PaperCameraSourceGeometry) -> Bool {
        guard geometry != next else { return false }
        requiresReview = geometry != nil
        geometry = next
        return true
    }

    @discardableResult
    mutating func confirm(_ reviewed: PaperCameraSourceGeometry?) -> Bool {
        guard let reviewed, reviewed == geometry else { return false }
        requiresReview = false
        return true
    }
}

/// Only the student's selected region leaves the capture queue. No video is recorded.
struct PaperFrame: Identifiable, Sendable {
    let id: UUID
    let capturedAt: Date
    let jpeg: Data
    let width: Int
    let height: Int
    let fingerprint: [UInt8]
    let qualityIssue: String?
    let handDetected: Bool
}

@MainActor
final class PaperCamera: ObservableObject {
    @Published private(set) var devices: [PaperCameraDevice] = []
    @Published var selectedID = ""
    @Published private(set) var status = "Camera off"
    @Published private(set) var isRunning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var rotationDegrees = 0
    @Published private(set) var needsRegionReview = false
    @Published private(set) var sourceDimensions = ""
    @Published var region = CGRect(x: 0, y: 0, width: 1, height: 1) {
        didSet {
            regionRevision = UUID()
            needsRegionReview = false
            worker.setRegion(region, revision: regionRevision, confirming: sourceGeometryRevision)
        }
    }

    let captureSession: AVCaptureSession
    var onFrame: (@MainActor (PaperFrame) -> Void)?
    var onInterruption: (@MainActor () -> Void)?
    var onSourceGeometryChange: (@MainActor () -> Void)?

    private let worker: PaperCaptureWorker
    private var generation = UUID()
    private var regionRevision = UUID()
    private var sourceGeometryRevision: UInt64?
    private var observers: [NSObjectProtocol] = []

    init() {
        let worker = PaperCaptureWorker()
        self.worker = worker
        captureSession = worker.session
        worker.onFrame = { [weak self] generation, revision, geometryRevision, frame in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.generation == generation,
                      self.regionRevision == revision,
                      self.sourceGeometryRevision == geometryRevision else { return }
                self.onFrame?(frame)
            }
        }
        worker.onSourceGeometry = { [weak self] generation, revision, geometry, requiresReview in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      revision > (self.sourceGeometryRevision ?? 0) else { return }
                self.sourceGeometryRevision = revision
                self.sourceDimensions = "\(geometry.width) × \(geometry.height)"
                if requiresReview {
                    self.regionRevision = UUID()
                    self.needsRegionReview = true
                    self.onSourceGeometryChange?()
                }
            }
        }
        worker.onState = { [weak self] generation, running, message in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.isRunning = running
                self.isConnecting = false
                self.status = message
                if !running {
                    self.generation = UUID()
                    self.onInterruption?()
                }
                self.refreshDevices()
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDevices() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak worker] _ in
            // An asynchronous stop can be abandoned when the process exits.
            // Finish the capture queue's teardown, including Center Stage
            // restoration, before a normal application termination returns.
            worker?.stopBeforeTermination()
        })
        refreshDevices()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        worker.stop()
    }

    func refreshDevices() {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .builtInWideAngleCamera, .external, .deskViewCamera],
            mediaType: .video, position: .unspecified
        ).devices
        devices = discovered.map {
            PaperCameraDevice(id: $0.uniqueID, name: $0.localizedName,
                              kind: PaperCameraDeviceKind(deviceType: $0.deviceType,
                                                          isContinuityCamera: $0.isContinuityCamera))
        }
        if selectedID.isEmpty {
            // Desk View can also identify as a Continuity Camera, but its
            // virtual perspective should not be the default notebook source.
            selectedID = devices.first(where: { $0.kind == .iPhone })?.id
                ?? devices.first(where: { $0.kind == .builtIn || $0.kind == .external })?.id
                ?? devices.first?.id ?? ""
        }
    }

    /// Explicit user action is required for both initial connection and reconnection.
    func start() async {
        guard !isConnecting else { return }
        let requestGeneration = UUID()
        generation = requestGeneration
        isConnecting = true
        isRunning = false
        needsRegionReview = false
        sourceGeometryRevision = nil
        sourceDimensions = ""
        onInterruption?()
        worker.stop()
        status = "Waiting for camera permission…"
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if authorization == .notDetermined {
            allowed = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            allowed = authorization == .authorized
        }
        guard generation == requestGeneration else { return }
        guard allowed else {
            isConnecting = false
            status = "Camera permission is blocked. Allow Scholia in System Settings → Privacy & Security → Camera, then reconnect."
            return
        }
        refreshDevices()
        guard let selectedDevice = devices.first(where: { $0.id == selectedID }) else {
            isConnecting = false
            status = "Selected camera is unavailable. Refresh cameras and choose an available camera, then reconnect."
            return
        }
        status = "Connecting to \(selectedDevice.name)…"
        worker.start(selection: selectedDevice, generation: requestGeneration, region: region,
                     revision: regionRevision, rotationDegrees: rotationDegrees)
    }

    func rotateClockwise() { setRotation((rotationDegrees + 90) % 360) }
    func resetRotation() { setRotation(0) }

    func confirmRegionReview() {
        guard needsRegionReview else { return }
        regionRevision = UUID()
        needsRegionReview = false
        worker.setRegion(region, revision: regionRevision, confirming: sourceGeometryRevision)
    }

    func showCameraEffects() { AVCaptureDevice.showSystemUserInterface(.videoEffects) }

    private func setRotation(_ degrees: Int) {
        guard rotationDegrees != degrees else { return }
        rotationDegrees = degrees
        regionRevision = UUID()
        // Keep the selected native-sensor region unchanged. The preview maps
        // its rotated selection back to these same coordinates.
        worker.setRotation(degrees, revision: regionRevision)
    }

    func stop() {
        generation = UUID()
        isRunning = false
        isConnecting = false
        needsRegionReview = false
        sourceGeometryRevision = nil
        sourceDimensions = ""
        status = "Camera off"
        worker.stop()
        onInterruption?()
    }

    func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// AVFoundation configuration, sample delivery, Vision, and JPEG encoding share
/// one serial queue. Only immutable frames and status messages cross to the UI.
private final class PaperCaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onFrame: (@Sendable (UUID, UUID, UInt64, PaperFrame) -> Void)?
    var onState: (@Sendable (UUID, Bool, String) -> Void)?
    var onSourceGeometry: (@Sendable (UUID, UInt64, PaperCameraSourceGeometry, Bool) -> Void)?

    private let queue = DispatchQueue(label: "app.scholia.paper-camera", qos: .userInitiated)
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var generation = UUID()
    private var regionRevision = UUID()
    private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var rotationDegrees = 0
    private var geometryGate = PaperCameraGeometryGate()
    private var sourceGeometryRevision: UInt64 = 0
    private var active = false
    private var selectedID = ""
    private var selectedKind = PaperCameraDeviceKind.external
    private var activeOutput: AVCaptureVideoDataOutput?
    private var lastDelivery = Date.distantPast
    private var startedAt = Date.distantPast
    private var lastSample: Date?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var suspensionObservation: NSKeyValueObservation?
    private var previousCenterStage: (mode: AVCaptureDevice.CenterStageControlMode, enabled: Bool)?

    private func observeInterruptions(generation: UUID) {
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification,
                     AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] notification in
                // Copy only Sendable values out of the notification.
                let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
                let relevantSession = (notification.object as? AVCaptureSession) === self?.session
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                let diagnostic = error.map { "\($0.localizedDescription) (\($0.domain) \($0.code))" }
                self?.queue.async { [weak self] in
                    guard let self, self.active, self.generation == generation,
                          relevantSession || deviceID == self.selectedID else { return }
                    let reason = diagnostic.map { "Camera error: \($0)." } ?? "Camera interrupted."
                    self.interrupt("\(reason) \(self.selectedKind.recoveryInstructions) Your study session is still here.")
                }
            })
        }
    }

    deinit {
        watchdog?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setRegion(_ region: CGRect, revision: UUID, confirming geometryRevision: UInt64?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.region = region
            self.regionRevision = revision
            self.lastDelivery = .distantPast
            if geometryRevision == self.sourceGeometryRevision {
                self.geometryGate.confirm(self.geometryGate.geometry)
            }
        }
    }

    func setRotation(_ degrees: Int, revision: UUID) {
        queue.async { [weak self] in
            self?.rotationDegrees = degrees
            self?.regionRevision = revision
            self?.lastDelivery = .distantPast
        }
    }

    func start(selection: PaperCameraDevice, generation: UUID, region: CGRect, revision: UUID,
               rotationDegrees: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.generation = generation
            self.region = region
            self.regionRevision = revision
            self.rotationDegrees = rotationDegrees
            self.selectedID = selection.id
            self.selectedKind = selection.kind
            guard let device = AVCaptureDevice(uniqueID: selection.id), device.isConnected else {
                self.onState?(generation, false, "Camera disconnected before it could start. \(selection.kind.recoveryInstructions)")
                return
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                for old in self.session.inputs { self.session.removeInput(old) }
                for old in self.session.outputs { self.session.removeOutput(old) }
                // Start with the broadly supported preset. Checking 1080p on an
                // empty session does not validate the selected camera's support.
                self.session.sessionPreset = .high
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration()
                    self.onState?(generation, false, "Could not add \(selection.name) as a camera input. \(selection.kind.recoveryInstructions)")
                    return
                }
                self.session.addInput(input)
                guard self.session.canAddOutput(output) else {
                    self.session.removeInput(input)
                    self.session.commitConfiguration()
                    self.onState?(generation, false, "This camera cannot provide video frames. Choose another camera and reconnect.")
                    return
                }
                self.session.addOutput(output)
                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                }
                self.activeOutput = output
                output.setSampleBufferDelegate(self, queue: self.queue)
                if let connection = output.connection(with: .video) {
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = false
                    }
                    // Crop coordinates remain in the native sensor space.
                    // Rotate only the selected crop below, using the same
                    // explicit angle as the preview rather than horizon tracking.
                    if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                }
                self.session.commitConfiguration()
                if device.activeFormat.isCenterStageSupported || device.isCenterStageActive {
                    self.previousCenterStage = (AVCaptureDevice.centerStageControlMode, AVCaptureDevice.isCenterStageEnabled)
                    AVCaptureDevice.centerStageControlMode = .app
                    AVCaptureDevice.isCenterStageEnabled = false
                }
                self.lastDelivery = .distantPast
                self.lastSample = nil
                self.active = true
                self.observeInterruptions(generation: generation)
                self.suspensionObservation = device.observe(\.isSuspended, options: [.new]) { [weak self] device, _ in
                    guard device.isSuspended else { return }
                    self?.queue.async { [weak self] in
                        guard let self, self.active, self.generation == generation else { return }
                        let reason = self.selectedKind == .iPhone ? "iPhone camera paused or unlocked." : "Camera is paused or unavailable."
                        self.interrupt("\(reason) \(self.selectedKind.recoveryInstructions)")
                    }
                }
                self.session.startRunning()
                guard self.session.isRunning else {
                    // A runtime-error notification may have been queued while
                    // startRunning blocked. Let its diagnostic win over this fallback.
                    self.queue.async { [weak self] in
                        guard let self, self.active, self.generation == generation else { return }
                        self.interrupt("Camera could not start. \(selection.kind.recoveryInstructions)")
                    }
                    return
                }
                self.startedAt = Date()
                self.onState?(generation, true, "Live · \(device.localizedName)")
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 2, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self, self.active,
                          PaperCameraTiming.isFrameDeliveryOverdue(startedAt: self.startedAt,
                                                                  lastSampleAt: self.lastSample, now: Date()) else { return }
                    let reason = self.lastSample == nil ? "No images arrived from the camera." : "Camera stopped delivering images."
                    self.interrupt("\(reason) \(self.selectedKind.recoveryInstructions)")
                }
                self.watchdog = timer
                timer.resume()
            } catch {
                let error = error as NSError
                self.onState?(generation, false, "Could not open camera: \(error.localizedDescription) (\(error.domain) \(error.code)). \(selection.kind.recoveryInstructions)")
            }
        }
    }

    func stop() { queue.async { self.stopOnQueue() } }

    /// Called only by the main-queue application termination observer. Worker
    /// callbacks enqueue main-actor Tasks and never wait on the main queue.
    func stopBeforeTermination() { queue.sync { self.stopOnQueue() } }

    private func stopOnQueue() {
        active = false
        activeOutput = nil
        watchdog?.cancel()
        watchdog = nil
        suspensionObservation = nil
        geometryGate = PaperCameraGeometryGate()
        sourceGeometryRevision = 0
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if session.isRunning { session.stopRunning() }
        if let previousCenterStage {
            // Restore only while our own settings are still applied; respect a
            // later change made elsewhere instead of overwriting it.
            if AVCaptureDevice.centerStageControlMode == .app, !AVCaptureDevice.isCenterStageEnabled {
                AVCaptureDevice.isCenterStageEnabled = previousCenterStage.enabled
                AVCaptureDevice.centerStageControlMode = previousCenterStage.mode
            }
            self.previousCenterStage = nil
        }
    }

    private func interrupt(_ message: String) {
        stopOnQueue()
        onState?(generation, false, message)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard active, output === activeOutput else { return }
        let now = Date()
        lastSample = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let geometry = PaperCameraSourceGeometry(width: CVPixelBufferGetWidth(buffer),
                                                height: CVPixelBufferGetHeight(buffer))
        if geometryGate.observe(geometry) {
            sourceGeometryRevision += 1
            onSourceGeometry?(generation, sourceGeometryRevision, geometry, geometryGate.requiresReview)
        }
        // Preview stays live while model-bound images wait for crop review.
        guard !geometryGate.requiresReview else { return }
        // The preview continues at the camera's negotiated frame rate. This is
        // local inspection only; the tutor chooses a much slower send cadence.
        guard now.timeIntervalSince(lastDelivery) >= 0.5 else { return }
        lastDelivery = now
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: buffer)
            guard let cgImage = imageContext.createCGImage(image, from: image.extent),
                  let frame = PaperFrameProcessor.makeFrame(image: cgImage, region: region, capturedAt: now,
                                                           rotationDegrees: rotationDegrees) else { return }
            onFrame?(generation, regionRevision, sourceGeometryRevision, frame)
        }
    }
}


enum PaperFrameProcessor {
    static let fingerprintWidth = 256
    static let fingerprintHeight = 192
    private static let rotationContext = CIContext(options: [.cacheIntermediates: false])

    static func makeFrame(
        image: CGImage, region: CGRect, capturedAt: Date = Date(), detectHands: Bool = true,
        rotationDegrees: Int = 0
    ) -> PaperFrame? {
        guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite) else { return nil }
        let region = region.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { return nil }
        let pixels = CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                            width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral
        guard let nativeCrop = image.cropping(to: pixels),
              let cropped = rotated(nativeCrop, degrees: rotationDegrees),
              let jpeg = ImageEncoding.jpegData(from: cropped, maximumDimension: 1_920, quality: 0.85),
              let fingerprint = grayscale(cropped, width: fingerprintWidth, height: fingerprintHeight),
              let qualityPixels = grayscale(cropped, width: 256, height: 256) else { return nil }
        let scale = min(1, 1_920 / Double(max(cropped.width, cropped.height)))
        var issue = qualityIssue(pixels: qualityPixels, width: 256, height: 256,
                                 sourceWidth: cropped.width, sourceHeight: cropped.height)
        var handDetected = false
        if detectHands {
            let request = VNDetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            do {
                try VNImageRequestHandler(cgImage: cropped).perform([request])
                handDetected = (request.results ?? []).contains { observation in
                    guard let points = try? observation.recognizedPoints(.all) else { return false }
                    return points.values.filter { $0.confidence >= 0.35 }.count >= 4
                }
                if handDetected { issue = "A hand may cover the selected region. Move it aside for a clear capture." }
            } catch {
                // Fail closed: do not describe a frame as unobstructed when the
                // local detector was unavailable. Manual retry remains possible.
                issue = "Could not check whether the page is covered. Reconnect the camera and try again."
            }
        }
        return PaperFrame(id: UUID(), capturedAt: capturedAt, jpeg: jpeg,
                          width: max(1, Int((Double(cropped.width) * scale).rounded())),
                          height: max(1, Int((Double(cropped.height) * scale).rounded())),
                          fingerprint: fingerprint, qualityIssue: issue, handDetected: handDetected)
    }

    private static func rotated(_ image: CGImage, degrees: Int) -> CGImage? {
        let orientation: CGImagePropertyOrientation
        switch (degrees % 360 + 360) % 360 {
        case 0: return image
        case 90: orientation = .right
        case 180: orientation = .down
        case 270: orientation = .left
        default: return nil
        }
        let oriented = CIImage(cgImage: image).oriented(orientation)
        return rotationContext.createCGImage(oriented, from: oriented.extent)
    }

    static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? pixels : nil
    }

    /// Conservative heuristics, not a promise that every symbol is readable.
    /// The tutor must still ask about ambiguous handwriting.
    static func qualityIssue(pixels: [UInt8], width: Int, height: Int, sourceWidth: Int, sourceHeight: Int) -> String? {
        guard pixels.count == width * height, width > 2, height > 2 else { return "Could not inspect image quality." }
        if max(sourceWidth, sourceHeight) < 320 || min(sourceWidth, sourceHeight) < 160 {
            return "Selected region has too few pixels. Move the camera closer or select a larger notebook region."
        }
        let mean = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
        if mean < 45 { return "The page is too dark or covered. Add light and clear the camera view." }
        var laplacianSquared = 0.0
        var darkPixels = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let center = Double(pixels[i])
                if center < mean - 35 { darkPixels += 1 }
                let laplacian = Double(pixels[i - 1]) + Double(pixels[i + 1])
                    + Double(pixels[i - width]) + Double(pixels[i + width]) - 4 * center
                laplacianSquared += laplacian * laplacian
            }
        }
        let variance = laplacianSquared / Double((width - 2) * (height - 2))
        if variance < 18 || darkPixels < 20 {
            return "Writing is blurred, faint, or not yet visible. Hold the camera steady, improve lighting, and check the crop."
        }
        return nil
    }
}
