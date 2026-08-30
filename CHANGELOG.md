# Changelog

Notable changes to Code CLI Bar are recorded here. Dates use YYYY-MM-DD.

## 1.5.0 - 2026-08-30

### Features

- Introduce the focused Code CLI Bar experience for Claude Code, Codex,
  OpenCode Go, Kimi Code, ZCode, and Grok Build.
- Show local token usage and API-equivalent cost for Today and each provider's
  active weekly plan cycle instead of a generic rolling window.
- Add native CLI detection, local-history readers, and plan-quota adapters for
  the supported providers, with experimental adapters clearly labelled.
- Keep subscription payments, credits, and overages in a separate Actual cash
  ledger so they are never mixed into API-equivalent estimates.
- Add an independent application identity, local storage root, icon, compact
  settings surface, and previewed import from compatible Vibe Bar history.
- Add tag-driven GitHub Release automation with reproducible ZIP, SHA-256,
  version validation, app-signature checks, and optional Apple/Sparkle signing.

### Fixes

- Prefer Claude Code's CLI account and provider-authored quota cache over stale
  browser cookies in automatic source selection.
- Preserve last-known quota buckets only while their provider-declared cycle
  is still active, label them as stale, and reject expired or future-dated
  snapshots.
- Bound and compact the local session index so long-running installations do
  not grow without limit.

### Documentation

- Replace the inherited project page with Code CLI Bar documentation, privacy
  boundaries, pricing semantics, release instructions, and scrubbed dark/light
  product screenshots.

### Distribution

- This release requires macOS 26 or newer.
- The initial GitHub download is ad-hoc signed. On first launch, right-click
  **Code CLI Bar.app**, choose **Open**, and confirm the Gatekeeper prompt.
