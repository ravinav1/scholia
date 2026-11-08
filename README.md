# Scholia

Scholia keeps your reading beside a tutor conversation. Open a PDF, select a
passage or figure, and ask a question with the source still in view. Organize
readings into workspaces or connect Canvas to browse courses and assignments.

There are two clients:

- **macOS:** a native SwiftUI and AppKit workspace with PDFKit, local OCR,
  document editing, practice and review, and a menu-bar companion for questions
  from other apps. Files and credentials stay on your Mac.
- **Chrome extension:** explain selected text, mathematics, pages, and PDFs in
  a popup, side panel, or full-tab conversation. Its history stays in extension
  storage.

The native and extension libraries are separate and do not synchronize.

Choose **Language** beside the chat input to set the default for all chats in
that client. **Auto** follows the language of each prompt; English and Norsk
bokmål are available as fixed defaults. You can also ask for another language
directly in a message.

In a PDF reader, choose **Send entire PDF** to include every page’s extracted
text and ask for an explanation of the whole document. Whole-document context
stays available for follow-up questions. The reader reports unreadable pages;
images and diagrams need to be attached for visual questions. Documents over
750,000 characters must be split or use regular page context.

Use **Search files** or **⌘K** in the Mac workspace to find names
and text within one workspace or across your library. Needle returns verified
page matches without embeddings or model calls. See [search and benchmarks](docs/SEARCH.md).

Press **⌘⇧K** or choose **Switch** to jump to a workspace by name or
course code. The same picker offers quick actions for coursework search,
assignments, exam dates, review, and new chats. Type **>** to show only actions;
use **↑ / ↓**, **Enter**, and **Escape** to navigate.

## Get started

Use Node.js 24 or newer (`.nvmrc`), then install dependencies:

```sh
npm ci
```

### macOS

Requires macOS 14 or newer and Apple's developer tools.

Double-click **[Update Scholia.command](scripts/macos/Update%20Scholia.command)**, or run:

```sh
npm run update:macos
```

This builds an optimized release from the current source, installs **Scholia**
in **Applications**, and opens it. For later updates, choose **Scholia → Update Scholia…** in the app.
Chats, documents, and settings are kept.

Choose a provider in Settings and test a model. Create a workspace, import a
file, or connect Canvas. See the [Mac setup guide](apps/macos/README.md) for
signing and permissions and the [workspace guide](docs/STUDY_WORKSPACE.md) for
reading, assignments, and course downloads.

Choose **Study on Paper (⌘3)** to work with an iPhone Continuity Camera or webcam.
Select a notebook region, ask contextual questions, or enable gentle proactive
feedback. The camera session is temporary and clears when its window closes.
See [camera setup, controls, and limitations](docs/PAPER_STUDY.md) and
[verification results](docs/PAPER_STUDY_VERIFICATION.md).

### Chrome extension

```sh
npm run build
```

Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**,
and select `dist/chrome`. Configure a provider in Scholia's settings. See the
[extension guide](apps/chrome/README.md) for shortcuts, PDF reading, site access,
and local provider bridges.

## Providers and privacy

The native app and extension support hosted providers, Ollama, custom compatible
endpoints, and local Codex, Claude Code, and opencode bridges.
Provider requests include your question and bounded source context. Selected
text, page references, and supplied images remain visible in the conversation.

Scholia includes no analytics or telemetry. Native and extension requests go
directly to the selected provider. See the [privacy policy](docs/PRIVACY.md) for
storage, permissions, and retention.

## Development

```sh
npm run check                  # JavaScript tests, syntax checks, and Swift parsing
npm run build:native-resources # native JavaScriptCore helpers and study-plan data
npm run build                  # extension in dist/chrome
npm run check:dist             # validate the extension package
npm run package:chrome         # Web Store ZIP
npm run smoke:macos:workspace -- --data-only
```

Browser verification uses Chromium. See [architecture](docs/ARCHITECTURE.md)
for component boundaries, [practice and review](docs/PRACTICE.md) for the native
learning model, and [Chrome release instructions](apps/chrome/README.md) for
packaging. Generated output belongs in ignored build directories.

[MIT license](LICENSE)

See [Contributing](docs/CONTRIBUTING.md) for the repository layout and verification commands.
