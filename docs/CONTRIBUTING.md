# Contributing

Run commands from the repository root. Use Node.js 24 or newer (`.nvmrc`) and
install the locked dependencies with `npm ci`. The native app needs macOS 14 or
newer and Apple's developer tools. Browser checks need Chromium; do not use Brave.

## Find the code

| Directory       | Contents                                                       |
| --------------- | -------------------------------------------------------------- |
| `apps/chrome`   | Extension pages, capture, PDF reader, and service worker       |
| `apps/macos`    | Swift app and native tests                                     |
| `apps/server`   | Hosted API, accounts, storage, and document workers            |
| `apps/web`      | Browser workspace shared by the native and hosted servers      |
| `packages/core` | Shared JavaScript contracts, prompts, and provider definitions |
| `scripts`       | Builds, local bridges, performance tools, and smoke checks     |
| `tests`         | JavaScript unit and integration tests                          |
| `docs`          | User guides, deployment, architecture, and privacy             |

Start with [Architecture](ARCHITECTURE.md) when a change crosses clients.
Keep code beside the feature that owns it. Share a helper when callers need the
same behavior; avoid adding a file just to wrap a single expression.

Client code is grouped by feature: readers, chat, courses, exams, and practice.
Tests follow their component under `tests/core`, `tests/chrome`, `tests/web`,
`tests/server`, and `tests/tooling`. Native XCTest files stay in `apps/macos/Tests`.

Build and packaging tools live in `scripts/build`; source checks in
`scripts/checks`; app installers in `scripts/macos`. Browser and native smoke
checks share `scripts/smoke`, while benchmarks stay in `scripts/performance`.
Deployment files belong to `apps/server`. Keep the root for the README, license,
repository instructions, and tools that need root-level configuration.

## Checks

```sh
npm run check
npm run build:web
npm run package:chrome
```

`check` parses JavaScript and JSON, parses Swift when `swiftc` is available, and
runs the Node test suite. It does not type-check or build the Mac app. Generated
files, dependency trees, and private data directories are excluded from the scan.

To run one JavaScript test while working:

```sh
node --test tests/core/context.test.js
```

For browser behavior, build the affected client first:

```sh
npm run build:web
node scripts/smoke/browser/smoke-hosted-web.mjs
npm run build
node scripts/smoke/browser/smoke-chromium-region.mjs
node scripts/smoke/browser/smoke-chromium-history.mjs
npm run smoke:chromium:recursion
```

Smoke checks use isolated data and deterministic provider fixtures. Screenshots
go under `dist/verification`. Set `CHROMIUM_BIN` if Chromium is installed outside
the default location used by the runner.

For native changes:

```sh
npm run build:macos
npm run smoke:macos:workspace -- --data-only
npm run smoke:macos:workspace -- --learning-only
npm run smoke:macos:panels
```

The full workspace smoke also exercises the local website in Chromium. With
full Xcode installed, run `swift test --package-path apps/macos`. See the
[Mac guide](../apps/macos/README.md) for SDK selection and signing.
All native smoke commands use `scripts/smoke/macos/run.sh`. Pass `-- --skip-build`
to reuse a current native build when running several suites.

CI runs the JavaScript checks and web/extension builds. It also builds the
Docker image and checks the running service and PDF worker dependencies.
Native UI checks are run locally.

Feature smoke checks also cover search, exam imports, course documents, and
native file tools:

```sh
npm run smoke:chromium:search
npm run smoke:chromium:exams
npm run smoke:chromium:courses
npm run smoke:chromium:studentweb
npm run smoke:macos:search
npm run smoke:macos:files
npm run test:search:native
```

Search performance experiments are documented in [Search](SEARCH.md).

## Making changes

Keep a PR focused enough to review. Preserve existing tests when moving or
combining files, and update imports, build entries, commands, and documentation
in the same change. Add regression coverage when behavior changes.

Prettier settings live in `package.json`; Swift settings are in
`apps/macos/.swift-format`. Format the files
you change rather than reformatting unrelated code:

```sh
npx prettier --write path/to/file.js path/to/guide.md
```

Write documentation around what a reader needs to do. Use the actual button and
command names, explain limits where they affect a task, and keep setup steps in
one guide with links from the others. Don't document unfinished features as
available.

Keep generated builds in `dist/`, exports in `output/`, and hosted development
data in `.data/`. Do not commit credentials, local bridge environment files, or
account data. `apps/server/.env.example` is the configuration template.

A PR should explain the problem, the resulting behavior, the checks run, and any
remaining limitations. Report sensitive vulnerabilities through
[GitHub Security Advisories](https://github.com/heaps0rt/scholia/security/advisories/new).
