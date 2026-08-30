# Quota reset sources: Vibe Bar vs CC Switch

Research date: 2026-08-30

Compared revisions:

- Vibe Bar upstream: `06f38afbebe67e71c72bacb8ca77bf3b3d863175`
- CC Switch: `d8065cc628fcd373d00c4363d718095f19e78c9e`

## Finding

Neither application derives a subscription reset time from local token history. Local session records are used for token and estimated-cost accounting; an exact plan reset must come from provider quota metadata. If the provider response or a trusted cache has no reset timestamp, an exact plan-week window cannot be constructed safely.

The current fork has not changed the inherited Vibe Bar quota adapters. Its compact UI resolves a plan week only from a weekly `QuotaBucket` that has both `resetAt` and a seven-day duration (`Sources/VibeBarCore/Models/PlanWeekWindow.swift`).

## Vibe Bar paths

| Provider | Credential source | Quota source |
| --- | --- | --- |
| Claude | macOS Keychain `Claude Code-credentials`, `~/.claude/.credentials.json`, or optional claude.ai browser cookie | Anthropic OAuth usage API or claude.ai organization usage API |
| Codex | macOS Keychain `Codex Auth`, `~/.codex/auth.json`, or optional ChatGPT browser cookie | `https://chatgpt.com/backend-api/wham/usage` |
| Kimi | kimi.com Chromium local-storage access/refresh JWTs imported into Vibe Bar's credential store | kimi.com Membership / Billing web APIs |
| OpenCode Go | opencode.ai browser `auth` cookie plus a discovered/configured workspace ID | HTML/server-function data from `/workspace/<id>/go` |
| Grok Build | `~/.grok/auth.json`, with grok.com browser cookie fallback | non-public Grok Build billing gRPC-web endpoint |
| Z.ai / ZCode | API key separately saved in Vibe Bar settings | `/api/monitor/usage/quota/limit` |

The weak paths on this machine are therefore credential discovery, not reset parsing. In particular, the Claude adapter does not read `~/.claude.json`, the Kimi adapter does not read `~/.kimi-code/credentials`, and the OpenCode Go adapter does not read `~/.local/share/opencode/auth.json`.

## CC Switch paths

CC Switch has two quota systems:

1. Official subscriptions read the existing CLI OAuth credential and call a fixed provider endpoint. Claude reads the same Keychain / `~/.claude/.credentials.json` sources as Vibe Bar and calls `https://api.anthropic.com/api/oauth/usage`; Codex reads Keychain / `~/.codex/auth.json` and calls `https://chatgpt.com/backend-api/wham/usage`; Grok reads `~/.grok/auth.json` and calls the non-public billing endpoint.
2. Token-plan providers reuse the base URL and API key already stored in CC Switch's provider configuration. This is why CC Switch can query more plans after a provider has been configured there; it is not inferring quota from unrelated local session logs.

Direct token-plan endpoints in the compared CC Switch revision include:

- Kimi: `GET https://api.kimi.com/coding/v1/usages`, parsing `limits[].detail.resetTime` and `usage.resetTime`.
- Zhipu: `GET /api/monitor/usage/quota/limit`, using `unit` to distinguish the 5-hour and weekly windows and parsing `nextResetTime`.
- OpenCode Go: `GET https://opencode.ai/zen/go/v1/usage` with Bearer API-key authentication, parsing `usage.rolling|weekly|monthly.{percent,resetsAt}`.
- Grok: the same local OAuth plus non-public billing approach used by Vibe Bar.

CC Switch intentionally drops OpenCode Go's reset timestamp when a window is at 0%, because the upstream currently returns a placeholder `now + window length`, not a trustworthy cycle anchor. It also keeps the last successful quota for up to ten minutes only for transient failures.

## Important comparison

- Claude: CC Switch does **not** solve this machine's special case; it also ignores `cachedUsageUtilization` in `~/.claude.json`.
- OpenCode Go: CC Switch is materially ahead of the inherited Vibe Bar adapter. It uses the newer direct API-key endpoint instead of browser-cookie workspace scraping.
- Kimi and Zhipu: CC Switch succeeds when it owns or is given the provider API key. It does not generally discover every standalone CLI's private credential store.
- dsh: neither project has an independent dsh subscription reset. dsh quota belongs to whichever upstream provider it uses; for this product, dsh's OpenCode Go activity should share the OpenCode Go quota account.

## Recommended implementation for Code CLI Bar

Use a layered resolver per provider:

1. Read trustworthy reset metadata already cached by the native CLI (for example Claude's `~/.claude.json`).
2. Read native CLI credentials and call the provider quota endpoint.
3. Fall back to explicit import or browser credentials only when needed.
4. Persist the last trustworthy reset anchor and advance it by whole provider windows while offline.
5. Never infer an account reset from first/last local activity.

The highest-value first changes are Claude local-cache support and OpenCode Go's direct `/zen/go/v1/usage` path using the native `opencode-go` key.

## Primary sources

- Vibe Bar: `Sources/VibeBarCore/Adapters/ClaudeQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Credentials/ClaudeCredentialReader.swift`
- Vibe Bar: `Sources/VibeBarCore/Adapters/CodexQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Adapters/KimiQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Adapters/OpenCodeGoQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Adapters/GrokQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Adapters/ZaiQuotaAdapter.swift`
- Vibe Bar: `Sources/VibeBarCore/Services/QuotaService.swift`
- CC Switch: <https://github.com/farion1231/cc-switch/blob/d8065cc628fcd373d00c4363d718095f19e78c9e/src-tauri/src/services/subscription.rs>
- CC Switch: <https://github.com/farion1231/cc-switch/blob/d8065cc628fcd373d00c4363d718095f19e78c9e/src-tauri/src/services/coding_plan.rs>
- CC Switch: <https://github.com/farion1231/cc-switch/blob/d8065cc628fcd373d00c4363d718095f19e78c9e/src-tauri/src/services/subscription_grok.rs>
- CC Switch: <https://github.com/farion1231/cc-switch/blob/d8065cc628fcd373d00c4363d718095f19e78c9e/src-tauri/src/provider.rs>
- CC Switch: <https://github.com/farion1231/cc-switch/blob/d8065cc628fcd373d00c4363d718095f19e78c9e/src/lib/query/queries.ts>
- OpenCode issue documenting the API-key usage endpoint and local key context: <https://github.com/anomalyco/opencode/issues/42776>
