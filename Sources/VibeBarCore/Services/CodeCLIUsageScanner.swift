import Foundation
import SQLite3

/// Local-only scanners for the four stores that were not part of Vibe Bar.
/// The parsers extract an explicit allow-list of timestamps, model ids, token
/// counters, and provider-reported cost. Prompt/response content and project
/// paths never enter `ParsedEvent`, the scan cache, or the usage ledger.
enum CodeCLIUsageScanner {
    static func scan(
        tool: ToolType,
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)?,
        sourcePath: String? = nil
    ) async -> CostSnapshot? {
        switch tool {
        case .openCodeGo:
            let source = resolvedSource(
                sourcePath,
                homeDirectory: homeDirectory,
                defaultRelativePath: ".local/share/opencode/opencode.db"
            )
            return await scanSQLite(
                tool: tool,
                database: source,
                homeDirectory: homeDirectory,
                now: now,
                retentionDays: retentionDays,
                eventSink: eventSink,
                parser: parseOpenCode
            )
        case .zai:
            let source = resolvedSource(
                sourcePath,
                homeDirectory: homeDirectory,
                defaultRelativePath: ".zcode/cli/db/db.sqlite"
            )
            return await scanSQLite(
                tool: tool,
                database: source,
                homeDirectory: homeDirectory,
                now: now,
                retentionDays: retentionDays,
                eventSink: eventSink,
                parser: parseZCode
            )
        case .kimi:
            let root = resolvedSource(
                sourcePath,
                homeDirectory: homeDirectory,
                defaultRelativePath: ".kimi-code/sessions"
            )
            return await scanLineFiles(
                tool: tool,
                files: collectFiles(under: root, extensions: ["jsonl"]),
                homeDirectory: homeDirectory,
                now: now,
                retentionDays: retentionDays,
                eventSink: eventSink,
                parser: { Optional(parseKimi($0)) }
            )
        case .dsh:
            let root = resolvedSource(
                sourcePath,
                homeDirectory: homeDirectory,
                defaultRelativePath: ".dsh/sessions"
            )
            let decoder = dshZstdDecoder(homeDirectory: homeDirectory)
            return await scanLineFiles(
                tool: tool,
                files: collectFiles(under: root, extensions: ["jsonl", "zstd"]),
                homeDirectory: homeDirectory,
                now: now,
                retentionDays: retentionDays,
                eventSink: eventSink,
                parser: { parseDSH($0, decoder: decoder) }
            )
        case .codex, .claude, .alibaba, .alibabaTokenPlan, .gemini,
             .antigravity, .grok, .copilot, .minimax, .cursor, .mimo,
             .iflytek, .tencentHunyuan, .tencentTokenPlan, .volcengine,
             .volcengineAgentPlan, .baiduQianfan, .kilo, .kiro, .ollama,
             .openRouter, .warp:
            return nil
        }
    }

    // MARK: - Scan orchestration

    private typealias SQLiteParser = (URL) -> [CostUsageScanCache.ParsedEvent]
    /// A `nil` line parse means the source could not be read. Keeping failure
    /// distinct from an empty-but-valid history prevents a missing decoder
    /// from poisoning the fingerprint cache until the source file changes.
    private typealias LineParser = (URL) -> [CostUsageScanCache.ParsedEvent]?

    private static func scanSQLite(
        tool: ToolType,
        database: URL,
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)?,
        parser: SQLiteParser
    ) async -> CostSnapshot {
        guard regularFile(database) else {
            return CostUsageScanner.CostAggregator(tool: tool, now: now)
                .snapshot(jsonlFilesFound: 0)
        }

        var cache = CostUsageScanCache.load(
            homeDirectory: homeDirectory,
            tool: tool,
            retentionDays: retentionDays
        )
        let before = databaseFingerprint(database)
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)
        let events: [CostUsageScanCache.ParsedEvent]
        if let reused = cache.reusable(
            for: database.path,
            mtime: before.mtime,
            size: before.size
        ) {
            events = retained(reused, cutoff: cutoff)
        } else {
            events = retained(parser(database), cutoff: cutoff)
            let after = databaseFingerprint(database)
            cache.store(events, for: database.path, mtime: after.mtime, size: after.size)
        }
        cache.prune(known: [database.path])
        cache.save(homeDirectory: homeDirectory, tool: tool)

        let current = databaseFingerprint(database)
        await emit(
            eventSink,
            tool: tool,
            file: database,
            fingerprint: current,
            events: events
        )
        return aggregate(tool: tool, events: events, now: now, filesFound: 1)
    }

    private static func scanLineFiles(
        tool: ToolType,
        files: [URL],
        homeDirectory: String,
        now: Date,
        retentionDays: Int?,
        eventSink: (any CostUsageEventSink)?,
        parser: LineParser
    ) async -> CostSnapshot {
        var cache = CostUsageScanCache.load(
            homeDirectory: homeDirectory,
            tool: tool,
            retentionDays: retentionDays
        )
        let cutoff = retentionCutoff(now: now, retentionDays: retentionDays)
        var allEvents: [CostUsageScanCache.ParsedEvent] = []
        var filesRead = 0

        for file in files {
            let fingerprint = fileFingerprint(file)
            let events: [CostUsageScanCache.ParsedEvent]
            if let reused = cache.reusable(
                for: file.path,
                mtime: fingerprint.mtime,
                size: fingerprint.size
            ) {
                events = retained(reused, cutoff: cutoff)
            } else {
                guard let parsed = parser(file) else { continue }
                events = retained(parsed, cutoff: cutoff)
                cache.store(
                    events,
                    for: file.path,
                    mtime: fingerprint.mtime,
                    size: fingerprint.size
                )
            }
            filesRead += 1
            allEvents.append(contentsOf: events)
            await emit(
                eventSink,
                tool: tool,
                file: file,
                fingerprint: fingerprint,
                events: events
            )
        }

        cache.prune(known: Set(files.map(\.path)))
        cache.save(homeDirectory: homeDirectory, tool: tool)
        let deduped = deduplicate(allEvents, tool: tool)
        return aggregate(tool: tool, events: deduped, now: now, filesFound: filesRead)
    }

    private static func aggregate(
        tool: ToolType,
        events: [CostUsageScanCache.ParsedEvent],
        now: Date,
        filesFound: Int
    ) -> CostSnapshot {
        var aggregator = CostUsageScanner.CostAggregator(tool: tool, now: now)
        for event in events {
            aggregator.add(
                at: event.date,
                model: event.model,
                input: event.input,
                output: event.output,
                cache: event.cache,
                optionalCostUSD: CodeCLIUsagePricing.costUSD(tool: tool, event: event)
            )
        }
        return aggregator.snapshot(jsonlFilesFound: filesFound)
    }

    private static func emit(
        _ sink: (any CostUsageEventSink)?,
        tool: ToolType,
        file: URL,
        fingerprint: Fingerprint,
        events: [CostUsageScanCache.ParsedEvent]
    ) async {
        guard let sink else { return }
        let priced = events.map {
            PricedUsageEvent(
                event: $0,
                costUSD: CodeCLIUsagePricing.costUSD(tool: tool, event: $0)
            )
        }
        await sink.consume(
            UsageEventFileBatch(
                tool: tool,
                filePath: file.path,
                mtime: fingerprint.mtime,
                size: fingerprint.size,
                events: priced
            )
        )
    }

    // MARK: - OpenCode Go

    private static func parseOpenCode(_ database: URL) -> [CostUsageScanCache.ParsedEvent] {
        guard let db = openReadOnly(database) else { return [] }
        defer { sqlite3_close(db) }
        let sql = "SELECT id, session_id, time_created, data FROM message ORDER BY time_created, id"
        guard let statement = prepare(sql, in: db) else { return [] }
        defer { sqlite3_finalize(statement) }

        var events: [CostUsageScanCache.ParsedEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let rawData = columnString(statement, 3)?.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: rawData)) as? [String: Any],
                  object["role"] as? String == "assistant",
                  object["providerID"] as? String == "opencode-go",
                  let tokens = object["tokens"] as? [String: Any]
            else { continue }

            let input = nonnegativeInt(tokens["input"])
            let output = nonnegativeInt(tokens["output"]) + nonnegativeInt(tokens["reasoning"])
            let cache = tokens["cache"] as? [String: Any]
            let cacheRead = nonnegativeInt(cache?["read"])
            let cacheWrite = nonnegativeInt(cache?["write"])
            guard input + output + cacheRead + cacheWrite > 0 else { continue }

            let time = object["time"] as? [String: Any]
            let fallbackTime = sqlite3_column_int64(statement, 2)
            let date = dateFromUnixMilliseconds(
                int64(time?["completed"] ?? time?["created"]),
                fallback: fallbackTime
            )
            let message = columnString(statement, 0) ?? ""
            let session = columnString(statement, 1) ?? ""
            let requestKey = opaque(
                prefix: "opencode-request-v1",
                raw: "\(session.utf8.count):\(session)|\(message)"
            )
            events.append(
                CostUsageScanCache.ParsedEvent(
                    date: date,
                    model: nonempty(object["modelID"] as? String) ?? "unknown",
                    input: input,
                    output: output,
                    cache: cacheRead + cacheWrite,
                    cacheCreation: cacheWrite,
                    reportedCostUSD: nonnegativeDouble(object["cost"]),
                    sessionId: opaque(prefix: "opencode-session-v1", raw: session),
                    messageId: opaque(prefix: "opencode-message-v1", raw: message),
                    requestId: requestKey,
                    sourceKey: opaque(prefix: "opencode-db-v1", raw: database.path)
                )
            )
        }
        return events
    }

    // MARK: - ZCode

    private static func parseZCode(_ database: URL) -> [CostUsageScanCache.ParsedEvent] {
        guard let db = openReadOnly(database) else { return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, session_id, model_id, started_at, input_tokens,
                   output_tokens, reasoning_tokens, cache_creation_input_tokens,
                   cache_read_input_tokens
              FROM model_usage
             WHERE status != 'running'
             ORDER BY started_at, id
            """
        guard let statement = prepare(sql, in: db) else { return [] }
        defer { sqlite3_finalize(statement) }

        var events: [CostUsageScanCache.ParsedEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let totalInput = nonnegativeInt(sqlite3_column_int64(statement, 4))
            let output = nonnegativeInt(sqlite3_column_int64(statement, 5))
                + nonnegativeInt(sqlite3_column_int64(statement, 6))
            let cacheCreation = nonnegativeInt(sqlite3_column_int64(statement, 7))
            let cacheRead = nonnegativeInt(sqlite3_column_int64(statement, 8))
            let freshInput = max(0, totalInput - cacheCreation - cacheRead)
            guard totalInput + output > 0 else { continue }

            let identifier = columnString(statement, 0) ?? ""
            let session = columnString(statement, 1) ?? ""
            events.append(
                CostUsageScanCache.ParsedEvent(
                    date: dateFromUnixMilliseconds(sqlite3_column_int64(statement, 3)),
                    model: nonempty(columnString(statement, 2)) ?? "unknown",
                    input: freshInput,
                    output: output,
                    cache: cacheCreation + cacheRead,
                    cacheCreation: cacheCreation,
                    sessionId: opaque(prefix: "zcode-session-v1", raw: session),
                    messageId: opaque(prefix: "zcode-usage-v1", raw: identifier),
                    requestId: opaque(prefix: "zcode-request-v1", raw: identifier),
                    sourceKey: opaque(prefix: "zcode-db-v1", raw: database.path)
                )
            )
        }
        return events
    }

    // MARK: - Kimi Code

    private static func parseKimi(_ file: URL) -> [CostUsageScanCache.ParsedEvent] {
        var events: [CostUsageScanCache.ParsedEvent] = []
        var lineNumber = 0
        _ = CostUsageScanner.forEachJSONLLine(in: file) { data in
            defer { lineNumber += 1 }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["type"] as? String == "usage.record",
                  object["usageScope"] as? String == "turn",
                  let usage = object["usage"] as? [String: Any]
            else { return }

            let input = nonnegativeInt(usage["inputOther"])
            let output = nonnegativeInt(usage["output"])
            let cacheRead = nonnegativeInt(usage["inputCacheRead"])
            let cacheCreation = nonnegativeInt(usage["inputCacheCreation"])
            guard input + output + cacheRead + cacheCreation > 0 else { return }

            let time = int64(object["time"])
            let agent = object["agentId"] as? String ?? ""
            let signature = [
                file.path, String(lineNumber), String(time), agent,
                String(input), String(output), String(cacheRead), String(cacheCreation)
            ].joined(separator: "|")
            events.append(
                CostUsageScanCache.ParsedEvent(
                    date: dateFromUnixMilliseconds(time, fallback: fileMTimeMilliseconds(file)),
                    model: nonempty(object["model"] as? String) ?? "unknown",
                    input: input,
                    output: output,
                    cache: cacheRead + cacheCreation,
                    cacheCreation: cacheCreation,
                    sessionId: opaque(prefix: "kimi-agent-v1", raw: agent),
                    requestId: opaque(prefix: "kimi-request-v1", raw: signature),
                    sourceKey: opaque(prefix: "kimi-file-v1", raw: file.path)
                )
            )
        }
        return events
    }

    // MARK: - dsh

    private enum DSHZstdDecoder {
        case standalone(URL)
        case node(executable: URL, helper: URL)
    }

    private static func parseDSH(
        _ file: URL,
        decoder: DSHZstdDecoder?
    ) -> [CostUsageScanCache.ParsedEvent]? {
        var events: [CostUsageScanCache.ParsedEvent] = []
        var currentModel = "unknown"
        var currentProvider = "unknown"
        var session = ""
        var lineNumber = 0

        let consume: (Data) -> Void = { data in
            defer { lineNumber += 1 }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }
            let type = object["type"] as? String
            if type == "session" {
                session = object["id"] as? String ?? session
                return
            }
            if type == "request/context", let context = object["data"] as? [String: Any] {
                currentModel = nonempty(context["model"] as? String) ?? currentModel
                currentProvider = nonempty(context["provider"] as? String) ?? currentProvider
                return
            }
            guard type == "assistant/message",
                  let payload = object["data"] as? [String: Any],
                  let usage = payload["usage"] as? [String: Any]
            else { return }

            let input = nonnegativeInt(usage["inputTokens"])
            let output = nonnegativeInt(usage["outputTokens"])
                + nonnegativeInt(usage["reasoningTokens"])
            let cacheRead = nonnegativeInt(usage["cacheReadTokens"])
            let cacheCreation = nonnegativeInt(usage["cacheCreationTokens"])
            guard input + output + cacheRead + cacheCreation > 0 else { return }

            let message = (payload["message"] as? [String: Any])?["id"] as? String ?? ""
            let stableMessage = message.isEmpty ? "line:\(lineNumber)" : message
            let tuple = "\(session.utf8.count):\(session)|\(stableMessage)"
            events.append(
                CostUsageScanCache.ParsedEvent(
                    date: dateFromUnixMilliseconds(
                        int64(object["time"]),
                        fallback: fileMTimeMilliseconds(file)
                    ),
                    model: currentModel,
                    modelFallback: currentProvider,
                    input: input,
                    output: output,
                    cache: cacheRead + cacheCreation,
                    cacheCreation: cacheCreation,
                    sessionId: opaque(prefix: "dsh-session-v1", raw: session),
                    messageId: opaque(prefix: "dsh-message-v1", raw: stableMessage),
                    requestId: opaque(prefix: "dsh-request-v1", raw: tuple),
                    sourceKey: opaque(prefix: "dsh-file-v1", raw: file.path)
                )
            )
        }

        let didRead: Bool
        if file.pathExtension == "zstd" {
            guard let decoder else { return nil }
            didRead = forEachZstdLine(in: file, decoder: decoder, consume)
        } else {
            didRead = CostUsageScanner.forEachJSONLLine(in: file, consume)
        }
        return didRead ? events : nil
    }

    /// Streams decompressed bytes instead of materializing large dsh sessions
    /// (individual files can expand to hundreds of MB).
    @discardableResult
    private static func forEachZstdLine(
        in file: URL,
        decoder: DSHZstdDecoder,
        _ body: (Data) -> Void
    ) -> Bool {
        let process = Process()
        switch decoder {
        case let .standalone(binary):
            process.executableURL = binary
            process.arguments = ["-q", "-d", "-c", "--", file.path]
        case let .node(executable, helper):
            process.executableURL = executable
            process.arguments = [helper.path, file.path]
        }
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardInput = nil
        do { try process.run() } catch { return false }

        var buffer = Data()
        while true {
            guard let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024),
                  !chunk.isEmpty
            else { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                if !line.isEmpty { body(Data(line)) }
                buffer.removeSubrange(...newline)
            }
        }
        if !buffer.isEmpty { body(buffer) }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Helpers

    private struct Fingerprint {
        let mtime: Date
        let size: Int64
    }

    private static func resolvedSource(
        _ override: String?,
        homeDirectory: String,
        defaultRelativePath: String
    ) -> URL {
        if let override = nonempty(override) {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        return URL(fileURLWithPath: homeDirectory).appendingPathComponent(defaultRelativePath)
    }

    private static func collectFiles(under source: URL, extensions: Set<String>) -> [URL] {
        if regularFile(source) {
            return extensions.contains(source.pathExtension.lowercased()) ? [source] : []
        }
        guard FileManager.default.fileExists(atPath: source.path),
              let enumerator = FileManager.default.enumerator(
                  at: source,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: [.skipsHiddenFiles]
              )
        else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator {
            guard extensions.contains(file.pathExtension.lowercased()) else { continue }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile != false, values?.isSymbolicLink != true else { continue }
            files.append(file)
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func regularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func fileFingerprint(_ url: URL) -> Fingerprint {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return Fingerprint(mtime: .distantPast, size: 0)
        }
        return Fingerprint(
            mtime: attributes[.modificationDate] as? Date ?? .distantPast,
            size: (attributes[.size] as? NSNumber)?.int64Value ?? 0
        )
    }

    /// SQLite can keep recent writes in `-wal` without touching the main db.
    /// Include that sidecar so a minute refresh never reuses a stale snapshot.
    private static func databaseFingerprint(_ database: URL) -> Fingerprint {
        let databasePart = fileFingerprint(database)
        let walPart = fileFingerprint(URL(fileURLWithPath: database.path + "-wal"))
        return Fingerprint(
            mtime: max(databasePart.mtime, walPart.mtime),
            size: databasePart.size &+ walPart.size
        )
    }

    private static func retentionCutoff(now: Date, retentionDays: Int?) -> Date? {
        guard let retentionDays else { return nil }
        let days = CostDataSettings.normalizedRetentionDays(retentionDays)
        guard days > 0 else { return nil }
        let today = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: -(days - 1), to: today)
    }

    private static func retained(
        _ events: [CostUsageScanCache.ParsedEvent],
        cutoff: Date?
    ) -> [CostUsageScanCache.ParsedEvent] {
        guard let cutoff else { return events }
        return events.filter { $0.date >= cutoff }
    }

    private static func deduplicate(
        _ events: [CostUsageScanCache.ParsedEvent],
        tool: ToolType
    ) -> [CostUsageScanCache.ParsedEvent] {
        guard tool == .dsh else { return events }
        var seen: Set<String> = []
        return events.filter { event in
            guard let key = event.requestId else { return true }
            return seen.insert(key).inserted
        }
    }

    private static func openReadOnly(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        sqlite3_busy_timeout(database, 2_000)
        return database
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        return statement
    }

    private static func columnString(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    private static func dshZstdDecoder(homeDirectory: String) -> DSHZstdDecoder? {
        let standalone = executablePaths(named: "zstd", homeDirectory: homeDirectory)
            .first(where: FileManager.default.isExecutableFile(atPath:))
        if let standalone {
            return .standalone(URL(fileURLWithPath: standalone))
        }

        guard let helper = Bundle.module.url(
            forResource: "dsh-zstd-decode",
            withExtension: "mjs"
        ) else { return nil }
        for path in nodePaths(homeDirectory: homeDirectory)
        where FileManager.default.isExecutableFile(atPath: path) {
            let executable = URL(fileURLWithPath: path)
            if nodeSupportsZstd(executable) {
                return .node(executable: executable, helper: helper)
            }
        }
        return nil
    }

    private static func executablePaths(named name: String, homeDirectory: String) -> [String] {
        var paths = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "\(homeDirectory)/.local/bin/\(name)",
            "\(homeDirectory)/.volta/bin/\(name)",
            "\(homeDirectory)/.asdf/shims/\(name)",
            "\(homeDirectory)/.nodenv/shims/\(name)",
            "\(homeDirectory)/.local/share/mise/shims/\(name)"
        ]
        if let environmentPath = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: environmentPath.split(separator: ":").map {
                String($0) + "/" + name
            })
        }
        return unique(paths)
    }

    private static func nodePaths(homeDirectory: String) -> [String] {
        var paths = executablePaths(named: "node", homeDirectory: homeDirectory)
        paths.append(contentsOf: [
            "\(homeDirectory)/.fnm/aliases/default/bin/node",
            "\(homeDirectory)/.local/share/fnm/aliases/default/bin/node",
            "/opt/homebrew/opt/node/bin/node",
            "/usr/local/opt/node/bin/node"
        ])

        let versionRoots = [
            "\(homeDirectory)/.nvm/versions/node",
            "\(homeDirectory)/.fnm/node-versions",
            "\(homeDirectory)/.local/share/fnm/node-versions"
        ]
        for root in versionRoots {
            guard let versions = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for version in versions.sorted(by: numericVersionDescending) {
                paths.append(version.appendingPathComponent("bin/node").path)
                paths.append(version.appendingPathComponent("installation/bin/node").path)
            }
        }
        return unique(paths)
    }

    private static func numericVersionDescending(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.numeric, .caseInsensitive]
        ) == .orderedDescending
    }

    private static func unique(_ paths: [String]) -> [String] {
        var seen: Set<String> = []
        return paths.filter { seen.insert($0).inserted }
    }

    private static func nodeSupportsZstd(_ executable: URL) -> Bool {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "-e",
            "const z=require('node:zlib');process.exit(typeof z.zstdDecompressSync==='function'?0:1)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func dateFromUnixMilliseconds(_ milliseconds: Int64, fallback: Int64? = nil) -> Date {
        let value = milliseconds > 0 ? milliseconds : (fallback ?? 0)
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: Double(value) / 1_000)
        }
        if value > 0 { return Date(timeIntervalSince1970: Double(value)) }
        return .distantPast
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return 0
    }

    private static func nonnegativeInt(_ value: Any?) -> Int {
        let value = int64(value)
        if value <= 0 { return 0 }
        return value > Int64(Int.max) ? Int.max : Int(value)
    }

    private static func nonnegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func opaque(prefix: String, raw: String) -> String {
        PrivacyPreservingHash.fileComponent(prefix: prefix, rawValue: raw)
    }

    private static func fileMTimeMilliseconds(_ file: URL) -> Int64 {
        let date = fileFingerprint(file).mtime
        return Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}
