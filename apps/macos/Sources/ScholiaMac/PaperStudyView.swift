@preconcurrency import AppKit
@preconcurrency import AVFoundation
import SwiftUI

struct PaperStudyView: View {
    @ObservedObject var session: PaperStudySession
    @Environment(\.colorScheme) private var colorScheme
    @State private var question = ""
    @State private var correction = ""
    @State private var setupExpanded = true
    @State private var correctionExpanded = false
    @State private var settingsExpanded = false
    @State private var historyExpanded = false
    @State private var selectedEvidence: PaperEvidence?
    @State private var selectedLocalFrame: PaperFrame?
    @State private var clearConfirmation = false
    private var dark: Bool { colorScheme == .dark }
    private var accent: Color { ScholiaVisualStyle.accentColor(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        problem
                        cameraSection
                        observationControls
                        localEvidence
                        history
                        privacy
                    }.padding(24)
                }.frame(minWidth: 500, idealWidth: 680, maxWidth: .infinity)
                tutor.frame(minWidth: 380, idealWidth: 480, maxWidth: .infinity)
            }
        }
        .background(StudyPalette.paper(dark))
        .tint(accent)
        .scholiaButtonStyle(.automatic)
        .sheet(item: $selectedEvidence) { evidence in
            PaperEvidenceDetail(evidence: evidence, isCurrent: session.isCurrent(evidence.id))
        }
        .sheet(item: $selectedLocalFrame) { frame in
            PaperLocalFrameDetail(frame: frame)
        }
        .confirmationDialog("Clear this paper session?", isPresented: $clearConfirmation) {
            Button("Clear session and stop camera", role: .destructive) {
                session.clearSession()
                question = ""
                correction = ""
                selectedEvidence = nil
                selectedLocalFrame = nil
            }
        } message: {
            Text("This removes the problem, images, conversation, and step history from this window. It cannot remove data already processed by your model provider.")
        }
        .onChange(of: session.turns.count) { _, count in
            if count > 0 { setupExpanded = false }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "pencil.and.outline").font(.system(size: 24)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Paper study").font(.system(size: 23, weight: .semibold, design: .serif))
                Text("Keep thinking on paper. Ask when you need a hand.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                Label("Temporary session", systemImage: "lock.shield").font(.caption.weight(.medium))
                Text("Page \(session.page) · cleared when this window closes").font(.caption).foregroundStyle(.secondary)
            }
            Button { clearConfirmation = true } label: {
                Image(systemName: "trash")
            }.help("Clear all session data and stop the camera")
                .accessibilityLabel("Clear paper study session")
        }.padding(.horizontal, 24).padding(.vertical, 18)
    }

    private var problem: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("The problem", symbol: "text.book.closed")
            TextField("What are you working on? Include the question or goal…", text: $session.problemStatement, axis: .vertical)
                .lineLimit(2...4).textFieldStyle(.plain).padding(12)
                .background(StudyPalette.canvas(dark), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("paper.problem")
            Text("You can also include the question inside the selected notebook region.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Your notebook", symbol: "camera")
            PaperCameraControls(camera: session.camera, stopCamera: session.stopCamera)
            PaperObservedCameraPreview(camera: session.camera, onRegionChanged: session.setRegion)
            .frame(height: 300)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                PaperCameraIndicator(camera: session.camera).padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                PaperCameraSelectionHint(camera: session.camera).padding(12)
            }
            PaperCameraFramingControls(camera: session.camera, rotate: { reset in
                session.setAnalysisPaused(true)
                if reset { session.camera.resetRotation() }
                else { session.camera.rotateClockwise() }
                session.setRegion(session.camera.region)
            }, useFullFrame: {
                session.setRegion(CGRect(x: 0, y: 0, width: 1, height: 1))
            })
            Text("Keep the page flat and evenly lit. After rotating, inspect the crop and resume auto-check.")
                .font(.caption).foregroundStyle(.secondary)
            PaperCameraFramingAdvice(camera: session.camera)
            DisclosureGroup("Camera setup · Mac or iPhone", isExpanded: $setupExpanded) {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Use this Mac’s camera", systemImage: "laptopcomputer").font(.caption.weight(.semibold))
                    Text("Choose Use Mac camera, or select the built-in FaceTime HD camera above. Hold the notebook facing the screen camera, check the writing in the preview, then select the page region. Your iPhone can stay unlocked.")
                        .font(.caption).foregroundStyle(.secondary)
                    Divider()
                    setupStep(1, "Enable Continuity Camera", "On iPhone: Settings → General → AirPlay & Continuity → Continuity Camera. Sign in to the same Apple Account on both devices with two-factor authentication.")
                    setupStep(2, "Mount the iPhone in landscape", "Use iOS 16 or later and an iPhone XR or newer. Keep Wi-Fi and Bluetooth on, lock the iPhone, and keep it near your Mac. Keep its orientation steady; Continuity can change framing when the phone turns. A trusted USB connection can improve reliability.")
                    setupStep(3, "Choose the regular iPhone camera", "Refresh the list, choose your iPhone rather than Desk View, and allow Scholia to use the camera. Desk View reshapes the scene. Leave other camera apps closed if the device is unavailable.")
                    Text("Continuity Camera pauses when you unlock your iPhone. Lock and mount it again, then reconnect. If you tapped Disconnect on the phone, plug it into your Mac to make it available again.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Camera permission settings") { session.camera.openCameraSettings() }
                        Spacer()
                        Text("The built-in Mac camera and USB webcams also work.").foregroundStyle(.secondary)
                    }.font(.caption)
                }.padding(.top, 10)
            }.font(.callout)
        }
    }

    private var observationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("When to help", symbol: "slider.horizontal.3")
            Picker("Tutoring mode", selection: $session.mode) {
                Text("Only when I ask").tag(PaperHelpMode.onRequest)
                Text("Auto-check as I write").tag(PaperHelpMode.proactive)
            }.pickerStyle(.segmented).accessibilityIdentifier("paper.helpMode")
            Text(session.mode == .onRequest
                 ? "When resumed, steady steps are kept locally. Images are sent only when you capture or ask."
                 : "Watches for changes locally, then checks clear, settled steps against your earlier work. Correct or unfinished work stays quiet.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button { session.captureNow() } label: { Label("Capture & ask for a hint", systemImage: "viewfinder") }
                    .disabled(session.latestFrame == nil || !session.canAskQuestion)
                    .help("Ask for a hint now. Your request takes priority over an automatic check.")
                    .accessibilityIdentifier("paper.capture")
                Spacer()
                Button {
                    session.setAnalysisPaused(!session.isAnalysisPaused)
                } label: {
                    Label(session.mode == .proactive
                          ? (session.isAnalysisPaused ? "Start auto-check" : "Pause auto-check")
                          : (session.isAnalysisPaused ? "Keep steps locally" : "Pause local observation"),
                          systemImage: session.isAnalysisPaused ? "play.fill" : "pause.fill")
                }.accessibilityIdentifier("paper.pauseAnalysis")
            }.controlSize(.small)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: session.requestInFlight ? "sparkle" : session.isAnalysisPaused ? "pause.circle" : "checkmark.circle")
                    .foregroundStyle(session.requestInFlight ? .orange : accent)
                Text(session.analysisStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            DisclosureGroup("Check timing & cue spacing", isExpanded: $settingsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Minimum time between changed-step checks")
                        Spacer()
                        Picker("Analysis interval", selection: $session.samplingInterval) {
                            ForEach([5.0, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) sec").tag($0) }
                        }.labelsHidden().frame(width: 95)
                    }
                    HStack {
                        Text("Minimum time between new cues")
                        Spacer()
                        Picker("Notification interval", selection: $session.notificationInterval) {
                            ForEach([20.0, 30, 60, 120, 300], id: \.self) { Text($0 < 60 ? "\(Int($0)) sec" : "\(Int($0 / 60)) min").tag($0) }
                        }.labelsHidden().frame(width: 95)
                    }
                    Text("The preview stays live while local checks watch for meaningful changes. Clear, settled writing is sent with relevant earlier captures for comparison. Unchanged, blurred, or covered views are skipped.")
                        .foregroundStyle(.secondary)
                    Text("Cue spacing does not delay checks. Slow model responses can delay the next check; shorter intervals can increase model usage.")
                        .foregroundStyle(.secondary)
                    Text("Pausing AI keeps the preview on. Stop camera turns capture off.").foregroundStyle(.secondary)
                    if let latency = session.lastLatency {
                        Text("Last check: \(latency, specifier: "%.1f") sec · \(session.requestsSent) checks · \(session.modelCallsSent) model calls")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }.font(.caption).padding(.top, 10)
            }.font(.caption)
        }.padding(16).background(StudyPalette.rail(dark), in: RoundedRectangle(cornerRadius: 12))
    }

    private var localEvidence: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Check the selected writing", symbol: "viewfinder.circle")
                Spacer()
                if session.latestFrame != nil { Text("LOCAL PREVIEW").font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            }
            if let frame = session.latestFrame, let image = NSImage(data: frame.jpeg) {
                HStack(alignment: .top, spacing: 13) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 160, height: 110)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Current cropped notebook preview")
                    VStack(alignment: .leading, spacing: 6) {
                        if let issue = frame.qualityIssue {
                            Label(issue, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else if frame.handDetected {
                            Label("Move your hand away to check the writing.", systemImage: "hand.raised").foregroundStyle(.orange)
                        } else {
                            Label("Check symbols and small exponents", systemImage: "eye").font(.callout.weight(.medium))
                        }
                        Text("Make sure you can distinguish minus signs, powers, and crossed-out work. Move closer or narrow the region if needed.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(frame.width) × \(frame.height) pixels · not every preview is sent")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        Button("Inspect crop at full size") { selectedLocalFrame = frame }.font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Connect a camera to inspect the exact region used for tutoring.").font(.callout).foregroundStyle(.secondary)
            }
            if session.pageChangeSuggested {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Is this a new page?", systemImage: "doc.on.doc").font(.callout.weight(.semibold))
                    Text("Confirm before continuing so feedback stays associated with the right work.").font(.caption)
                    HStack {
                        Button("New page") { session.startNewPage() }
                        Button("Still the same page") { session.continuePage() }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Button { session.startNewPage() } label: { Label("Start a new page", systemImage: "doc.badge.plus") }
                    .font(.caption).help("Keep the problem and discussion; mark subsequent writing as a new page")
            }
        }
    }

    private var history: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if session.history.isEmpty {
                    Text("Important captures, revisions, and feedback will appear here.").foregroundStyle(.secondary)
                }
                ForEach(session.history.suffix(12).reversed()) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(event.createdAt, style: .time).monospacedDigit().foregroundStyle(.secondary)
                        Text(event.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.font(.caption).padding(.top, 10)
        } label: {
            Label("Session trail · \(session.history.count) moments", systemImage: "clock.arrow.circlepath")
                .font(.callout.weight(.medium))
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Your camera, under your control", systemImage: "lock.shield").font(.caption.weight(.semibold))
            Text("Only selected notebook crops are sent with your problem, relevant earlier evidence, corrections, and discussion. The live video stream stays on this Mac. Scholia keeps this session in memory and clears it when you close this window. Your model provider or local model bridge may process or retain images under its own data policy.")
                .font(.caption).foregroundStyle(.secondary)
            Text(session.providerSummary).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.top, 2)
    }

    private var tutor: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("A little help, at the right step").font(.title3.weight(.semibold))
                    Text("Questions first. More detail when you ask.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles").foregroundStyle(accent)
            }.padding(20)
            modelControls
            if session.mode == .proactive {
                autoCheckStatus
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if session.turns.isEmpty { tutorWelcome }
                        ForEach(session.turns) { turn in turnView(turn).id(turn.id) }
                        Color.clear.frame(height: 1).id("paper.conversation.end")
                    }.padding(20)
                }
                .onChange(of: session.turns.count) { _, _ in
                    withAnimation { proxy.scrollTo("paper.conversation.end", anchor: .bottom) }
                }
            }
            if session.requestInFlight {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(session.routingStatus.isEmpty ? "Reading the captured work…" : session.routingStatus)
                        .font(.caption).lineLimit(2)
                        .accessibilityIdentifier("paper.routingStatus")
                    Spacer()
                    Button("Cancel") { session.cancelRequest() }.font(.caption)
                }.padding(.horizontal, 20).padding(.vertical, 10)
            }
            if !session.requestInFlight, let savedQuestion = session.retryableQuestion {
                retryableRequest(savedQuestion)
            }
            if let error = session.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(error).font(.caption).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(Color.orange.opacity(0.09)).accessibilityIdentifier("paper.error")
            }
            Divider()
            composer
        }.background(StudyPalette.paper(dark))
    }

    private var modelControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text("Model mode").font(.caption.weight(.semibold))
                Picker("Tutor model mode", selection: $session.modelMode) {
                    Text(PaperModelMode.automatic.label).tag(PaperModelMode.automatic)
                    Text(PaperModelMode.fast.label).tag(PaperModelMode.fast)
                    Text(PaperModelMode.thorough.label).tag(PaperModelMode.thorough)
                }.labelsHidden().pickerStyle(.segmented)
                    .disabled(session.requestInFlight)
                    .accessibilityIdentifier("paper.modelMode")
                    .help("Model mode chooses how to reason; auto-check controls when to observe.")
            }
            Text(session.modelMode.detail).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.horizontal, 18).padding(.bottom, 14)
    }

    private var autoCheckStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(session.isAnalysisPaused ? Color.orange : accent).frame(width: 7, height: 7)
                Text(session.isAnalysisPaused ? "Auto-check is paused" : "Auto-check is on")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button(session.isAnalysisPaused ? "Start auto-check" : "Pause auto-check") {
                    session.setAnalysisPaused(!session.isAnalysisPaused)
                }.controlSize(.small)
                    .disabled(session.isAnalysisPaused && session.latestFrame == nil)
                    .accessibilityIdentifier("paper.autoCheck")
            }
            Text(session.isAnalysisPaused
                 ? "Select your notebook region, then start. Connecting the camera alone does not send images."
                 : "Watching locally as you write. New, settled steps are compared with earlier work; a clear mistake gets a small cue here.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Changed-step checks: \(Int(session.samplingInterval)) sec minimum · cues: \(Int(session.notificationInterval)) sec minimum")
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            if !session.isAnalysisPaused {
                Text(session.analysisStatus).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).accessibilityIdentifier("paper.autoCheckStatus")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyPalette.rail(dark))
            .padding(.horizontal, 18).padding(.bottom, 14)
    }

    private func retryableRequest(_ savedQuestion: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise.circle").foregroundStyle(accent)
                Text("Your question is saved").font(.caption.weight(.semibold))
                Spacer()
                Button { session.dismissRetry() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Dismiss this saved question")
                    .accessibilityLabel("Dismiss saved question")
                    .accessibilityIdentifier("paper.dismissRetry")
            }
            Text(savedQuestion).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                .textSelection(.enabled).help(savedQuestion)
            HStack(alignment: .center) {
                Text("Check that the current page is clear, then retry when ready.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Retry with current page") { session.retryRequest() }
                    .controlSize(.small).accessibilityIdentifier("paper.retryRequest")
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyPalette.rail(dark))
            .accessibilityIdentifier("paper.savedQuestion")
    }

    private var tutorWelcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "quote.bubble").font(.system(size: 28)).foregroundStyle(accent)
            Text("Show your thinking.").font(.system(size: 24, weight: .medium, design: .serif))
            Text("Write naturally, then ask about a step. Your tutor can refer to the selected page, notice revisions, and keep the discussion in context.")
                .foregroundStyle(.secondary)
            Text("Try “Is this substitution useful?” or “I’m unsure about the sign on line 3.”")
                .font(.callout).foregroundStyle(.secondary)
            Text("A different approach or an unfinished line is not automatically a mistake.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(StudyPalette.canvas(dark), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func turnView(_ turn: PaperTurn) -> some View {
        let evidence = session.evidence.first { $0.id == turn.evidenceID }
        let isCurrent = session.isCurrent(turn.evidenceID)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(turn.role == .user ? "You" : "Scholia", systemImage: turn.role == .user ? "pencil" : "sparkles")
                    .font(.caption.weight(.semibold)).foregroundStyle(turn.role == .user ? Color.secondary : accent)
                Spacer()
                Text(turn.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
            }
            if let evidence {
                Button { selectedEvidence = evidence } label: {
                    HStack(spacing: 9) {
                        if let image = NSImage(data: evidence.jpeg) {
                            Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 36)
                                .background(.white, in: RoundedRectangle(cornerRadius: 4))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(evidence.page) · step \(evidence.revision + 1)").font(.caption.weight(.medium))
                            Text(isCurrent ? "View the writing used" : "Earlier work · view original capture")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                    }.padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(StudyPalette.canvas(dark), in: RoundedRectangle(cornerRadius: 7))
            } else if turn.evidenceID != nil {
                Text("Earlier capture is no longer in the visual buffer.").font(.caption2).foregroundStyle(.secondary)
            }
            if turn.role == .assistant, !turn.focus.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "scope").font(.caption).foregroundStyle(accent)
                    RichMarkdownView(source: turn.focus, compact: true)
                }
            }
            RichMarkdownView(source: turn.text, compact: true)
            if let evidence {
                Button {
                    session.selectEvidence(evidence.id)
                } label: {
                    Label("Discuss this step", systemImage: "bubble.left.and.text.bubble.right")
                        .font(.caption)
                }.buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(!session.canAskQuestion)
                    .help("Keep this captured step selected for follow-up questions while you continue writing")
                    .accessibilityIdentifier("paper.discuss.\(turn.id.uuidString)")
            }
        }.padding(14)
            .background(turn.role == .user ? StudyPalette.canvas(dark).opacity(0.6) : Color.clear, in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(accent.opacity(turn.role == .assistant ? 0.20 : 0), lineWidth: 1))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let evidence = session.selectedEvidence {
                HStack(alignment: .top, spacing: 9) {
                    if let image = NSImage(data: evidence.jpeg) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 42, height: 32)
                            .background(.white, in: RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Discussing page \(evidence.page) · step \(evidence.revision + 1)")
                            .font(.caption.weight(.semibold))
                        Text("This capture stays selected while you keep writing.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button("Use live page") { session.selectEvidence(nil) }
                        .font(.caption).disabled(!session.canAskQuestion)
                        .accessibilityIdentifier("paper.clearDiscussedStep")
                }.padding(10).background(StudyPalette.rail(dark), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("paper.discussedStep")
            }
            HStack(spacing: 7) {
                Button("Small hint") { session.requestHelp(level: 1) }
                Button("More help") { session.requestHelp(level: 2) }
                Spacer(minLength: 0)
                Button("Full solution") { session.requestHelp(level: 3) }
                    .help("Explicitly ask for a complete worked solution")
            }.controlSize(.small).disabled(!session.canAskQuestion)
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about this step…", text: $question, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.plain)
                    .accessibilityIdentifier("paper.question")
                Button(action: sendQuestion) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 25))
                }.buttonStyle(.plain)
                    .foregroundStyle(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : accent)
                    .disabled(!session.canAskQuestion || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Your question takes priority over an automatic check.")
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(session.selectedEvidence == nil
                        ? "Send question with current notebook context" : "Send question about selected captured step")
                    .accessibilityIdentifier("paper.send")
            }.padding(12).background(StudyPalette.canvas(dark), in: RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("Correct a symbol or explain my approach", isExpanded: $correctionExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("For example: that is a θ, not a 0; I’m trying integration by parts…", text: $correction, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("paper.correction")
                    HStack {
                        Text("Corrections stay with this session.").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add context") {
                            session.submitCorrection(correction)
                            correction = ""
                            correctionExpanded = false
                        }.disabled(correction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(.top, 9)
            }.font(.caption)
        }.padding(18)
    }

    private func sendQuestion() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.sendQuestion(text)
        if session.error == nil { question = "" }
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout.weight(.semibold))
    }

    private func setupStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.caption.weight(.semibold)).frame(width: 22, height: 22)
                .background(accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PaperCameraControls: View {
    @ObservedObject var camera: PaperCamera
    var stopCamera: () -> Void

    private var selectedDevice: PaperCameraDevice? {
        camera.devices.first { $0.id == camera.selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Picker("Camera", selection: Binding(get: { camera.selectedID }, set: { selectCamera($0) })) {
                    if camera.devices.isEmpty { Text("No camera found").tag("") }
                    if !camera.selectedID.isEmpty, !camera.devices.contains(where: { $0.id == camera.selectedID }) {
                        Text("Disconnected camera — choose another").tag(camera.selectedID)
                    }
                    ForEach(camera.devices) { device in
                        Text(device.kind == .builtIn ? "\(device.name) · This Mac" : device.name).tag(device.id)
                    }
                }.labelsHidden().disabled(camera.isConnecting).accessibilityIdentifier("paper.cameraPicker")
                Button { camera.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh available cameras").accessibilityLabel("Refresh available cameras")
                if camera.isConnecting {
                    ProgressView().controlSize(.small).accessibilityLabel("Connecting camera")
                    Button("Cancel", action: stopCamera).accessibilityIdentifier("paper.cancelConnect")
                } else if camera.isRunning {
                    Button("Stop camera", action: stopCamera).accessibilityIdentifier("paper.stopCamera")
                } else {
                    Button("Connect") { Task { await camera.start() } }
                        .disabled(camera.selectedID.isEmpty).accessibilityIdentifier("paper.connectCamera")
                }
            }
            HStack(spacing: 12) {
                if let builtIn = camera.devices.first(where: { $0.kind == .builtIn }),
                   builtIn.id != camera.selectedID || !camera.isRunning {
                    Button { selectCamera(builtIn.id, connect: true) } label: {
                        Label("Use Mac camera", systemImage: "laptopcomputer")
                    }.disabled(camera.isConnecting).accessibilityIdentifier("paper.useMacCamera")
                }
                if let iPhone = camera.devices.first(where: { $0.kind == .iPhone }),
                   iPhone.id != camera.selectedID {
                    Button { selectCamera(iPhone.id, connect: true) } label: {
                        Label("Use iPhone", systemImage: "iphone")
                    }.disabled(camera.isConnecting).accessibilityIdentifier("paper.useIPhoneCamera")
                }
                Spacer(minLength: 0)
                if camera.isRunning {
                    Button("Camera effects…") { camera.showCameraEffects() }
                        .help("Open macOS video effects for this camera")
                        .accessibilityIdentifier("paper.cameraEffects")
                }
            }.font(.caption)
            Text(camera.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .accessibilityIdentifier("paper.cameraStatus")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Camera status")
                .accessibilityValue(camera.status)
                .id(camera.status)
            if selectedDevice?.kind == .builtIn {
                Text("Face the writing toward the camera above your screen. The preview is unmirrored so notation reads correctly.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if selectedDevice?.kind == .iPhone || selectedDevice?.kind == .deskView {
                Text("Keep your iPhone locked. Unlocking it pauses Continuity Camera; you can switch to the Mac camera anytime.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { camera.refreshDevices() }
    }

    private func selectCamera(_ id: String, connect: Bool = false) {
        let shouldConnect = connect || camera.isRunning || camera.isConnecting
        if shouldConnect { stopCamera() }
        camera.selectedID = id
        if shouldConnect {
            Task { await camera.start() }
        }
    }
}

private struct PaperCameraIndicator: View {
    @ObservedObject var camera: PaperCamera
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(camera.isRunning ? Color.green : camera.isConnecting ? Color.orange : Color.gray).frame(width: 6, height: 6)
            Text(camera.isRunning ? "CAMERA ON · LOCAL PREVIEW" : camera.isConnecting ? "CONNECTING CAMERA" : "CAMERA OFF")
                .font(.system(size: 9, weight: .semibold))
        }.foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 6)
            .background(.black.opacity(0.7), in: Capsule()).allowsHitTesting(false)
    }
}

private struct PaperCameraSelectionHint: View {
    @ObservedObject var camera: PaperCamera

    var body: some View {
        Text(camera.isRunning ? "Drag to select the notebook region" : "Connect a camera to preview your page")
            .font(.caption.weight(.medium)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.65), in: Capsule())
            .accessibilityIdentifier("paper.previewInstruction")
            .allowsHitTesting(false)
    }
}

private struct PaperCameraFramingAdvice: View {
    @ObservedObject var camera: PaperCamera

    private var selectedKind: PaperCameraDeviceKind? {
        camera.devices.first { $0.id == camera.selectedID }?.kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if camera.needsRegionReview {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Camera framing changed", systemImage: "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                    Text("Check the selected notebook area in the live preview. Adjust it or confirm the region; auto-check stays paused until you resume.")
                        .font(.caption)
                    Button("Confirm selected region") { camera.confirmRegionReview() }
                        .controlSize(.small).accessibilityIdentifier("paper.confirmCameraRegion")
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityIdentifier("paper.cameraRegionReview")
            }
            if selectedKind == .iPhone || selectedKind == .deskView {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Keep iPhone framing steady", systemImage: "iphone")
                        .font(.caption.weight(.medium))
                    Text("Continuity changes framing when you turn the iPhone. Mount it in landscape and choose the regular iPhone camera rather than Desk View. Scholia cannot lock this framing; a Mac or USB camera avoids this behavior.")
                        .font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("paper.iPhoneFramingAdvice")
            }
        }
    }
}

private struct PaperEvidenceDetail: View {
    let evidence: PaperEvidence
    let isCurrent: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page \(evidence.page) · step \(evidence.revision + 1)").font(.title2.weight(.semibold))
                    Text(isCurrent ? "Visual evidence used for this response" : "Earlier work — this image may differ from the current page")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(data: evidence.jpeg) {
                    Image(nsImage: image).resizable().scaledToFit().frame(width: 760)
                        .accessibilityLabel("Notebook evidence captured at \(evidence.capturedAt.formatted())")
                }
            }.frame(maxHeight: .infinity).background(Color.black.opacity(0.04))
            if !evidence.transcription.isEmpty {
                Text("Model reading · you can correct this in the conversation").font(.caption.weight(.medium))
                ScrollView { RichMarkdownView(source: evidence.transcription, compact: true) }.frame(maxHeight: 140)
            }
            Text(evidence.capturedAt.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 820, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PaperLocalFrameDetail: View {
    let frame: PaperFrame
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check the writing before sending").font(.title2.weight(.semibold))
                    Text("Local preview · opening this view does not send an image")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView([.horizontal, .vertical]) {
                if let image = NSImage(data: frame.jpeg) {
                    Image(nsImage: image).resizable().frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                        .accessibilityLabel("Selected notebook crop at full pixel size")
                }
            }.background(Color.black.opacity(0.04))
            Text(frame.qualityIssue ?? "Can you read small exponents, signs, and fractions? Adjust lighting or the selected region if they are unclear.")
                .font(.callout).foregroundStyle(frame.qualityIssue == nil ? Color.secondary : Color.orange)
        }.padding(24).frame(width: 820, height: 700)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct PaperCameraFramingControls: View {
    @ObservedObject var camera: PaperCamera
    let rotate: (_ reset: Bool) -> Void
    let useFullFrame: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button { rotate(false) } label: {
                Label("Rotate 90°", systemImage: "rotate.right")
            }.disabled(!camera.isRunning)
                .help("Rotate the preview and captured writing clockwise. Auto-check pauses so you can inspect the page.")
                .accessibilityIdentifier("paper.rotateCamera")
            if camera.rotationDegrees != 0 {
                Text("\(camera.rotationDegrees)°").monospacedDigit().foregroundStyle(.secondary)
                Button { rotate(true) } label: { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!camera.isRunning)
                    .help("Reset the camera rotation and pause auto-check")
                    .accessibilityLabel("Reset camera rotation")
                    .accessibilityIdentifier("paper.resetCameraRotation")
            }
            Spacer(minLength: 0)
            Button("Use full frame", action: useFullFrame)
        }.font(.caption).controlSize(.small)
    }
}

