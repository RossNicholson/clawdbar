# ClawdBar

**A free, native macOS menu bar app that shows your Claude Code usage limits at a glance.**

![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6.0-orange) ![License: MIT](https://img.shields.io/badge/license-MIT-blue) ![Free](https://img.shields.io/badge/price-free-brightgreen)

---

Instead of hunting through the Claude UI, just glance at your menu bar. ClawdBar shows your **5-hour session** and **7-day weekly** usage percentages, color-coded so you know at a glance how close you are to hitting your limits.

- **Menu bar** — always-visible `48% · 23%` indicator, green → orange → red as you approach your limit
- **Popover** — progress bars, exact percentages, and time until each limit resets
- **Auto-refresh** — polls every 60 seconds
- 100% native SwiftUI · no Electron · no telemetry · Liquid Glass UI on macOS 26 Tahoe

> **Requires a Claude Max subscription.** The unified rate-limit headers that ClawdBar reads are only returned for Max plans.

---

## Install

```bash
brew tap RossNicholson/tap
brew install --cask clawdbar
```

**Requirements:** macOS 13+ · Claude Code installed and signed in (desktop app or CLI)

---

## How it works

On first launch ClawdBar explains what it needs and asks you to approve. Here's the full picture:

1. **Credentials** — ClawdBar reads your Claude Code session token from the `Claude Code-credentials` entry in your macOS Keychain. This is the same entry written by the Claude Code desktop app and CLI — ClawdBar never creates, modifies, or stores credentials itself.

2. **Usage check** — Every 60 seconds it makes a minimal API call to `api.anthropic.com/v1/messages` (1 token of Haiku) and reads the `anthropic-ratelimit-unified-*` response headers. No conversation data is sent or stored.

3. **Keychain access** — On signed/notarized releases, macOS will show its standard Keychain access dialog the first time. You can revoke this at any time in **Keychain Access → File → Lock Keychains**.

---

## Build from source

```bash
git clone https://github.com/RossNicholson/clawdbar
cd clawdbar
make setup   # installs xcodegen if needed, generates the .xcodeproj
make run     # builds and launches
```

For a release build, set your Apple Developer Team ID in `project.yml` under `configs.Release.DEVELOPMENT_TEAM` before running `make release`.

No `.xcodeproj` is checked in — regenerate it any time with `xcodegen generate`.

---

## Contributing

Bug reports, feature requests, and PRs are welcome — open an issue or start a discussion.

---

## Support

If you find ClawdBar useful, consider [buying me a coffee](https://buymeacoffee.com/rossnicholson) ☕

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20Ross-yellow?logo=buy-me-a-coffee)](https://buymeacoffee.com/rossnicholson)

---

## License

MIT — see [LICENSE](LICENSE) for details.
