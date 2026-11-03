import Combine

/// Keystrokes notify only the composer, not the reader or the chat transcript.
@MainActor
final class StudyComposerDraft: ObservableObject {
    @Published var text = "" {
        didSet { if text != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?
}
