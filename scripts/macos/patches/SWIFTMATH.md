# SwiftMath packaged resources

SwiftMath **1.7.3**, revision `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7`, uses `Bundle.module` in three font/font-table lookups. SwiftPM's generated macOS accessor searches `Bundle.main.bundleURL/SwiftMath_SwiftMath.bundle`, then an absolute build-directory path. A signed macOS app keeps its resources in `Contents/Resources`; a resource directory or link at the app root fails strict code signing. Without the compatibility patch a packaged app can accidentally work only while its development checkout exists.

`../patch-swiftmath-resources.mjs` runs after dependency resolution and before the ordinary SwiftPM build in `build-macos-app.sh`. It replaces those three lookups with a dependency-internal helper that first uses `Bundle.main.url(forResource:withExtension:)` for the standard packaged bundle. The helper evaluates `Bundle.module` only if that bundle is absent, retaining command-line and XCTest behavior. It changes no public API, application source, generated accessor, object file, linker input, or resource layout.

The patch checks the exact locked version/revision and SHA-256 of both upstream source files before writing anything. Reapplying is idempotent. Unknown contents or a version change fail the build with an explicit message. The patch is applied only to this checkout's disposable `.build/checkouts/SwiftMath` directory. To update SwiftMath, inspect its current resource lookup, remove this patch if upstream handles standard app resources, or review the replacement and refresh the pinned input hashes. Never bypass the guards to accept an unknown release.

After packaging, run:

```sh
node scripts/macos/verify-swiftmath-resource-patch.mjs
zsh scripts/macos/check-swiftmath-package.sh
```

Run this without concurrent native builds. It compiles a small executable from the production SwiftMath objects, copies the **packaged** fonts into a temporary signed standard-layout app, temporarily hides only this worktree's generated resource bundle, and loads all 12 fonts, math tables, raster output, and the legacy renderer. A trap restores the build bundle on exit. A separate command-line process then verifies the SwiftPM fallback. Both the probe app and Scholia package must pass `codesign --verify --deep --strict`. The probe never launches Scholia, accesses a library, creates an `NSApplication`, or starts app services.