private struct PaperObservedCameraPreview: View {
    @ObservedObject var camera: PaperCamera
    let onRegionChanged: (CGRect) -> Void
    var body: some View {
        PaperCameraPreview(captureSession: camera.isRunning ? camera.captureSession : nil,
                           region: camera.region, rotationDegrees: camera.rotationDegrees,
                           onRegionChanged: onRegionChanged)
    }
}

/// Camera crops use unrotated, top-left normalized sensor coordinates. The native preview
/// layer uses bottom-left points. Apply the same clockwise rotation as the captured JPEG
/// explicitly; AVFoundation's metadata rectangle conversion disagrees at quarter turns.
enum PaperPreviewGeometry {
    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func layerRect(forNativeRegion region: CGRect, in videoRect: CGRect,
                          rotationDegrees: Int) -> CGRect {
        guard isValid(region), isValid(videoRect) else { return .null }
        let clipped = region.intersection(unit)
        guard isValid(clipped) else { return .null }
        let display = rotated(clipped, clockwise: rotationDegrees)
        guard isValid(display) else { return .null }
        return CGRect(x: videoRect.minX + display.minX * videoRect.width,
                      y: videoRect.maxY - display.maxY * videoRect.height,
                      width: display.width * videoRect.width,
                      height: display.height * videoRect.height).intersection(videoRect)
    }

