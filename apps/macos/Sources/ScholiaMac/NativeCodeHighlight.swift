import AppKit
import JavaScriptCore

@MainActor
enum NativeCodeHighlight {
    private static let context: JSContext? = {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("StudyWeb/code-highlight.js"),
            root.appendingPathComponent("dist/web/code-highlight.js")].compactMap { $0 }
        guard let source = candidates.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first,
            let context = JSContext() else { return nil }
        context.evaluateScript(source)
        return context
    }()
    private static let cache: NSCache<NSString, NSArray> = {
        let value = NSCache<NSString, NSArray>(); value.countLimit = 64; value.totalCostLimit = 2_000_000; return value
    }()
    static func runs(_ code: String, language: String) -> [[String: Any]] {
        guard code.utf16.count <= 100_000 else { return [] }
        let key = (language + "\u{0}" + code) as NSString
        if let result = cache.object(forKey: key) { return result as? [[String: Any]] ?? [] }
        let result = context?.objectForKeyedSubscript("ScholiaCodeHighlight")?
            .objectForKeyedSubscript("highlightCodeRuns")?.call(withArguments: [code, language])?.toArray() as? [[String: Any]] ?? []
        cache.setObject(result as NSArray, forKey: key, cost: code.utf16.count)
        return result
    }
    static func color(_ scope: String, dark: Bool) -> NSColor {
        let colors: (String, String)
        if scope.contains("comment") || scope.contains("quote") { colors = ("627D73", "8CA19A") }
        else if scope.contains("keyword") || scope.contains("literal") || scope.contains("section") { colors = ("A24715", "F3A96B") }
        else if scope.contains("string") || scope.contains("title") || scope.contains("name") || scope.contains("type") || scope.contains("attribute") { colors = ("28704A", "9DD7B0") }
        else if scope.contains("number") || scope.contains("meta") || scope.contains("built_in") { colors = ("6652AB", "B7B6F1") }
        else { colors = ("A63C54", "EF929D") }
        let value = UInt32(dark ? colors.1 : colors.0, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
