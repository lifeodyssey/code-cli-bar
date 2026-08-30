import Combine
import Foundation
import VibeBarCore

@MainActor
final class CodeCLIProviderDetectionService: ObservableObject {
    @Published private(set) var detections: [CodeCLIProvider: CodeCLIProviderDetection] = [:]
    @Published private(set) var isScanning = false

    private var scanTask: Task<Void, Never>?

    func refresh(settings: CodeCLIBarSettings, homeDirectory: String = RealHomeDirectory.path) {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) {
                Self.scan(settings: settings, homeDirectory: homeDirectory)
            }.value
            guard !Task.isCancelled, let self else { return }
            detections = result
            isScanning = false
        }
    }

    func detection(for provider: CodeCLIProvider) -> CodeCLIProviderDetection {
        detections[provider] ?? CodeCLIProviderDetection(provider: provider, detectedPath: nil)
    }

    private nonisolated static func scan(
        settings: CodeCLIBarSettings,
        homeDirectory: String
    ) -> [CodeCLIProvider: CodeCLIProviderDetection] {
        let fileManager = FileManager.default
        var result: [CodeCLIProvider: CodeCLIProviderDetection] = [:]
        for provider in CodeCLIProvider.allCases {
            let configuration = settings.configuration(for: provider)
            let configured = configuration.customUsagePath.map {
                resolvedPath($0, homeDirectory: homeDirectory)
            }
            let usageCandidates = configured.map { [$0] }
                ?? provider.defaultUsagePaths.map {
                    URL(fileURLWithPath: homeDirectory, isDirectory: true)
                        .appendingPathComponent($0)
                        .path
                }
            let detectedUsage = usageCandidates.first(where: fileManager.fileExists(atPath:))
            let detectedExecutable = executableCandidates(for: provider).first(
                where: fileManager.isExecutableFile(atPath:)
            )
            result[provider] = CodeCLIProviderDetection(
                provider: provider,
                detectedPath: detectedUsage ?? detectedExecutable
            )
        }
        return result
    }

    private nonisolated static func resolvedPath(
        _ path: String,
        homeDirectory: String
    ) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent(String(path.dropFirst(2)))
                .path
        }
        if path.hasPrefix("/") { return path }
        return URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(path)
            .path
    }

    private nonisolated static func executableCandidates(
        for provider: CodeCLIProvider
    ) -> [String] {
        let names: [String]
        switch provider {
        case .claudeCode: names = ["claude"]
        case .codex: names = ["codex"]
        case .openCodeGo: names = ["opencode"]
        case .kimiCode: names = ["kimi", "kimi-code"]
        case .zcode: names = ["zcode"]
        case .grokBuild: names = ["grok"]
        case .dsh: names = ["dsh"]
        }
        let roots = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
        return roots.flatMap { root in names.map { root + "/" + $0 } }
    }
}
