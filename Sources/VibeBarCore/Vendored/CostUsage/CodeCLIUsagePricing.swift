import Foundation

/// Narrow pricing table for the local stores added by Code CLI Bar.
///
/// Values are USD per million tokens. Provider-reported costs always win;
/// this table is only an API/plan-equivalent estimate for logs that contain
/// token counters but no money field. Unknown models intentionally return
/// `nil` so callers can surface incomplete pricing coverage.
enum CodeCLIUsagePricing {
    private struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheCreation: Double
    }

    static let dataUpdatedAt = "2026-08-30"

    static func canPrice(tool: ToolType, model: String) -> Bool {
        rate(tool: tool, model: model) != nil
    }

    static func costUSD(
        tool: ToolType,
        event: CostUsageScanCache.ParsedEvent
    ) -> Double? {
        if let reported = event.reportedCostUSD,
           reported.isFinite,
           reported >= 0 {
            return reported
        }

        guard let rate = rate(tool: tool, model: event.model) else { return nil }
        let cacheCreation = max(0, min(event.cache, event.cacheCreation ?? 0))
        let cacheRead = max(0, event.cache - cacheCreation)
        let total = Double(max(0, event.input)) * rate.input
            + Double(max(0, event.output)) * rate.output
            + Double(cacheRead) * rate.cacheRead
            + Double(cacheCreation) * rate.cacheCreation
        return total / 1_000_000
    }

    private static func rate(tool: ToolType, model rawModel: String) -> Rate? {
        let model = normalize(rawModel)
        switch tool {
        case .kimi:
            // Kimi Code currently records `kimi-code/k3`.
            if model == "k3" || model == "kimi-k3" || model == "kimi-code-k3" {
                return Rate(input: 3, output: 15, cacheRead: 0.3, cacheCreation: 3)
            }
            if model == "kimi-k2.7-code" {
                return Rate(input: 0.95, output: 4, cacheRead: 0.19, cacheCreation: 0.95)
            }
            if model == "kimi-k2.6" {
                return Rate(input: 0.95, output: 4, cacheRead: 0.16, cacheCreation: 0.95)
            }
        case .zai:
            // Current public Z.ai API prices. GLM-5.3-Flash is deliberately
            // absent until its official per-token price is published.
            if model == "glm-5.1" || model == "glm-5.2" {
                return Rate(input: 1.4, output: 4.4, cacheRead: 0.26, cacheCreation: 1.4)
            }
            if model == "glm-5" {
                return Rate(input: 1, output: 3.2, cacheRead: 0.2, cacheCreation: 1)
            }
        case .dsh:
            // dsh's OpenCode Go profile exposes these accounting rates in its
            // model catalog. They estimate the same dollar-denominated quota
            // consumed by the provider, rather than the subscription fee.
            if model == "deepseek-v4-flash" {
                return Rate(input: 0.14, output: 0.28, cacheRead: 0.0028, cacheCreation: 0.14)
            }
            if model == "deepseek-v4-pro" {
                return Rate(input: 1.74, output: 3.84, cacheRead: 0.145, cacheCreation: 1.74)
            }
        case .openCodeGo:
            // Modern OpenCode rows carry `data.cost`; no fallback is safer
            // than guessing when an older row does not.
            break
        case .codex, .claude, .alibaba, .alibabaTokenPlan, .gemini,
             .antigravity, .grok, .copilot, .minimax, .cursor, .mimo,
             .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine,
             .volcengineAgentPlan, .baiduQianfan, .kilo, .kiro, .ollama,
             .openRouter, .warp:
            break
        }
        return nil
    }

    private static func normalize(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
