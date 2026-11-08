import AppKit
import SwiftMath

// This executable imports only SwiftMath. It never launches Scholia, creates an
// NSApplication, accesses the user's library, or starts application services.
@main
struct SwiftMathPackageCheck {
    static func main() throws {
        let standalone = CommandLine.arguments.contains("--standalone")
        if standalone {
            let expected = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/SwiftMath_SwiftMath.bundle")
            guard let actual = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle") else {
                fatalError("Missing packaged SwiftMath resource bundle")
            }
            precondition(actual.standardizedFileURL == expected.standardizedFileURL)
            precondition(actual.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
                .appendingPathComponent("Contents/Resources/SwiftMath_SwiftMath.bundle").standardizedFileURL)
            print("RESOURCE \(actual.path)")
        }
        precondition(MathFont.allCases.count == 12)
        for definition in MathFont.allCases {
            let cgFont = definition.cgFont()
            precondition(cgFont.numberOfGlyphs > 100)
            let font = definition.mtfont(size: 20)
            precondition(font.fontSize == 20)
            let renderer = MTMathImage(latex: #"\int_0^1 x^2\,dx=\frac{1}{3}"#, fontSize: 20, textColor: .black)
            renderer.font = font
            let (error, image) = renderer.asImage()
            precondition(error == nil && image != nil)
            precondition(image!.size.width > 0 && image!.size.height > 0)
            precondition((image!.tiffRepresentation?.count ?? 0) > 100)
            print("FONT \(definition.rawValue) glyphs=\(cgFont.numberOfGlyphs)")
        }
        // MTMathImage's default initialization exercises the older MTFont path.
        let legacy = MTMathImage(latex: #"\sqrt{a^2+b^2}"#, fontSize: 20, textColor: .black)
        let (error, image) = legacy.asImage()
        precondition(error == nil && (image?.tiffRepresentation?.count ?? 0) > 100)
        print("PASS \(standalone ? "standalone packaged" : "SwiftPM fallback"): 12 fonts, math tables, rasterization and legacy renderer")
    }
}
