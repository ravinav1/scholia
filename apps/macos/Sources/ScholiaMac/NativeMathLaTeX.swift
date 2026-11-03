import Foundation

/// Rewrites LaTeX that models commonly emit into the subset SwiftMath renders,
/// so one unsupported macro such as `\operatorname` does not leave the whole
/// expression as raw source in the chat.
enum NativeMathLaTeX {
    private static let rewrites: [(pattern: String, replacement: String)] = [
        (#"\\operatorname\*?\s*\{"#, #"\\mathrm{"#),
        (#"\\(?:dfrac|tfrac)\b"#, #"\\frac"#),
        (#"\\(?:boldsymbol|pmb)\b"#, #"\\bm"#),
        (#"\\mathscr\b"#, #"\\mathcal"#),
        (#"\\(?:mathop|mathbin|mathrel|mathord|ensuremath)\s*\{"#, "{"),
        (#"\\implies\b"#, #"\\Rightarrow"#),
        (#"\\impliedby\b"#, #"\\Leftarrow"#),
        (#"\\lvert\b|\\rvert\b"#, "|"),
        (#"\\lVert\b|\\rVert\b"#, #"\\|"#),
        (#"\\(?:tag|label)\*?\s*\{[^{}]*\}"#, ""),
        (#"\\(?:nonumber|notag)\b"#, ""),
        (#"\\(?:hphantom|vphantom|phantom)\s*\{[^{}]*\}"#, ""),
        (#"\\\\\[[^\]]*\]"#, #"\\\\"#),
        (#"\\begin\{(?:align|gather|multline|flalign|alignat)\*?\}"#, #"\\begin{aligned}"#),
        (#"\\end\{(?:align|gather|multline|flalign|alignat)\*?\}"#, #"\\end{aligned}"#),
        (#"\\(?:begin|end)\{(?:equation\*?|displaymath|math)\}"#, "")
    ]

    static func normalize(_ latex: String) -> String {
        var output = latex
        for rule in rewrites {
            output = output.replacingOccurrences(
                of: rule.pattern, with: rule.replacement, options: .regularExpression)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
