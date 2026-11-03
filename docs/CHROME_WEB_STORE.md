# Chrome Web Store release

Scholia's release manifest is Manifest V3 and the upload archive is produced
from the repository version in `package.json`.

```sh
npm ci
npm run check
npm run package:chrome
```

Upload `dist/scholia-chrome-<version>.zip` in the Chrome Web Store developer
dashboard. The packaging command builds production bundles, verifies every
manifest entry, rejects remote or dynamically evaluated code, checks bundled
KaTeX/PDF.js assets and renderer dependency notices, and confirms that
`manifest.json` is at the ZIP root.

## Listing copy

**Single purpose**

Scholia explains user-selected text, mathematics, images, screen regions, web
pages, and PDFs with the AI provider the user configures.

**Short description**

Select text, math, or a screen region and get a contextual AI explanation.

**Permission justifications**

- `activeTab`: reads or captures the tab only after the user asks Scholia to
  explain, capture, or start a page-grounded chat.
- `contextMenus`: adds explicit Explain and Capture commands to Chrome's context
  menu.
- `scripting`: connects the small, read-only ChatGPT context probe to a tab that
  was already open when Scholia was installed or updated, without reloading or
  modifying the conversation.
- `storage`: keeps provider preferences, credentials, website access rules, and
  bounded, user-deletable sidebar chat history on the device.
- `sidePanel`: hosts the full contextual chat separately from the compact
  toolbar popup.
- `offscreen`: runs the bundled local OCR worker for scanned PDFs, including
  attachments opened from pages that restrict worker execution.
- `<all_urls>` host access: injects the selection affordance, reads explicitly
  requested page/site/PDF context, and permits direct provider requests. Users
  can disable individual sites or switch to allowlist-only access.

## Submission checklist

- Publish `docs/PRIVACY.md` at the repository URL used in the store listing.
- Complete the Web Store privacy questionnaire consistently with that policy:
  no analytics, advertising, sale, or Scholia backend; user content is sent
  directly to the configured provider only after an explicit action.
- Provide screenshots of both the compact toolbar popup and full side panel.
- Confirm the support/homepage URL and contact details in the developer
  dashboard.
- Increment `package.json` and `apps/chrome/manifest.json` together for each
  release, then regenerate the ZIP.
