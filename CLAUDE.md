# ppaste
Personal macOS clipboard-history app (Paste replacement). Swift, macOS 14+, menu-bar only (LSUIElement).

## Layout
- `Sources/PPasteCore` — ClipItem + SQLite (GRDB) store: dedupe, search, image pruning. Unit-tested.
- `App/` — menu bar, Carbon hotkeys (configurable, default Cmd/Ctrl+Shift+V), pasteboard watcher, bottom shelf (NSPanel + SwiftUI).
- `project.yml` — XcodeGen spec; `PPaste.xcodeproj` is generated and gitignored.

## Commands
- Test core: `swift test`
- Build app: `xcodegen generate && xcodebuild -project PPaste.xcodeproj -scheme PPaste -derivedDataPath build build`
- Run: `open build/Build/Products/Debug/PPaste.app`

## Decisions
- Text/links kept forever; images pruned after the configured retention (default 30 days) unless pinned to a pinboard (migration `v2_pinboards`). Local only, no sync.
- Link previews (`App/LinkPreviewFetcher.swift`, migration `v3_link_previews`) are the only network access: public http(s) hosts only (`LinkPreviewPolicy`), capped, no cookies, opt-out via menu (`fetchLinkPreviews` default). Preview images are pruned with the 30-day rule.
- Skips concealed/transient pasteboard items and password-manager apps.
- Pasting simulates Cmd+V, which needs Accessibility permission (ad-hoc signing may reset the grant on rebuild).
- UI rule: any control that triggers async work must show a pending state.

## Demo / screenshots
`PPASTE_DATA_DIR=<dir>` uses a separate data folder (watcher off). `PPASTE_SNAPSHOT_FILE=<png>` (+ optional `PPASTE_SNAPSHOT_PINBOARD=<index>`) opens the shelf, writes a PNG and quits. Never screenshot the real history: it contains private clipboard data. Seed a demo DB with fake rows instead (`docs/*.png` were made this way).

- Settings live in `App/AppSettings.swift` (UserDefaults: shortcuts, ignored bundle IDs, image retention); UI in `App/SettingsView.swift`. `PPASTE_SETTINGS_SNAPSHOT=<png>` renders the settings window and quits.
