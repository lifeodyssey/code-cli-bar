import Combine
import Foundation

@MainActor
public final class CodeCLIBarSettingsStore: ObservableObject {
    @Published public var settings: CodeCLIBarSettings {
        didSet { persist() }
    }

    private let url: URL

    public init(url: URL = VibeBarLocalStore.codeCLIBarSettingsURL) {
        self.url = url
        self.settings = (try? VibeBarLocalStore.readJSON(
            CodeCLIBarSettings.self,
            from: url
        )) ?? .default
        persist()
    }

    public func configuration(for provider: CodeCLIProvider) -> CodeCLIProviderConfiguration {
        settings.configuration(for: provider)
    }

    public func update(
        _ provider: CodeCLIProvider,
        _ change: (inout CodeCLIProviderConfiguration) -> Void
    ) {
        var configuration = settings.configuration(for: provider)
        change(&configuration)
        settings.setConfiguration(configuration, for: provider)
    }

    public func flush() {
        persist()
    }

    private func persist() {
        do {
            try VibeBarLocalStore.writeJSON(settings, to: url)
        } catch {
            SafeLog.warn("Saving Code CLI Bar settings failed: \(SafeLog.sanitize(error.localizedDescription))")
        }
    }
}
