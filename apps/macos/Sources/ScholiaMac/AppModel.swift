@preconcurrency import AppKit
@preconcurrency import ApplicationServices
import Foundation
import ServiceManagement
import SwiftUI

private struct QuickChatSnapshot {
    var id: UUID
    var messages: [ConversationMessage]
    var selection: String?
    var selectionKind: CaptureKind?
    var parentContext: String?
    var error: String?
}

private enum PreparedFileAttachment: Sendable {
    case document(MessageAttachment)
    case failure(String)
}

func scholiaApplicationActivationPolicy(
    explanationWindowParticipates: Bool,
    quickChatWindowVisible: Bool,
    settingsWindowVisible: Bool = false,
    studyWindowVisible: Bool = false,
    hasOpenedApplicationWindow: Bool = false
) -> NSApplication.ActivationPolicy {
    hasOpenedApplicationWindow || explanationWindowParticipates || quickChatWindowVisible || settingsWindowVisible || studyWindowVisible
        ? .regular
        : .accessory
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings
    @Published private(set) var capture: CapturedContent?
    @Published private(set) var messages: [ConversationMessage] = []
    @Published var draft = ""
    @Published var conversationContextEnabled = true
    @Published var conversationCompactContextEnabled = true
    @Published var messageEditDraft = ""
    @Published private(set) var editingMessageID: UUID?
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var status = "Ready in the background."
    @Published private(set) var accessibilityGranted = SelectionReader.isTrusted
    @Published private(set) var screenCaptureGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var screenCaptureNeedsRelaunch = false
    @Published private(set) var permissionStatus: String?
    @Published private(set) var hotKeysAvailable = true
    @Published private(set) var modelVerification = ModelVerificationState()
    @Published private(set) var providerTestStatus: String?
    @Published private(set) var isStartingBridge = false
    @Published private(set) var bridgeReadyProviderIDs: Set<String> = []
    @Published private(set) var discoveredProviderModels: [String: [ModelDefinition]] = [:]
    @Published private(set) var savedConversations: [StoredConversation] = []
    @Published var quickDraft = ""
    @Published private(set) var quickDraftImageData: Data?
    @Published private(set) var quickDraftAttachments: [MessageAttachment] = []
    @Published private(set) var draftImageData: Data?
    @Published var draftAttachments: [MessageAttachment] = []
    @Published private(set) var isIngestingDraftAttachment = false
    @Published private(set) var isIngestingQuickAttachment = false
    @Published private(set) var opencodeSessionFindings: [OpenCodePoisonedAttachment] = []
    @Published private(set) var isScanningOpencodeSessions = false
    @Published private(set) var opencodeRepairStatus: String?
    @Published var quickContextEnabled = true
    @Published var quickCompactContextEnabled = true
    @Published var quickMessageEditDraft = ""
    @Published private(set) var editingQuickMessageID: UUID?
    @Published private(set) var quickMessages: [ConversationMessage] = []
    @Published private(set) var quickAskError: String?
    @Published private(set) var isQuickAskStreaming = false
    @Published private(set) var quickSelectionExcerpt: String?
    @Published private var quickAskThinkingProfileOverride: QuickAskThinkingProfile?
    @Published private(set) var quickLayerDepth = 0
    @Published private(set) var quickLayerID = UUID()
    @Published private(set) var activeApplication: ExternalApplication?

    private let providerClient = ProviderClient()
    let codexUsage = CodexUsageMonitor()
    private let localFileAccessPolicy = LocalFileAccessPolicy()
    private let bridgeManager = LocalBridgeManager()
    private let applicationTracker = ExternalApplicationTracker()
    private let hotKeys = GlobalHotKeyController()
    private let regionCapture = RegionCaptureController()
    private var activeTask: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var bridgeTask: Task<Void, Never>?
    private var providerTestTask: Task<Void, Never>?
    private var bridgeTasks: [String: Task<Void, Never>] = [:]
    private var bridgeStatusTasks: [String: Task<Void, Never>] = [:]
    private var bridgeMonitorTask: Task<Void, Never>?
    private let conversationWriter = ConversationHistoryWriter()
    private var modelCatalogTasks: [String: Task<Void, Never>] = [:]
    private var modelCatalogCheckedAt: [String: Date] = [:]
    private var modelCatalogEndpoints: [String: String] = [:]
    private var modelCatalogRequestIDs: [String: UUID] = [:]
    private var permissionRefreshTask: Task<Void, Never>?
    private var quickAskTask: Task<Void, Never>?
    private var draftAttachmentTask: Task<Void, Never>?
    private var quickAttachmentTask: Task<Void, Never>?
    private var queuedDraftFileURLs: [URL] = []
    private var queuedQuickFileURLs: [URL] = []
    private var draftFilePromiseCount = 0
    private var quickFilePromiseCount = 0
    private var draftFileDropGeneration = UUID()
    private var quickFileDropGeneration = UUID()
    private var draftAttachmentRequestID: UUID?
    private var quickAttachmentRequestID: UUID?
    private var currentRequestID: UUID?
    private var currentQuickAskRequestID: UUID?
    private var currentQuickAskAssistantID: UUID?
    private var quickSelectionKind: CaptureKind?
    private var quickParentContext: String?
    private var quickChatAncestors: [QuickChatSnapshot] = []
    private var currentConversationID: UUID?
    func isCurrentSavedConversation(_ id: UUID) -> Bool { currentConversationID == id }
    private var currentConversationCreatedAt: Date?
    private var accessibilityPermissionPending = false
    private var screenCapturePermissionPending = false
    private var quickChatWindowVisible = false
    private var settingsWindowVisible = false
    private var studyWindowVisible = false
    private var studyWorkspaceUsed = false
    private var hasOpenedApplicationWindow = false
    private var started = false

    private lazy var explanationPanel = ExplanationPanelController(model: self)
    private lazy var studyWindow = StudyWindowController(app: self)
    private lazy var studyWebServer = StudyWebServer(app: self, workspace: studyWindow.workspace)
    private lazy var quickAskPanel = QuickAskPanelController(model: self)
    private lazy var selectionPill = SelectionPillController(
        initialOffset: settings.resolvedSelectionPopupOffset,
        onMove: { [weak self] offset in self?.rememberSelectionPopupOffset(offset) },
        onExplain: { [weak self] capture, point, question in
            self?.markSelectionHandled(capture)
            self?.begin(capture: capture, near: point, automaticallyAsk: true, initialQuestion: question)
        }
    )
    private lazy var selectionWatcher = SelectionWatcher(
        applicationTracker: applicationTracker,
        shouldCapture: { [weak self] application in
            guard let self, self.started else { return false }
            return self.settings.selectionPillIsEnabled(for: application?.bundleIdentifier)
        },
        shouldIgnore: { [weak self] point in self?.selectionPill.contains(point) == true },
        onSelectionCleared: { [weak self] in
            self?.selectionPill.hide()
        }
    ) { [weak self] capture, point in
        guard let self, self.started,
              self.settings.selectionPillIsEnabled(for: capture.applicationBundleIdentifier),
              !self.isAnswering else { return }
        self.selectionPill.show(capture: capture, near: point)
    }

    private init() {
        settings = AppSettingsStore.load()
        localFileAccessPolicy.update(
            read: settings.resolvedLocalFileAccessEnabled,
            write: settings.resolvedLocalFileWriteAccessEnabled
        )
        conversationContextEnabled = true
        conversationCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        quickContextEnabled = true
        quickCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        activeApplication = nil
        savedConversations = ConversationStore.load()
        activeApplication = applicationTracker.preferredApplication
        applicationTracker.onApplicationChanged = { [weak self] application in
            self?.externalApplicationDidChange(application)
        }
    }

    var activeProvider: ProviderDefinition {
        ProviderCatalog.provider(id: settings.providerID)
    }

    var activeQuickAskProvider: ProviderDefinition {
        ProviderCatalog.provider(id: settings.resolvedQuickAskProviderID(for: settings.providerID))
    }

    var quickAskProviderIsOverridden: Bool {
        guard let id = settings.quickAskProviderID else { return false }
        return id != settings.providerID
    }

    var activeModel: String {
        settings.models[activeProvider.id] ?? activeProvider.defaultModel
    }

    func availableModels(for provider: ProviderDefinition) -> [ModelDefinition] {
        var seen = Set<String>()
        var indexByID: [String: Int] = [:]
        var result: [ModelDefinition] = []
        let discovered = discoveredProviderModels[provider.id] ?? []
        for definition in provider.models + discovered {
            let id = ProviderCatalog.canonicalModelID(definition.id, for: provider.id)
            if let index = indexByID[id] {
                // The live catalog enriches a stable built-in entry without
                // replacing its concise label. Missing capability fields keep
                // the fail-closed static value; explicit live fields win.
                if !definition.reasoningEfforts.isEmpty {
                    result[index].reasoningEfforts = definition.reasoningEfforts
                    result[index].defaultReasoningEffort = definition.defaultReasoningEffort
                }
                if let supportsImages = definition.supportsImages {
                    result[index].supportsImages = supportsImages
                }
                continue
            }
            guard seen.insert(id).inserted else { continue }
            indexByID[id] = result.count
            result.append(ModelDefinition(
                id: id,
                label: id == definition.id ? definition.label : id,
                reasoningEfforts: definition.reasoningEfforts,
                defaultReasoningEffort: definition.defaultReasoningEffort,
                supportsImages: definition.supportsImages
            ))
        }
        let selectedIDs = [
            settings.models[provider.id],
            settings.quickAskModels?[provider.id]
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let rememberedIDs = (settings.verifiedProviderModels?[provider.id] ?? []).map(\.id)
            + settings.recentModels.filter { $0.providerID == provider.id }.map(\.modelID)
            + modelVerification.results.keys.filter { $0.providerID == provider.id }.map(\.modelID)
        let profileIDs = (settings.quickAskThinkingProfiles?[provider.id] ?? [:])
            .values.compactMap(\.modelID)
        // Keep a custom model visible after a failed retest removes its verification.
        let testedIDs = modelVerification.results.keys
            .filter { $0.providerID == provider.id }.map(\.modelID)
        for rawID in selectedIDs + rememberedIDs + profileIDs + testedIDs {
            let id = ProviderCatalog.resolvedModelID(
                rawID,
                for: provider.id,
                candidates: discovered
            )
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            result.append(ModelDefinition(id: id, label: id))
        }
        return ModelPickerOrder.sorted(result, verified: settings.verifiedModelIDs(for: provider.id))
    }

    func verifiedModels(for provider: ProviderDefinition) -> [ModelDefinition] {
        let verified = settings.verifiedModelIDs(for: provider.id)
        return availableModels(for: provider).filter { verified.contains($0.id) }
    }

    var isTestingProvider: Bool { modelVerification.activeTest != nil }

    func modelTestTarget(_ modelID: String, for provider: ProviderDefinition) -> ModelTestTarget {
        ModelTestTarget(
            providerID: provider.id,
            modelID: ProviderCatalog.resolvedModelID(
                modelID, for: provider.id, candidates: discoveredProviderModels[provider.id] ?? []
            ),
            endpoint: settings.endpoints[provider.id] ?? provider.endpoint
        )
    }

    func modelTestStatus(_ modelID: String, for provider: ProviderDefinition) -> ModelTestStatus? {
        modelVerification.results[modelTestTarget(modelID, for: provider)]
    }

    func modelIsVerified(_ modelID: String, for provider: ProviderDefinition) -> Bool {
        settings.verifiedModel(for: provider.id, modelID: modelID) != nil
    }

    func modelVerificationDetail(_ modelID: String, for provider: ProviderDefinition) -> String? {
        guard let record = settings.verifiedModel(for: provider.id, modelID: modelID) else {
            return nil
        }
        return "Tested \(record.testedAt.formatted(date: .abbreviated, time: .shortened))"
    }

    func modelDefinition(for provider: ProviderDefinition, id: String) -> ModelDefinition? {
        // The composer asks for one model on every edit. Do not rebuild and
        // sort a potentially large provider catalog just to find that row.
        let discovered = discoveredProviderModels[provider.id] ?? []
        let resolved = ProviderCatalog.resolvedModelID(id, for: provider.id, candidates: discovered)
        var definition = provider.model(named: resolved)
        if let live = discovered.first(where: { $0.id == resolved }) {
            if definition == nil { return live }
            if !live.reasoningEfforts.isEmpty {
                definition?.reasoningEfforts = live.reasoningEfforts
                definition?.defaultReasoningEffort = live.defaultReasoningEffort
            }
            if let supportsImages = live.supportsImages { definition?.supportsImages = supportsImages }
        }
        if let definition { return definition }
        let remembered = [settings.models[provider.id], settings.quickAskModels?[provider.id]].compactMap { $0 }
            + (settings.quickAskThinkingProfiles?[provider.id] ?? [:]).values.compactMap(\.modelID)
            + (settings.verifiedProviderModels?[provider.id] ?? []).map(\.id)
            + settings.recentModels.filter { $0.providerID == provider.id }.map(\.modelID)
        return remembered.contains(resolved) ? ModelDefinition(id: resolved, label: resolved) : nil
    }

    var quickAskBaseModel: String {
        settings.resolvedQuickAskModel(for: activeQuickAskProvider)
    }

    var activeQuickAskThinkingProfile: QuickAskThinkingProfile {
        let preferred = quickAskThinkingProfileOverride
            ?? settings.resolvedQuickAskThinkingProfile(for: activeQuickAskProvider)
        return effectiveQuickAskThinkingProfile(
            preferred,
            provider: activeQuickAskProvider
        )
    }

    var activeQuickAskModel: String {
        settings.resolvedQuickAskThinkingModel(
            for: activeQuickAskThinkingProfile,
            provider: activeQuickAskProvider
        )
    }

    var activeQuickAskReasoningEffort: String? {
        quickAskReasoningEffort(
            for: activeQuickAskThinkingProfile,
            provider: activeQuickAskProvider
        )
    }

    func quickAskReasoningEfforts(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> [String] {
        let modelID = settings.resolvedQuickAskThinkingModel(for: profile, provider: provider)
        return modelDefinition(for: provider, id: modelID)?.reasoningEfforts ?? []
    }

    func defaultQuickAskReasoningEffort(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> String? {
        profile.defaultReasoningEffort(
            supportedEfforts: quickAskReasoningEfforts(for: profile, provider: provider)
        )
    }

    func quickAskReasoningEffort(
        for profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> String? {
        let supportedEfforts = quickAskReasoningEfforts(for: profile, provider: provider)
        guard !supportedEfforts.isEmpty else { return nil }
        if let configured = settings.quickAskThinkingConfiguration(
            for: profile,
            provider: provider
        )?.reasoningEffort,
           supportedEfforts.contains(configured) {
            return configured
        }
        return profile.defaultReasoningEffort(supportedEfforts: supportedEfforts)
    }

    func quickAskThinkingProfileIsAvailable(
        _ profile: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> Bool {
        quickAskReasoningEffort(for: profile, provider: provider) != nil
    }

    func availableQuickAskThinkingProfiles(
        for provider: ProviderDefinition
    ) -> [QuickAskThinkingProfile] {
        QuickAskThinkingProfile.allCases.filter {
            quickAskThinkingProfileIsAvailable($0, provider: provider)
        }
    }

    func effectiveQuickAskThinkingProfile(
        _ preferred: QuickAskThinkingProfile,
        provider: ProviderDefinition
    ) -> QuickAskThinkingProfile {
        let available = Set(availableQuickAskThinkingProfiles(for: provider))
        return available.contains(preferred)
            ? preferred
            : preferred.closest(among: available) ?? preferred
    }

    var quickAskThinkingIsAvailable: Bool {
        !availableQuickAskThinkingProfiles(for: activeQuickAskProvider).isEmpty
    }

    var latestQuickAnswer: String {
        quickMessages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content ?? ""
    }

    var quickDraftImage: NSImage? {
        quickDraftImageData.flatMap(NSImage.init(data:))
    }

    var canReturnToParentQuickChat: Bool { !quickChatAncestors.isEmpty }

    private var activeQuickCapture: CapturedContent? {
        guard let selection = quickSelectionExcerpt, !selection.isEmpty else { return nil }
        return CapturedContent(
            kind: quickSelectionKind ?? .text,
            text: selection,
            applicationName: "Scholia Quick Chat",
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            windowTitle: "Explanation layer \(quickLayerDepth + 1)",
            parentContext: quickParentContext
        )
    }

    var isAnswering: Bool { isStreaming || isQuickAskStreaming }

    var selectionPillIsEnabledForActiveApplication: Bool {
        settings.selectionPillIsEnabled(for: activeApplication?.bundleIdentifier)
    }

    var captureRegionIsEnabledForActiveApplication: Bool {
        settings.captureRegionIsEnabled(for: activeApplication?.bundleIdentifier)
    }

    var contextualShortcutsDeferredForActiveApplication: Bool {
        !selectionPillIsEnabledForActiveApplication || !captureRegionIsEnabledForActiveApplication
    }

    var activeApplicationHasSelectionPopupOverride: Bool {
        settings.selectionPopupPreference(for: activeApplication?.bundleIdentifier) != nil
    }

    var canConfigureActiveApplication: Bool {
        activeApplication?.bundleIdentifier != nil
    }

    var activeApplicationIcon: NSImage? {
        guard let application = activeApplication else { return nil }
        if let icon = NSRunningApplication(processIdentifier: application.processIdentifier)?.icon {
            return icon
        }
        guard let bundleIdentifier = application.bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    var menuBarAccessibilityLabel: String {
        if isAnswering { return "Scholia is explaining" }
        let selectionState = selectionPillIsEnabledForActiveApplication ? "on" : "off"
        let captureState = captureRegionIsEnabledForActiveApplication ? "on" : "off"
        if let name = activeApplication?.name {
            return "Scholia selection Explain is \(selectionState) and screen capture is \(captureState) for \(name)"
        }
        return "Scholia selection Explain is \(selectionState) and screen capture is \(captureState)"
    }

    var launchAtLoginAvailable: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }

    var hasConfiguredProvider: Bool {
        if activeProvider.bridge != nil {
            return activeBridgeIsReady || isStartingBridge
        }
        guard activeProvider.keyRequired else { return true }
        return !((try? ProviderKeychain.value(for: activeProvider.id)) ?? "").isEmpty
    }

    var hasConfiguredQuickAskProvider: Bool {
        let provider = activeQuickAskProvider
        if provider.bridge != nil {
            return bridgeReadyProviderIDs.contains(provider.id) || isStartingBridge
        }
        guard provider.keyRequired else { return true }
        return !((try? ProviderKeychain.value(for: provider.id)) ?? "").isEmpty
    }

    var activeBridgeIsReady: Bool {
        bridgeReadyProviderIDs.contains(activeProvider.id)
    }

    var runningFromApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").path + "/")
    }

    var currentAppPath: String { Bundle.main.bundleURL.path }

    func start() {
        guard !started else { return }
        started = true
        applicationTracker.refresh()
        applyExplanationWindowBehavior()
        refreshPermissions()
        registerHotKeys()
        if contextualShortcutsDeferredForActiveApplication {
            status = deferredShortcutStatus()
        } else {
            status = hotKeysAvailable
                ? "Press \(settings.resolvedQuickAskShortcut.displayName) to ask, or \(settings.resolvedExplainShortcut.displayName) to explain a selection."
                : "Global shortcuts are in use by another app; use the menu-bar controls."
        }
        prepareActiveLocalProvider()
        startBridgeMonitor()
        PersonalizationSync.shared.start()
    }

    func stop() {
        started = false
        PersonalizationSync.shared.stop()
        if studyWorkspaceUsed { studyWindow.workspace.flush() }
        do { try conversationWriter.flush() }
        catch { status = "Could not save chat history: \(error.localizedDescription)" }
        activeTask?.cancel()
        captureTask?.cancel()
        bridgeTask?.cancel()
        for task in bridgeTasks.values { task.cancel() }
        bridgeTasks = [:]
        for task in bridgeStatusTasks.values { task.cancel() }
        bridgeStatusTasks = [:]
        bridgeMonitorTask?.cancel()
        for task in modelCatalogTasks.values { task.cancel() }
        permissionRefreshTask?.cancel()
        quickAskTask?.cancel()
        cancelAttachmentIngestion(isQuickAsk: false)
        cancelAttachmentIngestion(isQuickAsk: true)
        bridgeManager.stopOwnedProcess()
        hotKeys.stop()
        selectionWatcher.stop()
        selectionPill.hide()
        quickAskPanel.hide()
        regionCapture.cancel()
    }

    func refreshPermissions() {
        accessibilityGranted = SelectionReader.isTrusted
        screenCaptureGranted = regionCapture.screenCaptureGranted
        if accessibilityGranted { accessibilityPermissionPending = false }
        if screenCaptureGranted {
            screenCapturePermissionPending = false
            screenCaptureNeedsRelaunch = false
        }
        if accessibilityGranted && screenCaptureGranted { permissionStatus = nil }
        // Permission refreshes also happen in workspace previews and when settings
        // are saved. Only the running menu-bar companion may watch other apps.
        if started && settings.shouldMonitorSelections && accessibilityGranted {
            selectionWatcher.start()
        } else {
            selectionWatcher.stop()
            selectionPill.hide()
        }
    }

    func applicationDidBecomeActive() {
        refreshActiveApplication()
        schedulePermissionRefresh(recommendRelaunchIfStillPending: screenCapturePermissionPending)
        prepareActiveLocalProvider()
    }

    func refreshActiveApplication() {
        applicationTracker.refresh()
        activeApplication = applicationTracker.preferredApplication
        if started { registerHotKeys() }
    }

    func requestAccessibility() {
        refreshPermissions()
        guard !accessibilityGranted else {
            status = "Selected-text access is already allowed."
            return
        }
        accessibilityPermissionPending = true
        accessibilityGranted = SelectionReader.requestPermission()
        status = accessibilityGranted
            ? "Selected-text access is ready."
            : "Approve Accessibility access in System Settings."
        refreshPermissions()
        schedulePermissionRefresh()
    }

    func openAccessibilitySettings() {
        accessibilityPermissionPending = true
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
        schedulePermissionRefresh()
    }

    func requestScreenCapture() {
        refreshPermissions()
        guard !screenCaptureGranted else {
            status = "Screen capture is already allowed."
            return
        }
        screenCapturePermissionPending = true
        screenCaptureGranted = regionCapture.requestPermission()
        status = screenCaptureGranted
            ? "Screen capture is ready."
            : "Approve Screen Recording access, then return to Scholia."
        if !screenCaptureGranted { screenCaptureNeedsRelaunch = true }
        schedulePermissionRefresh(recommendRelaunchIfStillPending: true)
    }

    func openScreenCaptureSettings() {
        screenCapturePermissionPending = true
        regionCapture.openScreenRecordingSettings()
        schedulePermissionRefresh(recommendRelaunchIfStillPending: true)
    }

    func relaunch() {
        guard Bundle.main.bundleURL.pathExtension.lowercased() == "app" else {
            status = "Open the packaged Scholia.app to relaunch it."
            return
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = [
            "-c", "sleep 0.4; exec /usr/bin/open -n -- \"$1\"",
            "scholia-relaunch", Bundle.main.bundleURL.path
        ]
        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            status = "Could not relaunch Scholia: \(error.localizedDescription)"
        }
    }

    func revealCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func explainSelectedText() {
        selectionPill.hide()
        refreshPermissions()
        guard accessibilityGranted else {
            present(error: SelectionReaderError.permissionRequired)
            return
        }
        captureTask?.cancel()
        let pid = applicationTracker.preferredPID
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let captured = try await SelectionReader.capture(preferredPID: pid)
                guard !Task.isCancelled else { return }
                self.markSelectionHandled(captured)
                self.begin(capture: captured, near: NSEvent.mouseLocation, automaticallyAsk: true)
            } catch {
                guard !Task.isCancelled else { return }
                self.present(error: error)
            }
        }
    }

    func captureRegion() {
        selectionPill.hide()
        refreshPermissions()
        guard screenCaptureGranted else {
            present(error: RegionCaptureError.permissionRequired)
            return
        }
        let sourcePID = applicationTracker.preferredPID
        let sourceContext = SelectionReader.captureApplicationContext(preferredPID: sourcePID)
        regionCapture.begin { [weak self] result in
            guard let self else { return }
            self.screenCaptureGranted = self.regionCapture.screenCaptureGranted
            switch result {
            case .success(var captured):
                captured.applicationName = sourceContext.applicationName ?? captured.applicationName
                captured.applicationBundleIdentifier = sourceContext.applicationBundleIdentifier
                captured.applicationPID = sourceContext.applicationPID
                captured.windowTitle = sourceContext.windowTitle ?? "Screen region"
                captured.sourceURL = sourceContext.sourceURL
                captured.context = sourceContext.context
                self.begin(capture: captured, near: NSEvent.mouseLocation, automaticallyAsk: false)
            case .failure(let error):
                self.present(error: error)
            }
        }
    }

    func explainClipboard() {
        selectionPill.hide()
        let pasteboard = NSPasteboard.general
        let source = "Clipboard"
        if let image = NSImage(pasteboard: pasteboard),
           let data = ImageEncoding.jpegData(from: image) {
            begin(
                capture: CapturedContent(
                    kind: .image, imageData: data, imageMimeType: "image/jpeg",
                    applicationName: source
                ),
                near: NSEvent.mouseLocation,
                automaticallyAsk: false
            )
            return
        }
        if let pasted = pasteboard.string(forType: .string),
           let text = TextInputPolicy.preparedMessage(pasted) {
            begin(
                capture: CapturedContent(kind: .text, text: text, applicationName: source),
                near: NSEvent.mouseLocation,
                automaticallyAsk: true
            )
            return
        }
        present(error: SelectionReaderError.noSelection)
    }

    func explainServiceText(_ text: String) {
        guard let normalized = TextInputPolicy.preparedMessage(text) else {
            present(error: SelectionReaderError.noSelection)
            return
        }
        begin(
            capture: CapturedContent(
                kind: .text,
                text: normalized,
                applicationName: NSWorkspace.shared.frontmostApplication?.localizedName,
                applicationBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                applicationPID: NSWorkspace.shared.frontmostApplication?.processIdentifier
            ),
            near: NSEvent.mouseLocation,
            automaticallyAsk: true
        )
    }

    func openConversation() {
        selectionPill.hide()
        explanationPanel.show(near: NSEvent.mouseLocation)
    }

    func openStudyWorkspace() {
        studyWindow.show()
    }

    var studyWorkspace: StudyWorkspaceModel {
        studyWorkspaceUsed = true
        return studyWindow.workspace
    }

    func openStudyWebsite() {
        studyWorkspaceUsed = true
        applicationWindowOpened()
        studyWebServer.open()
    }

    /// Start the local workspace API for explicit CLI/browser verification,
    /// without opening the user's default browser.
    func startStudyWebsite() {
        studyWorkspaceUsed = true
        studyWebServer.start()
    }

    func applicationWindowOpened() {
        hasOpenedApplicationWindow = true
        applyExplanationWindowBehavior()
    }

    func reopenFromDock() {
        applicationWindowOpened()
        if let window = NSApp.orderedWindows.first(where: { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeKey && ($0.title.contains("Scholia") || $0.canBecomeMain) }) {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { openStudyWorkspace() }
    }

    func openStudyDocuments(_ urls: [URL]) {
        studyWindow.show()
        if studyWindow.workspace.course == nil { studyWindow.workspace.createCourse(name: "My studies", code: "") }
        studyWindow.workspace.importDocuments(urls)
    }

    func chooseStudyDocuments() {
        studyWindow.show()
        if studyWindow.workspace.course == nil { studyWindow.workspace.createCourse(name: "My studies", code: "") }
        studyWindow.workspace.chooseDocuments()
    }

    func studyWindowVisibilityDidChange(_ visible: Bool) {
        studyWindowVisible = visible
        if visible { studyWorkspaceUsed = true }
        if visible { hasOpenedApplicationWindow = true }
        applyExplanationWindowBehavior()
    }

    func studyProviderConfiguration(allowLocalFiles: Bool = false) throws -> ProviderConfiguration {
        var configuration = try providerConfiguration(allowLocalFiles: allowLocalFiles)
        configuration.reasoningEffort = activeStudyReasoningEffort
        return configuration
    }

    var activeStudyModelMode: StudyModelMode { settings.resolvedStudyModelMode }

    func selectStudyModelMode(_ mode: StudyModelMode) {
        settings.studyModelMode = mode
        persistSettings()
    }

    var activeStudyReasoningEffort: String? {
        guard let definition = modelDefinition(for: activeProvider, id: activeModel),
            !definition.reasoningEfforts.isEmpty else { return nil }
        if let selected = settings.reasoningEfforts[activeProvider.id],
            definition.reasoningEfforts.contains(selected) { return selected }
        return definition.defaultReasoningEffort ?? definition.reasoningEfforts.first
    }

    func selectStudyReasoningEffort(_ effort: String) throws {
        guard modelDefinition(for: activeProvider, id: activeModel)?.reasoningEfforts.contains(effort) == true else {
            throw StudyError.message("This reasoning mode is unavailable for the selected model.")
        }
        settings.reasoningEfforts[activeProvider.id] = effort
        persistSettings()
    }

    func selectStudyModel(_ modelID: String, providerID: String) {
        let provider = ProviderCatalog.provider(id: providerID)
        guard modelIsVerified(modelID, for: provider) else { return }
        settings.providerID = providerID
        settings.models[providerID] = modelID
        persistSettings()
        prepareActiveLocalProvider()
    }

    func completeStudy(
        messages: [ConversationMessage], configuration: ProviderConfiguration,
        onProgress: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onToken: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> CompletionResult {
        onProgress("Connecting to \(configuration.provider.name)…")
        defer { refreshCodexUsageAfterResponse(configuration) }
        try await ensureLocalProvider(configuration)
        let result = try await providerClient.complete(capture: nil, messages: messages, configuration: configuration,
            onProgress: onProgress, onToken: onToken)
        try Task.checkCancellation()
        if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recordModelUse(configuration) }
        return result
    }

    private func refreshCodexUsageAfterResponse(_ configuration: ProviderConfiguration) {
        guard configuration.provider.id == "codex" else { return }
        Task {
            guard let current = try? providerConfiguration(providerOverride: configuration.provider),
                  current.endpoint == configuration.endpoint, current.apiKey == configuration.apiKey else { return }
            await codexUsage.refresh(configuration: current, force: true)
        }
    }

    func codexUsageConfiguration(quickChat: Bool = false) -> ProviderConfiguration? {
        let provider = quickChat ? activeQuickAskProvider : activeProvider
        guard provider.id == "codex" else { return nil }
        return try? providerConfiguration(providerOverride: provider)
    }

    private func recordModelUse(_ configuration: ProviderConfiguration) {
        settings.recordModelUse(providerID: configuration.provider.id, modelID: configuration.model,
            endpoint: configuration.endpoint)
        persistSettings()
    }

    func showQuickAsk() {
        selectionPill.hide()
        cancelQuickAsk()
        cancelAttachmentIngestion(isQuickAsk: true)
        clearQuickMessageEdit()
        quickDraft = ""
        quickDraftImageData = nil
        quickDraftAttachments = []
        quickMessages = []
        quickAskError = nil
        quickSelectionExcerpt = nil
        quickSelectionKind = nil
        quickParentContext = nil
        quickChatAncestors = []
        quickLayerDepth = 0
        quickLayerID = UUID()
        quickContextEnabled = true
        quickCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        quickAskThinkingProfileOverride = settings.resolvedQuickAskThinkingProfile(
            for: activeQuickAskProvider
        )
        quickAskPanel.showPrompt()
    }

    func submitQuickAsk() {
        guard !isQuickAskStreaming, !isIngestingQuickAttachment else { return }
        let hasImage = quickDraftImageData != nil || quickDraftAttachments.contains(where: \.isImage)
        let hasAttachments = quickDraftAttachments.contains { !$0.isImage }
        guard let question = preparedQuestion(
            quickDraft,
            hasImage: hasImage,
            hasAttachments: hasAttachments
        ) else { return }
        clearQuickMessageEdit()
        let imageData = quickDraftImageData
        let attachments = quickDraftAttachments
        quickDraft = ""
        quickDraftImageData = nil
        quickDraftAttachments = []
        quickAskError = nil
        let startingConversation = quickMessages.isEmpty
        quickMessages.append(ConversationMessage(
            role: .user,
            content: question,
            imageData: imageData,
            imageMimeType: imageData == nil ? nil : "image/jpeg",
            attachments: attachments.isEmpty ? nil : attachments
        ))
        let requestMessages = quickMessages
        let baseRequestCapture = activeQuickCapture
        let preferredPID = applicationTracker.preferredPID
        let useAutomaticContext = quickContextEnabled
        let useCompactContext = quickCompactContextEnabled
        let includeChatGptDesktopContext = useAutomaticContext
            && startingConversation
            && quickChatAncestors.isEmpty
        if startingConversation && quickChatAncestors.isEmpty { quickAskPanel.showAnswer() }

        let configuration: ProviderConfiguration
        do {
            configuration = try providerConfiguration(
                modelOverride: activeQuickAskModel,
                reasoningEffortOverride: activeQuickAskReasoningEffort,
                providerOverride: activeQuickAskProvider,
                allowLocalFiles: true
            )
        } catch {
            quickAskError = error.localizedDescription
            return
        }

        quickAskTask?.cancel()
        let requestID = UUID()
        let assistantID = UUID()
        currentQuickAskRequestID = requestID
        currentQuickAskAssistantID = assistantID
        quickMessages.append(ConversationMessage(
            id: assistantID,
            role: .assistant,
            content: "",
            isStreaming: true
        ))
        isQuickAskStreaming = true
        recordChatActivity(assistantID, quick: true, title: "Preparing request")
        for attachment in attachments where attachment.includedInContext { recordChatActivity(assistantID, quick: true, title: attachment.readStatusLabel, detail: attachment.fileName) }
        quickAskTask = Task { [weak self] in
            guard let self else { return }
            let responseStartedAt = Date()
            defer { refreshCodexUsageAfterResponse(configuration) }
            do {
                if useAutomaticContext { recordChatActivity(assistantID, quick: true, title: "Reading visible application context") }
                let workspaceContext = useAutomaticContext && useCompactContext
                    ? await SelectionReader.captureVisibleWorkspaceContextAsync(
                        question: question,
                        preferredPID: preferredPID,
                        includeChatGptDesktopContext: includeChatGptDesktopContext
                    )
                    : nil
                let fullApplicationContext = useAutomaticContext && !useCompactContext
                    ? SelectionReader.captureApplicationContext(preferredPID: preferredPID)
                    : nil
                guard !Task.isCancelled else { throw CancellationError() }
                let requestCapture = VisibleWorkspaceContext.requestCapture(
                    baseRequestCapture,
                    workspaceContext: workspaceContext,
                    automaticContextEnabled: useAutomaticContext,
                    compactContextEnabled: useCompactContext,
                    fullApplicationContext: fullApplicationContext
                )
                recordChatActivity(assistantID, quick: true, title: "Context prepared", detail: requestCapture?.applicationName)
                try await self.ensureLocalProvider(configuration, updatesStatus: configuration.provider.id == self.activeProvider.id)
                let result = try await providerClient.complete(
                    capture: requestCapture,
                    messages: requestMessages,
                    configuration: configuration,
                    onProgress: { [weak self] progress in
                        guard let self, self.currentQuickAskRequestID == requestID else { return }
                        self.recordChatActivity(assistantID, quick: true, title: progress)
                    }
                ) { [weak self] token in
                    guard let self, self.currentQuickAskRequestID == requestID,
                          let index = self.quickMessages.firstIndex(where: { $0.id == assistantID }) else { return }
                    self.quickMessages[index].content += token
                    self.quickMessages[index].recordActivity("Writing answer…")
                }
                guard currentQuickAskRequestID == requestID else { return }
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recordModelUse(configuration) }
                if let index = quickMessages.firstIndex(where: { $0.id == assistantID }) {
                    quickMessages[index].content = result.text
                    quickMessages[index].reasoning = result.reasoning
                    quickMessages[index].usage = result.usage
                    quickMessages[index].responseDurationSeconds = Date().timeIntervalSince(responseStartedAt)
                    quickMessages[index].isStreaming = false
                    quickMessages[index].recordActivity("Answer complete", detail: result.model)
                    quickMessages[index].metadata = [result.providerName, result.model, configuration.reasoningEffort]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                }
                isQuickAskStreaming = false
                currentQuickAskRequestID = nil
                currentQuickAskAssistantID = nil
                quickAskTask = nil
                status = "Quick chat response ready."
            } catch is CancellationError {
                guard currentQuickAskRequestID == requestID else { return }
                finishCancelledQuickAsk(assistantID: assistantID)
            } catch {
                guard currentQuickAskRequestID == requestID else { return }
                if let index = quickMessages.firstIndex(where: { $0.id == assistantID }) {
                    quickMessages[index].recordActivity("Response interrupted", detail: error.localizedDescription)
                    if quickMessages[index].content.isEmpty && quickMessages[index].activity?.isEmpty != false {
                        quickMessages.remove(at: index)
                    } else {
                        quickMessages[index].isStreaming = false
                        quickMessages[index].metadata = "Response interrupted"
                    }
                }
                isQuickAskStreaming = false
                currentQuickAskRequestID = nil
                currentQuickAskAssistantID = nil
                quickAskTask = nil
                quickAskError = error.localizedDescription
                status = error.localizedDescription
                if let providerError = error as? ProviderClientError,
                   case .sessionHistoryPoisoned = providerError {
                    scanOpencodeSessions()
                }
            }
        }
    }

    private func recordChatActivity(_ assistantID: UUID, quick: Bool, title: String, detail: String? = nil) {
        if quick, let index = quickMessages.firstIndex(where: { $0.id == assistantID }) {
            quickMessages[index].recordActivity(title, detail: detail)
        } else if !quick, let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].recordActivity(title, detail: detail)
        }
    }

    func beginEditingQuickMessage(_ messageID: UUID) {
        guard !isQuickAskStreaming,
              let message = quickMessages.first(where: {
                  $0.id == messageID && $0.role == .user
              }) else { return }
        editingQuickMessageID = messageID
        quickMessageEditDraft = message.content
    }

    func cancelQuickMessageEdit() {
        clearQuickMessageEdit()
    }

    func resendEditedQuickMessage() {
        guard !isQuickAskStreaming,
              let editingQuickMessageID,
              let prepared = ConversationEditor.prepareResend(
                  messages: quickMessages,
                  messageID: editingQuickMessageID,
                  rawQuestion: quickMessageEditDraft
              ) else { return }
        quickMessages = prepared.precedingMessages
        clearQuickMessageEdit()
        quickDraft = prepared.question
        quickDraftImageData = prepared.imageData
        quickDraftAttachments = prepared.attachments ?? []
        submitQuickAsk()
    }

    func removeQuickDraftImage() {
        quickDraftImageData = nil
        status = "Quick Chat image removed."
    }

    // MARK: Message attachments

    func attachQuickDraftAttachment(_ attachment: MessageAttachment) {
        guard !isQuickAskStreaming else { return }
        guard quickDraftAttachments.count < MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
            reportAttachmentError("Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) attachments are allowed per message.", isQuickAsk: true)
            return
        }
        quickDraftAttachments.append(attachment)
        status = "\(attachment.fileName) attached to the Quick Chat question."
    }

    func removeQuickDraftAttachment(_ id: UUID) {
        quickDraftAttachments.removeAll { $0.id == id }
        status = "Attachment removed."
    }

    func attachDraftAttachment(_ attachment: MessageAttachment) {
        guard draftAttachments.count < MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
            reportAttachmentError("Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) attachments are allowed per message.", isQuickAsk: false)
            return
        }
        draftAttachments.append(attachment)
        status = "\(attachment.fileName) attached to the question."
    }

    func removeDraftAttachment(_ id: UUID) {
        draftAttachments.removeAll { $0.id == id }
        status = "Attachment removed."
    }

    func removeDraftImage() {
        draftImageData = nil
        status = "Image removed."
    }

    /// Adds any file or project folder and shows its reading status before Send.
    func chooseDraftAttachment(isQuickAsk: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        attachFiles(at: panel.urls, isQuickAsk: isQuickAsk)
    }

    func attachFile(at url: URL, isQuickAsk: Bool) {
        attachFiles(at: [url], isQuickAsk: isQuickAsk)
    }

    func attachFiles(at urls: [URL], isQuickAsk: Bool) {
        guard !(isQuickAsk ? isQuickAskStreaming : isStreaming) else {
            reportAttachmentError("Wait for the response to finish before adding files.", isQuickAsk: isQuickAsk)
            return
        }
        if (isQuickAsk ? quickAttachmentTask : draftAttachmentTask) != nil {
            if isQuickAsk { queuedQuickFileURLs += urls }
            else { queuedDraftFileURLs += urls }
            return
        }
        let candidates = urls.filter(\.isFileURL)
        guard !candidates.isEmpty else { return }
        let currentCount = isQuickAsk ? quickDraftAttachments.count : draftAttachments.count
        guard currentCount + candidates.count <= MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
            reportAttachmentError(
                "Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) files can be attached per message. This batch was not added; choose fewer files.",
                isQuickAsk: isQuickAsk
            )
            return
        }
        let requestID = UUID()
        if isQuickAsk {
            quickAttachmentRequestID = requestID
            isIngestingQuickAttachment = true
        } else {
            draftAttachmentRequestID = requestID
            isIngestingDraftAttachment = true
        }
        status = "Reading \(candidates.count) attachment\(candidates.count == 1 ? "" : "s")…"
        let task = Task { [weak self] in
            var results: [PreparedFileAttachment] = []
            // Decode one file at a time off the main actor, including every
            // selected image. A large PDF batch must not exhaust memory.
            for candidate in candidates {
                guard !Task.isCancelled else { return }
                results.append(await Task.detached(priority: .userInitiated) {
                    Self.prepareFileAttachment(at: candidate)
                }.value)
            }
            guard !Task.isCancelled, let self,
                  self.finishAttachmentIngestion(requestID: requestID, isQuickAsk: isQuickAsk) else { return }
            var failures: [String] = []
            var attached = 0
            for result in results {
                switch result {
                case .document(let attachment):
                    if isQuickAsk { self.attachQuickDraftAttachment(attachment) }
                    else { self.attachDraftAttachment(attachment) }
                    attached += 1
                case .failure(let detail): failures.append(detail)
                }
            }
            self.status = "\(attached) attachment\(attached == 1 ? "" : "s") ready to send."
            if !failures.isEmpty {
                self.reportAttachmentError("Not attached:\n" + failures.joined(separator: "\n"), isQuickAsk: isQuickAsk)
            }
            self.ingestQueuedFiles(isQuickAsk: isQuickAsk)
        }
        if isQuickAsk { quickAttachmentTask = task }
        else { draftAttachmentTask = task }
    }

    private func reportAttachmentError(_ detail: String, isQuickAsk: Bool) {
        NSSound.beep()
        status = detail
        if isQuickAsk { quickAskError = detail }
        else { errorMessage = detail }
    }

    private func ingestQueuedFiles(isQuickAsk: Bool) {
        let urls = isQuickAsk ? queuedQuickFileURLs : queuedDraftFileURLs
        if isQuickAsk { queuedQuickFileURLs = [] }
        else { queuedDraftFileURLs = [] }
        if !urls.isEmpty { attachFiles(at: urls, isQuickAsk: isQuickAsk) }
    }

    /// Pasteboard ingestion shared by both composers. File URLs and explicit
    /// PDF payloads are resolved before generic image decoding so a PDF cannot
    /// be flattened into a first-page image by NSImage.
    @discardableResult
    func attachFromPasteboard(isQuickAsk: Bool, pasteboard: NSPasteboard = .general, acceptingDrop: Bool = false) -> Bool {
        guard !(isQuickAsk ? isQuickAskStreaming : isStreaming) else {
            guard AttachmentDropReader.canRead(pasteboard, allowPathStrings: acceptingDrop) else { return false }
            reportAttachmentError("Wait for the response to finish before adding files.", isQuickAsk: isQuickAsk)
            return true
        }
        let isBusy = isQuickAsk ? isIngestingQuickAttachment : isIngestingDraftAttachment
        let generation = isQuickAsk ? quickFileDropGeneration : draftFileDropGeneration
        if acceptingDrop && AttachmentDropReader.receivePromises(from: pasteboard, acceptingDrop: true, receiving: { [weak self] count in
            guard let self else { return }
            if isQuickAsk { self.quickFilePromiseCount += count; self.isIngestingQuickAttachment = true }
            else { self.draftFilePromiseCount += count; self.isIngestingDraftAttachment = true }
            self.status = "Receiving dropped files…"
        }, receive: { [weak self] url, failure in
            guard let self, generation == (isQuickAsk ? self.quickFileDropGeneration : self.draftFileDropGeneration) else { return }
            if isQuickAsk {
                self.quickFilePromiseCount = max(0, self.quickFilePromiseCount - 1)
                self.isIngestingQuickAttachment = self.quickFilePromiseCount > 0 || self.quickAttachmentTask != nil
            } else {
                self.draftFilePromiseCount = max(0, self.draftFilePromiseCount - 1)
                self.isIngestingDraftAttachment = self.draftFilePromiseCount > 0 || self.draftAttachmentTask != nil
            }
            if let failure { self.reportAttachmentError(failure, isQuickAsk: isQuickAsk) }
            if let url { self.attachFiles(at: [url], isQuickAsk: isQuickAsk) }
        }) { return true }
        let urls = AttachmentDropReader.fileURLs(from: pasteboard, allowPathStrings: acceptingDrop)
        if !urls.isEmpty {
            attachFiles(at: urls, isQuickAsk: isQuickAsk)
            return true
        }
        if !acceptingDrop && pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil) {
            reportAttachmentError("This app supplied a drag-only attachment. Drag it into the chat, or save it and attach the file.", isQuickAsk: isQuickAsk)
            return true
        }
        if let data = pasteboard.data(forType: .pdf) {
            guard !isBusy else {
                reportAttachmentError("Files are still being read. Paste this attachment again when they are ready.", isQuickAsk: isQuickAsk)
                return true
            }
            let name = pasteboardFileName(fallback: "Pasted document.pdf")
            let currentCount = isQuickAsk ? quickDraftAttachments.count : draftAttachments.count
            guard currentCount < MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
                reportAttachmentError("Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) attachments are allowed per message.", isQuickAsk: isQuickAsk)
                return true
            }
            let requestID = UUID()
            if isQuickAsk { quickAttachmentRequestID = requestID }
            else { draftAttachmentRequestID = requestID }
            if isQuickAsk { isIngestingQuickAttachment = true }
            else { isIngestingDraftAttachment = true }
            status = "Reading \(name)…"
            let task = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) {
                    do {
                        return PreparedFileAttachment.document(try MessageAttachmentIngestion.read(
                            data: data, fileName: name, mimeType: "application/pdf"
                        ))
                    } catch { return PreparedFileAttachment.failure("\(name): \(error.localizedDescription)") }
                }.value
                guard !Task.isCancelled, let self,
                      self.finishAttachmentIngestion(requestID: requestID, isQuickAsk: isQuickAsk) else {
                    return
                }
                switch result {
                case .document(let attachment):
                    if isQuickAsk { self.attachQuickDraftAttachment(attachment) }
                    else { self.attachDraftAttachment(attachment) }
                case .failure(let detail): self.reportAttachmentError(detail, isQuickAsk: isQuickAsk)
                }
                self.ingestQueuedFiles(isQuickAsk: isQuickAsk)
            }
            if isQuickAsk { quickAttachmentTask = task }
            else { draftAttachmentTask = task }
            return true
        }
        if let image = NSImage(pasteboard: pasteboard) {
            guard !isBusy else {
                reportAttachmentError("Files are still being read. Paste this attachment again when they are ready.", isQuickAsk: isQuickAsk)
                return true
            }
            preparePastedImage(image, isQuickAsk: isQuickAsk)
            return true
        }
        return false
    }

    private func preparePastedImage(_ image: NSImage, isQuickAsk: Bool) {
        guard !isQuickAsk || !isQuickAskStreaming else { return }
        let count = isQuickAsk ? quickDraftAttachments.count : draftAttachments.count
        guard count < MessageAttachmentIngestion.maximumAttachmentsPerMessage else {
            reportAttachmentError("Up to \(MessageAttachmentIngestion.maximumAttachmentsPerMessage) attachments are allowed per message.", isQuickAsk: isQuickAsk)
            return
        }
        guard let cgImage = ImageEncoding.cgImage(from: image) else {
            reportAttachmentError("The pasted image could not be prepared.", isQuickAsk: isQuickAsk)
            return
        }
        let requestID = UUID()
        if isQuickAsk {
            quickAttachmentRequestID = requestID
            isIngestingQuickAttachment = true
        } else {
            draftAttachmentRequestID = requestID
            isIngestingDraftAttachment = true
        }
        status = "Preparing pasted image…"
        let task = Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                ImageEncoding.jpegData(from: cgImage)
            }.value
            guard !Task.isCancelled, let self,
                  self.finishAttachmentIngestion(requestID: requestID, isQuickAsk: isQuickAsk) else {
                return
            }
            guard let data else {
                self.reportAttachmentError("The pasted image could not be prepared.", isQuickAsk: isQuickAsk)
                self.ingestQueuedFiles(isQuickAsk: isQuickAsk)
                return
            }
            let attachment = MessageAttachment(
                fileName: "Pasted image.jpg", mimeType: "image/jpeg",
                byteCount: data.count, extractedText: "", imageData: data
            )
            if isQuickAsk { self.attachQuickDraftAttachment(attachment) }
            else { self.attachDraftAttachment(attachment) }
            self.ingestQueuedFiles(isQuickAsk: isQuickAsk)
        }
        if isQuickAsk { quickAttachmentTask = task }
        else { draftAttachmentTask = task }
    }

    private func finishAttachmentIngestion(requestID: UUID, isQuickAsk: Bool) -> Bool {
        if isQuickAsk {
            guard quickAttachmentRequestID == requestID else { return false }
            quickAttachmentRequestID = nil
            quickAttachmentTask = nil
            isIngestingQuickAttachment = quickFilePromiseCount > 0
        } else {
            guard draftAttachmentRequestID == requestID else { return false }
            draftAttachmentRequestID = nil
            draftAttachmentTask = nil
            isIngestingDraftAttachment = draftFilePromiseCount > 0
        }
        return true
    }

    private func cancelAttachmentIngestion(isQuickAsk: Bool) {
        if isQuickAsk {
            quickFileDropGeneration = UUID()
            quickFilePromiseCount = 0
            queuedQuickFileURLs = []
            quickAttachmentRequestID = nil
            quickAttachmentTask?.cancel()
            quickAttachmentTask = nil
            isIngestingQuickAttachment = false
        } else {
            draftFileDropGeneration = UUID()
            draftFilePromiseCount = 0
            queuedDraftFileURLs = []
            draftAttachmentRequestID = nil
            draftAttachmentTask?.cancel()
            draftAttachmentTask = nil
            isIngestingDraftAttachment = false
        }
    }

    private func pasteboardFileName(fallback: String) -> String {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           let name = urls.first?.lastPathComponent, !name.isEmpty {
            return name
        }
        return fallback
    }

    nonisolated private static func isImageFile(_ url: URL) -> Bool {
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"
        ]
        return imageExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static func prepareFileAttachment(at url: URL) -> PreparedFileAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { return .document(try MessageAttachmentIngestion.read(fileAt: url)) }
        catch { return .failure("\(url.lastPathComponent): \(error.localizedDescription)") }
    }

    // MARK: opencode session health

    /// Reports, without modifying anything, opencode sessions whose stored
    /// attachments can make every provider request fail. The user decides
    /// what to repair from the Settings report.
    func scanOpencodeSessions() {
        guard !isScanningOpencodeSessions else { return }
        guard let databaseURL = OpenCodeSessionDoctor.defaultDatabaseURL() else {
            opencodeSessionFindings = []
            opencodeRepairStatus = "No opencode database was found on this Mac."
            return
        }
        isScanningOpencodeSessions = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let findings = try await Task.detached(priority: .utility) {
                    try OpenCodeSessionDoctor.scan(databaseURL: databaseURL)
                }.value
                self.opencodeSessionFindings = findings
                if findings.isEmpty {
                    self.opencodeRepairStatus = "No session-breaking attachments found."
                } else {
                    let sessions = Set(findings.map(\.sessionID)).count
                    self.opencodeRepairStatus = nil
                    self.status = "opencode: \(findings.count) session-breaking attachment(s) in \(sessions) session(s). Review them in Settings → Provider."
                }
            } catch {
                self.opencodeRepairStatus = error.localizedDescription
            }
            self.isScanningOpencodeSessions = false
        }
    }

    func repairOpencodeAttachment(_ finding: OpenCodePoisonedAttachment) {
        repair(findings: [finding], deleteSessions: false)
    }

    func deleteOpencodeSession(_ finding: OpenCodePoisonedAttachment) {
        repair(findings: [finding], deleteSessions: true)
    }

    func repairAllOpencodeFindings() {
        guard !opencodeSessionFindings.isEmpty else { return }
        repair(findings: opencodeSessionFindings, deleteSessions: false)
    }

    private func repair(findings: [OpenCodePoisonedAttachment], deleteSessions nuke: Bool) {
        guard let databaseURL = OpenCodeSessionDoctor.defaultDatabaseURL() else {
            opencodeRepairStatus = "No opencode database was found on this Mac."
            return
        }
        isScanningOpencodeSessions = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    let backupURL = try OpenCodeSessionDoctor.backup(databaseURL: databaseURL)
                    if nuke {
                        let removed = try OpenCodeSessionDoctor.deleteSessions(
                            findings.map(\.sessionID),
                            databaseURL: databaseURL
                        )
                        let remaining = try OpenCodeSessionDoctor.scan(databaseURL: databaseURL)
                        return (removed, backupURL, remaining)
                    }
                    let stripped = try OpenCodeSessionDoctor.stripAttachments(
                        findings, databaseURL: databaseURL
                    )
                    let remaining = try OpenCodeSessionDoctor.scan(databaseURL: databaseURL)
                    return (stripped, backupURL, remaining)
                }.value
                if nuke {
                    let removed = outcome.0
                    self.opencodeRepairStatus = "Deleted \(removed) opencode session(s). A backup was saved first."
                } else {
                    let stripped = outcome.0
                    self.opencodeRepairStatus = "Stripped \(stripped) attachment(s). A backup was saved first."
                }
                _ = outcome.1
                let remaining = outcome.2
                self.opencodeSessionFindings = remaining
                if remaining.isEmpty {
                    self.opencodeRepairStatus = (self.opencodeRepairStatus ?? "") + " No session-breaking attachments remain."
                }
            } catch {
                self.opencodeRepairStatus = error.localizedDescription
            }
            self.isScanningOpencodeSessions = false
        }
    }

    func explainQuickResponseSelection(
        capture selectedCapture: CapturedContent,
        parentMessageID: UUID,
        question: String
    ) {
        guard !isQuickAskStreaming,
              let selectedText = selectedCapture.text,
              let selection = TextInputPolicy.preparedMessage(
                  selectedText,
                  maximumUTF16Units: SelectionReader.maximumSelectionLength
              ),
              let parentIndex = quickMessages.firstIndex(where: {
                  $0.id == parentMessageID && $0.role == .assistant && !$0.isStreaming
              }) else { return }
        let parentResponse = quickMessages[parentIndex].content
        let surroundingMessages = quickMessages.enumerated().compactMap { index, message in
            index == parentIndex ? nil : message
        }
        let nextParentContext = PromptBuilder.recursiveParentContext(
            ancestorContext: quickParentContext,
            messages: surroundingMessages,
            response: parentResponse,
            selection: selection
        )
        quickChatAncestors.append(QuickChatSnapshot(
            id: quickLayerID,
            messages: quickMessages,
            selection: quickSelectionExcerpt,
            selectionKind: quickSelectionKind,
            parentContext: quickParentContext,
            error: quickAskError
        ))
        cancelAttachmentIngestion(isQuickAsk: true)
        quickMessages = []
        clearQuickMessageEdit()
        quickDraftImageData = nil
        quickDraftAttachments = []
        quickSelectionExcerpt = selection
        quickSelectionKind = selectedCapture.kind
        quickParentContext = nextParentContext
        quickAskError = nil
        quickDraft = TextInputPolicy.preparedMessage(question) ?? "Explain this."
        quickLayerDepth = quickChatAncestors.count
        quickLayerID = UUID()
        submitQuickAsk()
    }

    func explainConversationResponseSelection(
        capture selectedCapture: CapturedContent,
        parentMessageID: UUID,
        near point: NSPoint,
        question: String
    ) {
        guard !isStreaming,
              let selectedText = selectedCapture.text,
              let selection = TextInputPolicy.preparedMessage(
                  selectedText,
                  maximumUTF16Units: SelectionReader.maximumSelectionLength
              ),
              let parentIndex = messages.firstIndex(where: {
                  $0.id == parentMessageID && $0.role == .assistant && !$0.isStreaming
              }) else { return }
        let parentResponse = messages[parentIndex].content
        let surroundingMessages = messages.enumerated().compactMap { index, message in
            index == parentIndex ? nil : message
        }
        let parentContext = PromptBuilder.recursiveParentContext(
            ancestorContext: capture?.parentContext,
            messages: surroundingMessages,
            response: parentResponse,
            selection: selection
        )
        let nestedCapture = CapturedContent(
            kind: selectedCapture.kind,
            text: selection,
            applicationName: "Scholia",
            applicationBundleIdentifier: Bundle.main.bundleIdentifier,
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            windowTitle: "Chat response",
            selectionBounds: selectedCapture.selectionBounds,
            parentContext: parentContext
        )
        let normalizedQuestion = TextInputPolicy.preparedMessage(question)
        begin(
            capture: nestedCapture,
            near: point,
            automaticallyAsk: true,
            initialQuestion: normalizedQuestion ?? "Explain this."
        )
    }

    func returnToParentQuickChat() {
        guard let parent = quickChatAncestors.popLast() else { return }
        cancelQuickAsk()
        cancelAttachmentIngestion(isQuickAsk: true)
        clearQuickMessageEdit()
        quickAskPanel.hideResponseSelection()
        quickMessages = parent.messages
        quickSelectionExcerpt = parent.selection
        quickSelectionKind = parent.selectionKind
        quickParentContext = parent.parentContext
        quickAskError = parent.error
        quickDraft = ""
        quickDraftImageData = nil
        quickDraftAttachments = []
        quickLayerDepth = quickChatAncestors.count
        quickLayerID = parent.id
        status = "Returned to the previous Quick Chat explanation."
    }

    func cancelQuickAsk() {
        let assistantID = currentQuickAskAssistantID
        currentQuickAskRequestID = nil
        currentQuickAskAssistantID = nil
        quickAskTask?.cancel()
        quickAskTask = nil
        if let assistantID,
           let index = quickMessages.firstIndex(where: { $0.id == assistantID }) {
            quickMessages[index].isStreaming = false
            quickMessages[index].recordActivity("Stopped")
            quickMessages[index].metadata = "Stopped"
        }
        isQuickAskStreaming = false
    }

    func dismissQuickAsk() {
        cancelQuickAsk()
        cancelAttachmentIngestion(isQuickAsk: true)
        clearQuickMessageEdit()
        quickDraftImageData = nil
        quickDraftAttachments = []
        quickAskPanel.hideResponseSelection()
        quickAskPanel.hide()
        quickAskThinkingProfileOverride = nil
    }

    func quickChatWindowVisibilityDidChange(_ visible: Bool) {
        guard quickChatWindowVisible != visible else { return }
        quickChatWindowVisible = visible
        if visible { hasOpenedApplicationWindow = true }
        if !visible {
            cancelAttachmentIngestion(isQuickAsk: true)
            quickAskThinkingProfileOverride = nil
        }
        applyExplanationWindowBehavior()
    }

    func settingsWindowVisibilityDidChange(_ visible: Bool) {
        guard settingsWindowVisible != visible else { return }
        settingsWindowVisible = visible
        if visible { hasOpenedApplicationWindow = true }
        applyExplanationWindowBehavior()
    }

    func copyQuickAnswer() {
        guard !latestQuickAnswer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latestQuickAnswer, forType: .string)
        status = "Quick answer copied."
    }

    func moveQuickAskToChat() {
        guard !isQuickAskStreaming,
              quickMessages.contains(where: { $0.role == .user }),
              quickMessages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        persistCurrentConversation()
        cancelResponse()
        clearMessageEdit()
        clearQuickMessageEdit()
        cancelAttachmentIngestion(isQuickAsk: false)
        cancelAttachmentIngestion(isQuickAsk: true)
        capture = activeQuickCapture
        conversationContextEnabled = quickContextEnabled
        conversationCompactContextEnabled = quickCompactContextEnabled
        currentConversationID = UUID()
        currentConversationCreatedAt = Date()
        messages = quickMessages.compactMap { message in
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var copy = message
            copy.isStreaming = false
            return copy
        }
        errorMessage = nil
        draft = ""
        draftImageData = nil
        draftAttachments = []
        quickDraftImageData = nil
        quickDraftAttachments = []
        persistCurrentConversation()
        quickAskPanel.hide()
        explanationPanel.show(near: NSEvent.mouseLocation)
        status = "Quick chat moved to saved chat."
    }

    private func finishCancelledQuickAsk(assistantID: UUID) {
        if let index = quickMessages.firstIndex(where: { $0.id == assistantID }) {
            quickMessages[index].isStreaming = false
            quickMessages[index].recordActivity("Stopped")
            quickMessages[index].metadata = "Stopped"
        }
        isQuickAskStreaming = false
        currentQuickAskRequestID = nil
        currentQuickAskAssistantID = nil
        quickAskTask = nil
    }

    func setQuickAskModel(_ modelID: String, for providerID: String? = nil) {
        let normalized = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let targetProviderID = providerID ?? activeQuickAskProvider.id
        var values = settings.quickAskModels ?? [:]
        values[targetProviderID] = String(normalized.prefix(200))
        settings.quickAskModels = values
        if let providerID {
            settings.quickAskProviderID = providerID == settings.providerID ? nil : providerID
        }
        persistSettings()
    }

    func setQuickAskProvider(_ providerID: String) {
        let normalized = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ProviderCatalog.providers.contains(where: { $0.id == normalized }) else { return }
        settings.quickAskProviderID = normalized
        persistSettings()
    }

    func matchQuickAskModelToExplain() {
        var values = settings.quickAskModels ?? [:]
        values.removeValue(forKey: activeQuickAskProvider.id)
        settings.quickAskModels = values
        settings.quickAskProviderID = nil
        persistSettings()
    }

    func setQuickAskReasoningEffort(_ effort: String) {
        setQuickAskThinkingReasoningEffort(effort)
    }

    func setQuickAskThinkingProfile(_ profile: QuickAskThinkingProfile) {
        guard quickAskThinkingProfileIsAvailable(profile, provider: activeQuickAskProvider) else {
            status = "\(profile.label) thinking is unavailable for its selected model."
            return
        }
        quickAskThinkingProfileOverride = profile
        status = "Quick Chat thinking profile for this session: \(profile.label)."
    }

    func setDefaultQuickAskThinkingProfile(_ profile: QuickAskThinkingProfile) {
        guard quickAskThinkingProfileIsAvailable(profile, provider: activeQuickAskProvider) else {
            status = "\(profile.label) thinking is unavailable for its selected model."
            return
        }
        var values = settings.quickAskActiveThinkingProfiles ?? [:]
        values[activeQuickAskProvider.id] = profile.rawValue
        settings.quickAskActiveThinkingProfiles = values
        persistSettings()
        if !quickChatWindowVisible { quickAskThinkingProfileOverride = nil }
        status = "Default Quick Chat thinking profile: \(profile.label)."
    }

    func cycleQuickAskThinkingProfile(reverse: Bool = false) {
        guard !isQuickAskStreaming else { return }
        let available = Set(availableQuickAskThinkingProfiles(for: activeQuickAskProvider))
        guard let candidate = activeQuickAskThinkingProfile.advanced(
            reverse: reverse,
            among: available
        ) else { return }
        setQuickAskThinkingProfile(candidate)
    }

    func setQuickAskThinkingModel(
        _ modelID: String?,
        for profile: QuickAskThinkingProfile? = nil,
        providerID: String? = nil
    ) {
        guard !isQuickAskStreaming else { return }
        let targetProviderID = providerID ?? activeQuickAskProvider.id
        guard ProviderCatalog.providers.contains(where: { $0.id == targetProviderID }) else { return }
        let targetProfile = profile ?? activeQuickAskThinkingProfile
        var allProfiles = settings.quickAskThinkingProfiles ?? [:]
        var providerProfiles = allProfiles[targetProviderID] ?? [:]
        var configuration = providerProfiles[targetProfile.rawValue]
            ?? QuickAskThinkingProfileConfiguration()
        let normalized = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        configuration.modelID = normalized.isEmpty ? nil : String(normalized.prefix(200))
        let resolvedModelID = configuration.modelID
            ?? settings.resolvedQuickAskModel(for: ProviderCatalog.provider(id: targetProviderID))
        if let configuredEffort = configuration.reasoningEffort,
           modelDefinition(
            for: ProviderCatalog.provider(id: targetProviderID),
            id: resolvedModelID
           )?.reasoningEfforts.contains(configuredEffort) != true {
            configuration.reasoningEffort = nil
        }
        if configuration.modelID == nil && configuration.reasoningEffort == nil {
            providerProfiles.removeValue(forKey: targetProfile.rawValue)
        } else {
            providerProfiles[targetProfile.rawValue] = configuration
        }
        if providerProfiles.isEmpty { allProfiles.removeValue(forKey: targetProviderID) }
        else { allProfiles[targetProviderID] = providerProfiles }
        settings.quickAskThinkingProfiles = allProfiles
        if let providerID {
            settings.quickAskProviderID = providerID == settings.providerID ? nil : providerID
        }
        persistSettings()
    }

    func setQuickAskThinkingReasoningEffort(
        _ effort: String?,
        for profile: QuickAskThinkingProfile? = nil,
        providerID: String? = nil
    ) {
        guard !isQuickAskStreaming else { return }
        let targetProvider = ProviderCatalog.provider(id: providerID ?? activeQuickAskProvider.id)
        let targetProfile = profile ?? activeQuickAskThinkingProfile
        let normalized = effort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalized.isEmpty {
            let modelID = settings.resolvedQuickAskThinkingModel(
                for: targetProfile,
                provider: targetProvider
            )
            guard modelDefinition(for: targetProvider, id: modelID)?
                .reasoningEfforts.contains(normalized) == true else {
                return
            }
        }
        var allProfiles = settings.quickAskThinkingProfiles ?? [:]
        var providerProfiles = allProfiles[targetProvider.id] ?? [:]
        var configuration = providerProfiles[targetProfile.rawValue]
            ?? QuickAskThinkingProfileConfiguration()
        configuration.reasoningEffort = normalized.isEmpty ? nil : normalized
        if configuration.modelID == nil && configuration.reasoningEffort == nil {
            providerProfiles.removeValue(forKey: targetProfile.rawValue)
        } else {
            providerProfiles[targetProfile.rawValue] = configuration
        }
        if providerProfiles.isEmpty { allProfiles.removeValue(forKey: targetProvider.id) }
        else { allProfiles[targetProvider.id] = providerProfiles }
        settings.quickAskThinkingProfiles = allProfiles
        persistSettings()
    }

    func matchQuickAskReasoningEffortToExplain() {
        var values = settings.quickAskReasoningEfforts ?? [:]
        values.removeValue(forKey: activeQuickAskProvider.id)
        settings.quickAskReasoningEfforts = values
        setQuickAskThinkingReasoningEffort(nil)
    }

    func newConversation() {
        persistCurrentConversation()
        cancelResponse()
        cancelAttachmentIngestion(isQuickAsk: false)
        clearMessageEdit()
        capture = nil
        messages = []
        errorMessage = nil
        draft = ""
        draftImageData = nil
        draftAttachments = []
        conversationContextEnabled = true
        conversationCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        currentConversationID = nil
        currentConversationCreatedAt = nil
        explanationPanel.show(near: NSEvent.mouseLocation)
    }

    func closeConversation() {
        persistCurrentConversation()
        cancelAttachmentIngestion(isQuickAsk: false)
        explanationPanel.hide()
    }

    func openSavedConversation(_ id: UUID) {
        guard let conversation = savedConversations.first(where: { $0.id == id }) else { return }
        persistCurrentConversation()
        cancelResponse()
        cancelAttachmentIngestion(isQuickAsk: false)
        clearMessageEdit()
        currentConversationID = conversation.id
        currentConversationCreatedAt = conversation.createdAt
        capture = conversation.restoredCapture
        conversationContextEnabled = conversation.contextEnabled
            ?? true
        conversationCompactContextEnabled = conversation.compactContextEnabled
            ?? settings.resolvedUseVisibleWorkspaceContext
        messages = conversation.messages
        errorMessage = nil
        draft = ""
        draftImageData = nil
        draftAttachments = []
        explanationPanel.show(near: NSEvent.mouseLocation)
    }

    func deleteSavedConversation(_ id: UUID) {
        savedConversations.removeAll { $0.id == id }
        if currentConversationID == id {
            currentConversationID = nil
            currentConversationCreatedAt = nil
            cancelResponse()
            cancelAttachmentIngestion(isQuickAsk: false)
            clearMessageEdit()
            capture = nil
            messages = []
            errorMessage = nil
            draft = ""
            draftImageData = nil
            draftAttachments = []
            conversationContextEnabled = true
            conversationCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        }
        saveConversationHistory()
    }

    func clearSavedConversations() {
        cancelResponse()
        cancelAttachmentIngestion(isQuickAsk: false)
        clearMessageEdit()
        savedConversations = []
        currentConversationID = nil
        currentConversationCreatedAt = nil
        capture = nil
        messages = []
        errorMessage = nil
        draft = ""
        draftImageData = nil
        draftAttachments = []
        conversationContextEnabled = true
        conversationCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        // Clearing shares the write queue so an older in-flight save cannot
        // recreate deleted history after this operation completes.
        saveConversationHistory()
    }

    func askDraft() {
        guard !isIngestingDraftAttachment else { return }
        if canExplainCapturedImageDirectly {
            ask("Explain this image.")
            return
        }
        guard let question = preparedQuestion(
            draft,
            hasImage: draftImageData != nil || draftAttachments.contains(where: \.isImage),
            hasAttachments: draftAttachments.contains { !$0.isImage }
        ) else { return }
        let imageData = draftImageData
        let attachments = draftAttachments
        draft = ""
        draftImageData = nil
        draftAttachments = []
        ask(
            question,
            imageData: imageData,
            imageMimeType: imageData == nil ? nil : "image/jpeg",
            attachments: attachments.isEmpty ? nil : attachments
        )
    }

    var canExplainCapturedImageDirectly: Bool {
        capture?.kind == .image
            && capture?.imageData != nil
            && messages.isEmpty
            && TextInputPolicy.preparedMessage(draft) == nil
            && draftImageData == nil
            && draftAttachments.isEmpty
    }

    func beginEditingMessage(_ messageID: UUID) {
        guard !isStreaming,
              let message = messages.first(where: { $0.id == messageID && $0.role == .user }) else {
            return
        }
        editingMessageID = messageID
        messageEditDraft = message.content
    }

    func cancelMessageEdit() {
        clearMessageEdit()
    }

    func resendEditedMessage() {
        guard !isStreaming,
              let editingMessageID,
              let prepared = ConversationEditor.prepareResend(
                  messages: messages,
                  messageID: editingMessageID,
                  rawQuestion: messageEditDraft
              ) else { return }
        messages = prepared.precedingMessages
        clearMessageEdit()
        ask(
            prepared.question,
            imageData: prepared.imageData,
            imageMimeType: prepared.imageMimeType,
            attachments: prepared.attachments
        )
    }

    func ask(
        _ rawQuestion: String,
        imageData: Data? = nil,
        imageMimeType: String? = nil,
        attachments: [MessageAttachment]? = nil
    ) {
        guard !isStreaming,
              let question = preparedQuestion(
                rawQuestion,
                hasImage: imageData != nil,
                hasAttachments: attachments?.isEmpty == false
              ) else { return }
        clearMessageEdit()
        errorMessage = nil

        let user = ConversationMessage(
            role: .user,
            content: question,
            imageData: imageData,
            imageMimeType: imageMimeType,
            attachments: attachments
        )
        messages.append(user)
        let requestMessages = messages
        let assistantID = UUID()
        messages.append(ConversationMessage(id: assistantID, role: .assistant, content: "", isStreaming: true))
        isStreaming = true
        if currentConversationID == nil { currentConversationID = UUID() }
        if currentConversationCreatedAt == nil { currentConversationCreatedAt = Date() }
        persistCurrentConversation()

        let configuration: ProviderConfiguration
        do {
            configuration = try providerConfiguration(allowLocalFiles: true)
        } catch {
            messages.removeAll { $0.id == assistantID }
            isStreaming = false
            errorMessage = error.localizedDescription
            status = error.localizedDescription
            persistCurrentConversation()
            return
        }

        activeTask?.cancel()
        let requestID = UUID()
        currentRequestID = requestID
        let baseRequestCapture = capture
        let preferredPID = applicationTracker.preferredPID
        let useAutomaticContext = conversationContextEnabled
        let useCompactContext = conversationCompactContextEnabled
        activeTask = Task { [weak self] in
            guard let self else { return }
            let responseStartedAt = Date()
            defer { refreshCodexUsageAfterResponse(configuration) }
            do {
                recordChatActivity(assistantID, quick: false, title: "Preparing request")
                for attachment in attachments ?? [] where attachment.includedInContext { recordChatActivity(assistantID, quick: false, title: attachment.readStatusLabel, detail: attachment.fileName) }
                if useAutomaticContext { recordChatActivity(assistantID, quick: false, title: "Reading visible application context") }
                let workspaceContext = useAutomaticContext && useCompactContext
                    ? await SelectionReader.captureVisibleWorkspaceContextAsync(
                        question: question,
                        preferredPID: preferredPID
                    )
                    : nil
                let fullApplicationContext = useAutomaticContext && !useCompactContext
                    ? SelectionReader.captureApplicationContext(preferredPID: preferredPID)
                    : nil
                guard !Task.isCancelled else { throw CancellationError() }
                let requestCapture = VisibleWorkspaceContext.requestCapture(
                    baseRequestCapture,
                    workspaceContext: workspaceContext,
                    automaticContextEnabled: useAutomaticContext,
                    compactContextEnabled: useCompactContext,
                    fullApplicationContext: fullApplicationContext
                )
                try await self.ensureLocalProvider(configuration)
                recordChatActivity(assistantID, quick: false, title: "Context prepared", detail: requestCapture?.applicationName)
                let result = try await providerClient.complete(
                    capture: requestCapture,
                    messages: requestMessages,
                    configuration: configuration,
                    onProgress: { [weak self] progress in
                        guard let self, self.currentRequestID == requestID else { return }
                        self.recordChatActivity(assistantID, quick: false, title: progress)
                    }
                ) { [weak self] token in
                    guard let self, self.currentRequestID == requestID,
                          let index = self.messages.firstIndex(where: { $0.id == assistantID }) else { return }
                    self.messages[index].content += token
                    self.messages[index].recordActivity("Writing answer…")
                }
                guard currentRequestID == requestID else { return }
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { recordModelUse(configuration) }
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].content = result.text
                    messages[index].reasoning = result.reasoning
                    messages[index].usage = result.usage
                    messages[index].responseDurationSeconds = Date().timeIntervalSince(responseStartedAt)
                    messages[index].isStreaming = false
                    messages[index].recordActivity("Answer complete", detail: result.model)
                    messages[index].metadata = "\(result.providerName) · \(result.model)"
                }
                isStreaming = false
                currentRequestID = nil
                status = requestCapture?.kind == .mail ? "Reply draft ready." : "Explanation ready."
                persistCurrentConversation()
            } catch is CancellationError {
                guard currentRequestID == requestID else { return }
                finishCancelledResponse(assistantID: assistantID)
            } catch {
                guard currentRequestID == requestID else { return }
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index].recordActivity("Response interrupted", detail: error.localizedDescription)
                    if messages[index].content.isEmpty && messages[index].activity?.isEmpty != false { messages.remove(at: index) }
                    else {
                        messages[index].isStreaming = false
                        messages[index].metadata = "Response interrupted"
                    }
                }
                isStreaming = false
                currentRequestID = nil
                errorMessage = error.localizedDescription
                status = error.localizedDescription
                if let providerError = error as? ProviderClientError,
                   case .sessionHistoryPoisoned = providerError {
                    scanOpencodeSessions()
                }
                persistCurrentConversation()
            }
        }
    }

    func retryLastQuestion() {
        guard !isStreaming,
              let index = messages.lastIndex(where: { $0.role == .user }) else { return }
        let question = messages[index].content
        let imageData = messages[index].imageData
        let imageMimeType = messages[index].imageMimeType
        let attachments = messages[index].attachments
        messages.removeSubrange(index...)
        ask(
            question,
            imageData: imageData,
            imageMimeType: imageMimeType,
            attachments: attachments
        )
    }

    func cancelResponse() {
        guard isStreaming else { return }
        let requestID = currentRequestID
        currentRequestID = nil
        activeTask?.cancel()
        activeTask = nil
        if requestID != nil,
           let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
            messages[index].recordActivity("Stopped")
            messages[index].metadata = "Stopped"
        }
        isStreaming = false
        status = "Stopped."
        persistCurrentConversation()
    }

    func copyLatestAnswer() {
        guard let answer = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty })?.content else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
        status = "Answer copied."
    }

    func returnToSource() {
        guard let pid = capture?.applicationPID,
              let application = NSRunningApplication(processIdentifier: pid) else { return }
        application.activate()
    }

    func persistSettings() {
        settings.normalize()
        localFileAccessPolicy.update(
            read: settings.resolvedLocalFileAccessEnabled,
            write: settings.resolvedLocalFileWriteAccessEnabled
        )
        AppSettingsStore.save(settings)
        refreshPermissions()
    }

    func setSelectionPillEnabled(_ enabled: Bool) {
        settings.showSelectionPill = enabled
        persistSettings()
        if started { registerHotKeys() }
        status = enabled
            ? "Selection Explain is enabled by default."
            : "Selection Explain is handed off to the foreground app by default."
    }

    func setCaptureRegionEnabled(_ enabled: Bool) {
        settings.captureRegionEnabled = enabled
        persistSettings()
        if started { registerHotKeys() }
        status = enabled
            ? "The native screen-region shortcut is enabled by default."
            : "The screen-region shortcut is handed off to the foreground app by default."
    }

    func setSelectionPillEnabledForActiveApplication(_ enabled: Bool) {
        guard let application = activeApplication,
              let bundleIdentifier = application.bundleIdentifier else {
            status = "The active application does not expose an identifier that Scholia can remember."
            return
        }
        setSelectionPillEnabled(
            enabled,
            for: bundleIdentifier,
            applicationName: application.name
        )
    }

    func setSelectionPillEnabled(
        _ enabled: Bool,
        for bundleIdentifier: String,
        applicationName: String
    ) {
        settings.setSelectionPillEnabled(
            enabled,
            for: bundleIdentifier,
            applicationName: applicationName
        )
        persistSettings()
        if !enabled, activeApplication?.bundleIdentifier == bundleIdentifier {
            selectionPill.hide()
        }
        if started { registerHotKeys() }
        status = enabled
            ? "Selection Explain enabled for \(applicationName)."
            : "Selection Explain handed off in \(applicationName)."
    }

    func setCaptureRegionEnabledForActiveApplication(_ enabled: Bool) {
        guard let application = activeApplication,
              let bundleIdentifier = application.bundleIdentifier else {
            status = "The active application does not expose an identifier that Scholia can remember."
            return
        }
        setCaptureRegionEnabled(
            enabled,
            for: bundleIdentifier,
            applicationName: application.name
        )
    }

    func setCaptureRegionEnabled(
        _ enabled: Bool,
        for bundleIdentifier: String,
        applicationName: String
    ) {
        settings.setCaptureRegionEnabled(
            enabled,
            for: bundleIdentifier,
            applicationName: applicationName
        )
        persistSettings()
        if started { registerHotKeys() }
        status = enabled
            ? "Native screen-region capture enabled for \(applicationName)."
            : "Screen-region capture handed off in \(applicationName)."
    }

    func removeSelectionPopupPreference(
        for bundleIdentifier: String,
        applicationName: String
    ) {
        settings.removeSelectionPopupPreference(for: bundleIdentifier)
        persistSettings()
        if activeApplication?.bundleIdentifier == bundleIdentifier,
           !selectionPillIsEnabledForActiveApplication {
            selectionPill.hide()
        }
        if started { registerHotKeys() }
        status = "\(applicationName) now follows both default desktop integration settings."
    }

    func removeActiveApplicationSelectionPopupPreference() {
        guard let application = activeApplication,
              let bundleIdentifier = application.bundleIdentifier else { return }
        removeSelectionPopupPreference(
            for: bundleIdentifier,
            applicationName: application.name
        )
    }

    func toggleSelectionPill() {
        if canConfigureActiveApplication {
            setSelectionPillEnabledForActiveApplication(!selectionPillIsEnabledForActiveApplication)
        } else {
            setSelectionPillEnabled(!settings.showSelectionPill)
        }
    }

    func setKeepExplanationWindowOnTop(_ enabled: Bool) {
        settings.keepExplanationWindowOnTop = enabled
        persistSettings()
        applyExplanationWindowBehavior()
        status = enabled
            ? "Explanation windows stay above other windows."
            : "Explanation windows use the normal window level."
    }

    func setShowExplanationWindowInWindowSwitcher(_ enabled: Bool) {
        settings.showExplanationWindowInWindowSwitcher = enabled
        persistSettings()
        applyExplanationWindowBehavior()
        status = enabled
            ? "Scholia explanations now participate in normal window switching."
            : "Scholia is back to menu-bar-only window switching behavior."
    }

    private func rememberSelectionPopupOffset(_ offset: CGSize) {
        settings.selectionPopupOffsetX = Double(offset.width.rounded())
        settings.selectionPopupOffsetY = Double(offset.height.rounded())
        settings.normalize()
        AppSettingsStore.save(settings)
    }

    @discardableResult
    func setShortcut(_ shortcut: KeyboardShortcut, for action: GlobalAction) -> Bool {
        guard shortcut.isValid else {
            status = "Use Command, Option, or Control in a shortcut (or choose a function key)."
            return false
        }
        let existing: [GlobalAction: KeyboardShortcut] = [
            .explainSelection: settings.resolvedExplainShortcut,
            .captureRegion: settings.resolvedCaptureShortcut,
            .quickAsk: settings.resolvedQuickAskShortcut,
            .toggleSelectionPopup: settings.resolvedToggleSelectionPopupShortcut
        ]
        guard !existing.contains(where: { $0.key != action && $0.value == shortcut }) else {
            status = "Choose a different shortcut for each action."
            return false
        }
        switch action {
        case .explainSelection: settings.explainShortcut = shortcut
        case .captureRegion: settings.captureShortcut = shortcut
        case .quickAsk: settings.quickAskShortcut = shortcut
        case .toggleSelectionPopup: settings.toggleSelectionPopupShortcut = shortcut
        }
        settings.normalize()
        AppSettingsStore.save(settings)
        registerHotKeys()
        status = hotKeysAvailable
            ? "Shortcut changed to \(shortcut.displayName)."
            : "\(shortcut.displayName) is already in use by another app."
        return true
    }

    func resetShortcuts() {
        settings.explainShortcut = .explainDefault
        settings.captureShortcut = .captureDefault
        settings.quickAskShortcut = .quickAskDefault
        settings.toggleSelectionPopupShortcut = .toggleSelectionPopupDefault
        settings.normalize()
        AppSettingsStore.save(settings)
        registerHotKeys()
        status = hotKeysAvailable
            ? "Default shortcuts restored."
            : "One of the default shortcuts is already in use by another app."
    }

    func apiKey(for providerID: String) -> String {
        (try? ProviderKeychain.value(for: providerID)) ?? ""
    }

    func saveAPIKey(_ value: String, for providerID: String) throws {
        let previous = (try? ProviderKeychain.value(for: providerID)) ?? ""
        try ProviderKeychain.set(value, for: providerID)
        if previous != value {
            if modelVerification.activeTest?.target.providerID == providerID { cancelModelTest() }
            modelVerification.invalidate(providerID: providerID)
            settings.removeModelVerification(providerID: providerID)
            persistSettings()
        }
        status = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Credential removed from Keychain."
            : "Credential saved in Keychain."
    }

    func testActiveProvider(apiKeyOverride: String? = nil) {
        testModel(activeModel, providerID: activeProvider.id, apiKeyOverride: apiKeyOverride)
    }

    func testModel(_ modelID: String, providerID: String, apiKeyOverride: String? = nil) {
        guard !isTestingProvider else { return }
        persistSettings()
        let provider = ProviderCatalog.provider(id: providerID)
        let target = modelTestTarget(modelID, for: provider)
        guard let attempt = modelVerification.begin(target) else { return }
        providerTestStatus = "Testing \(provider.name) · \(target.modelID)…"
        let configuration: ProviderConfiguration
        do {
            configuration = try providerConfiguration(
                apiKeyOverride: apiKeyOverride,
                modelOverride: target.modelID,
                reasoningEffortOverride: settings.reasoningEfforts[providerID],
                providerOverride: provider
            )
        } catch {
            finishModelTest(attempt, status: .failed(error.localizedDescription))
            return
        }
        providerTestTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureLocalProvider(configuration, updatesStatus: false)
                try Task.checkCancellation()
                _ = try await providerClient.complete(
                    capture: nil,
                    messages: [ConversationMessage(role: .user, content: "Reply with OK only.")],
                    configuration: configuration,
                    onToken: { _ in }
                )
                try Task.checkCancellation()
                finishModelTest(attempt, status: .verified(Date()))
            } catch {
                finishModelTest(attempt, status: Task.isCancelled ? .cancelled : .failed(error.localizedDescription))
            }
            if configuration.provider.id == "opencode", !Task.isCancelled {
                scanOpencodeSessions()
            }
        }
    }

    private func finishModelTest(_ attempt: ModelVerificationState.Attempt, status: ModelTestStatus) {
        guard modelVerification.finish(attempt, status: status, settings: &settings) else { return }
        providerTestTask = nil
        persistSettings()
        let name = "\(ProviderCatalog.provider(id: attempt.target.providerID).name) · \(attempt.target.modelID)"
        switch status {
        case .verified:
            providerTestStatus = "Verified \(name). Ready to select in the model picker."
        case .failed(let message):
            providerTestStatus = "\(name): \(message)"
        case .cancelled:
            providerTestStatus = "Test cancelled for \(name)."
        case .testing:
            break
        }
    }

    func cancelModelTest() {
        guard let attempt = modelVerification.activeTest else { return }
        providerTestTask?.cancel()
        finishModelTest(attempt, status: .cancelled)
    }

    func startActiveBridge() {
        startBridge(for: activeProvider)
    }

    private func startBridge(for provider: ProviderDefinition) {
        guard provider.bridge != nil else { return }
        let isPrimary = provider.id == activeProvider.id
        if isPrimary, isStartingBridge { return }
        let configuration: ProviderConfiguration
        do {
            configuration = try providerConfiguration(providerOverride: provider)
        } catch {
            if isPrimary { providerTestStatus = error.localizedDescription }
            return
        }
        bridgeTasks[provider.id]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureLocalProvider(configuration, updatesStatus: isPrimary)
            } catch is CancellationError {
                return
            } catch {
                self.bridgeReadyProviderIDs.remove(provider.id)
                if isPrimary {
                    self.isStartingBridge = false
                    self.providerTestStatus = error.localizedDescription
                    self.status = error.localizedDescription
                }
            }
        }
        bridgeTasks[provider.id] = task
        if isPrimary { bridgeTask = task }
    }

    func prepareActiveLocalProvider() {
        prepareLocalProvider(activeProvider)
        if quickAskProviderIsOverridden, activeQuickAskProvider.id != activeProvider.id {
            prepareLocalProvider(activeQuickAskProvider)
        }
    }

    private func prepareLocalProvider(_ provider: ProviderDefinition) {
        if provider.id == "codex" || provider.id == "claudecode" {
            if !bridgeReadyProviderIDs.contains(provider.id) { startBridge(for: provider) }
        } else if provider.bridge != nil {
            refreshBridgeStatus(for: provider, showProgress: false)
        }
    }

    func refreshActiveBridgeStatus(showProgress: Bool = true) {
        refreshBridgeStatus(for: activeProvider, showProgress: showProgress)
    }

    private func refreshBridgeStatus(for provider: ProviderDefinition, showProgress: Bool) {
        guard let bridge = provider.bridge else {
            bridgeReadyProviderIDs.remove(provider.id)
            isStartingBridge = false
            return
        }
        let endpoint = settings.endpoints[provider.id] ?? provider.endpoint
        let apiKey = (try? ProviderKeychain.value(for: provider.id)) ?? ""
        bridgeStatusTasks[provider.id]?.cancel()
        if showProgress { providerTestStatus = "Checking \(bridge.label)…" }
        bridgeStatusTasks[provider.id] = Task { [weak self] in
            guard let self else { return }
            let health = await self.bridgeManager.check(provider: provider, endpoint: endpoint, apiKey: apiKey)
            guard !Task.isCancelled, self.activeProvider.id == provider.id
                    || self.activeQuickAskProvider.id == provider.id else { return }
            if let health {
                self.bridgeReadyProviderIDs.insert(provider.id)
                if provider.id == self.activeProvider.id {
                    self.providerTestStatus = self.bridgeReadyMessage(bridge: bridge, health: health)
                }
                self.scheduleModelCatalogRefresh(
                    provider: provider,
                    endpoint: endpoint,
                    apiKey: apiKey,
                    force: showProgress
                )
            } else {
                self.bridgeReadyProviderIDs.remove(provider.id)
                if showProgress, provider.id == self.activeProvider.id {
                    self.providerTestStatus = "\(bridge.label) is not running."
                }
            }
        }
    }

    func refreshModelCatalogs() {
        for provider in ProviderCatalog.providers where ["codex", "opencode"].contains(provider.id) {
            scheduleModelCatalogRefresh(provider: provider,
                endpoint: settings.endpoints[provider.id] ?? provider.endpoint,
                apiKey: (try? ProviderKeychain.value(for: provider.id)) ?? "")
        }
    }

    private func scheduleModelCatalogRefresh(
        provider: ProviderDefinition,
        endpoint: String,
        apiKey: String,
        force: Bool = false
    ) {
        guard ["opencode", "codex"].contains(provider.id) else { return }
        let now = Date()
        if !force,
           modelCatalogEndpoints[provider.id] == endpoint,
           let checkedAt = modelCatalogCheckedAt[provider.id],
           now.timeIntervalSince(checkedAt) < 2 * 60 {
            return
        }
        if modelCatalogTasks[provider.id] != nil, modelCatalogEndpoints[provider.id] == endpoint { return }

        modelCatalogTasks[provider.id]?.cancel()
        let requestID = UUID()
        modelCatalogRequestIDs[provider.id] = requestID
        modelCatalogEndpoints[provider.id] = endpoint
        modelCatalogTasks[provider.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.modelCatalogRequestIDs[provider.id] == requestID {
                    self.modelCatalogRequestIDs[provider.id] = nil
                    self.modelCatalogTasks[provider.id] = nil
                }
            }
            do {
                let models = try await self.bridgeManager.discoverModels(
                    provider: provider,
                    endpoint: endpoint,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, self.modelCatalogRequestIDs[provider.id] == requestID,
                      (self.settings.endpoints[provider.id] ?? provider.endpoint) == endpoint else { return }
                self.discoveredProviderModels[provider.id] = models
                let selected = self.settings.models[provider.id] ?? provider.defaultModel
                let resolved = ProviderCatalog.resolvedModelID(
                    selected,
                    for: provider.id,
                    candidates: models
                )
                if resolved != selected {
                    self.settings.models[provider.id] = resolved
                    self.persistSettings()
                }
                self.modelCatalogCheckedAt[provider.id] = Date()
            } catch is CancellationError {
                return
            } catch {
                guard self.modelCatalogRequestIDs[provider.id] == requestID else { return }
                self.modelCatalogCheckedAt[provider.id] = Date()
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLoginAvailable else {
            settings.launchAtLogin = false
            status = "Build and open Scholia.app before enabling launch at login."
            persistSettings()
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            persistSettings()
            status = enabled ? "Scholia will open at login." : "Launch at login is off."
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            status = "Launch at login: \(error.localizedDescription)"
        }
    }

    private func perform(_ action: GlobalAction) {
        switch action {
        case .explainSelection: explainSelectedText()
        case .captureRegion: captureRegion()
        case .quickAsk: showQuickAsk()
        case .toggleSelectionPopup: toggleSelectionPill()
        }
    }

    private func externalApplicationDidChange(_ application: ExternalApplication?) {
        activeApplication = application
        if started {
            selectionPill.hide()
            registerHotKeys()
            if contextualShortcutsDeferredForActiveApplication {
                status = deferredShortcutStatus()
            } else if hotKeysAvailable {
                status = "Desktop Explain and region shortcuts are active in \(application?.name ?? "the active application")."
            } else {
                status = "One or more desktop shortcuts are in use by another app."
            }
        }
    }

    private func applyExplanationWindowBehavior() {
        let participatesInWindowSwitcher = settings.resolvedShowExplanationWindowInWindowSwitcher
        NSApp.setActivationPolicy(scholiaApplicationActivationPolicy(
            explanationWindowParticipates: participatesInWindowSwitcher,
            quickChatWindowVisible: quickChatWindowVisible,
            settingsWindowVisible: settingsWindowVisible,
            studyWindowVisible: studyWindowVisible,
            hasOpenedApplicationWindow: hasOpenedApplicationWindow
        ))
        explanationPanel.updateWindowBehavior(
            alwaysOnTop: settings.resolvedKeepExplanationWindowOnTop,
            participatesInWindowSwitcher: participatesInWindowSwitcher
        )
    }

    private func registerHotKeys() {
        hotKeysAvailable = hotKeys.start(
            explainShortcut: settings.resolvedExplainShortcut,
            captureShortcut: settings.resolvedCaptureShortcut,
            quickAskShortcut: settings.resolvedQuickAskShortcut,
            toggleSelectionPopupShortcut: settings.resolvedToggleSelectionPopupShortcut,
            enabledActions: scholiaGlobalActions(
                selectionExplainEnabled: selectionPillIsEnabledForActiveApplication,
                captureRegionEnabled: captureRegionIsEnabledForActiveApplication
            )
        ) { [weak self] action in
            self?.perform(action)
        }
    }

    private func deferredShortcutStatus() -> String {
        let applicationName = activeApplication?.name ?? "the active application"
        switch (
            selectionPillIsEnabledForActiveApplication,
            captureRegionIsEnabledForActiveApplication
        ) {
        case (false, false):
            return "Selection Explain and screen-region shortcuts are handed off in \(applicationName)."
        case (false, true):
            return "Selection Explain is handed off in \(applicationName); native screen-region capture stays active."
        case (true, false):
            return "Screen-region capture is handed off in \(applicationName); native Selection Explain stays active."
        case (true, true):
            return "Desktop Explain and region shortcuts are active in \(applicationName)."
        }
    }

    private func ensureLocalProvider(_ configuration: ProviderConfiguration, updatesStatus: Bool = true) async throws {
        guard let bridge = configuration.provider.bridge else { return }
        if bridgeReadyProviderIDs.contains(configuration.provider.id) {
            scheduleModelCatalogRefresh(
                provider: configuration.provider,
                endpoint: configuration.endpoint,
                apiKey: configuration.apiKey
            )
            return
        }
        if updatesStatus {
            isStartingBridge = true
            bridgeReadyProviderIDs.remove(configuration.provider.id)
            providerTestStatus = "Starting \(bridge.label)…"
        }
        do {
            let health = try await bridgeManager.ensureRunning(
                provider: configuration.provider,
                endpoint: configuration.endpoint,
                apiKey: configuration.apiKey
            )
            scheduleModelCatalogRefresh(
                provider: configuration.provider,
                endpoint: configuration.endpoint,
                apiKey: configuration.apiKey
            )
            bridgeReadyProviderIDs.insert(configuration.provider.id)
            if updatesStatus {
                isStartingBridge = false
                providerTestStatus = bridgeReadyMessage(bridge: bridge, health: health)
            }
        } catch {
            bridgeReadyProviderIDs.remove(configuration.provider.id)
            if updatesStatus {
                isStartingBridge = false
                providerTestStatus = error.localizedDescription
                status = error.localizedDescription
            }
            throw error
        }
    }

    private func bridgeReadyMessage(bridge: LocalBridgeDefinition, health: LocalBridgeHealth) -> String {
        let version = health.version.map { " · \($0)" } ?? ""
        return "\(bridge.label) is ready\(version)."
    }

    private func schedulePermissionRefresh(recommendRelaunchIfStillPending: Bool = false) {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { [weak self] in
            guard let self else { return }
            let delays: [UInt64] = [0, 250_000_000, 750_000_000, 1_500_000_000]
            for delay in delays {
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: delay) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                self.refreshPermissions()
            }
            if recommendRelaunchIfStillPending && self.screenCapturePermissionPending && !self.screenCaptureGranted {
                self.screenCaptureNeedsRelaunch = true
                self.permissionStatus = "Screen Recording changes take effect after Scholia relaunches."
            } else if self.accessibilityPermissionPending && !self.accessibilityGranted {
                self.permissionStatus = "If Scholia is already enabled, remove the old entry and add this exact app copy."
            } else {
                self.permissionStatus = nil
            }
        }
    }

    private func startBridgeMonitor() {
        bridgeMonitorTask?.cancel()
        bridgeMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { return }
                guard !Task.isCancelled, !self.isStartingBridge else { continue }
                let providers = [self.activeProvider, self.activeQuickAskProvider]
                for provider in providers {
                    guard provider.bridge != nil,
                          provider.id == "codex" || provider.id == "claudecode" else { continue }
                    let endpoint = self.settings.endpoints[provider.id] ?? provider.endpoint
                    let apiKey = (try? await ProviderKeychain.valueAsync(for: provider.id)) ?? ""
                    let health = await self.bridgeManager.check(provider: provider, endpoint: endpoint, apiKey: apiKey)
                    guard !Task.isCancelled else { break }
                    if health == nil {
                        self.bridgeReadyProviderIDs.remove(provider.id)
                        self.startBridge(for: provider)
                    }
                }
            }
        }
    }

    private func begin(
        capture: CapturedContent,
        near point: NSPoint,
        automaticallyAsk: Bool,
        initialQuestion: String = ""
    ) {
        persistCurrentConversation()
        cancelResponse()
        cancelAttachmentIngestion(isQuickAsk: false)
        clearMessageEdit()
        self.capture = capture
        conversationContextEnabled = true
        conversationCompactContextEnabled = settings.resolvedUseVisibleWorkspaceContext
        messages = []
        errorMessage = nil
        draft = automaticallyAsk ? "" : (TextInputPolicy.preparedMessage(initialQuestion) ?? "")
        draftImageData = nil
        draftAttachments = []
        currentConversationID = nil
        currentConversationCreatedAt = nil
        status = switch capture.kind {
        case .image: automaticallyAsk ? "Image captured." : "Image ready. Add a question, or explain it as-is."
        case .mail: "Email thread captured."
        case .text, .latex: "Selection captured."
        }
        explanationPanel.show(near: point)
        if automaticallyAsk {
            let question = TextInputPolicy.preparedMessage(initialQuestion)
            let fallbackQuestion = switch capture.kind {
            case .image:
                "Explain this image."
            case .mail:
                NativeMailContext.defaultReplyQuestion(language: PromptBuilder.language(
                    for: settings.language
                ))
            case .text, .latex:
                "Explain this."
            }
            ask(question ?? fallbackQuestion)
        }
    }

    private func markSelectionHandled(_ capture: CapturedContent) {
        selectionWatcher.suppress(capture)
    }

    private func present(error: Error) {
        errorMessage = error.localizedDescription
        status = error.localizedDescription
        explanationPanel.show(near: NSEvent.mouseLocation)
    }

    private func finishCancelledResponse(assistantID: UUID) {
        if let index = messages.firstIndex(where: { $0.id == assistantID }) {
            messages[index].isStreaming = false
            messages[index].recordActivity("Stopped")
            messages[index].metadata = "Stopped"
        }
        isStreaming = false
        currentRequestID = nil
        persistCurrentConversation()
    }

    private func clearMessageEdit() {
        editingMessageID = nil
        messageEditDraft = ""
    }

    private func preparedQuestion(
        _ rawQuestion: String,
        hasImage: Bool,
        hasAttachments: Bool
    ) -> String? {
        if let question = TextInputPolicy.preparedMessage(rawQuestion) { return question }
        guard hasImage || hasAttachments else { return nil }
        if hasImage && hasAttachments { return "Explain the attached image and documents." }
        return hasImage ? "Explain the attached image." : "Explain the attached documents."
    }

    private func clearQuickMessageEdit() {
        editingQuickMessageID = nil
        quickMessageEditDraft = ""
    }

    private func providerConfiguration(
        apiKeyOverride: String? = nil,
        modelOverride: String? = nil,
        reasoningEffortOverride: String? = nil,
        providerOverride: ProviderDefinition? = nil,
        allowLocalFiles: Bool = false
    ) throws -> ProviderConfiguration {
        let provider = providerOverride ?? activeProvider
        let key: String
        if let apiKeyOverride {
            key = apiKeyOverride
        } else {
            key = try ProviderKeychain.value(for: provider.id)
        }
        let requestedModel = modelOverride ?? settings.models[provider.id] ?? provider.defaultModel
        let resolvedModel = ProviderCatalog.resolvedModelID(
            requestedModel,
            for: provider.id,
            candidates: discoveredProviderModels[provider.id] ?? []
        )
        let requestedEffort = modelOverride == nil
            ? settings.reasoningEfforts[provider.id]
            : reasoningEffortOverride
        let resolvedEffort = requestedEffort.flatMap { effort in
            modelDefinition(for: provider, id: resolvedModel)?
                .reasoningEfforts.contains(effort) == true ? effort : nil
        }
        return ProviderConfiguration(
            provider: provider,
            model: resolvedModel,
            endpoint: settings.endpoints[provider.id] ?? provider.endpoint,
            apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines),
            language: settings.language,
            reasoningEffort: resolvedEffort,
            fastClaudeMode: settings.fastClaudeMode,
            modelSupportsImages: modelDefinition(for: provider, id: resolvedModel)?
                .supportsImages ?? (provider.id != "opencode"),
            localFileAccess: allowLocalFiles ? localFileAccessPolicy : nil
        )
    }

    private func persistCurrentConversation() {
        guard let id = currentConversationID,
              messages.contains(where: { $0.role == .user }) else { return }
        let createdAt = currentConversationCreatedAt ?? Date()
        currentConversationCreatedAt = createdAt
        let title: String
        if capture?.kind == .mail {
            let conversation = capture?.windowTitle?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            title = conversation.isEmpty ? "Email reply" : "Reply — \(conversation)"
        } else {
            title = messages.first(where: { $0.role == .user })?.content
                ?? capture?.sourceTitle
                ?? "Untitled chat"
        }
        let conversation = StoredConversation(
            id: id,
            title: title,
            createdAt: createdAt,
            updatedAt: Date(),
            capture: capture,
            messages: messages,
            contextEnabled: conversationContextEnabled,
            compactContextEnabled: conversationCompactContextEnabled
        )
        savedConversations.removeAll { $0.id == id }
        savedConversations.insert(conversation, at: 0)
        // Loaded entries and the new StoredConversation are already sanitized.
        // Re-sanitizing every saved attachment on each navigation blocks the UI.
        savedConversations = Array(savedConversations.sorted { $0.updatedAt > $1.updatedAt }
            .prefix(ConversationStore.maximumConversations))
        saveConversationHistory()
    }

    private func saveConversationHistory() {
        conversationWriter.save(savedConversations) { [weak self] message in
            Task { @MainActor in self?.status = "Could not save chat history: \(message)" }
        }
    }
}
