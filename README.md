# ppaste

A fast, local-only clipboard history for macOS. Press a hotkey, and a shelf of your recent copies slides up along the bottom of the screen. Search, pick one, and it's pasted into the app you were using.

Built as a free, open-source alternative to paid clipboard managers. No account, no cloud, no tracking: your history never leaves your Mac.

## Features

- **Bottom shelf** of cards: text, links and images, each with the source app's icon, a relative timestamp and a character count
- **Instant search** - just start typing when the shelf is open
- **Paste straight into the previous app** with Enter, or quick-paste the first nine items with Cmd+1-9
- **Long history** - text and links are kept forever; images are pruned after 30 days
- **Duplicates are merged** - copying something again moves it to the front instead of cluttering the list
- **Privacy-aware** - ignores concealed/transient pasteboard items and password managers (1Password, Bitwarden, KeePassXC, Keychain, Passwords)
- **Menu-bar only** - no Dock icon, native Swift/SwiftUI, tiny footprint
- **Local storage** in a SQLite database at `~/Library/Application Support/ppaste/`

## Keyboard shortcuts

| Key | Action |
| --- | --- |
| Cmd+Shift+V or Ctrl+Shift+V | Open / close the shelf |
| Type, or Cmd+F | Search (Cmd+F refocuses the search field) |
| Left / Right | Move between cards |
| Enter | Paste the selected card into the previous app |
| Cmd+1 ... Cmd+9 | Paste the 1st-9th card |
| Cmd+Delete | Delete the selected card |
| Esc | Clear the search, then close the shelf |

Binding Cmd+Shift+V overrides "Paste and Match Style" in other apps while ppaste is running.

## Install

Requires macOS 14 (Sonoma) or later and Xcode.

```sh
brew install xcodegen
git clone https://github.com/pcollins-tech/ppaste.git
cd ppaste
xcodegen generate
xcodebuild -project PPaste.xcodeproj -scheme PPaste -configuration Release -derivedDataPath build build
open build/Build/Products/Release/PPaste.app
```

Drag `PPaste.app` into `/Applications` to keep it.

### Permissions

The first time you paste, macOS asks for **Accessibility** access. ppaste needs it to send Cmd+V to the app you were using. Without it, the item is still copied to your clipboard and you can paste it yourself.

The app is signed ad-hoc, so macOS may ask you to grant Accessibility again after a rebuild. Signing with your own Apple ID avoids that.

## Development

```sh
swift test          # unit tests for the core library
xcodegen generate   # regenerate PPaste.xcodeproj from project.yml
```

| Path | Purpose |
| --- | --- |
| `Sources/PPasteCore` | Clip model and SQLite store (GRDB): dedupe, search, retention |
| `Tests/PPasteCoreTests` | Unit tests for the core |
| `App/` | Menu bar, global hotkey, pasteboard watcher, shelf UI |
| `project.yml` | XcodeGen project definition |

## Roadmap

- Pinboards (named collections of saved items)
- Rich link previews
- Rich text and file clips, with true "paste as plain text"
- Launch at login
- Configurable hotkey and ignore list
- Full-text search

## Privacy

ppaste stores everything on your machine and makes no network requests. Anything you copy is saved, so treat the history folder like your clipboard: it can contain sensitive data. Use the menu-bar item "Clear All History..." to wipe it.

## Contributing

Issues and pull requests are welcome. Please run `swift test` before opening a PR.

## Licence

[MIT](LICENSE)

ppaste is an independent project and is not affiliated with or endorsed by the makers of Paste.
