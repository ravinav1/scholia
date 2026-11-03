import SwiftUI
import WebKit

enum StudentwebExtraction {
    static let startURL = URL(string: "https://fsweb.no/studentweb/")!
    static func trusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "fsweb.no" && (url.port ?? 443) == 443
            && url.user == nil && url.password == nil
            && (url.path == "/studentweb" || url.path.hasPrefix("/studentweb/"))
    }
    static func examPage(_ url: URL) -> Bool {
        trusted(url) && ["/studentweb", "/studentweb/", "/studentweb/index.jsf", "/studentweb/start.jsf", "/studentweb/forside.jsf", "/studentweb/forsiden.jsf"].contains(url.path.lowercased())
    }

    // Read only rendered rows in the opening page's Upcoming events table.
    // Never navigate, click disclosures, inspect form values, or read hidden DOM.
    // Only course codes and explicit exam date/time/type tokens cross the bridge.
    static let script = #"""
    if (location.protocol !== 'https:' || location.hostname !== 'fsweb.no' || location.username || location.password ||
        (location.port && location.port !== '443') || !['/studentweb', '/studentweb/', '/studentweb/index.jsf', '/studentweb/start.jsf', '/studentweb/forside.jsf', '/studentweb/forsiden.jsf'].includes(location.pathname.toLowerCase())) return '';
    const codeRE = /\b([A-ZÆØÅ]{2,8}[- ]?\d{3,5}[A-Z]?)\b/gi;
    const datesRE = /\b(?:\d{4}-\d{2}-\d{2}|\d{1,2}[./]\d{1,2}[./]\d{4}|\d{1,2}\.?\s+(?:januar(?:y)?|februar(?:y)?|mars|march|april|mai|may|juni|june|juli|july|august|september|oktober|october|november|desember|december)\s+\d{4})\b/gi;
    const blocked = /frist|deadline|fødsels|birth|studentn|kandidat|candidate|e-?post|e-?mail|telefon|phone|sensur|results?|karakter|grade|registrering|registration|oppmelding|avmelding|withdraw|publisert|published/i;
    const examLabel = /midterm|midtsemester|midtveis|deleksamen|underveis|partial|final|slutteksamen|skoleeksamen|skriftlig|written|hjemmeeksamen|home exam|muntlig|oral|vurdering|assessment|eksamen|exam/i;
    const upcoming = /^(kommende hendelser|komande hendingar|upcoming events)(?:\s*\(\d+\))?\s*$/i;
    const headings = 'h1,h2,h3,h4,[role="heading"],caption,.ui-panel-title,.ui-datatable-header';
    const ignored = 'script,style,noscript,template,input,textarea,select,iframe,nav,header,footer,[role="navigation"]';
    function visible(node) {
      for (let element = node; element?.nodeType === 1; element = element.parentElement) {
        if (element.hasAttribute('hidden') || element.getAttribute('aria-hidden') === 'true' ||
            element.matches('.ui-helper-hidden,.ui-helper-hidden-accessible,.uuHidden')) return false;
        const style = document.defaultView?.getComputedStyle?.(element) || element.style;
        if (style?.display === 'none' || ['hidden', 'collapse'].includes(style?.visibility) || style?.opacity === '0') return false;
        if (element.tagName === 'DETAILS' && !element.hasAttribute('open') && !element.querySelector('summary')?.contains(node)) return false;
      }
      return typeof node.getClientRects !== 'function' || node.getClientRects().length > 0;
    }
    function safeText(node) {
      if (node.nodeType === 3) return node.textContent;
      if (node.nodeType !== 1 || node.matches(ignored) || !visible(node)) return '';
      const text = [...node.childNodes].map(safeText).join('');
      return /^(BR|P|DIV|LI|TR|TD|TH|DT|DD|H[1-6])$/.test(node.tagName) ? text + '\n' : text;
    }
    function lines(node) {
      let skipValue = false;
      return safeText(node).slice(0, 30000).split(/\n/).map(s => s.trim()).filter(raw => {
        if (!raw) return false;
        if (blocked.test(raw)) { skipValue = !/\d/.test(raw); return false; }
        if (skipValue && !examLabel.test(raw) && !/^(dato|date|tid|time|kl\.?|start|slutt|end|varighet|duration)\b/i.test(raw)) {
          skipValue = false; return false;
        }
        skipValue = false; return true;
      });
    }
    function upcomingTable(table) {
      for (let node = table; node && node !== document.body; node = node.parentElement) {
        // Never extend scope from this table into another panel's content.
        if (node.querySelectorAll('table').length > 1) break;
        if ([...node.querySelectorAll(headings)].some(h => visible(h) && upcoming.test(safeText(h).trim()))) return true;
        const previous = node.previousElementSibling;
        if (previous?.matches(headings) && visible(previous)) return upcoming.test(safeText(previous).trim());
      }
      return false;
    }
    const output = [];
    let sourceCount = 0;
    for (const table of [...document.querySelectorAll('table')].filter(t => visible(t) && upcomingTable(t))) {
      const rows = [...table.querySelectorAll('tr')].filter(row => row.closest('table') === table && visible(row));
      const header = rows.find(row => row.querySelector('th'));
      if (!header) continue;
      const columns = [...header.children].map(cell => safeText(cell).trim());
      const dateIndex = columns.findIndex(t => /^(dato|date)$/i.test(t));
      const codeIndex = columns.findIndex(t => /^(emne|course)$/i.test(t));
      const infoIndex = columns.findIndex(t => /^(informasjon|information|info)$/i.test(t));
      if (dateIndex < 0 || codeIndex < 0 || infoIndex < 0) continue;
      sourceCount += rows.filter(row => row !== header).length;
      for (const row of rows.filter(row => row !== header).slice(0, 500)) {
        const cells = [...row.children].filter(n => n.matches('td,th'));
        if (cells.length !== columns.length) continue;
        const codes = [...safeText(cells[codeIndex]).matchAll(codeRE)].map(m => m[1].toUpperCase().replace(/[ -]/g, ''));
        if (new Set(codes).size !== 1) continue;
        const dateLines = lines(cells[dateIndex]);
        const infoLines = safeText(cells[infoIndex]).slice(0, 30000).split(/\n/).map(t => t.trim()).filter(Boolean);
        // Studentweb renders labels and values on separate lines. Associate values
        // with explicit assessment labels, stopping at unrelated/private metadata.
        const fields = [];
        let field = null;
        for (const raw of infoLines) {
          const label = raw.match(/^(eksamensperiode|exam(?:ination)? period|eksamen|exam(?:ination)?|uttak|utlevering|release(?: date)?|innleveringsfrist|innlevering|submission deadline|hand-in deadline|tid|time|kl\.?|start|slutt|end|varighet|duration)\s*:\s*(.*)$/i);
          if (label) {
            const key = label[1].toLowerCase();
            const type = /periode|period/.test(key) ? 'period' : /^(eksamen|exam)/.test(key) ? 'exam'
              : /uttak|utlevering|release/.test(key) ? 'release' : /innlevering|submission|hand-in/.test(key) ? 'submission'
              : /varighet|duration/.test(key) ? 'duration' : /slutt|end/.test(key) ? 'end' : 'time';
            field = {type, value: label[2]}; fields.push(field);
          } else if (blocked.test(raw) || /^[^\d:]+:/.test(raw) || /^(oppmøte|attendance|arrive)\b/i.test(raw)) {
            field = null;
          } else if (field && (/^\d/.test(raw) || /^(kl\.?|tid|time)\b/i.test(raw))) {
            field.value += ' ' + raw;
          } else {
            field = null;
          }
        }
        const event = fields.find(f => f.type === 'exam' || f.type === 'period')
          || fields.find(f => f.type === 'release') || fields.find(f => f.type === 'submission');
        const courseText = safeText(cells[codeIndex]);
        const labels = [courseText, ...lines(cells[infoIndex])].filter(t => examLabel.test(t)).join(' ');
        if (!event && !labels) continue;
        // Read dates only from this visible row's date column or explicit exam,
        // release, submission or exam-period fields. Never use other deadlines.
        const dates = dateLines.join(' ').match(datesRE) || event?.value.match(datesRE) || [];
        if (dates.length > 2) continue;
        let component = 'Exam';
        if (/\b(muntlig|oral)\b/i.test(labels) && (!event || ['exam', 'period'].includes(event.type))) component = 'Oral exam';
        else if (event?.type === 'period') component = 'Exam period';
        else if (event?.type === 'release') component = fields.some(f => f.type === 'submission') ? 'Exam window' : 'Exam release';
        else if (event?.type === 'submission') component = 'Submission deadline';
        else if (/midterm|midtsemester|midtveis|deleksamen|underveis|partial/i.test(labels)) component = 'Midterm';
        else if (/hjemmeeksamen|home exam/i.test(labels)) component = 'Home exam';
        else if (/final|slutteksamen|skoleeksamen|skriftlig|written/i.test(labels)) component = 'Final exam';
        const tokens = [codes[0], 'Assessment'];
        const submission = event?.type === 'release' ? fields.find(f => f.type === 'submission') : null;
        const endDate = submission?.value.match(datesRE)?.[0];
        if (dates.length === 1 && endDate && endDate !== dates[0]) dates.push(endDate);
        if (dates.length) tokens.push('Date: ' + dates.join(' – '));
        const metadata = [...dateLines.filter(t => t.match(datesRE) || /:|^kl\b/i.test(t)), event?.value || '',
          ...fields.filter(f => ['time', 'duration'].includes(f.type)).map(f => f.value),
          ...infoLines.filter(t => !blocked.test(t) && /^(midterm|midtsemester|midtveis|partial|final|skriftlig|written|muntlig|oral|hjemmeeksamen|home exam)\b/i.test(t))];
        for (const raw of dates.length ? metadata : []) {
          const withoutDates = raw.replace(datesRE, '');
          const times = withoutDates.match(/\b(?:[01]?\d|2[0-3])[:.][0-5]\d\b/g) || [];
          if (times.length) tokens.push('Time: ' + times.slice(0, 2).join(' – '));
          const duration = withoutDates.match(/\b(\d+(?:[.,]\d+)?)\s*(timer?|hours?|t|h|minutter?|minutes?|min)\b(?:\s*(\d+)\s*(?:minutter?|minutes?|min)\b)?/i);
          if (duration) {
            const minutes = Number(duration[1].replace(',', '.')) * (/^min/i.test(duration[2]) ? 1 : 60) + Number(duration[3] || 0);
            if (Number.isInteger(minutes) && minutes > 0 && minutes <= 10080) tokens.push(minutes + ' minutes');
          }
        }
        for (const end of dates.length ? [submission, ...fields.filter(f => f.type === 'end')].filter(Boolean) : []) {
          const time = end.value.replace(datesRE, '').match(/\b(?:[01]?\d|2[0-3])[:.][0-5]\d\b/);
          if (time) tokens.push('End: ' + time[0]);
        }
        // One record per source row, including identical-looking components.
        output.push({tokens: tokens.join('\n'), component});
      }
    }
    return JSON.stringify({rows: output, sourceCount});
    """#

    static func parse(_ text: String) -> StudyExamImport {
        struct Snapshot: Decodable {
            struct Row: Decodable { var tokens: String; var component: String }
            var rows: [Row]
            var sourceCount: Int
        }
        var result = StudyExamImport(replacesStudentweb: true)
        guard text.utf8.count <= 500_000,
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: Data(text.utf8)),
            snapshot.sourceCount >= 0 else { return result }
        result.sourceCount = snapshot.sourceCount
        let components = ["Midterm", "Final exam", "Oral exam", "Home exam", "Exam", "Submission deadline", "Exam release", "Exam window", "Exam period"]
        for row in snapshot.rows.prefix(StudyExamPlanner.maximumExams) {
            let parsed = StudyExamPlanner.parseStudentweb(row.tokens)
            let code = row.tokens.components(separatedBy: .newlines).first ?? ""
            guard code.range(of: #"^[A-ZÆØÅ]{2,8}\d{3,5}[A-Z]?$"#, options: .regularExpression) != nil else { continue }
            // Parse each source row separately so matching dates cannot merge
            // different assessment components. Undated rows stay visibly incomplete.
            var exam = parsed.exams.first ?? StudyExam(courseCode: code, source: "studentweb")
            exam.courseName = ""
            exam.selected = false
            exam.component = components.contains(row.component) ? row.component : "Exam"
            exam.flexible = exam.isOral
            exam.kind = exam.component == "Midterm" ? "midterm"
                : ["Final exam", "Oral exam", "Home exam"].contains(exam.component) ? "final" : "other"
            result.exams.append(exam)
        }
        if result.exams.count != snapshot.sourceCount {
            result.warnings.append("Read \(result.exams.count) of \(snapshot.sourceCount) opening-page entries. Check the entries that could not be read before saving.")
        }
        return result
    }

}

@MainActor
final class StudentwebImportSession: ObservableObject {
    let resultsMode: Bool
    let resultsConnection: StudentwebResultsConnection?
    let websiteDataStore: WKWebsiteDataStore
    var onResults: (([StudyCourseCompletion]) async throws -> Void)?
    @Published var completions: [StudyCourseCompletion] = []
    @Published var resultsPageReady = false
    @Published var savingResults = false
    @Published var savedResults = false
    @Published var showingSignIn = false
    private var resultsRead: Task<Void, Never>?
    private var generation = UUID()
    private var routing = StudentwebResultsNavigation()
    private var preferPIN = false
    private var finished = false
    var connectionIsCurrent: Bool { resultsConnection.map { $0.dataStore === websiteDataStore } ?? true }
    @Published var exams: [StudyExam] = []
    @Published var sourceCount: Int?
    @Published var warnings: [String] = []
    @Published var status = "Choose your institution and sign in. Stay on the opening page with Kommende hendelser / Upcoming events."
    @Published var host = "fsweb.no"
    @Published var loading = false
    @Published var extracting = false
    @Published var failure: String?
    weak var webView: WKWebView?
    init(resultsMode: Bool = false, connection: StudentwebResultsConnection? = nil) {
        self.resultsMode = resultsMode
        let connection = resultsMode ? (connection ?? StudentwebResultsConnection()) : nil
        resultsConnection = connection
        websiteDataStore = connection?.dataStore ?? .nonPersistent()
        if resultsMode { status = "Checking Studentweb. Sign in only if asked." }
    }
    func clearResults() {
        generation = UUID()
        resultsRead?.cancel(); resultsRead = nil
        completions = []; resultsPageReady = false
        if resultsMode { extracting = false }
    }
    func readResults() {
        guard resultsMode, connectionIsCurrent, !finished, !savingResults, !loading, let webView, let url = webView.url, StudentwebResults.resultsPage(url) else { return }
        resultsRead?.cancel()
        let ticket = UUID(); generation = ticket
        completions = []; failure = nil; extracting = true
        resultsRead = Task { @MainActor [weak self, weak webView] in
            guard let self, let webView else { return }
            defer { if generation == ticket { extracting = false } }
            do {
                // Require a stable, nonempty snapshot. Wait briefly for JSF to
                // render; never overwrite saved statuses with an empty, loading
                // or unsupported page. Retry is bounded, with no background sync.
                var previous: [StudyCourseCompletion]?
                for _ in 0..<6 {
                    try await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled, !finished, connectionIsCurrent, generation == ticket, webView.url == url else { return }
                    let value = try await webView.callAsyncJavaScript(StudentwebResults.script,
                        arguments: [:], in: nil, contentWorld: .defaultClient)
                    guard !Task.isCancelled, !finished, connectionIsCurrent, generation == ticket, webView.url == url else { return }
                    let rows = (value as? String).flatMap { try? StudentwebResults.parse($0) }
                    if let rows, !rows.isEmpty, rows == previous {
                        completions = rows
                        guard let onResults else { return }
                        // Commit this validated snapshot before allowing another
                        // navigation. The view disables Cancel during the write.
                        savingResults = true
                        defer { savingResults = false }
                        status = "Saving pass statuses on this Mac…"
                        try await onResults(rows)
                        savedResults = true
                        status = "\(rows.count) course pass statuses saved on this Mac."
                        return
                    }
                    previous = rows
                }
                failure = "No readable whole-course results found. Try again after Studentweb finishes loading. Your saved statuses were kept."
            } catch {
                guard !Task.isCancelled, generation == ticket else { return }
                completions = []
                failure = "Could not read or save pass statuses. Try again. Your saved statuses were kept."
            }
        }
    }

    func resultsDidFinish(_ url: URL) {
        guard connectionIsCurrent, !finished, !savingResults else { return }
        showingSignIn = StudentwebResultsNavigation.showsSignIn(url)
        resultsPageReady = StudentwebResults.resultsPage(url)
        switch routing.next(for: url) {
        case .institution: openResultsURL(StudentwebResultsNavigation.loginURL)
        case .results: openResultsURL(StudentwebResults.resultsURL)
        case .read:
            status = "Reading whole-course pass statuses…"
            readResults()
        case .feide:
            status = "Signing in through Feide…"
            let ticket = generation
            resultsRead = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, !Task.isCancelled, !finished, connectionIsCurrent, generation == ticket, webView.url == url else { return }
                // Only a Bool returns. Hidden JSF/Feide fields stay in WebKit.
                let started = try? await webView.callAsyncJavaScript(StudentwebResultsNavigation.signInScript,
                    arguments: [:], in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled, !finished, connectionIsCurrent, generation == ticket, webView.url == url else { return }
                if started as? Bool != true { status = "Choose Feide to sign in. Results will be checked automatically." }
            }
        case .wait:
            status = "Complete sign-in if requested. Results will be checked automatically."
        }
    }

    func openResultsURL(_ url: URL) {
        guard connectionIsCurrent, !finished, !savingResults else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        showingSignIn = StudentwebResultsNavigation.showsSignIn(url)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        webView?.load(request)
    }

    func start() async {
        await resultsConnection?.prepare()
        guard !Task.isCancelled, connectionIsCurrent, !finished else { return }
        if resultsMode { openResultsURL(StudentwebResults.resultsURL) }
        else { webView?.load(URLRequest(url: StudentwebExtraction.startURL)) }
    }

    func refresh() {
        guard !savingResults else { return }
        if resultsMode {
            routing = StudentwebResultsNavigation(automaticFeide: !preferPIN)
            clearResults()
            openResultsURL(StudentwebResults.resultsURL)
        } else { webView?.reload() }
    }

    func usePINSignIn() {
        guard resultsMode, connectionIsCurrent, !finished, !savingResults else { return }
        preferPIN = true
        routing = StudentwebResultsNavigation(automaticFeide: false)
        clearResults()
        status = "Enter your Norwegian ID and PIN directly on Studentweb."
        openResultsURL(StudentwebResultsNavigation.loginURL)
    }
    func finish() {
        guard !finished else { return }
        finished = true
        clearResults()
        onResults = nil
        webView?.stopLoading()
        exams = []; sourceCount = nil; warnings = []
        if let resultsConnection {
            resultsConnection.clearPageData(in: websiteDataStore)
        } else {
            let store = websiteDataStore
            Task { await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
        }
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
    }
}

struct StudentwebImportView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = StudentwebImportSession()
    let onImport: (StudyExamImport) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import from Studentweb").font(.system(size: 23, design: .serif))
                    Text("Temporary sign-in · local extraction · review before saving").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Sign in directly with your institution. Scholia imports only course codes and exam dates, times and types visible on the opening page under Kommende hendelser / Upcoming events. It does not read login fields or send this page to an AI provider. Login cookies are discarded when you close this window; your institution still handles its own sign-in data.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(Color.accentColor)
                Text(session.host).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if session.loading || session.extracting { ProgressView().controlSize(.small) }
                Spacer()
                Button("Opening page") { session.webView?.load(URLRequest(url: StudentwebExtraction.startURL)) }
                Button("Reload") { session.refresh() }
            }
            StudentwebBrowser(session: session).frame(minHeight: 410)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            if let failure = session.failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack(alignment: .center) {
                Text(session.extracting || session.exams.isEmpty ? session.status : "\(session.exams.count) of \(session.sourceCount ?? session.exams.count) opening-page entries found. Review each exam, release and hand-in deadline.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Review \(session.exams.count) exams") {
                    let result = StudyExamImport(exams: session.exams, warnings: session.warnings + ["Check every date and time against Studentweb. Missing times need to be added before collision checks are complete."], replacesStudentweb: true, sourceCount: session.sourceCount)
                    onImport(result)
                    dismiss()
                }.disabled(session.exams.isEmpty || session.extracting).buttonStyle(.borderedProminent)
            }
        }.padding(20).frame(minWidth: 820, idealWidth: 960, minHeight: 640, idealHeight: 740)
            .onDisappear { session.finish() }
    }
}

struct StudentwebBrowser: NSViewRepresentable {
    @ObservedObject var session: StudentwebImportSession
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = session.websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isInspectable = false
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        session.webView = view
        context.coordinator.start = Task { await session.start() }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(session) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.start?.cancel()
        coordinator.session.finish()
        coordinator.poll?.cancel(); view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
    }
    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let session: StudentwebImportSession
        var start: Task<Void, Never>?
        var poll: Task<Void, Never>?
        init(_ session: StudentwebImportSession) { self.session = session }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard !session.savingResults, let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil else {
                decisionHandler(.cancel); return
            }
            if session.resultsMode, navigationAction.targetFrame?.isMainFrame != false {
                session.showingSignIn = StudentwebResultsNavigation.showsSignIn(url)
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if !session.savingResults, navigationAction.targetFrame == nil, let url = navigationAction.request.url,
                url.scheme == "https", url.user == nil, url.password == nil { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            session.clearResults()
            poll?.cancel(); session.loading = true; session.extracting = false; session.failure = nil
            // Never carry candidates across an account/logout/navigation change.
            session.exams = []; session.sourceCount = nil; session.warnings = []
            session.host = webView.url?.host ?? "Connecting…"
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            session.loading = false
            guard let url = webView.url else { return }
            session.host = url.host ?? ""
            if session.resultsMode {
                session.resultsDidFinish(url)
                return
            }
            guard StudentwebExtraction.trusted(url) else { return }
            guard StudentwebExtraction.examPage(url) else {
                session.status = "Only the opening page’s Kommende hendelser / Upcoming events table is imported. Return to the opening page to read its dates."
                return
            }
            session.status = "Reading visible exams on the opening page…"
            session.extracting = true
            poll?.cancel()
            poll = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    guard let self, let webView, webView.url == url else { return }
                    do {
                        let value = try await webView.callAsyncJavaScript(StudentwebExtraction.script, arguments: [:], in: nil, contentWorld: .defaultClient)
                        guard !Task.isCancelled, webView.url == url else { return }
                        if let text = value as? String {
                            // Each read replaces the snapshot. Never retain rows that
                            // disappeared or combine dates from different pages.
                            let snapshot = StudentwebExtraction.parse(text)
                            session.exams = snapshot.exams.sorted(by: StudyExamPlanner.chronological)
                            session.sourceCount = snapshot.sourceCount
                            session.warnings = snapshot.warnings
                            session.extracting = false
                            session.status = session.exams.isEmpty
                                ? "No visible exam dates found in Kommende hendelser / Upcoming events. Stay on the opening page, or paste its exam rows into the planner."
                                : "\(session.exams.count) visible exams found on the opening page."
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        session.extracting = false
                        session.failure = "Could not read the opening page. Reload, or paste its exam rows into the planner."
                        return
                    }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            // Result import never downloads transcripts or opens documents.
            if session.resultsMode {
                let response = navigationResponse.response
                let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                guard navigationResponse.canShowMIMEType,
                    ["text/html", "application/xhtml+xml"].contains(response.mimeType?.lowercased() ?? ""),
                    !disposition.lowercased().contains("attachment") else {
                    decisionHandler(.cancel); return
                }
            }
            decisionHandler(.allow)
        }
        private func failed(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            session.loading = false
            session.clearResults(); session.extracting = false
            session.failure = session.resultsMode
                ? "Studentweb could not load. Check your connection and reload. Nothing has been saved."
                : "Studentweb could not load. Check your connection and reload, or use the paste option."
        }
    }
}