    static func nativeRegion(forLayerRect rect: CGRect, in videoRect: CGRect,
                             rotationDegrees: Int) -> CGRect {
        guard isValid(rect), isValid(videoRect) else { return .null }
        let clipped = rect.intersection(videoRect)
        guard isValid(clipped) else { return .null }
        let display = CGRect(x: (clipped.minX - videoRect.minX) / videoRect.width,
                             y: (videoRect.maxY - clipped.maxY) / videoRect.height,
                             width: clipped.width / videoRect.width,
                             height: clipped.height / videoRect.height)
        let native = rotated(display, clockwise: -(rotationDegrees % 360))
        guard isValid(native) else { return .null }
        return native.intersection(unit)
    }

    private static func rotated(_ rect: CGRect, clockwise degrees: Int) -> CGRect {
        switch (degrees % 360 + 360) % 360 {
        case 0: return rect
        case 90: return CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
        case 180: return CGRect(x: 1 - rect.maxX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
        case 270: return CGRect(x: rect.minY, y: 1 - rect.maxX, width: rect.height, height: rect.width)
        default: return .null
        }
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}

/// AVFoundation supplies only the full image's aspect-fit bounds. Crop selection and
/// hit-testing share an explicit, inverse coordinate mapping for every supported rotation.
struct PaperCameraPreview: NSViewRepresentable {
    let captureSession: AVCaptureSession?
    let region: CGRect
    let rotationDegrees: Int
    let onRegionChanged: (CGRect) -> Void

    func makeNSView(context: Context) -> PaperCameraPreviewView {
        let view = PaperCameraPreviewView()
        view.previewLayer.session = captureSession
        view.onRegionChanged = onRegionChanged
        view.region = region
        view.rotationDegrees = rotationDegrees
        view.configurePresentation()
        return view
    }

    func updateNSView(_ view: PaperCameraPreviewView, context: Context) {
        if view.previewLayer.session !== captureSession { view.previewLayer.session = captureSession }
        view.onRegionChanged = onRegionChanged
        view.region = region
        view.rotationDegrees = rotationDegrees
        view.configurePresentation()
        view.updateSelection()
    }
}

@MainActor
final class PaperCameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private let shadeLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()
    var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    var rotationDegrees = 0
    var onRegionChanged: ((CGRect) -> Void)?
    private var dragStart: CGPoint?
    private var draggedRegion: CGRect?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
        shadeLayer.fillColor = NSColor.black.withAlphaComponent(0.4).cgColor
        shadeLayer.fillRule = .evenOdd
        layer?.addSublayer(shadeLayer)
        outlineLayer.fillColor = nil
        outlineLayer.strokeColor = NSColor.systemMint.cgColor
        outlineLayer.lineWidth = 2
        layer?.addSublayer(outlineLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Live notebook camera. Drag to select the region sent for tutoring; use Full frame to reset.")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layerBounds = layer?.bounds ?? convertToLayer(bounds)
        previewLayer.frame = layerBounds
        shadeLayer.frame = layerBounds
        outlineLayer.frame = layerBounds
        configurePresentation()
        updateSelection()
        CATransaction.commit()
    }

    func configurePresentation() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let angle = CGFloat(rotationDegrees)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func updateSelection() {
        guard previewLayer.session != nil else {
            shadeLayer.path = nil
            outlineLayer.path = nil
            return
        }
        let videoRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            .intersection(previewLayer.bounds)
        guard !videoRect.isEmpty, !videoRect.isNull else {
            shadeLayer.path = nil
            outlineLayer.path = nil
            return
        }
        let selected = PaperPreviewGeometry.layerRect(forNativeRegion: draggedRegion ?? region,
                                                     in: videoRect, rotationDegrees: rotationDegrees)
        guard !selected.isEmpty, !selected.isNull else {
            shadeLayer.path = nil
            outlineLayer.path = nil
            return
        }
        let shade = CGMutablePath()
        shade.addRect(previewLayer.convert(videoRect, to: shadeLayer))
        shade.addRect(previewLayer.convert(selected, to: shadeLayer))
        shadeLayer.path = shade
        let outline = previewLayer.convert(selected, to: outlineLayer)
        outlineLayer.path = CGPath(rect: outline.insetBy(dx: 1, dy: 1), transform: nil)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        guard previewLayer.session?.isRunning == true, let layer else { return }
        let point = previewLayer.convert(convertToLayer(convert(event.locationInWindow, from: nil)), from: layer)
        let videoRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard videoRect.contains(point) else { return }
        dragStart = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let layer else { return }
        let point = previewLayer.convert(convertToLayer(convert(event.locationInWindow, from: nil)), from: layer)
        let selected = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(start.x - point.x), height: abs(start.y - point.y))
        let videoRect = previewLayer.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            .intersection(previewLayer.bounds)
        let normalized = PaperPreviewGeometry.nativeRegion(forLayerRect: selected, in: videoRect,
                                                           rotationDegrees: rotationDegrees)
        guard !normalized.isNull, normalized.width >= 0.03, normalized.height >= 0.03 else { return }
        draggedRegion = normalized
        updateSelection()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; draggedRegion = nil; updateSelection() }
        guard let selected = draggedRegion else { return }
        region = selected
        onRegionChanged?(selected)
    }
}
