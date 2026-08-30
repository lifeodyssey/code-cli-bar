<p align="center">
  <img src="Resources/AppIcon.png" alt="Code CLI Bar" width="112">
</p>

<h1 align="center">Code CLI Bar</h1>

<p align="center">
  <strong>Token usage, API-equivalent cost, and coding-plan quota in one macOS menu-bar popover.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-000000?logo=apple" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/data-local--first-2ea44f" alt="Local-first data">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-AGPL--3.0--only-blue" alt="AGPL-3.0-only"></a>
</p>

<p align="center">
  <a href="#what-it-shows">What it shows</a> ·
  <a href="#supported-clis">Supported CLIs</a> ·
  <a href="#build-from-source">Build from source</a> ·
  <a href="#privacy">Privacy</a>
</p>

Code CLI Bar is a native, local-first macOS utility for people who use several
coding-agent CLIs. It scans the usage records already on your Mac, estimates
their value at API rates, and shows provider-reported plan quota without
turning the menu bar into a full analytics dashboard.

## What it shows

- A menu-bar total for today's API-equivalent cost.
- Fixed **Today** and **Week** summaries for tokens and estimated cost.
- One expandable row per enabled CLI with local usage, quota progress, and
  reset time.
- Pricing coverage, request count, monthly totals, and all-time totals.
- Optional **Actual cash** bookkeeping for subscriptions, credits, and
  overages. This stays separate from estimated API value.
- Independent refresh schedules for local usage and remote quota. Defaults are
  one minute and ten minutes respectively.
- Provider toggles, custom usage paths, explicit browser-credential import,
  and experimental-quota opt-ins in Settings.

## Supported CLIs

| CLI | Default local usage source | Cost behavior | Plan quota |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects` | Model-aware pricing | Live quota with fresh local cache fallback |
| Codex | `~/.codex/sessions` | Model-aware pricing | Live account quota |
| OpenCode Go | `~/.local/share/opencode/opencode.db` | Provider-reported request cost when available | Experimental, opt-in |
| Kimi Code | `~/.kimi-code/sessions` | Known Kimi model rates | Available with compatible credentials |
| ZCode | `~/.zcode/cli/db/db.sqlite` | Known Z.ai rates; unknown models remain unpriced | Experimental, opt-in |
| Grok Build | `~/.grok/sessions` | Blended estimate when logs expose only total tokens | Live account quota |

Custom paths can replace a provider's default directory or database. Disabling
a provider stops both its scan and its quota refresh.

> [!IMPORTANT]
> **CLI detected** only means that Code CLI Bar found a readable local usage
> path. Plan quota is separate and may still need a valid CLI login, API key,
> or an explicit browser credential import.

## Today and Week

**Today** uses the Mac's current calendar day. **Week** is not a rolling
seven-day range: it starts at each provider's current weekly plan-cycle
boundary, derived from that provider's quota reset metadata.

If a provider does not expose a trustworthy weekly reset, Code CLI Bar leaves
its Week value unavailable instead of inventing a boundary. The combined Week
summary totals the providers whose current plan week can be resolved and marks
the result as partial when others are unavailable.

Quota snapshots also have to pass a timestamp-based freshness check. A future
reset time does not make an old utilization percentage current: stale quota is
removed from progress bars and Week calculations, then labeled with its data
age and latest refresh error instead of being presented as live.

Quota percentage and local token count intentionally remain separate. A
provider may meter subscription capacity using rules that cannot be recovered
from its local session files.

## What the dollar amount means

The headline dollar value is an **API-equivalent estimate**, not a claim that
the provider charged that amount.

- Provider-recorded request cost wins when the local store includes it.
- Otherwise Code CLI Bar applies known input, output, and cache-token rates.
- Unknown rates are never silently counted as zero. `$12.34+` is a priced
  floor with additional unpriced requests; `$—` means no selected request has
  a verified price.
- Subscription and credit payments appear only in the manual **Actual cash**
  ledger, which is hidden until it has an entry.

Pricing catalogs age as providers rename models and change rates, so every
estimate should be read as approximate rather than invoice-grade accounting.

## Privacy

Code CLI Bar reads provider history in place and stores derived accounting
data under `~/.code-cli-bar`.

Persisted usage records contain timestamps, model identifiers, token counters,
derived or reported cost, and opaque deduplication hashes. Prompt text,
response text, tool-call content, project paths, raw session IDs, raw message
IDs, and raw request IDs are excluded. Imported credentials are opt-in and are
kept in macOS Keychain-backed stores.

The app does not edit provider histories or authentication state, and it has
no telemetry or cloud sync.

## Build from source

Requirements:

- macOS 26 or newer
- Xcode 26 with Swift 6.2

```bash
git clone https://github.com/lifeodyssey/vibe-bar.git
cd vibe-bar
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./Scripts/build_app.sh release
open ".build/Code CLI Bar.app"
```

The resulting app is ad-hoc signed for local use. Public distribution requires
a Developer ID signature, Apple notarization, and a signed Sparkle update feed.
Automatic update checks remain disabled until that feed is configured.

Code CLI Bar is an accessory app (`LSUIElement`) and does not show a Dock icon.

## Settings and local data

The gear button opens Settings, where you can enable providers, set custom
paths, import credentials, change refresh intervals, manage Actual cash, and
preview legacy history before importing it.

> [!NOTE]
> The optional legacy importer reads `~/.vibebar/cost_history.json`, previews
> compatible daily aggregates, and copies only the selected accounting data.
> It never rewrites or deletes the source.

Primary application data lives in `~/.code-cli-bar`, including settings,
quota snapshots, the request-level usage ledger, cost history, and the manual
cash ledger. Removing the app bundle does not remove this directory.

Code CLI Bar is not affiliated with Anthropic, OpenAI, SST/OpenCode, Moonshot
AI, Zhipu AI, or xAI. Product names and trademarks belong to their respective
owners. Third-party acknowledgements are recorded in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
