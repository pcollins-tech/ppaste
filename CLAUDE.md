# ppaste
Personal macOS clipboard-history app (Paste replacement). Swift, macOS 14+, menu-bar only (LSUIElement).

## Layout
- `Sources/PPasteCore` — ClipItem + SQLite (GRDB) store: dedupe, search, image pruning. Unit-tested.
- `App/` — menu bar, Carbon hotkey (Ctrl+Shift+V), pasteboard watcher, bottom shelf (NSPanel + SwiftUI).
- `project.yml` — XcodeGen spec; `PPaste.xcodeproj` is generated and gitignored.

## Commands
- Test core: `swift test`
- Build app: `xcodegen generate && xcodebuild -project PPaste.xcodeproj -scheme PPaste -derivedDataPath build build`
- Run: `open build/Build/Products/Debug/PPaste.app`

## Decisions
- Text/links kept forever; images pruned after 30 days. Local only, no sync.
- Link previews (`App/LinkPreviewFetcher.swift`) are the only network access: public http(s) hosts only (`LinkPreviewPolicy`), capped, no cookies, opt-out via menu (`fetchLinkPreviews` default). Preview images are pruned with the 30-day rule.
- Skips concealed/transient pasteboard items and password-manager apps.
- Pasting simulates Cmd+V, which needs Accessibility permission (ad-hoc signing may reset the grant on rebuild).
- UI rule: any control that triggers async work must show a pending state.
